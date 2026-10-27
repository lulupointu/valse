@preconcurrency import AVFoundation
import Accelerate
import CoreML
import Foundation
import ValseCore
import ValseEngine

/// Speaker embeddings for diarization. `features` runs per speech window (16 kHz mono samples); `finalize` turns
/// the raw features of all windows into comparable vectors (cosine distance).
public protocol SpeakerEmbedder: Sendable {
    /// Cosine distance above which two clusters are different speakers ("Auto" number of speakers).
    var threshold: Double { get }
    var name: String { get }
    func features(_ windows: [[Float]]) throws -> [[Float]]
    func finalize(_ features: [[Float]]) -> [[Float]]
}

extension SpeakerEmbedder {
    public func finalize(_ features: [[Float]]) -> [[Float]] { features }
}

/// WeSpeaker ResNet34-LM (Core ML, fbank fused, 256-d; input 3 × 10 s + a frame mask).
public final class WeSpeakerEmbedder: SpeakerEmbedder, @unchecked Sendable {
    public let threshold = 0.62
    public let name = "wespeaker"
    let model: MLModel
    static let samples = 160_000, frames = 589, batch = 3

    public static var isAvailable: Bool { ModelCatalog.installedURL(ModelCatalog.speakerEmbedding) != nil }

    public init() throws {
        guard let url = ModelCatalog.installedURL(ModelCatalog.speakerEmbedding) else {
            throw AIToolError.modelMissing(ModelCatalog.speakerEmbedding.id)
        }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuAndGPU
        model = try MLModel(contentsOf: url, configuration: cfg)
    }

    /// One window per prediction in row 0 (rows are not independent in this conversion: batching different windows
    /// collapses their embeddings), tiled to fill the 10 s input, full mask.
    public func features(_ windows: [[Float]]) throws -> [[Float]] {
        let wave = try MLMultiArray(shape: [NSNumber(value: Self.batch), NSNumber(value: Self.samples)], dataType: .float32)
        let mask = try MLMultiArray(shape: [NSNumber(value: Self.batch), NSNumber(value: Self.frames)], dataType: .float32)
        let wp = wave.dataPointer.bindMemory(to: Float.self, capacity: Self.batch * Self.samples)
        let mp = mask.dataPointer.bindMemory(to: Float.self, capacity: Self.batch * Self.frames)
        mp.initialize(repeating: 0, count: Self.batch * Self.frames)
        for k in 0..<Self.frames { mp[k] = 1 }
        var out: [[Float]] = []
        for w in windows {
            try Task.checkCancellation()
            wp.initialize(repeating: 0, count: Self.batch * Self.samples)
            let n = min(w.count, Self.samples)
            guard n > 0 else { out.append([]); continue }
            var k = 0
            w.withUnsafeBufferPointer { src in
                while k < Self.samples { let m = min(n, Self.samples - k); (wp + k).update(from: src.baseAddress!, count: m); k += m }
            }
            let input = try MLDictionaryFeatureProvider(dictionary: ["waveform": MLFeatureValue(multiArray: wave), "mask": MLFeatureValue(multiArray: mask)])
            let r = try autoreleasepool { try model.prediction(from: input) }
            guard let e = r.featureValue(for: "embedding")?.multiArrayValue else { throw AIToolError.unavailable("embedding") }
            let dim = e.shape.last?.intValue ?? 256
            let cs = e.strides.last?.intValue ?? 1
            var v = [Float](repeating: 0, count: dim)
            if e.dataType == .float32 {
                let ep = e.dataPointer.bindMemory(to: Float.self, capacity: dim * cs)
                for i in 0..<dim { v[i] = ep[i * cs] }
            } else {
                for i in 0..<dim { v[i] = e[[0, NSNumber(value: i)]].floatValue }
            }
            out.append(v)
        }
        return out
    }
}

/// No-model fallback: MFCC mean / spread + pitch statistics per window, z-scored over the recording. Good at telling
/// clearly different voices apart (e.g. a low and a high voice), weaker than WeSpeaker on similar voices.
public struct StatisticsEmbedder: SpeakerEmbedder {
    public let threshold = 0.95
    public let name = "statistics"
    public init() {}

