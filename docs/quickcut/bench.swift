// Quick-cut blank-detection bench (standalone, no app code).
// swiftc -O bench.swift -o bench && ./bench
import Foundation
import Accelerate

let SR = 16000
let HOP = 160            // 10 ms frames
let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

// MARK: - utils
struct RNG { var s: UInt64
    mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
    mutating func uni() -> Float { Float(next() >> 40) / Float(1 << 24) }
    mutating func gauss() -> Float { let u = max(uni(), 1e-7), v = uni(); return sqrtf(-2 * logf(u)) * cosf(2 * .pi * v) }
}
func load(_ name: String) -> [Float] {
    let d = try! Data(contentsOf: URL(fileURLWithPath: "\(dir)/raw/\(name).f32"))
    return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}
func rms(_ x: ArraySlice<Float>) -> Float { var s: Float = 0; for v in x { s += v * v }; return sqrtf(s / Float(max(x.count, 1))) }
func db(_ x: Float) -> Float { 20 * log10f(max(x, 1e-6)) }
func percentile(_ a: [Float], _ p: Float) -> Float { let s = a.sorted(); return s[min(s.count - 1, Int(Float(s.count - 1) * p))] }

struct Biquad { var b0, b1, b2, a1, a2: Float; var z1: Float = 0, z2: Float = 0
    static func hp(_ f: Float, _ q: Float = 0.707) -> Biquad { let w = 2 * Float.pi * f / Float(SR), al = sinf(w) / (2 * q), c = cosf(w), a0 = 1 + al
        return Biquad(b0: (1 + c) / 2 / a0, b1: -(1 + c) / a0, b2: (1 + c) / 2 / a0, a1: -2 * c / a0, a2: (1 - al) / a0) }
    static func lp(_ f: Float, _ q: Float = 0.707) -> Biquad { let w = 2 * Float.pi * f / Float(SR), al = sinf(w) / (2 * q), c = cosf(w), a0 = 1 + al
        return Biquad(b0: (1 - c) / 2 / a0, b1: (1 - c) / a0, b2: (1 - c) / 2 / a0, a1: -2 * c / a0, a2: (1 - al) / a0) }
    mutating func run(_ x: inout [Float]) { for i in x.indices { let y = b0 * x[i] + z1; z1 = b1 * x[i] - a1 * y + z2; z2 = b2 * x[i] - a2 * y; x[i] = y } }
}

// MARK: - corpus
// A take = lead silence, sentences separated by pauses of known length, tail silence.
struct Take { var name: String; var clean: [Float] }
func buildTakes() -> [Take] {
    var rng = RNG(s: 42)
    let pauses: [Double] = [0.12, 0.2, 0.3, 0.45, 0.6, 0.8, 1.1, 1.6, 2.4, 3.5]
    let groups: [(String, [Int])] = [("en_samantha", [1, 2, 3, 4, 5]), ("en_daniel", [6, 7, 8, 9]), ("fr_thomas", [10, 11, 12]), ("fr_flo", [13, 14, 15])]
    var takes: [Take] = []
    for (name, ids) in groups {
        var x = [Float](repeating: 0, count: Int(1.3 * Double(SR)))
        // each sentence twice with different pauses to get enough pauses
        for rep in 0..<2 { for (k, id) in ids.enumerated() {
            var s = load("s_\(id)")
            // trim TTS lead/tail silence so pauses are exact
            let thr: Float = 1e-3
            let a = s.firstIndex { abs($0) > thr } ?? 0, b = s.lastIndex { abs($0) > thr } ?? s.count - 1
            s = Array(s[a...b])
            let g: Float = 0.5 + 0.4 * rng.uni() // speakers vary
            x += s.map { $0 * g }
            let p = pauses[(k * 3 + rep * 5 + id) % pauses.count]
            x += [Float](repeating: 0, count: Int(p * Double(SR)))
        } }
        x += [Float](repeating: 0, count: Int(1.8 * Double(SR)))
        takes.append(Take(name: name, clean: x))
    }
    return takes
}
// truth: 10 ms frames where clean has energy; inter-word gaps < 60 ms closed
func truthMask(_ clean: [Float]) -> [Bool] {
    let n = clean.count / HOP
    var m = (0..<n).map { i in db(rms(clean[i * HOP..<min(clean.count, i * HOP + HOP)])) > -55 }
    closeGaps(&m, 6)
    return m
}
func closeGaps(_ m: inout [Bool], _ maxGap: Int) {
    var i = 0
    while i < m.count { if !m[i] { var j = i; while j < m.count && !m[j] { j += 1 }
        if i > 0 && j < m.count && j - i <= maxGap { for k in i..<j { m[k] = true } }; i = j } else { i += 1 } }
}
func dilate(_ m: [Bool], before: Int, after: Int) -> [Bool] {
    var o = m
    for i in m.indices where m[i] { for k in max(0, i - before)...min(m.count - 1, i + after) { o[k] = true } }
    return o
}

