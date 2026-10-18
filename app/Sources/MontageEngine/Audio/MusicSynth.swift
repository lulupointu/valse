import Foundation

// Procedural music synthesizer behind `MusicLibrary` (AU-001 substitute): a tiny "arranger" turns a track descriptor
// (genre style, key, progression, seed) into notes and drum hits, and a set of cheap voices (FM e-piano, bells,
// Karplus-Strong guitar, polyBLEP saws/pulses, pads, 808, synth drums) renders them into float buses, followed by a
// reverb/delay send, sidechain pumping, compressor, soft clipper, fades and peak normalization.
// Everything is deterministic (seeded RNG, no system randomness) and allocation-free in the per-sample loops.

// MARK: - RNG

struct MusicRNG {
    var s: UInt64
    init(_ seed: UInt64) { s = seed ^ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        s &+= 0x9E37_79B9_7F4A_7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
    mutating func chance(_ p: Double) -> Bool { unit() < p }
    mutating func pick<T>(_ a: [T]) -> T { a[int(a.count)] }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * unit() }
}

/// Stable string hash (String.hashValue is randomized per process).
func musicSeed(_ s: String) -> UInt64 {
    var h: UInt64 = 0xCBF2_9CE4_8422_2325
    for b in s.utf8 { h ^= UInt64(b); h = h &* 0x0000_0100_0000_01B3 }
    return h
}

/// Cheap per-voice white noise.
struct Noise32 {
    var s: UInt32
    init(_ seed: UInt32) { s = seed == 0 ? 0x1234_5678 : seed }
    @inline(__always) mutating func next() -> Float {
        s ^= s << 13; s ^= s >> 17; s ^= s << 5
        return Float(s) * (2.0 / 4_294_967_296.0) - 1
    }
}

// MARK: - Events

enum MusicInst: Sendable {
    case epiano, bell, pluck, guitar, pad, strings, organ, lead, brass, square, pulse, triangle, flute
    case sineBass, sawBass, sub808, upright
}

enum DrumKind: Sendable { case kick, snare, clap, hat, openHat, crash, ride, shaker, rim, taiko, chipKick, chipSnare, chipHat, brush }

struct MusicNote {
    var start: Double
    var length: Double
    var midi: Double
    var velocity: Float
    var inst: MusicInst
    var pan: Float = 0
    var reverb: Float = 0.2
    var delay: Float = 0
}

struct DrumHit {
    var time: Double
    var kind: DrumKind
    var velocity: Float
    var pan: Float = 0
}

/// Stereo bus plus mono reverb and delay sends (the drum bus shares the music bus's sends).
final class MusicBus {
    let n: Int
    let L: UnsafeMutablePointer<Float>
    let R: UnsafeMutablePointer<Float>
    let S: UnsafeMutablePointer<Float>
    let D: UnsafeMutablePointer<Float>
    private let ownsSends: Bool

    init(frames: Int, sharing other: MusicBus? = nil) {
        n = frames
        func alloc() -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: max(frames, 1))
            p.initialize(repeating: 0, count: max(frames, 1))
            return p
        }
        L = alloc(); R = alloc()
        if let other { S = other.S; D = other.D; ownsSends = false } else { S = alloc(); D = alloc(); ownsSends = true }
    }

    deinit {
        L.deallocate(); R.deallocate()
        if ownsSends { S.deallocate(); D.deallocate() }
    }
}

/// Per-note output gains (pan law applied).
struct VoiceGains {
    var l: Float, r: Float, s: Float, d: Float
    init(velocity v: Float, pan: Float, reverb: Float, delay: Float) {
        let a = (max(-1, min(1, pan)) + 1) * Float.pi / 4
        l = v * cos(a) * 1.414; r = v * sin(a) * 1.414; s = v * reverb; d = v * delay
    }
}

// MARK: - Voices

enum MusicVoices {
    static let sr: Float = 48000
    static let twoPi: Float = 2 * .pi