    static let n = 512, hop = 160, win = 400, mels = 40, ceps = 13

    public func features(_ windows: [[Float]]) throws -> [[Float]] {
        let fb = Self.melBank()
        return try windows.map { w in try Task.checkCancellation(); return Self.windowFeatures(w, fb) }
    }

    /// z-score every dimension across windows (speaker-independent channel / loudness effects cancel out).
    public func finalize(_ f: [[Float]]) -> [[Float]] {
        guard let d = f.first?.count, f.count > 1 else { return f }
        var mean = [Float](repeating: 0, count: d), sd = [Float](repeating: 0, count: d)
        for v in f { for k in 0..<d { mean[k] += v[k] } }
        for k in 0..<d { mean[k] /= Float(f.count) }
        for v in f { for k in 0..<d { sd[k] += (v[k] - mean[k]) * (v[k] - mean[k]) } }
        for k in 0..<d { sd[k] = max((sd[k] / Float(f.count)).squareRoot(), 1e-4) }
        return f.map { v in (0..<d).map { (v[$0] - mean[$0]) / sd[$0] } }
    }

    static func melBank() -> [[Float]] {
        func mel(_ f: Double) -> Double { 2595 * log10(1 + f / 700) }
        func hz(_ m: Double) -> Double { 700 * (pow(10, m / 2595) - 1) }
        let lo = mel(60), hi = mel(7600)
        let pts = (0...(mels + 1)).map { hz(lo + (hi - lo) * Double($0) / Double(mels + 1)) / 16000 * Double(n) }
        return (0..<mels).map { m in
            (0..<(n / 2 + 1)).map { b -> Float in
                let x = Double(b)
                if x < pts[m] || x > pts[m + 2] { return 0 }
                return Float(x <= pts[m + 1] ? (x - pts[m]) / max(pts[m + 1] - pts[m], 1e-6) : (pts[m + 2] - x) / max(pts[m + 2] - pts[m + 1], 1e-6))
            }
        }
    }

    static func windowFeatures(_ s: [Float], _ fb: [[Float]]) -> [Float] {
        let log2n = vDSP_Length(9)
        guard s.count >= win, let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else {
            return [Float](repeating: 0, count: 2 * (ceps - 1) + 2)
        }
        let hann = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: win, isHalfWindow: false)
        var frames: [[Float]] = []
        var energies: [Float] = []
        var pitches: [Float] = []
        var re = [Float](repeating: 0, count: n / 2), im = [Float](repeating: 0, count: n / 2)
        var start = 0
        while start + win <= s.count {
            var frame = [Float](repeating: 0, count: n)
            let seg = Array(s[start..<(start + win)])
            for i in 0..<win { frame[i] = seg[i] * hann[i] }
            let energy = vDSP.sumOfSquares(seg) / Float(win)
            // power spectrum
            var power = [Float](repeating: 0, count: n / 2 + 1)
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frame.withUnsafeBufferPointer { fp in
                        fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2)) }
                    }
                    fft.forward(input: split, output: &split)
                    power[0] = rp[0] * rp[0]; power[n / 2] = ip[0] * ip[0]
                    for k in 1..<(n / 2) { power[k] = rp[k] * rp[k] + ip[k] * ip[k] }
                }
            }
            let melE = fb.map { f in log(max(vDSP.dot(f, power), 1e-10)) }
            // DCT-II → cepstra 1…ceps-1
            var c = [Float](repeating: 0, count: ceps - 1)
            for k in 1..<ceps {
                var a: Float = 0
                for (m, e) in melE.enumerated() { a += e * cos(Float.pi * Float(k) * (Float(m) + 0.5) / Float(mels)) }
                c[k - 1] = a
            }
            frames.append(c)
            energies.append(energy)
            pitches.append(pitch(seg))
            start += hop
        }
        guard !frames.isEmpty else { return [Float](repeating: 0, count: 2 * (ceps - 1) + 2) }
        // voiced / loud frames only (top 60 % energy)
        let thr = energies.sorted()[Int(Double(energies.count) * 0.4)]
        let keep = energies.indices.filter { energies[$0] >= thr }
        let d = ceps - 1
        var mean = [Float](repeating: 0, count: d), sd = [Float](repeating: 0, count: d)
        for i in keep { for k in 0..<d { mean[k] += frames[i][k] } }
        for k in 0..<d { mean[k] /= Float(keep.count) }
        for i in keep { for k in 0..<d { sd[k] += (frames[i][k] - mean[k]) * (frames[i][k] - mean[k]) } }
        for k in 0..<d { sd[k] = (sd[k] / Float(keep.count)).squareRoot() }
        let voiced = keep.map { pitches[$0] }.filter { $0 > 0 }.sorted()
        let f0 = voiced.isEmpty ? 0 : log(voiced[voiced.count / 2])
        let f0spread = voiced.count > 4 ? log(voiced[voiced.count * 3 / 4]) - log(voiced[voiced.count / 4]) : 0
        // pitch weighs like several cepstra (strong speaker cue)
        return mean + sd + [f0, f0, f0, f0, f0spread]
    }

    /// Autocorrelation pitch (70–400 Hz) of one 25 ms frame; 0 = unvoiced.
    static func pitch(_ x: [Float]) -> Float {
        let lo = 16000 / 400, hi = 16000 / 70
        guard x.count > hi + 10 else { return 0 }
        let e = vDSP.sumOfSquares(x)
        guard e > 1e-6 else { return 0 }
        var best: Float = 0, lag = 0
        for l in lo...min(hi, x.count - 10) {
            var a: Float = 0
            x.withUnsafeBufferPointer { p in vDSP_dotpr(p.baseAddress!, 1, p.baseAddress! + l, 1, &a, vDSP_Length(x.count - l)) }
            a /= e
            if a > best { best = a; lag = l }
        }
        return best > 0.45 && lag > 0 ? 16000 / Float(lag) : 0
    }
}

