import Foundation
import ValseCore

/// Compact, deterministic audio descriptor for "similar sounds" (AU-025) and library metadata (key, tempo).
/// Hand-crafted features (no model download): MFCC mean/std (timbre), key-relative chroma (mode / harmony),
/// spectral shape, loudness dynamics, onset/tempo statistics and duration. Vectors are compared after a per-library
/// z-score (`ContentFeatureStats`) with group weights, by cosine similarity.
public enum AudioFeatures {
    public static let sampleRate: Double = 22050
    static let n = 2048, hop = 1024
    static let melBands = 40, mfccCount = 13

    /// Feature layout (keep in sync with `groups`); bump `version` when it changes (the manifest stores it).
    public static let version = 1
    public static let dimension = 12 + 12 + 12 + 6 + 5
    /// (range, weight) per feature group, applied after z-scoring.
    static let groups: [(Range<Int>, Float)] = [
        (0..<12, 1.0),    // MFCC 1…12 mean (timbre)
        (12..<24, 0.6),   // MFCC 1…12 std (timbre movement)
        (24..<36, 0.5),   // chroma, rotated to the tonic (harmony / mode)
        (36..<42, 0.9),   // centroid mean/std, rolloff, flatness, zcr, log duration
        (42..<47, 1.1),   // rms mean/std (dB), onset mean/std, tempo
    ]

    public struct Result: Sendable, Equatable {
        public var vector: [Float]
        /// Tonic pitch class (0 = C) and mode, from Krumhansl–Kessler key profiles; nil for unpitched audio.
        public var keyTonic: Int?
        public var keyMinor: Bool
        public var keyName: String? { keyTonic.map { AudioFeatures.keyName(tonic: $0, minor: keyMinor) } }
    }

    public static let pitchNames = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
    /// "A minor" / "C major" (English, stable — the UI localizes from the tonic + mode).
    public static func keyName(tonic: Int, minor: Bool) -> String { "\(pitchNames[tonic % 12]) \(minor ? "minor" : "major")" }

    /// Parses `keyName` back.
    public static func parseKey(_ s: String) -> (tonic: Int, minor: Bool)? {
        let p = s.split(separator: " ")
        guard p.count == 2, let t = pitchNames.firstIndex(of: String(p[0])) else { return nil }
        return (t, p[1] == "minor")
    }