    @inline(__always) static func hz(_ midi: Double) -> Float { Float(440 * pow(2, (midi - 69) / 12)) }

    @inline(__always) static func put(_ b: MusicBus, _ i: Int, _ v: Float, _ g: VoiceGains) {
        b.L[i] += v * g.l; b.R[i] += v * g.r; b.S[i] += v * g.s; b.D[i] += v * g.d
    }

    @inline(__always) static func blep(_ t: Float, _ dt: Float) -> Float {
        if t < dt { let x = t / dt; return x + x - x * x - 1 }
        if t > 1 - dt { let x = (t - 1) / dt; return x * x + x + x + 1 }
        return 0
    }

    @inline(__always) static func coef(_ cutoff: Float) -> Float { 1 - exp(-twoPi * min(cutoff, 20000) / sr) }

    static func release(_ inst: MusicInst) -> Double {
        switch inst {
        case .pad: return 1.2
        case .strings: return 0.6
        case .epiano, .bell, .guitar: return 0.35
        case .pluck: return 0.15
        case .brass, .lead, .flute: return 0.15
        case .organ: return 0.08
        case .square, .pulse, .triangle: return 0.03
        case .sineBass, .sawBass, .upright: return 0.08
        case .sub808: return 0.12
        }
    }

    static func render(_ n: MusicNote, into b: MusicBus, seed: UInt32) {
        let start = Int(n.start * Double(sr))
        guard start < b.n, start >= 0 else { return }
        let gate = max(1, Int(n.length * Double(sr)))
        let rel = max(1, Int(release(n.inst) * Double(sr)))
        let end = min(b.n, start + gate + rel)
        let f = hz(n.midi)
        let g = VoiceGains(velocity: n.velocity, pan: n.pan, reverb: n.reverb, delay: n.delay)
        let ctx = VoiceSpan(start: start, gate: gate, rel: rel, end: end)
        switch n.inst {
        case .epiano: fm(b, ctx, f, g, ratio: 1, index: 1.6, indexTau: 0.35, tau: 1.6 * pow(261 / f, 0.35), level: 0.55)
        case .bell: fm(b, ctx, f, g, ratio: 3.5, index: 2.2, indexTau: 0.5, tau: 1.8 * pow(523 / f, 0.3), level: 0.4)
        case .pluck: pluck(b, ctx, f, g)
        case .guitar: karplus(b, ctx, f, g, seed: seed)
        case .pad: pad(b, ctx, f, g, attack: 0.5, cutoff: 1600, vibrato: 0, level: 0.22)
        case .strings: pad(b, ctx, f, g, attack: 0.25, cutoff: 2800, vibrato: 0.004, level: 0.22)
        case .organ: organ(b, ctx, f, g)
        case .lead: saw(b, ctx, f, g, cutoff: 3200, envCutoff: 2500, attack: 0.008, sustain: 0.75, vibrato: 0.005, level: 0.32)
        case .brass: saw(b, ctx, f, g, cutoff: 900, envCutoff: 2200, attack: 0.06, sustain: 0.85, vibrato: 0.004, level: 0.35)
        case .square: pulse(b, ctx, f, g, duty: 0.25, level: 0.22)
        case .pulse: pulse(b, ctx, f, g, duty: 0.5, level: 0.2)
        case .triangle: triangle(b, ctx, f, g)
        case .flute: flute(b, ctx, f, g, seed: seed)
        case .sineBass: sineBass(b, ctx, f, g, drive: 1.6, tau: 0, level: 0.6)
        case .upright: sineBass(b, ctx, f, g, drive: 2.2, tau: 0.45, level: 0.7)
        case .sawBass: saw(b, ctx, f, g, cutoff: 500, envCutoff: 900, attack: 0.003, sustain: 0.7, vibrato: 0, level: 0.45, sub: 0.5)
        case .sub808: sub808(b, ctx, f, g)
        }
    }