/// Diarization of caption speech (AI-005 / TX-038): speech windows from the caption word timings (≤ 2 s, split at
/// pauses), their audio from the clip that plays at that time, speaker embeddings (WeSpeaker Core ML when installed,
/// else statistics), agglomerative clustering (Auto or a fixed number of speakers) → timeline `SpeakerTurn`s.
public enum SpeakerDiarizer {
    struct Window { var start: Double; var end: Double; var clip: Int }

    /// Picks WeSpeaker when installed (falls back to statistics if it can't load).
    public static func defaultEmbedder() -> any SpeakerEmbedder {
        if WeSpeakerEmbedder.isAvailable, let w = try? WeSpeakerEmbedder() { return w }
        return StatisticsEmbedder()
    }

    /// `segments` in timeline seconds (with word timings when available), `clips` = the clips whose audio was captioned.
    public static func turns(segments: [CaptionSegment], clips: [Clip], project: Project, speakerCount: Int? = nil,
                             embedder: (any SpeakerEmbedder)? = nil,
                             progress: (@Sendable (Double) -> Void)? = nil) async throws -> [SpeakerTurn] {
        let words: [(start: Double, end: Double)] = segments.flatMap { s in
            s.words.isEmpty ? [(s.start, s.end)] : s.words.map { ($0.start, $0.end) }
        }.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        guard !words.isEmpty, speakerCount != 1 else {
            return words.isEmpty ? [] : [SpeakerTurn(start: words.first!.start, end: words.last!.end, speaker: 0)]
        }
        // which clip plays each word
        func clipIndex(_ t: Double) -> Int? {
            clips.firstIndex { $0.start.seconds <= t && t < $0.end.seconds }
        }
        var windows: [Window] = []
        for w in words {
            guard let ci = clipIndex((w.start + w.end) / 2) else { continue }
            if var last = windows.last, last.clip == ci, w.start - last.end <= 0.5, w.end - last.start <= 2.0 {
                last.end = max(last.end, w.end); windows[windows.count - 1] = last
            } else {
                windows.append(Window(start: w.start, end: w.end, clip: ci))
            }
        }
        guard windows.count >= 2 else { return windows.map { SpeakerTurn(start: $0.start, end: $0.end, speaker: 0) } }
        let emb = embedder ?? defaultEmbedder()
        // audio per clip (read window by window, never the whole file)
        var feats = [[Float]](repeating: [], count: windows.count)
        let byClip = Dictionary(grouping: windows.indices, by: { windows[$0].clip })
        var done = 0
        for (ci, idx) in byClip.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            let c = clips[ci]
            guard let asset = c.mediaID.flatMap(project.asset) else { continue }
            let wav = try await AudioExtractor.wav16k(asset.url, range: c.sourceRange, audioStream: c.audioStreamIndex)
            defer { try? FileManager.default.removeItem(at: wav) }
            let file = try AVAudioFile(forReading: wav, commonFormat: .pcmFormatFloat32, interleaved: false)
            let total = Int(file.length)
            var batch: [[Float]] = []
            for i in idx {
                let w = windows[i]
                // timeline → media seconds relative to the extracted range
                let a = c.sourceTime(at: Time(w.start)).seconds - c.sourceRange.start.seconds
                let b = c.sourceTime(at: Time(w.end)).seconds - c.sourceRange.start.seconds
                var lo = Int(min(a, b) * 16000), hi = Int(max(a, b) * 16000)
                // short windows get context up to 1.2 s
                let minLen = 19_200
                if hi - lo < minLen { let pad = (minLen - (hi - lo)) / 2; lo -= pad; hi += pad }
                lo = max(0, lo); hi = min(total, hi)
                batch.append(hi > lo ? try read(file, from: lo, count: hi - lo) : [])
            }
            let f = try emb.features(batch)
            for (k, i) in idx.enumerated() { feats[i] = f[k] }
            done += idx.count
            progress?(Double(done) / Double(windows.count))
        }
        let valid = windows.indices.filter { !feats[$0].isEmpty }
        guard valid.count >= 2 else { return windows.map { SpeakerTurn(start: $0.start, end: $0.end, speaker: 0) } }
        let vecs = emb.finalize(valid.map { feats[$0] })
        let labels = SpeakerClustering.cluster(vecs, threshold: emb.threshold, count: speakerCount,
                                               weights: valid.map { windows[$0].end - windows[$0].start })
        return zip(valid, labels).map { SpeakerTurn(start: windows[$0].start, end: windows[$0].end, speaker: $1) }
    }

    static func read(_ f: AVAudioFile, from: Int, count: Int) throws -> [Float] {
        f.framePosition = AVAudioFramePosition(from)
        guard let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(count)) else { return [] }
        try f.read(into: buf, frameCount: AVAudioFrameCount(count))
        guard let ch = buf.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength)))
    }
}

