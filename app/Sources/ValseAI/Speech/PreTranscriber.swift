import Foundation
import ValseCore
import ValseEngine

/// App-wide scheduler of background pre-transcription passes (PERF-CAPTIONS-2, owner: "make sure that a PC is not
/// overloaded when the user imports all its media at the start of a project").
///
/// - Editors register a source: their "busy" check and their work (project + the caption panel's options). They
///   `kick` the scheduler when that work may have changed (media imported, project opened, timeline saved).
/// - One pass at a time, app-wide: `PreTranscription.prepare` for the first source with audio left to recognise,
///   batched like the request itself (one joined whisper run per ≤ 10 min of audio), at background priority.
/// - Starts only `quietDelay` after the last kick and `startQuietDelay` after the app was last busy, when the system
///   allows it (`BackgroundConditions`) and whisper is installed (nothing is ever downloaded).
/// - Polls (`pollInterval`, only while there is work) the sources' activity (playback, scrubbing, export, any
///   `JobQueue` job, proxy / conversion work) and the system. Either pauses the pass at once: its whisper process is
///   stopped in place (`PassControl`, SIGSTOP: no CPU / GPU from then on, no work lost); it continues
///   `resumeQuietDelay` after the activity ended. A pause longer than `maxPause` terminates the run to give its
///   memory back; a later pass redoes that run.
@MainActor
public final class PreTranscriber {
    public static let shared = PreTranscriber()

    /// What an editor wants prepared.
    public struct Work: Sendable {
        public var project: Project
        public var options: CaptionOptions
        public init(project: Project, options: CaptionOptions) { self.project = project; self.options = options }
    }

    struct Source {
        /// nil = the editor is gone.
        var busy: () -> Bool?
        var work: () -> Work?
    }

    /// Settings ▸ Performance "Prepare captions in the background" (never in test processes unless a test turns it
    /// on). Turning it off stops the run in progress.
    public var isEnabled = false {
        didSet {
            if !isEnabled { cancelRun(); kicked = false; stopPolling() }
            else if !oldValue { kick() }
        }
    }
    private(set) var sources: [ObjectIdentifier: Source] = [:]
    /// System gate (thermal state, Low Power Mode, battery); nil = fine. Injectable for tests.
    public var systemBlocker: () -> BackgroundConditions.Blocker? = { BackgroundConditions.current() }
    /// whisper installed (helper + model). Injectable for tests.
    public var engineReady: () -> Bool = { WhisperRuntime.isAvailable }
    public var store: TranscriptStore = .shared
    /// nil = whisper at background priority; tests inject a fake.
    var recognizer: CaptionBatch.Recognizer?

    /// Seconds after the last kick (import, open, save) before a pass starts: a user importing a whole shoot drops
    /// files in several goes and arranges them; thumbnails, waveforms and proxies are made meanwhile.
    public var quietDelay = 15.0
    /// Seconds after the app was last busy before a pass starts (a start loads the model: not between two scrubs).
    public var startQuietDelay = 8.0
    /// Seconds after the app was last busy before a paused pass continues (free: the process just continues).
    public var resumeQuietDelay = 2.0
    /// Longest pause before the run in progress is terminated to give its memory back (≈ 0.9 GB for whisper turbo).
    public var maxPause = 60.0
    /// Activity poll period while there is work (s): bounds how late a pause comes.
    public var pollInterval = 0.25

    public enum State: String, Sendable { case idle, waiting, running, paused }
    public private(set) var state: State = .idle
    /// Passes started / paused / stopped after a long pause / finished / failed, and the last pass's timings.
    public private(set) var started = 0, paused = 0, stopped = 0, finished = 0, failed = 0
    public private(set) var lastTimings: CaptionTimings?
    /// Why the pass is paused (activity / thermal / lowPower / battery).
    public private(set) var pauseReason: String?

    private var kicked = false
    private var lastKick = Date.distantPast
    private var lastBusy = Date.distantPast
    private var pausedAt: Date?
    private var run: Task<Void, Never>?
    private var control: PassControl?
    private var runID = 0
    private var poller: Task<Void, Never>?
    private var now: () -> Date = Date.init

    public init() {}

    /// Registers an editor: its activity check and its work (`nil` from `busy` = editor gone).
    public func setSource(_ owner: AnyObject, busy: @escaping () -> Bool?, work: @escaping () -> Work?) {
        sources[ObjectIdentifier(owner)] = Source(busy: busy, work: work)
    }

    public func removeSource(_ owner: AnyObject) { sources[ObjectIdentifier(owner)] = nil }

    /// The work of some editor may have changed (media imported, project opened, timeline saved): look again after the
    /// quiet delay.
    public func kick() {
        guard isEnabled else { return }
        kicked = true
        lastKick = now()
        if state == .idle { state = .waiting }
        ensurePolling()
    }

    /// Terminates the run in progress, e.g. when the user asks for captions now (the request redoes that run in the
    /// foreground; a paused whisper would hold its memory next to the request's).
    public func stopRun() {
        guard run != nil else { return }
        cancelRun()
        kick()
    }