    /// Features of a mono signal at `sampleRate`. `bpm` (from the beat tracker) feeds the tempo feature (0 = none).
    public static func extract(_ mono: [Float], bpm: Double) -> Result {
        let fft = RealFFT(n: n)
        let bins = n / 2 + 1
        let win = (0..<n).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n))) }
        let melFB = melFilterbank(bins: bins)
        let pcOfBin: [Int] = (0..<bins).map { k in
            let f = Double(k) * sampleRate / Double(n)
            guard f >= 55, f <= 5000 else { return -1 }
            let midi = 69 + 12 * log2(f / 440)
            return ((Int(midi.rounded()) % 12) + 12) % 12
        }
        var frame = [Float](repeating: 0, count: n)
        var re = [Float](repeating: 0, count: bins), im = re, mag = re
        var mfccSum = [Double](repeating: 0, count: mfccCount), mfccSq = mfccSum
        var chroma = [Double](repeating: 0, count: 12)
        var cent: [Double] = [], roll: [Double] = [], flat: [Double] = [], zcr: [Double] = [], rmsDB: [Double] = []
        var prevMag = [Float](repeating: 0, count: bins)
        var flux: [Double] = []
        var frames = 0
        var pos = 0
        let total = mono.count
        while pos + n <= max(total, n) {
            for k in 0..<n { frame[k] = (pos + k < total ? mono[pos + k] : 0) * win[k] }
            var zc = 0
            var energy = 0.0
            for k in 0..<n {
                let x = pos + k < total ? mono[pos + k] : 0
                energy += Double(x * x)
                if k > 0, pos + k < total, (mono[pos + k - 1] >= 0) != (x >= 0) { zc += 1 }
            }
            frame.withUnsafeBufferPointer { f in re.withUnsafeMutableBufferPointer { r in im.withUnsafeMutableBufferPointer { i in
                fft.forward(f.baseAddress!, r.baseAddress!, i.baseAddress!) } } }
            var sum = 0.0, wsum = 0.0, logSum = 0.0
            var fl = 0.0
            for k in 0..<bins {
                let m = sqrt(re[k] * re[k] + im[k] * im[k])
                mag[k] = m
                sum += Double(m); wsum += Double(m) * Double(k)
                logSum += log(Double(m) + 1e-10)
                let d = log(1 + 100 * m) - log(1 + 100 * prevMag[k])
                if d > 0 { fl += Double(d) }
            }
            swap(&prevMag, &mag)
            // prevMag now holds this frame's magnitudes
            let rms = sqrt(energy / Double(n))
            let silent = rms < 1e-4
            if !silent {
                frames += 1
                // MFCC
                var mel = [Double](repeating: 0, count: melBands)
                for (b, (lo, ws)) in melFB.enumerated() {
                    var s = 0.0
                    for (j, w) in ws.enumerated() { let m = Double(prevMag[lo + j]); s += Double(w) * m * m }
                    mel[b] = log(s + 1e-10)
                }
                for c in 0..<mfccCount {
                    var s = 0.0
                    for b in 0..<melBands { s += mel[b] * cos(Double.pi * Double(c) * (Double(b) + 0.5) / Double(melBands)) }
                    mfccSum[c] += s; mfccSq[c] += s * s
                }
                // chroma (frame-normalized)
                var ch = [Double](repeating: 0, count: 12)
                for k in 0..<bins where pcOfBin[k] >= 0 { ch[pcOfBin[k]] += Double(prevMag[k]) }
                let cs = ch.reduce(0, +)
                if cs > 0 { for i in 0..<12 { chroma[i] += ch[i] / cs } }
                // spectral shape
                let centroid = sum > 0 ? wsum / sum / Double(bins) : 0
                cent.append(centroid)
                var acc = 0.0, r85 = 0
                for k in 0..<bins { acc += Double(prevMag[k]); if acc >= 0.85 * sum { r85 = k; break } }
                roll.append(Double(r85) / Double(bins))
                let geo = exp(logSum / Double(bins)), arith = sum / Double(bins)
                flat.append(arith > 0 ? geo / arith : 0)
                zcr.append(Double(zc) / Double(n))
                rmsDB.append(20 * log10(rms + 1e-9))
            }
            flux.append(fl)
            pos += hop
            if total < n { break }
        }
        func mean(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }
        func sd(_ a: [Double]) -> Double { let m = mean(a); return a.isEmpty ? 0 : sqrt(a.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(a.count)) }
        let fN = Double(max(frames, 1))
        var v: [Float] = []
        for c in 1...12 { v.append(Float(mfccSum[c] / fN)) }
        for c in 1...12 { let m = mfccSum[c] / fN; v.append(Float(sqrt(max(0, mfccSq[c] / fN - m * m)))) }
        // key estimate + tonic-relative chroma
        let chromaMean = chroma.map { $0 / fN }
        let key = estimateKey(chromaMean)
        let tonic = key?.tonic ?? 0
        for i in 0..<12 { v.append(Float(chromaMean[(i + tonic) % 12])) }
        v.append(Float(mean(cent))); v.append(Float(sd(cent))); v.append(Float(mean(roll)))
        v.append(Float(mean(flat))); v.append(Float(mean(zcr)))
        v.append(Float(log(max(0.05, Double(total) / sampleRate))))
        v.append(Float(mean(rmsDB))); v.append(Float(sd(rmsDB)))
        v.append(Float(mean(flux))); v.append(Float(sd(flux)))
        v.append(Float(bpm > 0 ? log2(bpm / 120) : 0))
        assert(v.count == dimension)
        return Result(vector: v.map { $0.isFinite ? $0 : 0 }, keyTonic: key?.tonic, keyMinor: key?.minor ?? false)
    }

    /// Krumhansl–Kessler key estimate from a 12-bin chroma profile (nil when the profile is flat / unpitched).
    public static func estimateKey(_ chroma: [Double]) -> (tonic: Int, minor: Bool)? {
        let major: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
        let minor: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
        func corr(_ a: [Double], _ b: [Double]) -> Double {
            let ma = a.reduce(0, +) / 12, mb = b.reduce(0, +) / 12
            var num = 0.0, da = 0.0, db = 0.0
            for i in 0..<12 { num += (a[i] - ma) * (b[i] - mb); da += (a[i] - ma) * (a[i] - ma); db += (b[i] - mb) * (b[i] - mb) }
            return da > 0 && db > 0 ? num / sqrt(da * db) : 0
        }
        var best = -2.0, out: (Int, Bool)?
        for t in 0..<12 {
            let rot = (0..<12).map { chroma[($0 + t) % 12] }
            let a = corr(rot, major), b = corr(rot, minor)
            if a > best { best = a; out = (t, false) }
            if b > best { best = b; out = (t, true) }
        }
        return best > 0.3 ? out : nil
    }

    /// Triangular mel filters over the FFT bins: (first bin, weights).
    static func melFilterbank(bins: Int) -> [(Int, [Float])] {
        func mel(_ f: Double) -> Double { 2595 * log10(1 + f / 700) }
        func hz(_ m: Double) -> Double { 700 * (pow(10, m / 2595) - 1) }
        let lo = mel(30), hi = mel(sampleRate / 2)
        let pts = (0...(melBands + 1)).map { hz(lo + (hi - lo) * Double($0) / Double(melBands + 1)) }
        let binHz = sampleRate / Double(n)
        return (0..<melBands).map { b in
            let f0 = pts[b], f1 = pts[b + 1], f2 = pts[b + 2]
            let k0 = max(0, Int(floor(f0 / binHz))), k2 = min(bins - 1, Int(ceil(f2 / binHz)))
            var w: [Float] = []
            for k in k0...max(k0, k2) {
                let f = Double(k) * binHz
                let x = f < f1 ? (f - f0) / max(1e-9, f1 - f0) : (f2 - f) / max(1e-9, f2 - f1)
                w.append(Float(max(0, x)))
            }
            return (k0, w)
        }
    }

    /// Features (and beats) of a file range. Reads at most `maxSeconds` (from the range start).
    public static func analyze(url: URL, range: TimeRange? = nil, maxSeconds: Double? = nil) async throws -> (Result, AudioAnalysis.BeatResult, [Float]) {
        var r = range
        if let maxS = maxSeconds {
            let start = range?.start ?? .zero
            let len = range.map { min($0.duration, Time(maxS)) } ?? Time(maxS)
            r = TimeRange(start: start, duration: len)
        }
        let mono = try await AudioFileIO.read(url, sampleRate: sampleRate, channels: 1, range: r).channel(0)
        let beats = AudioAnalysis.beats(onsets: AudioAnalysis.onsetEnvelope(mono))
        return (extract(mono, bpm: beats.bpm), beats, mono)
    }
}

