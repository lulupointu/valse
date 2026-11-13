import Foundation
import ValseEngine

/// Seconds spent in each phase of one caption run (PERF-CAPTIONS-1: the owner's 1:25 timeline took 1:15 to caption;
/// one `EngineLog.info` line per run says where the time goes).
public struct CaptionTimings: Sendable, Equatable {
    /// Audio extraction (file open + decode + resample to 16 kHz), vocal separation included for auto lyrics.
    public var extraction = 0.0
    public var separation = 0.0
    public var silenceCheck = 0.0
    /// Joining the pieces into one WAV.
    public var joining = 0.0
    /// The speech engine (whisper-cli process / Apple Speech), permission prompt excluded.
    public var engine = 0.0
    /// `SpeechActivity` boundary snapping.
    public var snapping = 0.0
    /// Words → caption segments.
    public var segmenting = 0.0
    public var total = 0.0
    /// Media ranges in the request / served from the transcript cache / silent / sent to the engine, engine runs.
    public var ranges = 0, cached = 0, silent = 0, transcribed = 0, engineRuns = 0
    /// Of `cached`: ranges sliced from a whole-file transcript (background pre-transcription, PERF-CAPTIONS-2).
    public var wholeFile = 0
    /// Seconds of audio sent to the engine.
    public var audioSeconds = 0.0

    public init() {}

    public var logLine: String {
        func f(_ v: Double) -> String { String(format: "%.2f", v) }
        return "captions: total \(f(total))s = extraction \(f(extraction)) separation \(f(separation)) silence \(f(silenceCheck)) "
            + "join \(f(joining)) engine \(f(engine)) snapping \(f(snapping)) segmenting \(f(segmenting)) | ranges \(ranges) "
            + "cached \(cached) (whole-file \(wholeFile)) silent \(silent) transcribed \(transcribed) (\(f(audioSeconds))s audio) "
            + "engine runs \(engineRuns)"
    }

    /// Monotonic clock (seconds).
    static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
}
