import Foundation
import ValseCore

/// One zero-latency, causal effect of the live chain (runs in the MTAudioProcessingTap, so parameter edits are heard
/// immediately without rebuilding the composition). Latency-bearing processing (pitch, denoise, separation) lives in
/// the rendered stage instead (`RenderStageSpec`).
public enum LiveNode: Hashable, Sendable {
    case gain(db: Double)
    /// 10-band graphic EQ (dB per `AudioEQ.frequencies`).
    case eq([Double])
    case highPass(hz: Double)
    case lowPass(hz: Double)
    case bandPass(hz: Double, q: Double)
    case peak(hz: Double, q: Double, db: Double)
    case lowShelf(hz: Double, db: Double)
    case highShelf(hz: Double, db: Double)
    /// Feedback delay. `mix` 0…1 wet amount.
    case echo(seconds: Double, feedback: Double, mix: Double)
    /// Modulated delay: chorus (base ≈ 15–25 ms) or flanger (base ≈ 1–3 ms + feedback).
    case chorus(rate: Double, depthMs: Double, baseMs: Double, feedback: Double, mix: Double)
    /// Freeverb. room 0…1, damp 0…1, wet 0…1, width 0…1.
    case reverb(room: Double, damp: Double, wet: Double, width: Double)
    case tremolo(rate: Double, depth: Double)
    /// Ring modulation with a sine carrier (robot / metallic).
    case ringMod(hz: Double, mix: Double)
    /// Bit depth reduction + sample-and-hold downsampling (lo-fi, low battery).
    case bitcrush(bits: Double, downsample: Double)
    /// tanh waveshaper; drive ≥ 1.
    case distortion(drive: Double, mix: Double)
    /// Hiss + crackle (vinyl, broken radio). Deterministic seed.
    case noise(level: Double, crackle: Double)
    case compressor(thresholdDB: Double, ratio: Double, attackMs: Double, releaseMs: Double, makeupDB: Double)
    case channels(ChannelMode)
    /// Brick-wall-ish soft limiter at −1 dBFS (zero latency).
    case limiter

    /// Nodes with the same kind can be reconfigured in place (state kept, no allocation).
    var kind: Int {
        switch self {
        case .gain: 0; case .eq: 1; case .highPass: 2; case .lowPass: 3; case .bandPass: 4; case .peak: 5
        case .lowShelf: 6; case .highShelf: 7; case .echo: 8; case .chorus: 9; case .reverb: 10; case .tremolo: 11
        case .ringMod: 12; case .bitcrush: 13; case .distortion: 14; case .noise: 15; case .compressor: 16
        case .channels: 17; case .limiter: 18
        }
    }
}

/// Processing object for a `LiveNode`. Max 2 channels are processed (stereo); extra channels pass through.
class LiveProcessor {
    var sampleRate: Double = 48000
    func prepare(sampleRate: Double) { self.sampleRate = sampleRate }
    func configure(_ node: LiveNode) {}
    func process(_ b: AudioBlock) {}
    func reset() {}

    static func make(_ node: LiveNode, sampleRate: Double) -> LiveProcessor {
        let p: LiveProcessor
        switch node {
        case .gain: p = GainProc()
        case .eq, .highPass, .lowPass, .bandPass, .peak, .lowShelf, .highShelf: p = FilterProc()
        case .echo: p = EchoProc()
        case .chorus: p = ChorusProc()
        case .reverb: p = ReverbProc()
        case .tremolo: p = TremoloProc()
        case .ringMod: p = RingModProc()
        case .bitcrush: p = BitcrushProc()
        case .distortion: p = DistortionProc()
        case .noise: p = NoiseProc()
        case .compressor: p = CompressorProc()
        case .channels: p = ChannelProc()
        case .limiter: p = LimiterProc()
        }
        p.prepare(sampleRate: sampleRate)
        p.configure(node)
        return p
    }
}

/// An ordered list of live processors built from `[LiveNode]`.
public final class LiveChain: @unchecked Sendable {
    public private(set) var spec: [LiveNode]
    private var procs: [LiveProcessor]
    private(set) var sampleRate: Double

    public init(_ spec: [LiveNode], sampleRate: Double) {
        self.spec = spec; self.sampleRate = sampleRate
        procs = spec.map { LiveProcessor.make($0, sampleRate: sampleRate) }
    }