    struct VoiceSpan { let start: Int, gate: Int, rel: Int, end: Int }

    /// Two-operator FM (e-piano, bells): exponential amplitude and index decay.
    static func fm(_ b: MusicBus, _ c: VoiceSpan, _ f: Float, _ g: VoiceGains, ratio: Float, index: Float, indexTau: Float, tau: Float, level: Float) {
        let inc = f / sr, minc = f * ratio / sr
        let dk = exp(-1 / (tau * sr)), ik = exp(-1 / (indexTau * sr))
        let att = Int(0.003 * sr)
        var pc: Float = 0, pm: Float = 0, amp: Float = 1, idx = index, rg: Float = 1
        let rstep = 1 / Float(c.rel)
        for i in c.start..<c.end {
            let k = i - c.start
            if k >= c.gate { rg -= rstep; if rg <= 0 { break } }
            let a = k < att ? Float(k) / Float(att) : 1
            let v = sin(twoPi * pc + idx * sin(twoPi * pm)) * amp * a * rg * level
            put(b, i, v, g)
            pc += inc; if pc >= 1 { pc -= 1 }
            pm += minc; if pm >= 1 { pm -= 1 }
            amp *= dk; idx = idx * ik + 0.08 * (1 - ik)
        }
    }

    /// Synth pluck: polyBLEP saw through a 2-pole low-pass whose cutoff decays.
    static func pluck(_ b: MusicBus, _ c: VoiceSpan, _ f: Float, _ g: VoiceGains) {
        let dt = f / sr
        var p: Float = 0, y1: Float = 0, y2: Float = 0, amp: Float = 1, cut: Float = 7000, rg: Float = 1
        let dk = exp(-1 / (0.32 * sr)), ck = exp(-1 / (0.08 * sr))
        let rstep = 1 / Float(c.rel)
        for i in c.start..<c.end {
            let k = i - c.start
            if k >= c.gate { rg -= rstep; if rg <= 0 { break } }
            let x = 2 * p - 1 - blep(p, dt)
            let a = coef(cut + 300)
            y1 += a * (x - y1); y2 += a * (y1 - y2)
            let att: Float = k < 96 ? Float(k) / 96 : 1
            put(b, i, y2 * amp * att * rg * 0.35, g)
            p += dt; if p >= 1 { p -= 1 }
            amp *= dk; cut *= ck
        }
    }

    /// Karplus-Strong plucked string (acoustic guitar).
    static func karplus(_ b: MusicBus, _ c: VoiceSpan, _ f: Float, _ g: VoiceGains, seed: UInt32) {
        let n = max(2, Int(sr / f))
        let buf = UnsafeMutablePointer<Float>.allocate(capacity: n)
        defer { buf.deallocate() }
        var noise = Noise32(seed &* 2_654_435_761 &+ UInt32(n))
        var lp: Float = 0
        for j in 0..<n { lp += 0.5 * (noise.next() - lp); buf[j] = lp }
        var idx = 0, rg: Float = 1
        let rstep = 1 / Float(c.rel)
        let damp: Float = 0.4985
        for i in c.start..<c.end {
            let k = i - c.start
            if k >= c.gate { rg -= rstep; if rg <= 0 { break } }
            let v = buf[idx]
            let nx = idx + 1 == n ? 0 : idx + 1
            buf[idx] = (v + buf[nx]) * damp
            idx = nx
            put(b, i, v * rg * 0.9, g)
        }
    }

