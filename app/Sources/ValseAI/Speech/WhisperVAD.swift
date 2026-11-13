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