    public var isEmpty: Bool { spec.isEmpty }

    /// Same kinds → reconfigure in place (keeps reverb tails, no allocation); otherwise rebuild.
    public func update(_ new: [LiveNode]) {
        guard new != spec else { return }
        if new.count == spec.count, zip(new, spec).allSatisfy({ $0.kind == $1.kind }) {
            for (p, n) in zip(procs, new) { p.configure(n) }
        } else {
            procs = new.map { LiveProcessor.make($0, sampleRate: sampleRate) }
        }
        spec = new
    }

    public func prepare(sampleRate: Double) {
        guard sampleRate != self.sampleRate else { return }
        self.sampleRate = sampleRate
        procs = spec.map { LiveProcessor.make($0, sampleRate: sampleRate) }
    }

    public func process(_ b: AudioBlock) { for p in procs { p.process(b) } }
    public func reset() { for p in procs { p.reset() } }

    /// Convenience for offline use / tests.
    public func process(_ buffer: AudioBuffer, chunk: Int = 512) { buffer.process(chunk: chunk) { process($0) } }
}

// MARK: Processors

final class GainProc: LiveProcessor {
    var g: Float = 1
    override func configure(_ node: LiveNode) { if case .gain(let db) = node { g = Float(pow(10, db / 20)) } }
    override func process(_ b: AudioBlock) {
        guard g != 1 else { return }
        for c in 0..<b.channels { let p = b[c]; for i in 0..<b.frames { p[i] *= g } }
    }
}

final class FilterProc: LiveProcessor {
    var sections: [[Biquad]] = [[], []]   // [channel][section]
    var node: LiveNode = .gain(db: 0)
    override func prepare(sampleRate: Double) { super.prepare(sampleRate: sampleRate); configure(node) }
    override func configure(_ node: LiveNode) {
        self.node = node
        let sr = sampleRate
        var ks: [BiquadCoefficients] = []
        switch node {
        case .eq(let gains):
            for (i, f) in AudioEQ.frequencies.enumerated() where i < gains.count && abs(gains[i]) > 0.01 {
                // last band as a shelf so the top octave lifts evenly
                ks.append(i == AudioEQ.frequencies.count - 1 ? .highShelf(f * 0.7, gainDB: gains[i], sampleRate: sr)
                          : i == 0 ? .lowShelf(f * 1.4, gainDB: gains[i], sampleRate: sr)
                          : .peaking(f, q: 1.41, gainDB: gains[i], sampleRate: sr))
            }
        case .highPass(let f): ks = [.highPass(f, sampleRate: sr), .highPass(f, sampleRate: sr)]
        case .lowPass(let f): ks = [.lowPass(f, sampleRate: sr), .lowPass(f, sampleRate: sr)]
        case .bandPass(let f, let q): ks = [.bandPass(f, q: q, sampleRate: sr)]
        case .peak(let f, let q, let db): ks = [.peaking(f, q: q, gainDB: db, sampleRate: sr)]
        case .lowShelf(let f, let db): ks = [.lowShelf(f, gainDB: db, sampleRate: sr)]
        case .highShelf(let f, let db): ks = [.highShelf(f, gainDB: db, sampleRate: sr)]
        default: break
        }
        for c in 0..<2 {
            if sections[c].count == ks.count { for i in ks.indices { sections[c][i].k = ks[i] } }
            else { sections[c] = ks.map { Biquad($0) } }
        }
    }
    override func process(_ b: AudioBlock) {
        for c in 0..<min(2, b.channels) {
            for i in sections[c].indices { sections[c][i].process(b[c], b.frames) }
        }
    }
    override func reset() { for c in 0..<2 { for i in sections[c].indices { sections[c][i].reset() } } }
}

/// Circular delay buffer with fractional reads.
struct DelayLine {
    var buf: [Float]
    var w = 0
    init(maxSamples: Int) { buf = [Float](repeating: 0, count: max(4, maxSamples + 2)) }
    @inline(__always) mutating func write(_ x: Float) { buf[w] = x; w += 1; if w == buf.count { w = 0 } }
    /// Sample written `d` samples ago (d ≥ 1, fractional).
    @inline(__always) func read(_ d: Double) -> Float {
        let n = buf.count
        let dd = min(max(d, 1), Double(n - 2))
        let i = Int(dd), f = Float(dd - Double(i))
        var a = w - i; if a < 0 { a += n }
        var b2 = a - 1; if b2 < 0 { b2 += n }
        return buf[a] * (1 - f) + buf[b2] * f
    }
    mutating func reset() { for i in buf.indices { buf[i] = 0 } }
}