    /// Detuned 3-saw pad / string section with slow attack.
    static func pad(_ b: MusicBus, _ c: VoiceSpan, _ f: Float, _ g: VoiceGains, attack: Float, cutoff: Float, vibrato: Float, level: Float) {
        let d0 = f / sr, d1 = d0 * 1.0046, d2 = d0 * 0.9954
        var p0: Float = 0, p1: Float = 0.33, p2: Float = 0.66, y1: Float = 0, y2: Float = 0, rg: Float = 1, vp: Float = 0
        let a = coef(cutoff * pow(f / 261, 0.3)), att = attack * sr, rstep = 1 / Float(c.rel), vinc = 5.2 / sr
        for i in c.start..<c.end {
            let k = i - c.start
            if k >= c.gate { rg -= rstep; if rg <= 0 { break } }
            let vib = vibrato == 0 ? 1 : 1 + vibrato * sin(twoPi * vp)
            let x = (2 * p0 - 1 - blep(p0, d0)) + (2 * p1 - 1 - blep(p1, d1)) + (2 * p2 - 1 - blep(p2, d2))
            y1 += a * (x - y1); y2 += a * (y1 - y2)
            let e = Float(k) < att ? Float(k) / att : 1
            put(b, i, y2 * e * rg * level, g)
            p0 += d0 * vib; if p0 >= 1 { p0 -= 1 }
            p1 += d1 * vib; if p1 >= 1 { p1 -= 1 }
            p2 += d2 * vib; if p2 >= 1 { p2 -= 1 }
            vp += vinc; if vp >= 1 { vp -= 1 }
        }
    }

    static func organ(_ b: MusicBus, _ c: VoiceSpan, _ f: Float, _ g: VoiceGains) {
        let inc = f / sr
        var p: Float = 0, rg: Float = 1
        let rstep = 1 / Float(c.rel), att = 0.01 * sr
        for i in c.start..<c.end {
            let k = i - c.start
            if k >= c.gate { rg -= rstep; if rg <= 0 { break } }
            let w = twoPi * p
            let x = sin(w) + 0.5 * sin(2 * w) + 0.28 * sin(3 * w) + 0.15 * sin(4 * w)
            let e = Float(k) < att ? Float(k) / att : 1
            put(b, i, x * e * rg * 0.22, g)
            p += inc; if p >= 1 { p -= 1 }
        }
    }

    /// Filtered saw (lead, brass, bass) with filter envelope, optional sub sine and delayed vibrato.
    static func saw(_ b: MusicBus, _ c: VoiceSpan, _ f: Float, _ g: VoiceGains, cutoff: Float, envCutoff: Float, attack: Float,
                    sustain: Float, vibrato: Float, level: Float, sub: Float = 0) {
        let dt = f / sr
        var p: Float = 0, ps: Float = 0, y1: Float = 0, y2: Float = 0, rg: Float = 1, vp: Float = 0, fe: Float = 1
        let att = max(1, attack * sr), rstep = 1 / Float(c.rel), fk = exp(-1 / (0.18 * sr)), vinc = 5.5 / sr
        let vibStart = Int(0.25 * sr)
        for i in c.start..<c.end {
            let k = i - c.start
            if k >= c.gate { rg -= rstep; if rg <= 0 { break } }
            let vib: Float = (vibrato > 0 && k > vibStart) ? 1 + vibrato * sin(twoPi * vp) : 1
            var x = 2 * p - 1 - blep(p, dt)
            if sub > 0 { x += sub * sin(twoPi * ps) }
            let a = coef(cutoff + envCutoff * fe)
            y1 += a * (x - y1); y2 += a * (y1 - y2)
            let e: Float = Float(k) < att ? Float(k) / att : sustain + (1 - sustain) * fe
            put(b, i, y2 * e * rg * level, g)
            p += dt * vib; if p >= 1 { p -= 1 }
            ps += dt * 0.5; if ps >= 1 { ps -= 1 }
            vp += vinc; if vp >= 1 { vp -= 1 }
            fe *= fk
        }
    }

    static func pulse(_ b: MusicBus, _ c: VoiceSpan, _ f: Float, _ g: VoiceGains, duty: Float, level: Float) {
        let dt = f / sr
        var p: Float = 0, rg: Float = 1
        let rstep = 1 / Float(c.rel)
        for i in c.start..<c.end {
            let k = i - c.start
            if k >= c.gate { rg -= rstep; if rg <= 0 { break } }
            var x: Float = p < duty ? 1 : -1
            x += blep(p, dt)
            var q = p + 1 - duty; if q >= 1 { q -= 1 }
            x -= blep(q, dt)
            let e: Float = k < 48 ? Float(k) / 48 : 0.85
            put(b, i, x * e * rg * level, g)
            p += dt; if p >= 1 { p -= 1 }
        }
    }

