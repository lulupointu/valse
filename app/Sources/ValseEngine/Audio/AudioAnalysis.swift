import Foundation
import ValseCore

/// Offline audio analysis: integrated loudness (BS.1770 / EBU R128), onset envelope, tempo & beat tracking,
/// envelope cross-correlation sync. Pure DSP over `AudioBuffer`s plus file helpers.
public enum AudioAnalysis {

    // MARK: Loudness (ITU-R BS.1770-4)

    /// Streaming integrated-loudness meter: K-weighting, 400 ms blocks with 75 % overlap, −70 LUFS absolute gate and
    /// −10 LU relative gate.
    public final class LoudnessMeter {
        let sampleRate: Double
        private var filters: [[Biquad]]
        private var blockPower: [Double] = []
        private var acc: [Double]
        private var stepCount = 0
        private var steps: [[Double]] = []  // per 100 ms step: per-channel sum of squares
        private let stepLen: Int

        public init(sampleRate: Double, channels: Int) {
            self.sampleRate = sampleRate
            let shelf = BiquadCoefficients.highShelf(1500, gainDB: 4, sampleRate: sampleRate)
            let hp = BiquadCoefficients.highPass(38, q: 0.5, sampleRate: sampleRate)
            filters = (0..<channels).map { _ in [Biquad(shelf), Biquad(hp)] }
            acc = [Double](repeating: 0, count: channels)
            stepLen = Int(sampleRate * 0.1)
        }

        public func feed(_ b: AudioBlock) {
            let ch = min(b.channels, filters.count)
            for i in 0..<b.frames {
                for c in 0..<ch {
                    var x = b[c][i]
                    x = filters[c][0].tick(x); x = filters[c][1].tick(x)
                    acc[c] += Double(x) * Double(x)
                }
                stepCount += 1
                if stepCount == stepLen {
                    steps.append(acc); for c in acc.indices { acc[c] = 0 }; stepCount = 0
                    if steps.count >= 4 {
                        let last = steps.suffix(4)
                        var z = 0.0
                        for c in acc.indices { z += last.reduce(0) { $0 + $1[c] } / Double(4 * stepLen) }
                        blockPower.append(z)
                    }
                }
            }
        }

        /// Integrated loudness in LUFS (−∞ for silence).
        public var integrated: Double {
            func lufs(_ p: Double) -> Double { -0.691 + 10 * log10(max(p, 1e-30)) }
            let abs = blockPower.filter { lufs($0) > -70 }
            guard !abs.isEmpty else { return -.infinity }
            let rel = lufs(abs.reduce(0, +) / Double(abs.count)) - 10
            let gated = abs.filter { lufs($0) > rel }
            guard !gated.isEmpty else { return -.infinity }
            return lufs(gated.reduce(0, +) / Double(gated.count))
        }
    }

    public static func loudness(_ b: AudioBuffer) -> Double {
        let m = LoudnessMeter(sampleRate: b.sampleRate, channels: b.channels)
        m.feed(b.block)
        return m.integrated
    }

    /// Integrated loudness of a file's source range (streams; any length).
    public static func loudness(url: URL, range: TimeRange? = nil) async throws -> Double {
        let m = LoudnessMeter(sampleRate: AudioFileIO.sampleRate, channels: 2)
        try await AudioFileIO.stream(url, range: range) { m.feed($0) }
        return m.integrated
    }

    // MARK: Onsets, tempo, beats

    /// Analysis rate for onset/beat work.
    public static let onsetSampleRate: Double = 22050
    static let onsetN = 1024, onsetHop = 220