final class EchoProc: LiveProcessor {
    var lines: [DelayLine] = []
    var delay = 0.3, fb: Float = 0.4, mix: Float = 0.4
    override func prepare(sampleRate: Double) {
        super.prepare(sampleRate: sampleRate)
        lines = [DelayLine(maxSamples: Int(sampleRate * 2.1)), DelayLine(maxSamples: Int(sampleRate * 2.1))]
    }
    override func configure(_ node: LiveNode) {
        if case .echo(let s, let f, let m) = node { delay = min(max(s, 0.01), 2); fb = Float(min(max(f, 0), 0.95)); mix = Float(min(max(m, 0), 1)) }
    }
    override func process(_ b: AudioBlock) {
        let d = delay * sampleRate
        for c in 0..<min(2, b.channels) {
            let p = b[c]
            for i in 0..<b.frames {
                let x = p[i]
                let y = lines[c].read(d)
                lines[c].write(x + y * fb)
                p[i] = x + y * mix
            }
        }
    }
    override func reset() { for i in lines.indices { lines[i].reset() } }
}

final class ChorusProc: LiveProcessor {
    var lines: [DelayLine] = []
    var rate = 0.8, depth = 3.0, base = 20.0, fb: Float = 0, mix: Float = 0.5
    var phase = 0.0
    override func prepare(sampleRate: Double) {
        super.prepare(sampleRate: sampleRate)
        lines = [DelayLine(maxSamples: Int(sampleRate * 0.1)), DelayLine(maxSamples: Int(sampleRate * 0.1))]
    }
    override func configure(_ node: LiveNode) {
        if case .chorus(let r, let d, let bms, let f, let m) = node {
            rate = max(0.01, r); depth = min(max(d, 0), 30); base = min(max(bms, 0.5), 60)
            fb = Float(min(max(f, -0.9), 0.9)); mix = Float(min(max(m, 0), 1))
        }
    }
    override func process(_ b: AudioBlock) {
        let inc = 2 * Double.pi * rate / sampleRate
        let ms = sampleRate / 1000
        var ph = phase
        for i in 0..<b.frames {
            for c in 0..<min(2, b.channels) {
                let p = b[c]
                // stereo: quadrature LFO on the right channel
                let lfo = sin(ph + (c == 1 ? Double.pi / 2 : 0))
                let d = (base + depth * (0.5 + 0.5 * lfo)) * ms
                let x = p[i]
                let y = lines[c].read(d)
                lines[c].write(x + y * fb)
                p[i] = x * (1 - mix * 0.5) + y * mix
            }
            ph += inc; if ph > 2 * .pi { ph -= 2 * .pi }
        }
        phase = ph
    }
    override func reset() { for i in lines.indices { lines[i].reset() }; phase = 0 }
}