    /// Stops the run in progress (and waits until its whisper process is gone: a child process outlives its parent)
    /// and forgets everything: app quit, end of a UI test.
    public func stopAll() async {
        let r = run
        cancelRun(); kicked = false; stopPolling()
        await r?.value
    }

    /// Awaits the run in progress (tests).
    public func waitForRun() async { await run?.value }

    /// The whisper process of the run in progress (tests, measurements).
    public var processID: Int32? { control?.processID }

    // MARK: Polling

    private func ensurePolling() {
        guard poller == nil, isEnabled else { return }
        poller = Task { [weak self] in
            while let self, !Task.isCancelled {
                let interval = self.pollInterval
                if !self.tick() { self.poller = nil; return }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1e9))
            }
        }
    }

    private func stopPolling() { poller?.cancel(); poller = nil; if run == nil { state = kicked ? .waiting : .idle } }

    /// One scheduling decision; false = nothing left to watch (polling stops).
    @discardableResult
    func tick() -> Bool {
        let t = now()
        var busy = false
        for (id, s) in sources {
            guard let b = s.busy() else { sources[id] = nil; continue }
            busy = busy || b
        }
        if busy { lastBusy = t }
        if run != nil, let control {
            if !isEnabled { cancelRun(); return false }
            let reason = busy ? "activity" : systemBlocker()?.rawValue
            if let reason {
                if !control.isPaused {
                    control.setPaused(true)
                    pausedAt = t; pauseReason = reason; paused += 1; state = .paused
                    EngineLog.info("pre-transcription: paused (\(reason))")
                } else if let p = pausedAt, t.timeIntervalSince(p) > maxPause {
                    stopped += 1
                    EngineLog.info("pre-transcription: stopped after a long pause (\(reason))")
                    cancelRun()
                    kicked = true
                }
            } else if control.isPaused, t.timeIntervalSince(lastBusy) >= resumeQuietDelay {
                control.setPaused(false)
                pausedAt = nil; pauseReason = nil; state = .running
                EngineLog.info("pre-transcription: resumed")
            }
            return true
        }
        guard isEnabled, kicked else { state = .idle; return false }
        state = .waiting
        guard !busy, t.timeIntervalSince(lastKick) >= quietDelay, t.timeIntervalSince(lastBusy) >= startQuietDelay,
              systemBlocker() == nil, engineReady() else { return true }
        // the first editor with audio left to recognise (within the pass budget)
        for s in sources.values {
            guard let w = s.work() else { continue }
            let pending = PreTranscription.pendingSeconds(w.project, w.options, store: store)
            if pending > 0, pending <= PreTranscription.maxPassSeconds { start(w); return true }
        }
        kicked = false   // nothing to do until the next kick
        state = .idle
        return false
    }

    private func start(_ w: Work) {
        runID += 1
        let id = runID, target = store, recognizer = recognizer
        let control = PassControl()
        self.control = control
        state = .running
        started += 1
        EngineLog.info("pre-transcription: starting")
        run = Task.detached(priority: .background) { [weak self] in
            let outcome: Result<CaptionTimings, any Error>
            do { outcome = .success(try await PreTranscription.prepare(w.project, w.options, store: target, recognizer: recognizer, control: control)) }
            catch { outcome = .failure(error) }
            await self?.runEnded(id, outcome)
        }
    }

    private func runEnded(_ id: Int, _ outcome: Result<CaptionTimings, any Error>) {
        guard id == runID else { return }
        run = nil; control = nil; pausedAt = nil; pauseReason = nil
        switch outcome {
        case .success(let tm):
            lastTimings = tm; finished += 1
            EngineLog.info("pre-transcription: done | " + tm.logLine)
            kicked = true   // edits made meanwhile may have left new ranges
        case .failure(let e) where e is CancellationError:
            kicked = true
        case .failure(let e):
            // media offline, engine error…: not retried until the next kick (the request will say what is wrong)
            failed += 1
            EngineLog.error("pre-transcription failed: \(e)")
            kicked = false
        }
        state = kicked ? .waiting : .idle
        if kicked { ensurePolling() }
    }

    /// Terminates the run in progress.
    private func cancelRun() {
        guard let r = run else { return }
        r.cancel()          // terminates the whisper process (SIGTERM)…
        control?.release()  // …which a stopped process only acts on once continued
        run = nil; control = nil; pausedAt = nil; pauseReason = nil
        runID += 1          // its end is ignored
        lastBusy = now()    // the next start waits `startQuietDelay`
        state = kicked ? .waiting : .idle
    }

    // MARK: Tests

    /// Unit tests: clock and delays.
    func configureForTests(now: @escaping () -> Date, quietDelay: Double, startQuietDelay: Double,
                           resumeQuietDelay: Double, maxPause: Double = 60, pollInterval: Double) {
        self.now = now
        self.quietDelay = quietDelay; self.startQuietDelay = startQuietDelay
        self.resumeQuietDelay = resumeQuietDelay; self.maxPause = maxPause; self.pollInterval = pollInterval
    }
}