/// Per-kind normalisation of feature vectors (z-score) stored in the content manifest.
public struct ContentFeatureStats: Codable, Sendable, Equatable {
    public var mean: [Float]
    public var std: [Float]

    public init(mean: [Float], std: [Float]) { self.mean = mean; self.std = std }

    public init(_ vectors: [[Float]]) {
        let d = vectors.first?.count ?? AudioFeatures.dimension
        var m = [Float](repeating: 0, count: d), s = m
        for v in vectors { for i in 0..<d { m[i] += v[i] } }
        let n = Float(max(1, vectors.count))
        for i in 0..<d { m[i] /= n }
        for v in vectors { for i in 0..<d { s[i] += (v[i] - m[i]) * (v[i] - m[i]) } }
        for i in 0..<d { s[i] = max(1e-4, (s[i] / n).squareRoot()) }
        mean = m; std = s
    }

    /// z-scored, group-weighted, L2-normalised vector (cosine similarity = dot product).
    public func embed(_ v: [Float]) -> [Float] {
        guard v.count == mean.count else { return [] }
        var out = [Float](repeating: 0, count: v.count)
        for (r, w) in AudioFeatures.groups where r.upperBound <= v.count {
            let gw = w / Float(r.count).squareRoot()
            for i in r { out[i] = max(-4, min(4, (v[i] - mean[i]) / std[i])) * gw }
        }
        let norm = out.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? out.map { $0 / norm } : out
    }
}