    static func triangle(_ b: MusicBus, _ c: VoiceSpan, _ f: Float, _ g: VoiceGains) {
        let dt = f / sr
        var p: Float = 0, rg: Float = 1
        let rstep = 1 / Float(c.rel)
        for i in c.start..<c.end {
            let k = i - c.start
            if k >= c.gate { rg -= rstep; if rg <= 0 { break } }
            // 4-bit-ish stepped triangle (NES flavour)
            let tri = 4 * abs(p - 0.5) - 1
            let x = (tri * 7.5).rounded() / 7.5
            put(b, i, x * rg * 0.5, g)
            p += dt; if p >= 1 { p -= 1 }
        }
    }

    static func flute(_ b: MusicBus, _ c: VoiceSpan, _ f: Float, _ g: VoiceGains, seed: UInt32) {
        let inc = f / sr
        var p: Float = 0, vp: Float = 0, rg: Float = 1, nlp: Float = 0
        var noise = Noise32(seed | 1)
        let rstep = 1 / Float(c.rel), att = 0.05 * sr, vinc = 5 / sr, na = coef(f * 2)
        for i in c.start..<c.end {
            let k = i - c.start
            if k >= c.gate { rg -= rstep; if rg <= 0 { break } }
            let vib = k > Int(0.2 * sr) ? 1 + 0.006 * sin(twoPi * vp) : 1
            nlp += na * (noise.next() - nlp)
            let x = sin(twoPi * p) + 0.12 * sin(2 * twoPi * p) + 0.5 * nlp
            let e = Float(k) < att ? Float(k) / att : 0.9
            put(b, i, x * e * rg * 0.3, g)
            p += inc * vib; if p >= 1 { p -= 1 }
            vp += vinc; if vp >= 1 { vp -= 1 }
        }
    }

    static func sineBass(_ b: MusicBus, _ c: VoiceSpan, _ f: Float, _ g: VoiceGains, drive: Float, tau: Float, level: Float) {
        let inc = f / sr
        var p: Float = 0, rg: Float = 1, amp: Float = 1
        let rstep = 1 / Float(c.rel), dk: Float = tau > 0 ? exp(-1 / (tau * sr)) : 1
        for i in c.start..<c.end {
            let k = i - c.start
            if k >= c.gate { rg -= rstep; if rg <= 0 { break } }
            let a: Float = k < 240 ? Float(k) / 240 : 1
            let x = tanh(drive * sin(twoPi * p)) / tanh(drive)
            put(b, i, x * a * rg * amp * level, g)
            p += inc; if p >= 1 { p -= 1 }
            amp = max(0.35, amp * dk)
        }
    }

    static func sub808(_ b: MusicBus, _ c: VoiceSpan, _ f: Float, _ g: VoiceGains) {
        var p: Float = 0, rg: Float = 1, amp: Float = 1, bend: Float = 1
        let rstep = 1 / Float(c.rel), dk = exp(-1 / (1.1 * sr)), bk = exp(-1 / (0.03 * sr))
        for i in c.start..<c.end {
            let k = i - c.start
            if k >= c.gate { rg -= rstep; if rg <= 0 { break } }
            let a: Float = k < 96 ? Float(k) / 96 : 1
            let x = tanh(2.2 * sin(twoPi * p))
            put(b, i, x * a * rg * amp * 0.62, g)
            p += f * (1 + 0.6 * bend) / sr; if p >= 1 { p -= 1 }
            amp *= dk; bend *= bk
        }
    }

    // MARK: Drums

