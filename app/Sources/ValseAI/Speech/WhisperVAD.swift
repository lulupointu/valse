@preconcurrency import AVFoundation
import Foundation
import ValseCore

/// PERF-CAPTIONS-4: whisper.cpp voice activity detection (`--vad -vm <Silero ggml model>`). whisper-cli then decodes
/// only the voiced parts, laid end to end ("condensed" audio, 0.1 s between parts). Measured (2026-11, turbo, app
/// flags): 166 s of speech with 10–20 s pauses 16.2 s → 5.3 s, and no more repeated sentences / "Sous-titrage
/// Société Radio-Canada" invented in the pauses (WER 40 % → 4 %); owner's joined dialogue project (134 s) ≈ 15–20 %
/// faster; continuous speech and speech over music: same words, onsets within a few ms after snapping.
///
/// whisper.cpp 1.8 maps only the segment offsets back to the input's time: token offsets and DTW times stay in the
/// condensed audio. It logs each voiced part on stderr (`vad_segment_info: orig_start: 7.97, orig_end: 11.20,
/// vad_start: 0.00, vad_end: 3.33`; the part copied is `vad_end - vad_start` long from `orig_start`, padding
/// included), which is the map used here (10 ms precision: the log's 2 decimals).
public struct VADTimeMap: Sendable, Equatable {
    public struct Span: Sendable, Equatable {
        /// Input time of the part's first sample.
        public var original: Double
        /// The part in the condensed audio.
        public var start: Double, end: Double
        public init(original: Double, start: Double, end: Double) { self.original = original; self.start = start; self.end = end }
    }
    public var spans: [Span]
    public init(spans: [Span]) { self.spans = spans }

    /// One `vad_segment_info` stderr line → its span (nil for any other line).
    public static func span(fromLog line: String) -> Span? {
        guard let r = line.range(of: "vad_segment_info:") else { return nil }
        var v: [String: Double] = [:]
        for field in line[r.upperBound...].split(separator: ",") {
            let kv = field.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2, let d = Double(kv[1]) { v[kv[0]] = d }
        }
        guard let o = v["orig_start"], let s = v["vad_start"], let e = v["vad_end"], e >= s else { return nil }
        return Span(original: o, start: s, end: e)
    }

    /// Condensed time → the span it belongs to (the containing one, else the nearest: the gaps between parts).
    func span(at t: Double) -> Span? {
        spans.min { a, b in Self.distance(t, a.start, a.end) < Self.distance(t, b.start, b.end) }
    }

    private static func distance(_ t: Double, _ a: Double, _ b: Double) -> Double { t < a ? a - t : t > b ? t - b : 0 }

    /// Input time → condensed time (whisper's mapped segment offsets back into the token time base).
    public func condensed(_ t: Double) -> Double {
        guard let s = spans.min(by: { a, b in
            Self.distance(t, a.original, a.original + a.end - a.start) < Self.distance(t, b.original, b.original + b.end - b.start)
        }) else { return t }
        return s.start + min(max(t - s.original, 0), s.end - s.start)
    }

    /// Words timed in the condensed audio → input time. A word belongs to the part its end is in; its start is kept
    /// inside that part (a sentence's first word must not start in the pause before it, which the condensed audio
    /// doesn't have). Starts stay in order.
    public func original(_ words: [TranscriptWord]) -> [TranscriptWord] {
        var out: [TranscriptWord] = []
        out.reserveCapacity(words.count)
        for var w in words {
            guard let s = span(at: w.end) else { out.append(w); continue }
            func map(_ t: Double) -> Double { s.original + min(max(t, s.start), s.end) - s.start }
            let end = map(w.end)
            w.start = max(map(w.start), out.last?.start ?? 0)
            w.end = max(end, w.start + 0.02)
            out.append(w)
        }
        return out
    }

    /// Collects the spans from whisper-cli's stderr lines while it runs.
    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var spans: [Span] = []
        var add: @Sendable (String) -> Void {
            { [self] line in if let s = VADTimeMap.span(fromLog: line) { lock.withLock { spans.append(s) } } }
        }
        var map: VADTimeMap { lock.withLock { VADTimeMap(spans: spans.sorted { $0.start < $1.start }) } }
    }
}