// MARK: - scenarios (degradations)
func speechRMS(_ clean: [Float], _ truth: [Bool]) -> Float {
    var s: Float = 0, c = 0
    for (i, t) in truth.enumerated() where t { for v in clean[i * HOP..<min(clean.count, i * HOP + HOP)] { s += v * v; c += 1 } }
    return sqrtf(s / Float(max(c, 1)))
}
func pink(_ n: Int, _ rng: inout RNG) -> [Float] { // Voss-McCartney-ish via filtered white
    var b0: Float = 0, b1: Float = 0, b2: Float = 0; var o = [Float](repeating: 0, count: n)
    for i in 0..<n { let w = rng.gauss(); b0 = 0.99765 * b0 + w * 0.0990460; b1 = 0.96300 * b1 + w * 0.2965164; b2 = 0.57000 * b2 + w * 1.0526913; o[i] = b0 + b1 + b2 + w * 0.1848 }
    return o
}
func scaled(_ x: [Float], toRMS r: Float) -> [Float] { let c = rms(x[...]); return x.map { $0 * r / max(c, 1e-9) } }
func add(_ a: inout [Float], _ b: [Float]) { for i in 0..<min(a.count, b.count) { a[i] += b[i] } }

typealias Scenario = (String, (Take, [Bool], inout RNG) -> [Float])
let scenarios: [Scenario] = [
    ("clean", { t, _, _ in t.clean }),
    ("quiet-30dB", { t, _, _ in t.clean.map { $0 * 0.0316 } }),
    ("hot+15dB-clip", { t, _, _ in t.clean.map { max(-1, min(1, $0 * 5.6)) } }),
    ("pink-snr25", { t, m, r in var x = t.clean; add(&x, scaled(pink(x.count, &r), toRMS: speechRMS(t.clean, m) / 17.8)); return x }),
    ("pink-snr12", { t, m, r in var x = t.clean; add(&x, scaled(pink(x.count, &r), toRMS: speechRMS(t.clean, m) / 4.0)); return x }),
    ("hum50-snr20", { t, m, r in var x = t.clean; let a = speechRMS(t.clean, m) / 10
        let h = (0..<x.count).map { i -> Float in let ph = 2 * Float.pi * 50 * Float(i) / Float(SR); return sinf(ph) + 0.5 * sinf(2 * ph) + 0.3 * sinf(3 * ph) + 0.01 * r.gauss() }
        add(&x, scaled(h, toRMS: a)); add(&x, scaled(pink(x.count, &r), toRMS: a / 10)); return x }),
    ("traffic-varying", { t, m, r in var x = t.clean; var br = [Float](repeating: 0, count: x.count); var acc: Float = 0
        for i in br.indices { acc = 0.995 * acc + 0.1 * r.gauss(); br[i] = acc }
        br = scaled(br, toRMS: speechRMS(t.clean, m) / 5.6)
        for i in br.indices { let lfo = powf(10, (7.5 * sinf(2 * .pi * 0.07 * Float(i) / Float(SR))) / 20); br[i] *= lfo }
        add(&x, br); return x }),
    ("breaths+clicks+room", { t, m, r in var x = t.clean; let sr = speechRMS(t.clean, m)
        add(&x, scaled(pink(x.count, &r), toRMS: sr / 30))
        // in every truth gap >= 0.45 s: a breath (bandpassed noise, 0.35 s hann) and a click
        var i = 0
        while i < m.count { if !m[i] { var j = i; while j < m.count && !m[j] { j += 1 }
            let len = Double(j - i) / 100
            if len >= 0.45 { let c = (i + j) / 2 * HOP, bl = Int(0.35 * Double(SR))
                var b = (0..<bl).map { _ in r.gauss() }; var hp = Biquad.hp(500), lp = Biquad.lp(2500); hp.run(&b); lp.run(&b)
                b = scaled(b, toRMS: sr * 0.08) // ~ -22 dB rel. speech
                for k in 0..<bl where c - bl / 2 + k < x.count && c - bl / 2 + k >= 0 { let w = 0.5 - 0.5 * cosf(2 * .pi * Float(k) / Float(bl)); x[c - bl / 2 + k] += b[k] * w }
                let cc = i * HOP + Int(0.12 * Double(SR)) // click 120 ms into the pause
                for k in 0..<80 where cc + k < x.count { x[cc + k] += sr * 2.5 * r.gauss() * expf(-Float(k) / 12) } }
            i = j } else { i += 1 } }
        return x }),
    ("reverb-rt400", { t, m, r in let x = t.clean; var o = x; let L = Int(0.4 * Double(SR))
        var taps: [(Int, Float)] = []; var k = 40; while k < L { taps.append((k, 0.35 * r.gauss() * expf(-6.9 * Float(k) / Float(L)) )); k += 37 }
        for (d, g) in taps { for i in d..<x.count { o[i] += g * x[i - d] } }
        add(&o, scaled(pink(x.count, &r), toRMS: speechRMS(t.clean, m) / 40)); return o }),
    ("music-bed-20dB", { t, m, _ in var x = t.clean; let mu = load("music"); var mm = [Float](repeating: 0, count: x.count)
        for i in mm.indices { mm[i] = mu[i % mu.count] }
        add(&x, scaled(mm, toRMS: speechRMS(t.clean, m) / 10)); return x }),
]