/// Inspector ▸ Captions ▸ Identify speakers on existing captions: diarizes the audio under every caption and tags
/// each caption with its majority speaker (no splitting, styles kept) → one undoable edit.
public enum SpeakerIdentification {
    public static func run(project p: Project, speakerCount: Int?, progress: (@Sendable (Double) -> Void)? = nil) async throws -> any EditCommand {
        var segments: [CaptionSegment] = []
        for ti in CaptionOps.captionTracks(p.timeline) { segments += CaptionOps.segments(of: p.timeline.tracks[ti]) }
        guard !segments.isEmpty else { throw AIToolError.noInput }
        let clips = CaptionGenerator.sourceClips(p, .allTracks).sorted { a, b in
            (p.timeline.locate(a.id).map { p.timeline.tracks[$0.track].isMain } ?? false) && !(p.timeline.locate(b.id).map { p.timeline.tracks[$0.track].isMain } ?? false)
        }
        guard !clips.isEmpty else { throw AIToolError.noInput }
        let turns = try await SpeakerDiarizer.turns(segments: segments, clips: clips, project: p, speakerCount: speakerCount, progress: progress)
        guard !turns.isEmpty else { throw AIToolError.noSpeech }
        return Edit("cmd.identifySpeakers") { p in SpeakerCaptions.assign(turns: turns, in: &p) }
    }
}