/// PERF-CAPTIONS-5: when whisper's VAD may run, and whether its run can be trusted. Silero drops speech under a music
/// bed, not only all of it (the empty-result fallback) but whole lines: measured 2026-11 on the owner's Episode 6
/// dialogue (134 s, 28 lines) mixed with a synthetic band / a dense broadband bed, VAD lost 2 lines with the bed 12 dB
/// under the voice, 5–10 lines at 6–0 dB, WER 85 % vs 5.6 % plain at −6 dB. On every clip where VAD was proven (speech,
/// speech with pauses in room noise) the audio it drops is quiet — 44–60 dB under the kept audio's median level —
/// whereas under a bed it drops 50–134 s of audio within 20 dB of the kept level. So:
/// - before the run: audio without quiet parts (10 ms frames, p90 − p10 < 25 dB: a bed under everything; measured
///   7–23 dB with a bed 18 dB under the voice or louder, ≥ 30.7 dB on speech without one) never takes the VAD path —
///   nothing for VAD to skip but the bed, and continuous speech gains nothing from it (measured);
/// - after the run: if the dropped audio holds more than 1 s + 2 % of the kept duration within 20 dB of the kept
///   audio's median level (measured ≤ 0.5 s on the proven clips, ≥ 27 s with any bed up to 24 dB under the voice),
///   the run is redone without VAD (costs the VAD run, ≈ +80 % on such pieces; correctness first).
public enum VADGuard {
    /// Frame hop (seconds) of the energies.
    static let hop = 0.01
    /// Dropped audio this close (dB) to the kept audio's median level is "near speech".
    static let nearSpeechDB = 20.0
    /// Near-speech dropped audio allowed: segment edges (`allowedSeconds` + `allowedFraction` × kept duration).
    static let allowedSeconds = 1.0, allowedFraction = 0.02
    /// Spread (dB) between the 90th and 10th percentile frames below which the audio has no quiet part.
    static let quietSpreadDB = 25.0

    /// 10 ms frame energies (dB) of a mono PCM file (the whisper input WAV); nil when it can't be read.
    public static func frameDB(wav: URL) -> [Double]? {
        guard let f = try? AVAudioFile(forReading: wav, commonFormat: .pcmFormatFloat32, interleaved: false) else { return nil }
        let hopN = max(1, Int(f.processingFormat.sampleRate * hop))
        guard let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(hopN * 1000)) else { return nil }
        var db: [Double] = []
        db.reserveCapacity(Int(f.length) / hopN + 1)
        var acc = 0.0, n = 0
        while (try? f.read(into: buf, frameCount: buf.frameCapacity)) != nil, buf.frameLength > 0 {
            guard let ch = buf.floatChannelData?[0] else { return nil }
            for i in 0..<Int(buf.frameLength) {
                let x = Double(ch[i]); acc += x * x; n += 1
                if n == hopN { db.append(10 * log10(acc / Double(n) + 1e-12)); acc = 0; n = 0 }
            }
        }
        return db
    }

    private static func percentile(_ sorted: [Double], _ p: Double) -> Double { sorted[Int(Double(sorted.count - 1) * p)] }

    /// The audio has quiet parts VAD could skip (false: a steady bed or noise under everything → no VAD).
    public static func hasQuietParts(_ db: [Double]) -> Bool {
        guard db.count >= 10 else { return false }
        let s = db.sorted()
        return percentile(s, 0.9) - percentile(s, 0.1) >= quietSpreadDB
    }

    /// Seconds of the audio VAD dropped that are within `nearSpeechDB` of the kept audio's median level, and the kept
    /// duration (input time, from the run's time map).
    public static func nearSpeechDropped(_ db: [Double], map: VADTimeMap) -> (dropped: Double, kept: Double) {
        var inside = [Bool](repeating: false, count: db.count)
        for s in map.spans {
            let a = max(0, Int((s.original / hop).rounded()))
            let b = min(db.count, Int(((s.original + s.end - s.start) / hop).rounded()))
            if a < b { for k in a..<b { inside[k] = true } }
        }
        let kept = zip(db, inside).filter(\.1).map(\.0).sorted()
        guard !kept.isEmpty else { return (0, 0) }
        let level = percentile(kept, 0.5) - nearSpeechDB
        let dropped = zip(db, inside).reduce(0) { n, f in !f.1 && f.0 > level ? n + 1 : n }
        return (Double(dropped) * hop, Double(kept.count) * hop)
    }

    /// The VAD run left out audio that sounds like the speech it kept (a music bed: lines may be missing).
    public static func droppedSpeech(_ db: [Double], map: VADTimeMap) -> Bool {
        let r = nearSpeechDropped(db, map: map)
        return r.dropped > allowedSeconds + allowedFraction * r.kept
    }
}

extension WhisperEngine {
    /// The VAD model used by default: `VALSE_WHISPER_VAD` = a model path, or `0` to turn VAD off; else the Silero
    /// model when installed (captions work the same without it, VAD only skips non-speech).
    public static var defaultVADModel: URL? {
        let env = ProcessInfo.processInfo.environment["VALSE_WHISPER_VAD"] ?? ""
        if env == "0" { return nil }
        if !env.isEmpty { return URL(fileURLWithPath: env) }
        return ModelCatalog.installedURL(ModelCatalog.sileroVAD)
    }
}
