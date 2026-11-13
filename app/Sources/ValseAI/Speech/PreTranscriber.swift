import Foundation
import ValseCore
import ValseEngine

/// App-wide scheduler of background pre-transcription passes (PERF-CAPTIONS-2, owner: "make sure that a PC is not
/// overloaded when the user imports all its media at the start of a project").
///
/// - One pass at a time, app-wide; a pass batches every waiting media item into joined whisper runs
///   (`PreTranscription.pass`), launched with the background task policy and few threads.
/// - Starts only after `importQuietDelay` without a new import and `startQuietDelay` after the app was last busy.
/// - Polls (`pollInterval`, only while media wait) the editors' activity (`activitySources`: playback, scrubbing,
///   export, any `JobQueue` job, proxy / conversion work) and the system (`BackgroundConditions`). Either pauses the
///   pass at once: its whisper process is stopped in place (`PassControl`, SIGSTOP: no CPU / GPU from then on, no work
///   lost); it continues `resumeQuietDelay` after the activity ended. A pause longer than `maxPause` terminates the
///   run to give its memory back; the pass starts again later with what is left (the stopped run's audio only).
/// - Media that failed (unreadable, engine error) are not retried in this session.
@MainActor
public final class PreTranscriber {
    public static let shared = PreTranscriber()

    /// Settings ▸ Performance "Prepare captions in the background" (and never in test processes unless a test turns
    /// it on). Turning it off stops the run in progress.
    public var isEnabled = false {
        didSet {
            if !isEnabled { cancelRun(); pending.removeAll(); stopPolling() }
            else if !oldValue { ensurePolling() }
        }
    }
    /// Editors' "busy" checks, keyed by owner; a check returning nil is dropped (its editor is gone).
    public private(set) var activitySources: [ObjectIdentifier: () -> Bool?] = [:]
    /// System gate (thermal state, Low Power Mode, battery); nil = fine. Injectable for tests.
    public var systemBlocker: () -> BackgroundConditions.Blocker? = { BackgroundConditions.current() }
    /// whisper installed (helper + model): the pass never downloads anything. Injectable for tests.
    public var engineReady: () -> Bool = { WhisperRuntime.isAvailable }
    public var store: TranscriptStore = .shared
    /// nil = whisper at background priority (`PreTranscription.backgroundRecognizer`); tests inject a fake.
    var recognizer: CaptionBatch.Recognizer?
    public var runSeconds = PreTranscription.runSeconds

    /// Seconds without a new import before a pass starts (a user importing a whole shoot drops files in several goes;
    /// thumbnails, waveforms and proxies of the new media are made meanwhile).
    public var importQuietDelay = 15.0
    /// Seconds after the app was last busy before a pass starts (a start loads the model: not between two scrubs).
    public var startQuietDelay = 8.0
    /// Seconds after the app was last busy before a paused pass continues (free: the process just continues).
    public var resumeQuietDelay = 2.0
    /// Longest pause before the run in progress is terminated to give its memory back (≈ 0.6 GB for whisper turbo).
    public var maxPause = 60.0
    /// Activity poll period while media wait (s): bounds how late a pause can come.
    public var pollInterval = 0.25

    public enum State: String, Sendable { case idle, waiting, running, paused }
    public private(set) var state: State = .idle
    /// Media waiting, in order of arrival.
    public private(set) var pending: [MediaAsset] = []
    /// Passes started / paused / stopped after a long pause / finished, and the last pass's stats.
    public private(set) var started = 0, paused = 0, stopped = 0, finished = 0
    public private(set) var lastStats: PreTranscription.Stats?
    /// Why the pass is paused (activity / thermal / lowPower / battery).
    public private(set) var pauseReason: String?

    private var failed: Set<String> = []
    private var lastImport = Date.distantPast
    private var lastBusy = Date.distantPast
    private var pausedAt: Date?
    private var run: Task<Void, Never>?
    private var control: PassControl?
    private var runID = 0
    private var poller: Task<Void, Never>?
    private var now: () -> Date = Date.init

    public init() {}

    /// Registers an editor's activity check (`nil` = editor gone).
    public func setActivitySource(_ owner: AnyObject, _ busy: @escaping () -> Bool?) {
        activitySources[ObjectIdentifier(owner)] = busy
    }

    public func removeActivitySource(_ owner: AnyObject) { activitySources[ObjectIdentifier(owner)] = nil }

