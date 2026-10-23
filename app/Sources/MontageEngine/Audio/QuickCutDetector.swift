import Accelerate
import Foundation
import MontageCore

/// Quick cut blank detector (TL-048, docs/QUICK_CUT.md §4, strategy "S5 hybrid"): a faithful, streaming port of
/// `Hybrid(attach: true)` (frac 0.3, localWin 150, vmin 4) from docs/quickcut/bench.swift, where it was tuned on a
/// 10-condition corpus. Feed 16 kHz mono Float32 in chunks of any size, then `finish()`.
///
/// Per 10 ms frame: band (150 Hz HP + 4 kHz LP biquads) energy over 25 ms, and a voicing score (max normalised
/// autocorrelation for 67–400 Hz on the band signal decimated to 8 kHz, 32 ms window). The streaming state keeps only a
/// few hundred samples; the per-frame features (2 floats / 10 ms) are kept until `finish` builds the mask.
public struct QuickCutDetector: Sendable {
    public static let sampleRate = 16000
    static let hop = 160            // 10 ms
    static let window = 400         // 25 ms energy window
    static let vWindow = 256        // 32 ms at 8 kHz
    static let minLag = 20, maxLag = 120   // 400 … 67 Hz at 8 kHz
    // Hybrid parameters (bench: frac 0.3, localWin 150, vmin 4, attach)
    static let frac: Float = 0.3
    static let localWin = 150
    static let vmin = 4

    /// Per-frame features (exposed for tests): band energy (dB), voicing (0 … 1, 0 where not computed) and full-band
    /// energy (dB, same 25 ms window: decides the speech edges, fricatives above 4 kHz included) and energy above
    /// 4 kHz (dB, same window: tells a fricative /s/ from a breath or an exhale). `high` empty = not computed.
    public struct Features: Sendable {
        public var energy: [Float]
        public var voicing: [Float]
        public var full: [Float]
        public var high: [Float] = []
    }

    private let filter = BandFilter()      // 150 Hz HP + 4 kHz LP (vDSP biquad cascade, keeps its state)
    private let highFilter = BandFilter.high()
    private var total = 0                  // samples fed
    private var band: [Float] = []         // band signal, band[0] = sample `bandBase`
    private var raw: [Float] = []          // input signal, same indexing as `band`
    private var hp: [Float] = []           // input above 4 kHz, same indexing as `band`
    private var high: [Float] = []
    private var bandBase = 0
    private var dec: [Float] = []          // 8 kHz decimated band, dec[0] = sample `decBase`
    private var decBase = 0
    private var decCount = 0               // decimated samples produced
    private var energy: [Float] = []
    private var voicing: [Float] = []
    private var full: [Float] = []
    /// Scratch of `voicing` (correlations, lag energies, squares).
    private var corr = [Float](repeating: 0, count: QuickCutDetector.workCount)
    static let workCount = 3 * (maxLag - minLag + 1) + vWindow

    /// A detector holds filter state by reference: use one instance per stream (don't copy it mid-stream).
    public init() {}

    public mutating func feed(_ x: UnsafeBufferPointer<Float>) {
        guard let src = x.baseAddress, x.count > 0 else { return }
        let start = band.count
        band.append(contentsOf: repeatElement(0, count: x.count))
        band.withUnsafeMutableBufferPointer { b in filter.run(src, b.baseAddress! + start, x.count) }
        raw.append(contentsOf: x)
        hp.append(contentsOf: repeatElement(0, count: x.count))
        hp.withUnsafeMutableBufferPointer { h in highFilter.run(src, h.baseAddress! + start, x.count) }
        total += x.count
        decimate()
        process(final: false)
    }

    public mutating func feed(_ x: [Float]) { x.withUnsafeBufferPointer { feed($0) } }

    /// Features of everything fed (call once, at the end).
    public mutating func finishFeatures() -> Features {
        process(final: true)
        return Features(energy: energy, voicing: voicing, full: full, high: high)
    }

    /// The speech mask of everything fed.
    public mutating func finish() -> QuickCutMask { Self.mask(finishFeatures()) }

