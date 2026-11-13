import Foundation
import ValseCore
import ValseEngine

/// Background pre-transcription (PERF-CAPTIONS-2): the speech of imported media is recognised in the background, whole
/// file by whole file, so "Auto captions" later finds it in `TranscriptStore` and only slices it (Instagram feels instant
/// because it transcribes on upload). This type holds the pure parts: which media qualify, the whole-file cache key,
/// the cache lookup a caption request makes, slicing, and one background pass. `PreTranscriber` schedules the passes.
///
/// Whole-file transcripts are cached under the transcript panel's key (`range` nil, auto language, `.automatic` engine,
/// no filler prompt), so the transcript panel, AI clipper and media search reuse them too.
public enum PreTranscription {
    /// Longest media pre-transcribed (s). Longer media (an hour of podcast, a screen recording) would hold whisper for
    /// minutes at background priority for audio the user may only use a few seconds of; on-demand captions still work
    /// for them. 10 min is also `CaptionBatch.maxJoinedSeconds`, so such a file never needs a run of its own beyond it.
    public static let maxMediaSeconds = 600.0
    /// Shortest media worth a run (a 0.3 s sound effect has no speech).
    public static let minMediaSeconds = 1.0
    /// Audio per engine run in the background: a pause (playback, export…) terminates the run in progress and loses at
    /// most this much work; every run pays the model load (~1 s), so runs are not made shorter.
    public static let runSeconds = 180.0

    /// Cache key of a media item's whole-file background transcript.
    public static func key(hash: String) -> String {
        TranscriptStore.key(hash: hash, range: nil, language: nil, engine: .automatic, fillers: false)
    }

    /// Media that a pass would transcribe: audio, not too short or long, not already cached.
    public static func qualifies(_ a: MediaAsset, store: TranscriptStore) -> Bool {
        guard a.hasAudio, a.kind == .video || a.kind == .audio else { return false }
        let d = a.duration.seconds
        guard d >= minMediaSeconds, d <= maxMediaSeconds else { return false }
        return !store.contains(key(hash: a.contentHash))
    }

    /// The whole-file transcript a caption request may reuse for any range of the media, nil when none matches the
    /// request exactly:
    /// - same filler setting (it changes whisper's prompt);
    /// - language: auto-detect uses an auto transcript; an explicit language uses a transcript made in that language,
    ///   or an auto one whose DETECTED language is the requested one (never a transcript of another language);
    /// - engine: Apple only from Apple; automatic / whisper from a whisper transcript when whisper is installed (what
    ///   the request would run), from any engine's only when it is not and the request is automatic.
    static func wholeFile(hash: String, language: String?, engine: SpeechEngine, keepFillers: Bool, whisperAvailable: Bool,
                          store: TranscriptStore) -> Transcript? {
        let engines: [SpeechEngine] = engine == .apple ? [.apple] : [.automatic, .whisper]
        let languages: [String?] = language == nil ? [nil] : [language, nil]
        for e in engines {
            for l in languages {
                let k = TranscriptStore.key(hash: hash, range: nil, language: l, engine: e, fillers: keepFillers)
                guard let t = store.get(k) else { continue }
                if let language, l == nil, t.language != language { continue }   // auto transcript of another language
                if engine == .whisper || (engine == .automatic && whisperAvailable) {
                    guard t.engine == "whisper.cpp" || t.engine == "silence" else { continue }
                }
                return t
            }
        }
        return nil
    }

    /// The words of a whole-file transcript (media time) heard in `range`: those whose middle is inside it (merged
    /// request ranges never overlap, so no word is used twice).
    static func slice(_ t: Transcript, to range: TimeRange) -> Transcript {
        let s = range.start.seconds, e = range.end.seconds
        let words = t.words.filter { w in let m = (w.start + w.end) / 2; return m >= s && m < e }
        return Transcript(engine: t.engine, language: t.language, words: words)
    }

    /// What a pass did.
    public struct Stats: Sendable, Equatable {
        public var transcribed = 0, silent = 0, failed = 0, engineRuns = 0
        public var audioSeconds = 0.0, extraction = 0.0, engine = 0.0
        public init() {}
        public var logLine: String {
            String(format: "pre-transcription: %d media transcribed (%.1fs audio) in %d runs, %d silent, %d failed | extraction %.2fs engine %.2fs",
                   transcribed, audioSeconds, engineRuns, silent, failed, extraction, engine)
        }
    }