    static func drum(_ h: DrumHit, into b: MusicBus, seed: UInt32) {
        let start = Int(h.time * Double(sr))
        guard start >= 0, start < b.n else { return }
        var noise = Noise32(seed &* 747_796_405 &+ 2_891_336_453)
        let rev: Float
        switch h.kind {
        case .taiko, .crash, .snare, .clap: rev = 0.25
        case .kick, .chipKick: rev = 0.02
        default: rev = 0.1
        }
        let g = VoiceGains(velocity: h.velocity, pan: h.pan, reverb: rev, delay: 0)
        switch h.kind {
        case .kick: kick(b, start, g, &noise, f0: 48, sweep: 115, tau: 0.32, level: 0.95)
        case .taiko: kick(b, start, g, &noise, f0: 58, sweep: 60, tau: 0.55, level: 0.9, thump: 0.5)
        case .chipKick: chipTone(b, start, g, f0: 120, f1: 40, dur: 0.12, level: 0.5)
        case .snare: snare(b, start, g, &noise, tone: 185, toneLevel: 0.45, noiseTau: 0.13, level: 0.55)
        case .brush: noiseHit(b, start, g, &noise, hp: 2500, lp: 9000, attack: 0.01, tau: 0.09, level: 0.18)
        case .rim: snare(b, start, g, &noise, tone: 1700, toneLevel: 0.6, noiseTau: 0.012, level: 0.3)
        case .clap: clap(b, start, g, &noise)
        case .hat: noiseHit(b, start, g, &noise, hp: 7000, lp: 16000, attack: 0.0005, tau: 0.035, level: 0.28)
        case .openHat: noiseHit(b, start, g, &noise, hp: 6500, lp: 16000, attack: 0.0005, tau: 0.2, level: 0.22)
        case .crash: noiseHit(b, start, g, &noise, hp: 4000, lp: 15000, attack: 0.001, tau: 0.9, level: 0.2)
        case .ride: ride(b, start, g, &noise)
        case .shaker: noiseHit(b, start, g, &noise, hp: 5000, lp: 12000, attack: 0.008, tau: 0.04, level: 0.16)
        case .chipSnare: chipNoise(b, start, g, &noise, hold: 6, tau: 0.09, level: 0.35)
        case .chipHat: chipNoise(b, start, g, &noise, hold: 1, tau: 0.03, level: 0.2)
        }
    }

    static func kick(_ b: MusicBus, _ s: Int, _ g: VoiceGains, _ noise: inout Noise32, f0: Float, sweep: Float, tau: Float, level: Float, thump: Float = 0) {
        let end = min(b.n, s + Int(tau * 4 * sr))
        var p: Float = 0, amp: Float = 1, pe: Float = 1, lp: Float = 0
        let dk = exp(-1 / (tau * sr)), pk = exp(-1 / (0.03 * sr))
        for i in s..<end {
            let k = i - s
            var x = sin(twoPi * p) * amp
            if k < 96 { x += noise.next() * 0.3 * (1 - Float(k) / 96) }
            if thump > 0 { lp += 0.02 * (noise.next() - lp); x += lp * thump * 6 * amp }
            put(b, i, tanh(1.3 * x) * level, g)
            p += (f0 + sweep * pe) / sr; if p >= 1 { p -= 1 }
            amp *= dk; pe *= pk
        }
    }

    static func snare(_ b: MusicBus, _ s: Int, _ g: VoiceGains, _ noise: inout Noise32, tone: Float, toneLevel: Float, noiseTau: Float, level: Float) {
        let end = min(b.n, s + Int(max(noiseTau, 0.08) * 5 * sr))
        var p: Float = 0, ta: Float = 1, na: Float = 1, lp: Float = 0, hp: Float = 0
        let tk = exp(-1 / (0.07 * sr)), nk = exp(-1 / (noiseTau * sr)), a1 = coef(1200), a2 = coef(9000)
        for i in s..<end {
            let n = noise.next()
            hp += a1 * (n - hp)
            lp += a2 * ((n - hp) - lp)
            let x = sin(twoPi * p) * ta * toneLevel + lp * na
            put(b, i, x * level, g)
            p += tone / sr; if p >= 1 { p -= 1 }
            ta *= tk; na *= nk
        }
    }