    /// Whole-signal convenience.
    public static func mask(samples: [Float]) -> QuickCutMask {
        var d = QuickCutDetector()
        d.feed(samples)
        return d.finish()
    }

    // MARK: Streaming features

    private mutating func decimate() {
        // dec[k] = (band[2k] + band[2k+1]) / 2 for every complete pair
        let pairs = total / 2
        guard pairs > decCount else { return }
        let n = pairs - decCount
        let first = 2 * decCount - bandBase
        let start = dec.count
        dec.append(contentsOf: repeatElement(0, count: n))
        band.withUnsafeBufferPointer { b in
            dec.withUnsafeMutableBufferPointer { d in
                var half: Float = 0.5
                // (even + odd) * 0.5 with strided reads
                vDSP_vasm(b.baseAddress! + first, 2, b.baseAddress! + first + 1, 2, &half, d.baseAddress! + start, 1, vDSP_Length(n))
            }
        }
        decCount = pairs
    }

    /// Computes every frame whose windows are complete (or all frames when `final`), then drops consumed samples.
    private mutating func process(final: Bool) {
        let n = total / Self.hop   // frames of the whole signal so far (bench: x.count / HOP)
        // energy: frame i uses band[a ..< a + 400], a = max(0, i·160 − 120)
        band.withUnsafeBufferPointer { b in
            raw.withUnsafeBufferPointer { r in
                hp.withUnsafeBufferPointer { h in
                    while energy.count < n {
                        let i = energy.count
                        let a = max(0, i * Self.hop + Self.hop / 2 - Self.window / 2)
                        let e = min(total, a + Self.window)
                        if !final && a + Self.window > total { break }
                        var ms: Float = 0, mf: Float = 0, mh: Float = 0
                        vDSP_measqv(b.baseAddress! + (a - bandBase), 1, &ms, vDSP_Length(e - a))
                        vDSP_measqv(r.baseAddress! + (a - bandBase), 1, &mf, vDSP_Length(e - a))
                        vDSP_measqv(h.baseAddress! + (a - bandBase), 1, &mh, vDSP_Length(e - a))
                        energy.append(20 * log10f(max(sqrtf(ms), 1e-6)))
                        full.append(20 * log10f(max(sqrtf(mf), 1e-6)))
                        high.append(20 * log10f(max(sqrtf(mh), 1e-6)))
                    }
                }
            }
        }
        // voicing: frame i, decimated window start c = i·80 + 40 − 128; needs c ≥ 0 and c + 256 + 120 < decimated count
        let span = Self.vWindow + Self.maxLag
        dec.withUnsafeBufferPointer { d in
            corr.withUnsafeMutableBufferPointer { cr in
                while voicing.count < min(n, energy.count) {
                    let i = voicing.count
                    let c = i * Self.hop / 2 + Self.hop / 4 - Self.vWindow / 2
                    if c + span >= decCount {
                        if !final { break }
                        voicing.append(0); continue   // window runs past the end (bench: skipped)
                    }
                    // frames this quiet are below any possible voicing gate (gate ≥ −90 + 4 dB): skip the work
                    guard c >= 0, energy[i] > -86 else { voicing.append(0); continue }
                    voicing.append(Self.voicing(d.baseAddress! + (c - decBase), cr.baseAddress!))
                }
            }
        }
        // drop what no later frame reads
        let nextE = energy.count
        let keepBand = max(0, nextE * Self.hop + Self.hop / 2 - Self.window / 2)
        let keepBandFrom = min(keepBand, 2 * decCount)   // samples not yet decimated stay too
        if keepBandFrom - bandBase > 1 << 15 {
            band.removeFirst(keepBandFrom - bandBase); raw.removeFirst(keepBandFrom - bandBase); hp.removeFirst(keepBandFrom - bandBase)
            bandBase = keepBandFrom
        }
        let nextV = voicing.count
        let keepDec = max(0, nextV * Self.hop / 2 + Self.hop / 4 - Self.vWindow / 2)
        if keepDec - decBase > 1 << 15 {
            dec.removeFirst(keepDec - decBase); decBase = keepDec
        }
    }