    /// Threads for a background whisper run (on-demand: up to 8). Measured on an M1 Pro under `taskpolicy -b`, 317 s
    /// of speech, shared machine: 4 threads 74–187 s vs 2 threads 146–288 s (normal priority, 8 threads: 32–55 s).
    /// The background policy already yields the CPU to any other work, so 4 only shortens the pass.
    public static var backgroundThreads: Int { max(1, min(4, ProcessInfo.processInfo.activeProcessorCount / 2)) }

    /// whisper.cpp at background priority (`taskpolicy -b`, `backgroundThreads`), auto language, no filler prompt; its
    /// process is reported to `control` (pause in place). No Apple-engine fallback: a background pass never shows the
    /// speech permission prompt.
    static func backgroundRecognizer(_ control: PassControl? = nil) -> CaptionBatch.Recognizer {
        { wav, request, progress in
            guard let cli = WhisperRuntime.cliURL, let model = ModelCatalog.preferredWhisperModel else { throw SpeechFailure.speechModelNeeded }
            var o = WhisperEngine.Options(language: request.language, model: model, cli: cli, keepFillers: request.keepFillers,
                                          threads: backgroundThreads)
            o.background = true
            o.onLaunch = { pid in control?.launched(pid) }
            defer { control?.ended() }
            return try await WhisperEngine.transcribe(wav: wav, options: o, progress: progress)
        }
    }

    /// Transcribes the qualifying `assets` (whole files) into `store`, batched into joined runs of ≤ `runSeconds`
    /// (`CaptionBatch`). Each run's transcripts are stored as soon as it ends, so a cancelled pass keeps what was done
    /// (the run in progress is lost; its whisper process is terminated). Between steps it waits while `control` is
    /// paused. Silent media are cached as silence; media that fail to extract are skipped (counted in `failed`).
    /// Throws `CancellationError` or the engine's error.
    static func pass(_ assets: [MediaAsset], store: TranscriptStore = .shared, recognizer: CaptionBatch.Recognizer? = nil,
                     control: PassControl? = nil, runSeconds: Double = runSeconds) async throws -> Stats {
        let recognizer = recognizer ?? backgroundRecognizer(control)
        var stats = Stats()
        let request = Transcriber.Request(language: nil, engine: .whisper, keepFillers: false)
        var group: [(asset: MediaAsset, wav: URL, seconds: Double)] = []
        defer { for g in group { try? FileManager.default.removeItem(at: g.wav) } }
        func flush() async throws {
            guard !group.isEmpty else { return }
            try await control?.checkpoint()
            var tm = CaptionTimings()
            let out = try await CaptionBatch.transcribe(group.map(\.wav), request: request, recognizer: recognizer,
                                                        timings: &tm, maxSeconds: .infinity)
            for (k, g) in group.enumerated() { store.put(out[k], key(hash: g.asset.contentHash)) }
            stats.engine += tm.engine; stats.engineRuns += tm.engineRuns
            stats.transcribed += group.count; stats.audioSeconds += group.reduce(0) { $0 + $1.seconds }
            for g in group { try? FileManager.default.removeItem(at: g.wav) }
            group = []
        }
        var seen: Set<String> = []
        for a in assets where seen.insert(a.contentHash).inserted && qualifies(a, store: store) {
            try await control?.checkpoint()
            try Task.checkCancellation()
            let source = PlayableURL.resolve(a)
            let t0 = CaptionTimings.now()
            let wav: URL
            do { wav = try await AudioExtractor.wav16k(source, range: nil) }
            catch is CancellationError { throw CancellationError() }
            catch { stats.failed += 1; continue }
            try Task.checkCancellation()
            let silent = AudioExtractor.isSilent(wav)
            stats.extraction += CaptionTimings.now() - t0
            if silent {
                try? FileManager.default.removeItem(at: wav)
                store.put(Transcript(engine: "silence", language: "", words: []), key(hash: a.contentHash))
                stats.silent += 1
                continue
            }
            let seconds = CaptionBatch.duration(wav)
            let length = group.reduce(0) { $0 + $1.seconds + CaptionBatch.gap }
            if !group.isEmpty, length + seconds > runSeconds { try await flush() }
            group.append((a, wav, seconds))
        }
        try await flush()
        return stats
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