/// Freeverb (Jezar, public domain): 8 parallel damped combs + 4 series all-passes per channel.
final class ReverbProc: LiveProcessor {
    struct Comb { var buf: [Float]; var i = 0; var store: Float = 0
        @inline(__always) mutating func tick(_ x: Float, fb: Float, damp: Float) -> Float {
            let y = buf[i]; store = y * (1 - damp) + store * damp
            buf[i] = x + store * fb; i += 1; if i == buf.count { i = 0 }; return y
        }
    }
    struct AllPass { var buf: [Float]; var i = 0
        @inline(__always) mutating func tick(_ x: Float) -> Float {
            let b = buf[i]; let y = -x + b; buf[i] = x + b * 0.5; i += 1; if i == buf.count { i = 0 }; return y
        }
    }
    static let combs = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617], allpasses = [556, 441, 341, 225]
    var c: [[Comb]] = [], a: [[AllPass]] = []
    var fb: Float = 0.84, damp: Float = 0.2, wet: Float = 0.3, width: Float = 1
    override func prepare(sampleRate: Double) {
        super.prepare(sampleRate: sampleRate)
        let k = sampleRate / 44100
        c = (0..<2).map { ch in Self.combs.map { Comb(buf: [Float](repeating: 0, count: Int(Double($0 + ch * 23) * k))) } }
        a = (0..<2).map { ch in Self.allpasses.map { AllPass(buf: [Float](repeating: 0, count: Int(Double($0 + ch * 23) * k))) } }
    }
    override func configure(_ node: LiveNode) {
        if case .reverb(let r, let d, let w, let wd) = node {
            fb = Float(0.7 + 0.28 * min(max(r, 0), 1)); damp = Float(0.4 * min(max(d, 0), 1))
            wet = Float(min(max(w, 0), 1)); width = Float(min(max(wd, 0), 1))
        }
    }
    override func process(_ b: AudioBlock) {
        let stereo = b.channels >= 2
        let l = b[0], r = stereo ? b[1] : b[0]
        let wet1 = wet * 3 * (width / 2 + 0.5), wet2 = wet * 3 * ((1 - width) / 2)
        let dry = 1 - wet * 0.5
        for i in 0..<b.frames {
            let input = (l[i] + r[i]) * 0.015 * (stereo ? 1 : 2) * 0.5
            var ol: Float = 0, or: Float = 0
            for j in 0..<8 { ol += c[0][j].tick(input, fb: fb, damp: damp); or += c[1][j].tick(input, fb: fb, damp: damp) }
            for j in 0..<4 { ol = a[0][j].tick(ol); or = a[1][j].tick(or) }
            let xl = l[i], xr = r[i]
            l[i] = ol * wet1 + or * wet2 + xl * dry
            if stereo { r[i] = or * wet1 + ol * wet2 + xr * dry }
        }
    }
    override func reset() { prepare(sampleRate: sampleRate) }
}

final class TremoloProc: LiveProcessor {
    var rate = 5.0, depth: Float = 0.5, phase = 0.0
    override func configure(_ node: LiveNode) { if case .tremolo(let r, let d) = node { rate = r; depth = Float(min(max(d, 0), 1)) } }
    override func process(_ b: AudioBlock) {
        let inc = 2 * Double.pi * rate / sampleRate
        var ph = phase
        for i in 0..<b.frames {
            let g = 1 - depth * Float(0.5 + 0.5 * sin(ph))
            for c in 0..<b.channels { b[c][i] *= g }
            ph += inc; if ph > 2 * .pi { ph -= 2 * .pi }
        }
        phase = ph
    }
    override func reset() { phase = 0 }
}

final class RingModProc: LiveProcessor {
    var hz = 50.0, mix: Float = 1, phase = 0.0
    override func configure(_ node: LiveNode) { if case .ringMod(let f, let m) = node { hz = f; mix = Float(min(max(m, 0), 1)) } }
    override func process(_ b: AudioBlock) {
        let inc = 2 * Double.pi * hz / sampleRate
        var ph = phase
        for i in 0..<b.frames {
            let m = Float(sin(ph))
            for c in 0..<b.channels { let x = b[c][i]; b[c][i] = x * (1 - mix) + x * m * mix }
            ph += inc; if ph > 2 * .pi { ph -= 2 * .pi }
        }
        phase = ph
    }
    override func reset() { phase = 0 }
}

final class BitcrushProc: LiveProcessor {
    var levels: Float = 256, hold = 1.0
    var counter = 0.0, held: [Float] = [0, 0]
    override func configure(_ node: LiveNode) {
        if case .bitcrush(let bits, let ds) = node { levels = Float(pow(2, min(max(bits, 1), 24)) / 2); hold = max(1, ds) }
    }
    override func process(_ b: AudioBlock) {
        for i in 0..<b.frames {
            counter += 1
            let take = counter >= hold
            if take { counter -= hold }
            for c in 0..<min(2, b.channels) {
                if take { held[c] = (b[c][i] * levels).rounded() / levels }
                b[c][i] = held[c]
            }
        }
    }
    override func reset() { counter = 0; held = [0, 0] }
}