    static func clap(_ b: MusicBus, _ s: Int, _ g: VoiceGains, _ noise: inout Noise32) {
        let end = min(b.n, s + Int(0.4 * sr))
        var hp: Float = 0, lp: Float = 0
        let a1 = coef(900), a2 = coef(3500), tk = exp(-1 / (0.11 * sr)), bk = exp(-1 / (0.007 * sr))
        var tail: Float = 1, burst: Float = 1
        let bursts = [0, Int(0.011 * sr), Int(0.022 * sr)]
        var bi = 0
        for i in s..<end {
            let k = i - s
            if bi < bursts.count, k == bursts[bi] { burst = 1; bi += 1 }
            let n = noise.next()
            hp += a1 * (n - hp); lp += a2 * ((n - hp) - lp)
            let env = k < bursts[2] ? burst : max(burst, tail * 0.7)
            put(b, i, lp * env * 0.9, g)
            burst *= bk
            if k >= bursts[2] { tail *= tk }
        }
    }

    static func noiseHit(_ b: MusicBus, _ s: Int, _ g: VoiceGains, _ noise: inout Noise32, hp hpf: Float, lp lpf: Float,
                         attack: Float, tau: Float, level: Float) {
        let end = min(b.n, s + Int(tau * 5 * sr + attack * sr))
        var hp: Float = 0, lp: Float = 0, amp: Float = 1
        let a1 = coef(hpf), a2 = coef(lpf), dk = exp(-1 / (tau * sr)), att = max(1, attack * sr)
        for i in s..<end {
            let k = i - s
            let n = noise.next()
            hp += a1 * (n - hp); lp += a2 * ((n - hp) - lp)
            let e: Float = Float(k) < att ? Float(k) / att : amp
            put(b, i, lp * e * level * 1.6, g)
            if Float(k) >= att { amp *= dk }
        }
    }

    static func ride(_ b: MusicBus, _ s: Int, _ g: VoiceGains, _ noise: inout Noise32) {
        let end = min(b.n, s + Int(1.2 * sr))
        var hp: Float = 0, amp: Float = 1
        var ph: (Float, Float, Float) = (0, 0, 0)
        let a1 = coef(5000), dk = exp(-1 / (0.35 * sr))
        for i in s..<end {
            let n = noise.next()
            hp += a1 * (n - hp)
            let metal = (ph.0 < 0.5 ? 1 : -1) + (ph.1 < 0.5 ? 1 : -1) + (ph.2 < 0.5 ? 1 : -1) as Float
            put(b, i, ((n - hp) * 0.5 + metal * 0.08) * amp * 0.35, g)
            ph.0 += 3100 / sr; if ph.0 >= 1 { ph.0 -= 1 }
            ph.1 += 4570 / sr; if ph.1 >= 1 { ph.1 -= 1 }
            ph.2 += 5830 / sr; if ph.2 >= 1 { ph.2 -= 1 }
            amp *= dk
        }
    }

    static func chipTone(_ b: MusicBus, _ s: Int, _ g: VoiceGains, f0: Float, f1: Float, dur: Float, level: Float) {
        let end = min(b.n, s + Int(dur * sr))
        var p: Float = 0
        for i in s..<end {
            let t = Float(i - s) / Float(end - s)
            put(b, i, (p < 0.5 ? 1 : -1) * (1 - t) * level, g)
            p += (f0 + (f1 - f0) * t) / sr; if p >= 1 { p -= 1 }
        }
    }