    /// Max normalised autocorrelation over lags 20 … 120 of the 256-sample window at `w` (bench `features`).
    /// `work` holds `workCount` floats.
    static func voicing(_ w: UnsafePointer<Float>, _ work: UnsafeMutablePointer<Float>) -> Float {
        let W = vDSP_Length(vWindow)
        var e0: Float = 0
        vDSP_dotpr(w, 1, w, 1, &e0, W)
        guard e0 > 1e-9 else { return 0 }
        let lags = maxLag - minLag + 1
        let corr = work, el = work + lags, sq = work + 2 * lags
        // corr[k] = Σ_p w[minLag + k + p] · w[p]  (all lags in one call)
        vDSP_conv(w + minLag, 1, w, 1, corr, 1, vDSP_Length(lags), W)
        // el[k] = energy of the window at lag minLag + k (bench: updated incrementally), as a sliding sum of squares
        let span = lags + vWindow - 1
        vDSP_vsq(w + minLag, 1, sq, 1, vDSP_Length(span))
        vDSP_vswsum(sq, 1, el, 1, vDSP_Length(lags), W)
        // r[k] = corr[k] / sqrt(e0 · el[k] + 1e-12); best = max(0, max r)
        var tiny: Float = 1e-12, e = e0
        vDSP_vsmsa(el, 1, &e, &tiny, el, 1, vDSP_Length(lags))
        var n = Int32(lags)
        vvsqrtf(el, el, &n)
        vDSP_vdiv(el, 1, corr, 1, corr, 1, vDSP_Length(lags))
        var best: Float = 0
        vDSP_maxv(corr, 1, &best, vDSP_Length(lags))
        return max(best, 0)
    }

    // MARK: Mask (bench `Hybrid.mask`, attach = true)

    static func percentile(_ a: [Float], _ p: Float) -> Float {
        let s = a.sorted()
        return s[min(s.count - 1, Int(Float(s.count - 1) * p))]
    }

    /// Speech edges (dB under the speaker's level, full band): where speech starts and ends, the same level on both
    /// sides (TL-048-fix3, docs/QUICK_CUT.md §4 step 7). On the owner's iPhone rushes the voice is heard to stop where
    /// the word's decay crosses ≈ 20–25 dB under the speaker's level; the former 35 dB (fix2) also kept the decay's
    /// last 30–60 ms and, worse, the exhale that follows most phrases (≈ 100–160 ms of hiss ≈ 20 dB under the voice,
    /// after a dip), so ≈ 0.2 s more was kept after speech than before it.
    static let edgeDrop: Float = 25
    /// Mean energy above 4 kHz minus detection-band energy (dB, unvoiced frames) above which a segment is sibilant
    /// (/s/, /z/ devoiced) and stays speech even when a dip separates it from the voice ("…ste", "st…") or the
    /// detection band misses it. Measured on the owner's rushes: /s/ +6 … +9 dB, exhales after a phrase −5 … +3.5 dB.
    static let sibilance: Float = 5
    /// A fricative is quieter than vowels: its frames count from `sibilantMargin` dB under the edge level.
    static let sibilantMargin: Float = 6
    /// Dips under the edge level this short (frames) don't end the voice's decay (flutter); the exhale after a phrase
    /// is cut off from the voice by a dip of ≥ 50 ms.
    static let bridge = 3

    public static func mask(_ f: Features) -> QuickCutMask { mask(f, edgeDrop: edgeDrop) }