// MARK: - features
struct Feat { var e: [Float]; var be: [Float]; var voiced: [Float]; var hi: [Float] = [] }   // hi: energy above 4 kHz (fix3)
func features(_ x: [Float]) -> Feat {
    let n = x.count / HOP
    var band = x; var hp = Biquad.hp(150), lp = Biquad.lp(4000); hp.run(&band); lp.run(&band)
    var e = [Float](repeating: -120, count: n), be = e, vo = [Float](repeating: 0, count: n)
    // 8 kHz decimated band signal for voicing
    var d = [Float](repeating: 0, count: band.count / 2); for i in d.indices { d[i] = 0.5 * (band[2 * i] + band[2 * i + 1]) }
    let W = 256, minLag = 20, maxLag = 120 // 32 ms window, 67-400 Hz
    var hx = x; var h1 = Biquad.hp(4000), h2 = Biquad.hp(4000); h1.run(&hx); h2.run(&hx); var hi = e
    for i in 0..<n { let a = max(0, i * HOP + HOP / 2 - 200), b = min(x.count, a + 400); e[i] = db(rms(x[a..<b])); be[i] = db(rms(band[a..<b])); hi[i] = db(rms(hx[a..<b])) }
    // voicing only where the band energy is clearly above the clip floor (the rest can't be speech anyway)
    let gate = max(percentile(be, 0.10), -90) + 4
    d.withUnsafeBufferPointer { p in let base = p.baseAddress!
    for i in 0..<n where be[i] > gate {
        let c = i * HOP / 2 + HOP / 4 - W / 2
        guard c >= 0 && c + W + maxLag < d.count else { continue }
        var e0: Float = 0; vDSP_dotpr(base + c, 1, base + c, 1, &e0, vDSP_Length(W))
        guard e0 > 1e-9 else { continue }
        var el: Float = 0; vDSP_dotpr(base + c + minLag, 1, base + c + minLag, 1, &el, vDSP_Length(W))
        var best: Float = 0
        for lag in minLag...maxLag { var s: Float = 0; vDSP_dotpr(base + c, 1, base + c + lag, 1, &s, vDSP_Length(W))
            let r = s / sqrtf(e0 * el + 1e-12); if r > best { best = r }
            let o = base[c + lag], nw = base[c + lag + W]; el += nw * nw - o * o }
        vo[i] = best }
    }
    return Feat(e: e, be: be, voiced: vo, hi: hi)
}