final class DistortionProc: LiveProcessor {
    var drive: Float = 2, mix: Float = 1
    override func configure(_ node: LiveNode) { if case .distortion(let d, let m) = node { drive = Float(max(1, d)); mix = Float(min(max(m, 0), 1)) } }
    override func process(_ b: AudioBlock) {
        let norm = 1 / tanh(drive)
        for c in 0..<b.channels {
            let p = b[c]
            for i in 0..<b.frames { let x = p[i]; p[i] = x * (1 - mix) + tanh(x * drive) * norm * mix }
        }
    }
}

/// xorshift PRNG: deterministic (export = preview, EX-023).
struct XorShift { var s: UInt64 = 0x9E3779B97F4A7C15
    @inline(__always) mutating func next() -> Float {
        s ^= s << 13; s ^= s >> 7; s ^= s << 17
        return Float(Double(s >> 11) / Double(1 << 53)) * 2 - 1
    }
}

final class NoiseProc: LiveProcessor {
    var level: Float = 0.01, crackle: Float = 0
    var rng = XorShift(), lp: Float = 0
    override func configure(_ node: LiveNode) { if case .noise(let l, let c) = node { level = Float(l); crackle = Float(c) } }
    override func process(_ b: AudioBlock) {
        for i in 0..<b.frames {
            let w = rng.next()
            lp = lp * 0.6 + w * 0.4
            var n = lp * level
            if crackle > 0, abs(rng.next()) > 1 - crackle * 0.002 { n += rng.next() * 0.3 * crackle }
            for c in 0..<b.channels { b[c][i] += n }
        }
    }
    override func reset() { rng = XorShift(); lp = 0 }
}

/// Feed-forward RMS compressor (stereo-linked, zero latency).
final class CompressorProc: LiveProcessor {
    var threshold = -18.0, ratio = 3.0, attack = 0.0, release = 0.0, makeup: Float = 1
    var env = 0.0
    var attackMs = 5.0, releaseMs = 80.0
    override func prepare(sampleRate: Double) { super.prepare(sampleRate: sampleRate); setTimes() }
    func setTimes() { attack = exp(-1 / (attackMs * 0.001 * sampleRate)); release = exp(-1 / (releaseMs * 0.001 * sampleRate)) }
    override func configure(_ node: LiveNode) {
        if case .compressor(let t, let r, let a, let rel, let m) = node {
            threshold = t; ratio = max(1, r); attackMs = max(0.1, a); releaseMs = max(1, rel); makeup = Float(pow(10, m / 20)); setTimes()
        }
    }
    override func process(_ b: AudioBlock) {
        let slope = 1 - 1 / ratio
        for i in 0..<b.frames {
            var x2 = 0.0
            for c in 0..<b.channels { let v = Double(b[c][i]); x2 = max(x2, v * v) }
            let coef = x2 > env ? attack : release
            env = coef * env + (1 - coef) * x2
            let lvl = 10 * log10(env + 1e-12)
            let over = lvl - threshold
            let gdb = over > 0 ? -over * slope : 0
            let g = Float(pow(10, gdb / 20)) * makeup
            for c in 0..<b.channels { b[c][i] *= g }
        }
    }
    override func reset() { env = 0 }
}

final class ChannelProc: LiveProcessor {
    var mode: ChannelMode = .stereo
    override func configure(_ node: LiveNode) { if case .channels(let m) = node { mode = m } }
    override func process(_ b: AudioBlock) {
        guard b.channels >= 2, mode != .stereo else { return }
        let l = b[0], r = b[1]
        for i in 0..<b.frames {
            switch mode {
            case .leftToBoth: r[i] = l[i]
            case .rightToBoth: l[i] = r[i]
            case .mono: let m = (l[i] + r[i]) * 0.5; l[i] = m; r[i] = m
            case .swap: let t = l[i]; l[i] = r[i]; r[i] = t
            case .stereo: break
            }
        }
    }
}

/// Soft knee limiter: transparent below −6 dBFS, approaches −1 dBFS asymptotically (stateless, zero latency).
final class LimiterProc: LiveProcessor {
    override func process(_ b: AudioBlock) {
        let knee: Float = 0.5, ceiling: Float = 0.891
        for c in 0..<b.channels {
            let p = b[c]
            for i in 0..<b.frames {
                let x = p[i], a = abs(x)
                if a > knee {
                    let over = (a - knee) / (ceiling - knee)
                    p[i] = (knee + (ceiling - knee) * tanh(over)) * (x < 0 ? -1 : 1)
                }
            }
        }
    }
}