    static func mask(_ f: Features, edgeDrop: Float) -> QuickCutMask {
        let e = f.energy, n = e.count
        guard n > 0 else { return .empty }
        // voicing only counts where the band energy is clearly above the media's floor (bench gate)
        let floor = max(percentile(e, 0.10), -90)
        let gate = floor + 4
        let peak = percentile(e, 0.97)
        // smoothed energy (210 ms mean) → sliding minimum over ±1.5 s = local noise floor
        var prefix = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + Double(e[i]) }
        var sm = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let a = max(0, i - 10), b = min(n - 1, i + 10)
            sm[i] = Float((prefix[b + 1] - prefix[a]) / Double(b - a + 1))
        }
        let lf = slidingMin(sm, radius: localWin).map { max($0, -90) }
        var loud = [Bool](repeating: false, count: n)
        for i in 0..<n { loud[i] = e[i] > lf[i] + max(6, frac * (peak - lf[i])) }
        func low(_ i: Int) -> Float { lf[i] + max(3, frac * (peak - lf[i])) - 6 }
        if n > 1 {
            for i in 1..<n where !loud[i] && loud[i - 1] && e[i] > low(i) { loud[i] = true }
            for i in stride(from: n - 2, through: 0, by: -1) where !loud[i] && loud[i + 1] && e[i] > low(i) { loud[i] = true }
        }
        closeGaps(&loud, 4)
        // a loud run is speech when voiced (or loud and long enough), else a breath / click / noise swell
        var runs: [(r: Range<Int>, keep: Bool, attached: Bool)] = []
        var i = 0
        while i < n {
            guard loud[i] else { i += 1; continue }
            var j = i, v = 0
            var pk: Float = -200
            while j < n && loud[j] {
                if e[j] > gate && f.voicing[j] > 0.5 { v += 1 }
                pk = max(pk, e[j]); j += 1
            }
            runs.append((i..<j, v >= vmin || (j - i >= 8 && pk > peak - 12), false))
            i = j
        }
        // unvoiced runs next to speech are consonants / word tails
        for k in runs.indices where !runs[k].keep {
            let near = (k > 0 && runs[k - 1].keep && !runs[k - 1].attached && runs[k].r.lowerBound - runs[k - 1].r.upperBound <= 20)
                || (k + 1 < runs.count && runs[k + 1].keep && runs[k + 1].r.lowerBound - runs[k].r.upperBound <= 20)
            if near && runs[k].r.count >= 3 { runs[k].keep = true; runs[k].attached = true }
        }
        var m = [Bool](repeating: false, count: n)
        var any = false
        // Speech edges (TL-048-fix3, docs/QUICK_CUT.md §4 step 7): ONE audibility level for the start and the end,
        // `edgeDrop` under the speaker's level (the media's full-band p97, or the run's own peak when quieter).
        // Speech starts at the run's first frame above it and ends where the last voiced frame's decay sinks under it.
        // Unvoiced sound cut off from the voice by a dip below the level after the last word (an exhale) is not
        // speech unless it is sibilant (a final /s/).
        let fe = f.full.count == n ? f.full : e
        let mediaLevel = percentile(fe, 0.97)
        let hf = f.high.count == n ? f.high : [Float](repeating: -200, count: n)   // no high band: nothing is sibilant
        func sibilant(_ s: Range<Int>, _ lvl: Float) -> Range<Int>? {
            var lo = Int.max, hi = Int.min, c = 0
            var sum: Float = 0
            for k in s where fe[k] >= lvl - sibilantMargin && f.voicing[k] <= 0.5 {
                lo = min(lo, k); hi = max(hi, k); sum += hf[k] - e[k]; c += 1
            }
            return c >= 3 && sum / Float(c) >= sibilance ? lo..<(hi + 1) : nil
        }
        // the unvoiced sound segment starting within 100 ms of `edge` (frames ≥ the fricative level, dips ≤ `bridge`
        // bridged, ≤ 400 ms, not past `limit`), when sibilant
        func sibilantNear(_ edge: Int, forward: Bool, limit: Int, _ lvl: Float) -> Range<Int>? {
            let low = lvl - sibilantMargin, step = forward ? 1 : -1
            func inside(_ j: Int) -> Bool { forward ? j < limit : j >= limit }
            var j = forward ? edge : edge - 1
            var skipped = 0
            // skip the voice's own decay / attack and the dip (≤ 100 ms) to the first unvoiced frame above the level
            while inside(j) && skipped < 10 && (fe[j] < low || f.voicing[j] > 0.5) { j += step; skipped += 1 }
            guard inside(j) && fe[j] >= low && f.voicing[j] <= 0.5 else { return nil }
            let j0 = j
            var last = j, gap = 0
            while inside(j) && abs(j - j0) < 40 {
                if fe[j] >= low { last = j; gap = 0 } else { gap += 1; if gap > bridge { break } }
                j += step
            }
            return sibilant(forward ? j0..<(last + 1) : last..<(j0 + 1), lvl)
        }
        // the level per run: its own peak when quieter than the media's (a quiet speaker); an attached run takes the
        // level of the speech it is attached to
        var level = runs.map { run -> Float in
            var p: Float = -200
            for i in run.r { p = max(p, fe[i]) }
            return min(mediaLevel, p) - edgeDrop
        }
        for k in runs.indices where runs[k].attached {
            var l: Float = -200
            if k > 0 && runs[k - 1].keep && !runs[k - 1].attached { l = max(l, level[k - 1]) }
            if k + 1 < runs.count && runs[k + 1].keep && !runs[k + 1].attached { l = max(l, level[k + 1]) }
            level[k] = l > -200 ? l : mediaLevel - edgeDrop
        }
        for k in runs.indices where runs[k].keep {
            let r = runs[k].r
            let lvl = level[k]
            var a: Int, b: Int
            if let c0 = r.first(where: { e[$0] > gate && f.voicing[$0] > 0.5 && fe[$0] >= lvl }),
               let c1 = r.last(where: { e[$0] > gate && f.voicing[$0] > 0.5 && fe[$0] >= lvl }) {
                // start: the first audible frame (a consonant's burst, aspiration or fricative is the word's first sound,
                // even when a closure dips between it and the vowel)
                a = r[r.lowerBound...c0].first(where: { fe[$0] >= lvl }) ?? c0
                // end: the voice's decay down to the same level (dips of ≤ `bridge` frames bridged); sound cut off from
                // it by a longer dip is an exhale unless sibilant (a final /s/)
                b = c1 + 1
                grow: while b < r.upperBound {
                    for j in b..<min(r.upperBound, b + 1 + bridge) where fe[j] >= lvl { b = j + 1; continue grow }
                    break
                }
                // a fricative next to the voice, on either side: its energy is mostly above the detection band, so it
                // can lie outside the loud run
                let before = k > 0 ? runs[k - 1].r.upperBound : 0, after = k + 1 < runs.count ? runs[k + 1].r.lowerBound : n
                if let s = sibilantNear(b, forward: true, limit: after, lvl) { b = s.upperBound }
                if let s = sibilantNear(a, forward: false, limit: before, lvl) { a = s.lowerBound }
            } else if runs[k].attached {
                // an unvoiced run near speech: a consonant before the next voiced run (or between two), or a sibilant
                // after the last one
                let next = k + 1 < runs.count && runs[k + 1].keep && runs[k + 1].r.lowerBound - r.upperBound <= 20
                if next, let lo = r.first(where: { fe[$0] >= lvl }), let hi = r.last(where: { fe[$0] >= lvl }) {
                    a = lo; b = hi + 1
                } else if let s = sibilant(r, lvl) { a = s.lowerBound; b = s.upperBound }
                else { continue }
            } else {
                // loud unvoiced run (conservative: kept), trimmed to the level
                a = r.first(where: { fe[$0] >= lvl }) ?? r.lowerBound
                b = (r.last(where: { fe[$0] >= lvl }) ?? (r.upperBound - 1)) + 1
            }
            any = true
            for i in a..<b { m[i] = true }
        }
        return QuickCutMask(speech: m, hasDynamics: any && peak - floor >= 10)
    }

    /// Minimum of `x` over [i − radius, i + radius] for every i (monotonic deque, O(n)).
    static func slidingMin(_ x: [Float], radius: Int) -> [Float] {
        let n = x.count
        var out = [Float](repeating: 0, count: n)
        var dq = [Int](repeating: 0, count: n)
        var head = 0, tail = 0
        var next = 0   // next index to push
        for i in 0..<n {
            let hi = min(n - 1, i + radius)
            while next <= hi {
                while tail > head && x[dq[tail - 1]] >= x[next] { tail -= 1 }
                dq[tail] = next; tail += 1; next += 1
            }
            while dq[head] < i - radius { head += 1 }
            out[i] = x[dq[head]]
        }
        return out
    }

    static func closeGaps(_ m: inout [Bool], _ maxGap: Int) {
        var i = 0
        while i < m.count {
            if !m[i] {
                var j = i
                while j < m.count && !m[j] { j += 1 }
                if i > 0 && j < m.count && j - i <= maxGap { for k in i..<j { m[k] = true } }
                i = j
            } else { i += 1 }
        }
    }
}