// MARK: - detectors -> speech mask (true = keep)
protocol Detector { var name: String { get }; func mask(_ f: Feat) -> [Bool] }
struct Fixed: Detector { var t: Float; var name: String { "S1 fixed \(Int(t))dBFS" }
    func mask(_ f: Feat) -> [Bool] { dilate(f.e.map { $0 > t }, before: 2, after: 10) } }
struct Adaptive: Detector { var frac: Float; var band: Bool; var name: String { "S2 adaptive\(band ? "-band" : "") \(frac)" }
    func mask(_ f: Feat) -> [Bool] {
        let e = band ? f.be : f.e
        let floor = max(percentile(e, 0.10), -90), peak = percentile(e, 0.97)
        let thr = max(floor + 6, floor + frac * (peak - floor))
        var m = e.map { $0 > thr }
        // hysteresis: extend while above thr-6
        for i in 1..<m.count where !m[i] && m[i - 1] && e[i] > thr - 6 { m[i] = true }
        for i in stride(from: m.count - 2, through: 0, by: -1) where !m[i] && m[i + 1] && e[i] > thr - 6 { m[i] = true }
        // drop bursts < 60 ms (clicks)
        dropShort(&m, 6)
        return dilate(m, before: 3, after: 8)
    } }
struct Voiced: Detector { var frac: Float; var vthr: Float; var name: String { "S3 voiced \(frac)/\(vthr)" }
    func mask(_ f: Feat) -> [Bool] {
        let e = f.be
        let floor = max(percentile(e, 0.10), -90), peak = percentile(e, 0.97)
        let thr = max(floor + 4, floor + frac * (peak - floor))
        let loud = e.map { $0 > thr }
        // voiced nucleus: periodic AND above the energy gate; need >= 40 ms of voicing in a 100 ms window
        let v = (0..<e.count).map { loud[$0] && f.voiced[$0] > vthr }
        var nuc = [Bool](repeating: false, count: e.count)
        for i in v.indices { var c = 0; for k in max(0, i - 5)...min(v.count - 1, i + 5) where v[k] { c += 1 }; nuc[i] = c >= 4 && v[i] }
        // grow nucleus over contiguous loud frames (unvoiced consonants, word tails), max 250 ms each side
        var m = nuc
        for i in nuc.indices where nuc[i] {
            var k = i - 1; while k >= 0 && k > i - 25 && loud[k] && !m[k] { m[k] = true; k -= 1 }
            k = i + 1; while k < m.count && k < i + 25 && loud[k] && !m[k] { m[k] = true; k += 1 }
        }
        return dilate(m, before: 3, after: 8)
    } }
