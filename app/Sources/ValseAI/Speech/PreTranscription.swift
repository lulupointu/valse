import Foundation
import ValseCore
import ValseEngine

/// Background pre-transcription (PERF-CAPTIONS-2): the speech an "Auto captions" request would recognise is recognised
/// ahead of time, in the background, so the request finds every range in `TranscriptStore` and only builds the
/// captions (Instagram feels instant because it transcribes on upload).
///
/// What is prepared is exactly the request's own work: the same ranges (the timeline clips' merged source ranges for
/// the panel's current options), the same cache keys, the same joined engine runs, the same whisper arguments
/// (`CaptionGenerator.transcribe`); only the process priority differs. A prepared request therefore gives the captions
/// an on-demand request would have given. Whole media files are NOT transcribed: measured on the owner's project, a
/// whole-file transcript sliced to the clip ranges lost whole phrases (repeated takes, long silences: 257 words
/// instead of 293), so it could not be reused without changing the captions.
public enum PreTranscription {
    /// Most audio one pass prepares (s). A longer timeline (a podcast, an hour of rushes) is left to the request: the
    /// pass would hold whisper for many minutes for captions the user may never ask for. Also keeps the joined runs
    /// identical to the request's (all or nothing: dropping some ranges would change how the rest are joined).
    public static let maxPassSeconds = 20.0 * 60

    /// whisper.cpp with the request's own arguments, launched through `taskpolicy -b` (lowest CPU priority, throttled
    /// I/O); its process is reported to `control` (pause in place). No Apple-engine fallback: a background pass never
    /// shows the speech permission prompt (`PreTranscriber` only runs when whisper is installed).
    static func backgroundRecognizer(_ control: PassControl? = nil) -> CaptionBatch.Recognizer {
        { wav, request, progress in
            guard let cli = WhisperRuntime.cliURL, let model = ModelCatalog.preferredWhisperModel else { throw SpeechFailure.speechModelNeeded }
            var o = Transcriber.whisperOptions(request, model: model, cli: cli)   // the request's own (VAD included)
            o.background = true
            o.onLaunch = { pid in control?.launched(pid) }
            defer { control?.ended() }
            return try await WhisperEngine.transcribe(wav: wav, options: o, progress: progress)
        }
    }

    /// The options a pass prepares for: the caption panel's current ones, if they are preparable (not Auto lyrics:
    /// vocal separation is far heavier; not the Apple engine).
    static func preparable(_ o: CaptionOptions) -> Bool { !o.lyrics && o.engine != .apple }

    /// Seconds of audio a request with `o` would still recognise on `p`.
    public static func pendingSeconds(_ p: Project, _ o: CaptionOptions, store: TranscriptStore = .shared) -> Double {
        guard preparable(o) else { return 0 }
        return CaptionGenerator.pendingSeconds(CaptionGenerator.plan(p, o), store: store)
    }

    /// Recognises and caches the ranges a caption request with `o` would recognise on `p`. Waits while `control` is
    /// paused; throws `CancellationError` or the request's own errors (media offline…).
    static func prepare(_ p: Project, _ o: CaptionOptions, store: TranscriptStore = .shared,
                        recognizer: CaptionBatch.Recognizer? = nil, control: PassControl? = nil) async throws -> CaptionTimings {
        var tm = CaptionTimings()
        guard preparable(o) else { return tm }
        let plan = CaptionGenerator.plan(p, o)
        guard !plan.jobs.isEmpty else { return tm }
        let t0 = CaptionTimings.now()
        _ = try await CaptionGenerator.transcribe(plan, store: store, recognizer: recognizer ?? backgroundRecognizer(control),
                                                  control: control, timings: &tm)
        tm.total = CaptionTimings.now() - t0
        return tm
    }
}

/// Pause / resume of a running pass. Paused, the pass waits between steps, and the whisper process of the run in
/// progress is stopped in place (SIGSTOP): no CPU / GPU use from the next instant, and no work lost — it continues
/// (SIGCONT) where it was. Its memory stays allocated meanwhile; the scheduler terminates a run paused too long.
public final class PassControl: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false
    private var pid: Int32?
    public init() {}

    public var isPaused: Bool { lock.withLock { paused } }
    /// The whisper process of the run in progress (nil between runs).
    public var processID: Int32? { lock.withLock { pid } }

    public func setPaused(_ p: Bool) {
        lock.withLock {
            guard paused != p else { return }
            paused = p
            if let pid { kill(pid, p ? SIGSTOP : SIGCONT) }
        }
    }

    /// Lets a stopped process run again so it acts on the termination its cancellation sent (a stopped process only
    /// handles SIGTERM once continued).
    public func release() { setPaused(false) }

    func launched(_ id: Int32) { lock.withLock { pid = id; if paused { kill(id, SIGSTOP) } } }
    func ended() { lock.withLock { pid = nil } }

    /// Waits while paused; throws when the task is cancelled.
    func checkpoint() async throws {
        while isPaused {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try Task.checkCancellation()
    }
}