/// The detector's band-pass: the bench's two RBJ biquads (150 Hz high-pass, then 4 kHz low-pass, Q 0.707) as one
/// vDSP biquad cascade whose delay line carries over between chunks.
final class BandFilter: @unchecked Sendable {
    private let setup: vDSP_biquad_Setup
    private var delay: [Float]

    convenience init() {
        let sr = Double(QuickCutDetector.sampleRate)
        self.init([Biquad2.highPass(150, sampleRate: sr), Biquad2.lowPass(4000, sampleRate: sr)])
    }

    /// The fricative filter: 4 kHz high-pass, 4th order (TL-048-fix3, `Features.high`).
    static func high() -> BandFilter {
        let sr = Double(QuickCutDetector.sampleRate)
        return BandFilter([Biquad2.highPass(4000, sampleRate: sr), Biquad2.highPass(4000, sampleRate: sr)])
    }

    init(_ sections: [Biquad2]) {
        let c = sections.flatMap { [$0.b0, $0.b1, $0.b2, $0.a1, $0.a2].map(Double.init) }
        setup = vDSP_biquad_CreateSetup(c, vDSP_Length(sections.count))!
        delay = [Float](repeating: 0, count: 2 * sections.count + 2)
    }
    deinit { vDSP_biquad_DestroySetup(setup) }