struct Hybrid: Detector { var frac: Float; var localWin: Int; var vmin: Int; var attach = false; var edgeDrop: Float? = nil
    var name: String { "S\(attach ? 5 : 4) hybrid \(frac) w\(localWin) v\(vmin)" + (edgeDrop.map { " e\(Int($0))" } ?? "") }
    func mask(_ f: Feat) -> [Bool] {
        let e = f.be, n = e.count
        // smoothed energy (200 ms mean) -> sliding minimum = local noise floor
        var sm = [Float](repeating: 0, count: n)
        for i in 0..<n { var s: Float = 0, c: Float = 0; for k in max(0, i - 10)...min(n - 1, i + 10) { s += e[k]; c += 1 }; sm[i] = s / c }
        var lf = [Float](repeating: 0, count: n)
        for i in 0..<n { var m: Float = 1e9; for k in max(0, i - localWin)...min(n - 1, i + localWin) { m = min(m, sm[k]) }; lf[i] = max(m, -90) }
        let peak = percentile(e, 0.97)
        var loud = [Bool](repeating: false, count: n)
        for i in 0..<n { let thr = lf[i] + max(6, frac * (peak - lf[i])); loud[i] = e[i] > thr }
        for i in 1..<n where !loud[i] && loud[i - 1] && e[i] > lf[i] + max(3, frac * (peak - lf[i])) - 6 { loud[i] = true }
        for i in stride(from: n - 2, through: 0, by: -1) where !loud[i] && loud[i + 1] && e[i] > lf[i] + max(3, frac * (peak - lf[i])) - 6 { loud[i] = true }
        closeGaps(&loud, 4)
        // keep a loud run only if it has voicing (speech), else it is a breath / click / noise swell
        var runs: [(Range<Int>, Bool)] = []; var i = 0
        while i < n { if loud[i] { var j = i; var v = 0; var pk: Float = -200; while j < n && loud[j] { if f.voiced[j] > 0.5 { v += 1 }; pk = max(pk, e[j]); j += 1 }
            // speech = voiced; conservative: a loud (near speech level) run of >= 80 ms is kept too
            runs.append((i..<j, v >= vmin || (attach && j - i >= 8 && pk > peak - 12))); i = j } else { i += 1 } }
        var attached = [Bool](repeating: false, count: runs.count)
        if attach { // unvoiced runs close to speech are consonants / word tails: keep them
            for k in runs.indices where !runs[k].1 {
                let near = (k > 0 && runs[k - 1].1 && !attached[k - 1] && runs[k].0.lowerBound - runs[k - 1].0.upperBound <= 20) || (k + 1 < runs.count && runs[k + 1].1 && runs[k + 1].0.lowerBound - runs[k].0.upperBound <= 20)
                if near && runs[k].0.count >= 3 { runs[k].1 = true; attached[k] = true } } }
        var m = [Bool](repeating: false, count: n)
        guard let drop = edgeDrop else { for (r, keep) in runs where keep { for k in r { m[k] = true } }; return m }
        // app speech edges (TL-048-fix3, QuickCutDetector.mask): one level `drop` dB under the speaker's full-band level;
        // speech starts at the run's first frame above it, ends where the last voiced frame's decay sinks under it (dips
        // ≤ 3 frames bridged); sound after a longer dip (an exhale) only if sibilant (full − band ≥ 4 dB)
        let fe = f.e, ml = percentile(fe, 0.97)
        func sib(_ s: Range<Int>, _ l: Float) -> Range<Int>? { var lo = Int.max, hi = Int.min, c = 0; var sum: Float = 0
            for k in s where fe[k] >= l - 6 && f.voiced[k] <= 0.5 { lo = min(lo, k); hi = max(hi, k); sum += f.hi[k] - e[k]; c += 1 }
            return c >= 3 && sum / Float(c) >= 5 ? lo..<(hi + 1) : nil }
        func sibNear(_ edge: Int, _ fwd: Bool, _ limit: Int, _ l: Float) -> Range<Int>? {
            let low = l - 6, st = fwd ? 1 : -1; func ins(_ j: Int) -> Bool { fwd ? j < limit : j >= limit }
            var j = fwd ? edge : edge - 1, sk = 0
            while ins(j) && sk < 10 && (fe[j] < low || f.voiced[j] > 0.5) { j += st; sk += 1 }
            guard ins(j) && fe[j] >= low && f.voiced[j] <= 0.5 else { return nil }
            let j0 = j; var last = j, gap = 0
            while ins(j) && abs(j - j0) < 40 { if fe[j] >= low { last = j; gap = 0 } else { gap += 1; if gap > 3 { break } }; j += st }
            return sib(fwd ? j0..<(last + 1) : last..<(j0 + 1), l) }
        var level = runs.map { r -> Float in min(ml, r.0.map { fe[$0] }.max() ?? -200) - drop }
        for k in runs.indices where attached[k] { var l: Float = -200
            if k > 0 && runs[k - 1].1 && !attached[k - 1] { l = max(l, level[k - 1]) }
            if k + 1 < runs.count && runs[k + 1].1 && !attached[k + 1] { l = max(l, level[k + 1]) }
            level[k] = l > -200 ? l : ml - drop }
        for k in runs.indices where runs[k].1 {
            let r = runs[k].0, l = level[k]; var a: Int, b: Int
            if let c0 = r.first(where: { f.voiced[$0] > 0.5 && fe[$0] >= l }), let c1 = r.last(where: { f.voiced[$0] > 0.5 && fe[$0] >= l }) {
                a = r[r.lowerBound...c0].first(where: { fe[$0] >= l }) ?? c0; b = c1 + 1
                grow: while b < r.upperBound { for j in b..<min(r.upperBound, b + 4) where fe[j] >= l { b = j + 1; continue grow }; break }
                let bef = k > 0 ? runs[k - 1].0.upperBound : 0, aft = k + 1 < runs.count ? runs[k + 1].0.lowerBound : n
                if let s = sibNear(b, true, aft, l) { b = s.upperBound }
                if let s = sibNear(a, false, bef, l) { a = s.lowerBound }
            } else if attached[k] {
                let next = k + 1 < runs.count && runs[k + 1].1 && runs[k + 1].0.lowerBound - r.upperBound <= 20
                if next, let lo = r.first(where: { fe[$0] >= l }), let hi = r.last(where: { fe[$0] >= l }) { a = lo; b = hi + 1 }
                else if let s = sib(r, l) { a = s.lowerBound; b = s.upperBound }
                else { continue }
            } else { a = r.first(where: { fe[$0] >= l }) ?? r.lowerBound; b = (r.last(where: { fe[$0] >= l }) ?? (r.upperBound - 1)) + 1 }
            for i in a..<b { m[i] = true }
        }
        return m
    } }