    /// Media just imported, or of a project just opened: queued, and the quiet delay starts again (opening a project
    /// is busy too: thumbnails, waveforms, proxies).
    public func enqueue(_ assets: [MediaAsset]) {
        guard isEnabled else { return }
        var known = Set(pending.map(\.contentHash)).union(failed)
        let fresh = assets.filter { known.insert($0.contentHash).inserted && PreTranscription.qualifies($0, store: store) }
        guard !fresh.isEmpty else { return }
        pending += fresh
        lastImport = now()
        if state == .idle { state = .waiting }
        ensurePolling()
    }

    /// Stops the run in progress (and waits until its whisper process is gone: a child process outlives its parent)
    /// and forgets the queue: app quit, end of a UI test.
    public func stopAll() async {
        let r = run
        cancelRun(); pending.removeAll(); stopPolling()
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

    private func stopPolling() { poller?.cancel(); poller = nil; if run == nil { state = pending.isEmpty ? .idle : .waiting } }

    /// One scheduling decision; false = nothing left to watch (polling stops).
    @discardableResult
    func tick() -> Bool {
        let t = now()
        var busy = false
        for (id, check) in activitySources {
            guard let b = check() else { activitySources[id] = nil; continue }
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
                }
            } else if control.isPaused, t.timeIntervalSince(lastBusy) >= resumeQuietDelay {
                control.setPaused(false)
                pausedAt = nil; pauseReason = nil; state = .running
                EngineLog.info("pre-transcription: resumed")
            }
            return true
        }
        guard isEnabled, !pending.isEmpty else { state = .idle; return false }
        state = .waiting
        guard !busy, t.timeIntervalSince(lastImport) >= importQuietDelay, t.timeIntervalSince(lastBusy) >= startQuietDelay,
              systemBlocker() == nil, engineReady() else { return true }
        start()
        return true
    }

    private func start() {
        let target = self.store
        let batch = pending.filter { PreTranscription.qualifies($0, store: target) }
        guard !batch.isEmpty else { pending.removeAll(); state = .idle; return }
        runID += 1
        let id = runID, recognizer = recognizer, runSeconds = runSeconds
        let control = PassControl()
        self.control = control
        state = .running
        started += 1
        EngineLog.info("pre-transcription: starting (\(batch.count) media)")
        run = Task.detached(priority: .background) { [weak self] in
            let outcome: Result<PreTranscription.Stats, any Error>
            do {
                outcome = .success(try await PreTranscription.pass(batch, store: target, recognizer: recognizer, control: control,
                                                                   runSeconds: runSeconds))
            } catch { outcome = .failure(error) }
            await self?.runEnded(id, batch: batch, outcome)
        }
    }

    private func runEnded(_ id: Int, batch: [MediaAsset], _ outcome: Result<PreTranscription.Stats, any Error>) {
        guard id == runID else { return }
        run = nil; control = nil; pausedAt = nil; pauseReason = nil
        switch outcome {
        case .success(let s):
            lastStats = s; finished += 1
            EngineLog.info(s.logLine)
            // what is still not cached failed to extract: not retried this session
            for a in batch where PreTranscription.qualifies(a, store: store) { failed.insert(a.contentHash) }
        case .failure(let e) where e is CancellationError:
            break
        case .failure(let e):
            EngineLog.error("pre-transcription failed: \(e)")
            for a in batch where PreTranscription.qualifies(a, store: store) { failed.insert(a.contentHash) }
        }
        pending.removeAll { failed.contains($0.contentHash) || !PreTranscription.qualifies($0, store: store) }
        state = pending.isEmpty ? .idle : .waiting
        if !pending.isEmpty { ensurePolling() }
    }

    /// Terminates the run in progress (`pending` still holds what it did not finish).
    private func cancelRun() {
        guard let r = run else { return }
        r.cancel()          // terminates the whisper process (SIGTERM)…
        control?.release()  // …which a stopped process only acts on once continued
        run = nil; control = nil; pausedAt = nil; pauseReason = nil
        runID += 1          // its end is ignored
        lastBusy = now()    // the next start waits `startQuietDelay`
        state = pending.isEmpty ? .idle : .waiting
    }

    // MARK: Tests

    /// Unit tests: clock and delays.
    func configureForTests(now: @escaping () -> Date, importQuietDelay: Double, startQuietDelay: Double,
                           resumeQuietDelay: Double, maxPause: Double = 60, pollInterval: Double) {
        self.now = now
        self.importQuietDelay = importQuietDelay; self.startQuietDelay = startQuietDelay
        self.resumeQuietDelay = resumeQuietDelay; self.maxPause = maxPause; self.pollInterval = pollInterval
    }
}