    func run(_ x: UnsafePointer<Float>, _ y: UnsafeMutablePointer<Float>, _ n: Int) {
        vDSP_biquad(setup, &delay, x, 1, y, 1, vDSP_Length(n))
    }
}

/// One RBJ biquad section (coefficients as in the bench; `run` = transposed direct form II, used by tests).
struct Biquad2: Sendable {
    var b0, b1, b2, a1, a2: Float
    var z1: Float = 0, z2: Float = 0

    static func highPass(_ f: Double, sampleRate sr: Double, q: Double = 0.707) -> Biquad2 {
        let w = Float(2 * Double.pi * f / sr), al = sinf(w) / Float(2 * q), c = cosf(w), a0 = 1 + al
        return Biquad2(b0: (1 + c) / 2 / a0, b1: -(1 + c) / a0, b2: (1 + c) / 2 / a0, a1: -2 * c / a0, a2: (1 - al) / a0)
    }
    static func lowPass(_ f: Double, sampleRate sr: Double, q: Double = 0.707) -> Biquad2 {
        let w = Float(2 * Double.pi * f / sr), al = sinf(w) / Float(2 * q), c = cosf(w), a0 = 1 + al
        return Biquad2(b0: (1 - c) / 2 / a0, b1: (1 - c) / a0, b2: (1 - c) / 2 / a0, a1: -2 * c / a0, a2: (1 - al) / a0)
    }

    /// Filters `n` samples from `x` into `y` (may alias).
    mutating func run(_ x: UnsafePointer<Float>, _ y: UnsafeMutablePointer<Float>, _ n: Int) {
        var z1 = self.z1, z2 = self.z2
        let b0 = self.b0, b1 = self.b1, b2 = self.b2, a1 = self.a1, a2 = self.a2
        for i in 0..<n {
            let v = x[i]
            let o = b0 * v + z1
            z1 = b1 * v - a1 * o + z2
            z2 = b2 * v - a2 * o
            y[i] = o
        }
        self.z1 = z1; self.z2 = z2
    }
}