func dropShort(_ m: inout [Bool], _ minLen: Int) {
    var i = 0; while i < m.count { if m[i] { var j = i; while j < m.count && m[j] { j += 1 }; if j - i < minLen { for k in i..<j { m[k] = false } }; i = j } else { i += 1 } }
}

// removal plan: gaps (runs of !mask) longer than X seconds; removed fully (padding already in mask)
// a gap qualifies on its raw length (what the user means by "a blank of more than X"); the removed part keeps
// handles of PRE before / POST after speech so attacks and tails survive; leading/trailing gaps keep only the inner handle
var PRE = 5, POST = 5   // the app's QuickCut.handleBefore / handleAfter (TL-048-fix1; the research ran with 6 / 14)
func plan(_ m: [Bool], _ X: Double) -> [Range<Int>] {
    var r: [Range<Int>] = []; var i = 0
    while i < m.count { if !m[i] { var j = i; while j < m.count && !m[j] { j += 1 }
        if Double(j - i) / 100 > X { let a = i == 0 ? 0 : i + POST, b = j == m.count ? j : j - PRE; if b - a >= 4 { r.append(a..<b) } }
        i = j } else { i += 1 } }
    return r
}
func gaps(_ m: [Bool]) -> [Range<Int>] { var r: [Range<Int>] = []; var i = 0
    while i < m.count { if !m[i] { var j = i; while j < m.count && !m[j] { j += 1 }; r.append(i..<j); i = j } else { i += 1 } }; return r }

// MARK: - eval
struct Score { var audible = 0.0, cutMs = 0.0, cutEvents = 0, pauseTime = 0.0, removedInPause = 0.0, pauses = 0, missed = 0, spurious = 0
    mutating func add(_ o: Score) { audible += o.audible; cutMs += o.cutMs; cutEvents += o.cutEvents; pauseTime += o.pauseTime; removedInPause += o.removedInPause; pauses += o.pauses; missed += o.missed; spurious += o.spurious } }