    /// Onset strength envelope (log-magnitude spectral flux, half-wave rectified, local-mean removed), one value per
    /// `onsetHop` samples at `onsetSampleRate`; value i is centred at `onsetTime(i)`.
    public static func onsetEnvelope(_ mono: [Float]) -> [Float] {
        let n = onsetN, hop = onsetHop
        guard mono.count > n else { return [] }
        let fft = RealFFT(n: n)
        let win = (0..<n).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n))) }
        let bins = n / 2 + 1
        var re = [Float](repeating: 0, count: bins), im = re, prev = re, cur = re
        var frame = [Float](repeating: 0, count: n)
        var env: [Float] = []
        var pos = 0
        while pos + n <= mono.count {
            for k in 0..<n { frame[k] = mono[pos + k] * win[k] }
            frame.withUnsafeBufferPointer { f in re.withUnsafeMutableBufferPointer { r in im.withUnsafeMutableBufferPointer { i in
                fft.forward(f.baseAddress!, r.baseAddress!, i.baseAddress!) } } }
            var flux: Float = 0
            for k in 1..<bins {
                cur[k] = log(1 + 100 * sqrt(re[k] * re[k] + im[k] * im[k]))
                let d = cur[k] - prev[k]
                if d > 0 { flux += d }
            }
            env.append(env.isEmpty ? 0 : flux)
            swap(&prev, &cur)
            pos += hop
        }
        // remove the local mean (±0.25 s) and normalize
        let w = Int(0.25 * onsetSampleRate / Double(hop))
        var out = [Float](repeating: 0, count: env.count)
        var sum: Float = 0
        var lo = 0, hi = 0
        for i in env.indices {
            while hi < env.count && hi <= i + w { sum += env[hi]; hi += 1 }
            while lo < i - w { sum -= env[lo]; lo += 1 }
            out[i] = max(0, env[i] - sum / Float(hi - lo))
        }
        let mean = out.reduce(0, +) / Float(max(1, out.count))
        let sd = sqrt(out.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(max(1, out.count)))
        return sd > 0 ? out.map { $0 / sd } : out
    }

    public static func onsetTime(_ i: Int) -> Double { (Double(i * onsetHop) + Double(onsetN) / 2) / onsetSampleRate }

    public struct BeatResult: Sendable, Equatable {
        public var bpm: Double
        /// Every beat, seconds from the start of the analysed audio.
        public var beats: [Double]
        /// Every other beat, phase with the strongest onsets ("Beats 1").
        public var strongBeats: [Double]
    }

    /// Tempo (autocorrelation with a log-normal prior around 120 BPM) + dynamic-programming beat tracking (Ellis 2007).
    public static func beats(onsets o: [Float]) -> BeatResult {
        let fps = onsetSampleRate / Double(onsetHop)
        guard o.count > Int(fps * 2) else { return BeatResult(bpm: 0, beats: [], strongBeats: []) }
        let minLag = Int(fps * 60 / 200), maxLag = Int(fps * 60 / 55)
        var best = 0.0, bestLag = Int(fps / 2)
        var ac = [Double](repeating: 0, count: maxLag + 2)
        for lag in max(1, minLag - 1)...min(maxLag + 1, o.count - 1) {
            var s = 0.0
            for i in lag..<o.count { s += Double(o[i]) * Double(o[i - lag]) }
            ac[lag] = s / Double(o.count - lag)
        }
        for lag in minLag...min(maxLag, o.count - 2) {
            let bpm = 60 * fps / Double(lag)
            let prior = exp(-0.5 * pow(log2(bpm / 120) / 0.9, 2))
            // reward lags whose double also correlates (metrical consistency)
            let dbl = 2 * lag < ac.count ? ac[2 * lag] : 0
            let score = (ac[lag] + 0.5 * dbl) * prior
            if score > best { best = score; bestLag = lag }
        }
        // parabolic refinement of the period
        var period = Double(bestLag)
        if bestLag > 1 && bestLag + 1 < ac.count {
            let a = ac[bestLag - 1], b = ac[bestLag], c = ac[bestLag + 1]
            let den = a - 2 * b + c
            if den < 0 { period += 0.5 * (a - c) / den }
        }
        let p = period
        let tightness = 100.0
        var score = [Double](repeating: 0, count: o.count), back = [Int](repeating: -1, count: o.count)
        for t in 0..<o.count {
            var bestPrev = -1, bestVal = -Double.infinity
            let lo = max(0, t - Int(2 * p)), hi = t - Int(p / 2)
            if hi >= lo {
                for tau in lo...hi {
                    let v = score[tau] - tightness * pow(log(Double(t - tau) / p), 2)
                    if v > bestVal { bestVal = v; bestPrev = tau }
                }
            }
            score[t] = Double(o[t]) + (bestPrev >= 0 ? max(bestVal, 0) : 0)
            back[t] = bestVal > 0 ? bestPrev : -1
        }
        let tail = max(0, o.count - Int(p))
        var t = (tail..<o.count).max { score[$0] < score[$1] } ?? o.count - 1
        var idx: [Int] = []
        while t >= 0 { idx.append(t); t = back[t] }
        idx.reverse()
        let beats = idx.map { onsetTime($0) }
        let even = stride(from: 0, to: idx.count, by: 2).reduce(0.0) { $0 + Double(o[idx[$1]]) }
        let odd = stride(from: 1, to: idx.count, by: 2).reduce(0.0) { $0 + Double(o[idx[$1]]) }
        let phase = even >= odd ? 0 : 1
        let strong = stride(from: phase, to: beats.count, by: 2).map { beats[$0] }
        return BeatResult(bpm: 60 * fps / p, beats: beats, strongBeats: strong)
    }

    /// Beats of a file's source range (times relative to `range.start`).
    public static func beats(url: URL, range: TimeRange? = nil) async throws -> BeatResult {
        let mono = try await AudioFileIO.read(url, sampleRate: onsetSampleRate, channels: 1, range: range).channel(0)
        return beats(onsets: onsetEnvelope(mono))
    }

    /// Beat markers for a clip in clip-local time (CapCut "Beats 1" = level 1, "Beats 2" = level 2), following its
    /// speed / time remap. Writes nothing: callers store the result in `Clip.beats`.
    public static func clipBeats(_ clip: Clip, asset: MediaAsset, level: Int) async throws -> [Time] {
        let r = try await beats(url: asset.url, range: clip.sourceRange)
        let src = (level >= 2 ? r.beats : r.strongBeats).map { clip.sourceStart + Time($0) }
        return src.compactMap { s -> Time? in
            // invert the (monotonic) time remap by bisection on clip-local output time
            var lo = Time.zero, hi = clip.duration
            for _ in 0..<40 {
                let mid = Time(ticks: (lo.ticks + hi.ticks) / 2)
                let v = clip.sourceTime(at: clip.start + mid)
                if clip.reversed ? v > s : v < s { lo = mid } else { hi = mid }
            }
            return hi > .zero && hi < clip.duration ? hi : nil
        }.sorted()
    }

    // MARK: Sync (AU-016)

    /// Offset (seconds) to ADD to `b`'s timeline position so its audio lines up with `a`'s, from the
    /// cross-correlation of onset envelopes (search ±`maxLag` s). `a`, `b` are mono at `onsetSampleRate`.
    public static func syncOffset(_ a: [Float], _ b: [Float], maxLag: Double = 10) -> Double {
        let ea = onsetEnvelope(a), eb = onsetEnvelope(b)
        let fps = onsetSampleRate / Double(onsetHop)
        let m = Int(maxLag * fps)
        var best = -Double.infinity, bestLag = 0
        for lag in -m...m {
            var s = 0.0, n = 0
            for i in 0..<eb.count {
                let j = i + lag
                if j >= 0 && j < ea.count { s += Double(ea[j]) * Double(eb[i]); n += 1 }
            }
            if n > Int(fps) && s > best { best = s; bestLag = lag }
        }
        return Double(bestLag) / fps
    }
}
