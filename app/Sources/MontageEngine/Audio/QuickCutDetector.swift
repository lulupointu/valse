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
    /// energy (dB, same 25 ms window: decides the speech edges, fricatives above 4 kHz included).
    public struct Features: Sendable {
        public var energy: [Float]
        public var voicing: [Float]
        public var full: [Float]
    }

    private let filter = BandFilter()      // 150 Hz HP + 4 kHz LP (vDSP biquad cascade, keeps its state)
    private var total = 0                  // samples fed
    private var band: [Float] = []         // band signal, band[0] = sample `bandBase`
    private var raw: [Float] = []          // input signal, same indexing as `band`
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
        total += x.count
        decimate()
        process(final: false)
    }

    public mutating func feed(_ x: [Float]) { x.withUnsafeBufferPointer { feed($0) } }

    /// Features of everything fed (call once, at the end).
    public mutating func finishFeatures() -> Features {
        process(final: true)
        return Features(energy: energy, voicing: voicing, full: full)
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
                while energy.count < n {
                    let i = energy.count
                    let a = max(0, i * Self.hop + Self.hop / 2 - Self.window / 2)
                    let e = min(total, a + Self.window)
                    if !final && a + Self.window > total { break }
                    var ms: Float = 0, mf: Float = 0
                    vDSP_measqv(b.baseAddress! + (a - bandBase), 1, &ms, vDSP_Length(e - a))
                    vDSP_measqv(r.baseAddress! + (a - bandBase), 1, &mf, vDSP_Length(e - a))
                    energy.append(20 * log10f(max(sqrtf(ms), 1e-6)))
                    full.append(20 * log10f(max(sqrtf(mf), 1e-6)))
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
            band.removeFirst(keepBandFrom - bandBase); raw.removeFirst(keepBandFrom - bandBase); bandBase = keepBandFrom
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

    /// Speech edges (dB): a run's leading / trailing frames whose full-band energy is more than this far below the
    /// media's full-band speech peak (p97) are not speech (TL-048-fix2, docs/QUICK_CUT.md §4 step 7). One level for the
    /// onset and the end of speech: onsets rise through it within a frame, but a word's decay (and the room's reverb)
    /// takes 200–300 ms to sink from there to the detection threshold, which used to be kept as a blank before every
    /// cut. 35 dB: no audible speech cut on the bench corpus (30 dB started clipping word endings).
    static let edgeDrop: Float = 35

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
        // edges: the same level decides where speech starts and ends (`edgeDrop` below the media's full-band speech
        // peak, so fricatives above the detection band count). A speech run entirely below it (a quiet speaker in a
        // loud media) is kept whole; an attached unvoiced run below it is inaudible and dropped.
        let fe = f.full.count == n ? f.full : e
        let edge = percentile(fe, 0.97) - edgeDrop
        for (r, keep, attached) in runs where keep {
            var a = r.lowerBound, b = r.upperBound
            while a < b && fe[a] < edge { a += 1 }
            while b > a && fe[b - 1] < edge { b -= 1 }
            if a == b {
                if attached { continue }
                a = r.lowerBound; b = r.upperBound
            }
            any = true
            for k in a..<b { m[k] = true }
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
    private var delay = [Float](repeating: 0, count: 2 * 2 + 2)

    init() {
        let sr = Double(QuickCutDetector.sampleRate)
        let c = [Biquad2.highPass(150, sampleRate: sr), Biquad2.lowPass(4000, sampleRate: sr)]
            .flatMap { [$0.b0, $0.b1, $0.b2, $0.a1, $0.a2].map(Double.init) }
        setup = vDSP_biquad_CreateSetup(c, 2)!
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