func evaluate(_ truth: [Bool], _ m: [Bool], _ X: Double) -> Score { evaluate(truth, removed: plan(Array(m[0..<min(truth.count, m.count)]), X), X) }
// the app's current ActivityProfile.silences (50 ms RMS, global percentile threshold, 0.12 s padding, >= 0.2 s kept)
func existing(_ x: [Float], _ X: Double) -> [Range<Int>] {
    let w = 800; var lv: [Float] = []; var i = 0
    while i + w <= x.count { let r = rms(x[i..<i + w]); lv.append(r > 1e-5 ? 20 * log10f(r) : -100); i += w }
    let s = lv.sorted(); let floor = s[Int(Double(s.count - 1) * 0.10)], loud = s[Int(Double(s.count - 1) * 0.90)]
    let thr: Float = loud < -50 ? loud + 1 : (loud - floor < 10 ? min(floor - 1, -50) : min(floor + max(6, 0.35 * (loud - floor)), loud - 6))
    var out: [Range<Int>] = []; var k = 0
    while k < lv.count { if lv[k] < thr { var j = k; while j < lv.count && lv[j] < thr { j += 1 }
        let a = Double(k) * 0.05, b = Double(j) * 0.05
        if b - a >= X { let pa = k == 0 ? 0 : 0.12, pb = j == lv.count ? 0 : 0.12
            if b - pb - (a + pa) >= 0.2 { out.append(Int(((a + pa) * 100).rounded())..<Int(((b - pb) * 100).rounded())) } }
        k = j } else { k += 1 } }
    return out
}
func evaluate(_ truth: [Bool], removed rr: [Range<Int>], _ X: Double) -> Score {
    var s = Score()
    let n = truth.count
    let removed = rr.map { $0.clamped(to: 0..<n) }
    let tp = gaps(Array(truth[0..<n])).filter { Double($0.count) / 100 > X }
    var inPause = [Bool](repeating: false, count: n); for p in tp { for k in p { inPause[k] = true } }
    for r in removed {
        var sp = 0, ip = 0; for k in r { if truth[k] { sp += 1 }; if inPause[k] { ip += 1 } }
        s.cutMs += Double(sp) * 10; if sp >= 3 { s.cutEvents += 1 }
        for k in r where k < curLoud.count && curLoud[k] { s.audible += 10 }
        s.removedInPause += Double(ip) / 100
        if ip * 2 < r.count { s.spurious += 1 }
    }
    for p in tp { s.pauses += 1; s.pauseTime += Double(p.count) / 100
        if Double(p.count) / 100 > X + 0.25 && !removed.contains(where: { $0.overlaps(p) }) { s.missed += 1 } }
    return s
}

// MARK: - main
let takes = buildTakes()
let truths = takes.map { truthMask($0.clean) }
// audible speech: clean frames within 30 dB of the take's speech peak
let loudTruths: [[Bool]] = takes.map { t in let n = t.clean.count / HOP; let e = (0..<n).map { db(rms(t.clean[$0 * HOP..<min(t.clean.count, $0 * HOP + HOP)])) }
    let p = percentile(e, 0.97); return e.map { $0 > p - 30 } }
var curLoud: [Bool] = []
let detectors: [Detector] = [Fixed(t: -40), Adaptive(frac: 0.35, band: true),
                             Voiced(frac: 0.2, vthr: 0.5), Hybrid(frac: 0.3, localWin: 150, vmin: 4), Hybrid(frac: 0.3, localWin: 150, vmin: 4, attach: true), Hybrid(frac: 0.25, localWin: 150, vmin: 4, attach: true),
                             Hybrid(frac: 0.3, localWin: 150, vmin: 4, attach: true, edgeDrop: 30),
                             Hybrid(frac: 0.3, localWin: 150, vmin: 4, attach: true, edgeDrop: 25)]   // e25 = the app (TL-048-fix3)