    static func chipNoise(_ b: MusicBus, _ s: Int, _ g: VoiceGains, _ noise: inout Noise32, hold: Int, tau: Float, level: Float) {
        let end = min(b.n, s + Int(tau * 4 * sr))
        var amp: Float = 1, v: Float = 0
        let dk = exp(-1 / (tau * sr))
        for i in s..<end {
            if (i - s) % hold == 0 { v = noise.next() > 0 ? 1 : -1 }
            put(b, i, v * amp * level, g)
            amp *= dk
        }
    }
}

// MARK: - Master effects

enum MusicMaster {
    /// Freeverb-style stereo reverb of the mono send, added into `out`.
    static func reverb(_ send: UnsafeMutablePointer<Float>, frames: Int, into out: AudioBuffer, wet: Float, feedback: Float) {
        guard wet > 0 else { return }
        let lens = [1116, 1188, 1277, 1356, 556, 441]
        for ch in 0..<2 {
            let spread = ch == 0 ? 0 : 23
            let ls = lens.map { $0 + spread }
            let total = ls.reduce(0, +)
            let mem = UnsafeMutablePointer<Float>.allocate(capacity: total)
            mem.initialize(repeating: 0, count: total)
            defer { mem.deallocate() }
            var bases = [Int](), acc0 = 0
            for l in ls { bases.append(acc0); acc0 += l }
            let c0 = mem + bases[0], c1 = mem + bases[1], c2 = mem + bases[2], c3 = mem + bases[3], a0 = mem + bases[4], a1 = mem + bases[5]
            let n0 = ls[0], n1 = ls[1], n2 = ls[2], n3 = ls[3], m0 = ls[4], m1 = ls[5]
            var i0 = 0, i1 = 0, i2 = 0, i3 = 0, j0 = 0, j1 = 0
            var s0: Float = 0, s1: Float = 0, s2: Float = 0, s3: Float = 0
            let o = out.pointer(ch)
            let damp: Float = 0.35, und = 1 - damp, fb = feedback
            for i in 0..<frames {
                let x = send[i] * 0.25
                let y0 = c0[i0], y1 = c1[i1], y2 = c2[i2], y3 = c3[i3]
                s0 = y0 * und + s0 * damp; c0[i0] = x + s0 * fb
                s1 = y1 * und + s1 * damp; c1[i1] = x + s1 * fb
                s2 = y2 * und + s2 * damp; c2[i2] = x + s2 * fb
                s3 = y3 * und + s3 * damp; c3[i3] = x + s3 * fb
                i0 += 1; if i0 == n0 { i0 = 0 }
                i1 += 1; if i1 == n1 { i1 = 0 }
                i2 += 1; if i2 == n2 { i2 = 0 }
                i3 += 1; if i3 == n3 { i3 = 0 }
                var acc = y0 + y1 + y2 + y3
                let b0 = a0[j0]; let z0 = -acc + b0; a0[j0] = acc + b0 * 0.5; acc = z0
                j0 += 1; if j0 == m0 { j0 = 0 }
                let b1 = a1[j1]; let z1 = -acc + b1; a1[j1] = acc + b1 * 0.5; acc = z1
                j1 += 1; if j1 == m1 { j1 = 0 }
                o[i] += acc * wet
            }
        }
    }

    /// Ping-pong delay of the mono send.
    static func pingPong(_ send: UnsafeMutablePointer<Float>, frames: Int, into out: AudioBuffer, delaySeconds: Double, feedback: Float, wet: Float) {
        guard wet > 0 else { return }
        let n = max(1, Int(delaySeconds * 48000))
        var l = [Float](repeating: 0, count: n), r = [Float](repeating: 0, count: n)
        var idx = 0, lp: Float = 0
        let L = out.pointer(0), R = out.pointer(1)
        for i in 0..<frames {
            let dl = l[idx], dr = r[idx]
            lp += 0.35 * (dr - lp)
            l[idx] = send[i] + lp * feedback
            r[idx] = dl
            idx += 1; if idx == n { idx = 0 }
            L[i] += dl * wet; R[i] += dr * wet
        }
    }
}