// kept pause around speech at X: median of (slice start − end of the clean speech) and (next onset − slice end), ms
func keptMedians(_ truth: [Bool], _ m: [Bool], _ X: Double) -> (after: [Int], before: [Int]) {
    let n = min(truth.count, m.count); var after: [Int] = [], before: [Int] = []
    for r in plan(Array(m[0..<n]), X) where r.lowerBound > 0 && r.upperBound < n {
        if let e = (0..<r.lowerBound).last(where: { truth[$0] }), r.lowerBound - e - 1 < 100 { after.append((r.lowerBound - e - 1) * 10) }
        if let s = (r.upperBound..<n).first(where: { truth[$0] }), s - r.upperBound < 100 { before.append((s - r.upperBound) * 10) }
    }
    return (after, before)
}
func median(_ v: [Int]) -> Int { v.isEmpty ? -1 : v.sorted()[v.count / 2] }
let Xs = [0.3, 0.5, 1.0]
var t0 = Date(), featTime = 0.0, audioSec = 0.0
print(String(format: "corpus: %d takes, %.0f s audio", takes.count, takes.reduce(0) { $0 + Double($1.clean.count) / Double(SR) }))
print("cols per X: speechCut ms / cutEvents | pause removed % | missed/pauses | spurious")
for (sname, sfn) in scenarios {
    var rng = RNG(s: 7)
    var feats: [Feat] = []
    for (i, t) in takes.enumerated() { let x = sfn(t, truths[i], &rng); let a = Date(); feats.append(features(x)); featTime += Date().timeIntervalSince(a); audioSec += Double(x.count) / Double(SR) }
    print("== \(sname)")
    do { var xs: [[Float]] = []; var r2 = RNG(s: 7); for (i, t) in takes.enumerated() { xs.append(sfn(t, truths[i], &r2)) }
        var line = "S0 app ActivityProfile".padding(toLength: 26, withPad: " ", startingAt: 0)
        for X in Xs { var tot = Score(); for (i, x) in xs.enumerated() { curLoud = loudTruths[i]; tot.add(evaluate(truths[i], removed: existing(x, X), X)) }
            line += String(format: " | X=%.1f aud%4.0f %5.0f/%-2d %3.0f%% %2d/%-2d sp%-2d", X, tot.audible, tot.cutMs, tot.cutEvents, 100 * tot.removedInPause / max(tot.pauseTime, 1e-9), tot.missed, tot.pauses, tot.spurious) }
        print(line) }
    for d in detectors {
        var line = d.name.padding(toLength: 26, withPad: " ", startingAt: 0)
        for X in Xs { var tot = Score()
            for (i, f) in feats.enumerated() { curLoud = loudTruths[i]; tot.add(evaluate(truths[i], d.mask(f), X)) }
            line += String(format: " | X=%.1f aud%4.0f %5.0f/%-2d %3.0f%% %2d/%-2d sp%-2d", X, tot.audible, tot.cutMs, tot.cutEvents, 100 * tot.removedInPause / max(tot.pauseTime, 1e-9), tot.missed, tot.pauses, tot.spurious) }
        if let h = d as? Hybrid, h.attach {
            var a: [Int] = [], b: [Int] = []
            for (i, f) in feats.enumerated() { let k = keptMedians(truths[i], h.mask(f), 0.5); a += k.after; b += k.before }
            line += " | X=0.5 kept after/before median \(median(a))/\(median(b)) ms"
        }
        print(line)
    }
}
print(String(format: "feature extraction: %.2f s for %.0f s audio (%.0fx realtime, 1 core, naive)", featTime, audioSec, audioSec / featTime))
// debug: list speech-cut events for S4 on clean & pink12 at X=0.3
for (sn, sf) in scenarios where sn == "clean" || sn == "pink-snr12" || sn == "music-bed-20dB" {
    var rng = RNG(s: 7)
    for (ti, t) in takes.enumerated() {
        let x = sf(t, truths[ti], &rng); let f = features(x); let m = Hybrid(frac: 0.3, localWin: 150, vmin: 4).mask(f)
        let n = min(m.count, truths[ti].count)
        for r in plan(Array(m[0..<n]), 0.5) { let sp = r.filter { truths[ti][$0] }; if sp.count >= 3 {
            let pk = sp.map { f.be[$0] }.max()!, vo = sp.map { f.voiced[$0] }.max()!
            print(String(format: "%@ %@ removed %.2f-%.2f speech frames %d (%.2f-%.2f) peakBand %.1f dB voiced %.2f p97 %.1f", sn, t.name, Double(r.lowerBound)/100, Double(r.upperBound)/100, sp.count, Double(sp.first!)/100, Double(sp.last!)/100, pk, vo, percentile(f.be, 0.97))) } }
    }
}
// real files: print kept segments
for name in ["real_speech_en", "real_speech_fr", "real_a"] {
    let x = load(name); let f = features(x); let m = Hybrid(frac: 0.3, localWin: 150, vmin: 4).mask(f)
    let segs = gaps(m.map { !$0 }).map { String(format: "%.2f-%.2f", Double($0.lowerBound)/100, Double($0.upperBound)/100) }
    print(String(format: "%@ %.1fs floor p10 %.1f p97 %.1f keep: ", name, Double(x.count)/16000, percentile(f.be, 0.1), percentile(f.be, 0.97)), segs.joined(separator: " "))
    for X in [0.3, 0.5, 1.0] { let r = plan(m, X); print(String(format: "  X=%.1f removes %d gaps, %.1f s", X, r.count, Double(r.reduce(0) { $0 + $1.count }) / 100)) }
}
