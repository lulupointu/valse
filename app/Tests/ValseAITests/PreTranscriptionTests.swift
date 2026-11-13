import Testing
import Foundation
import Darwin
@testable import ValseAI
import ValseCore
import ValseEngine
import ValseTestSupport

/// PERF-CAPTIONS-2: background pre-transcription prepares exactly what an "Auto captions" request recognises.
@Suite(.serialized) struct PreTranscriptionTests {
    static func tempStore() -> TranscriptStore {
        TranscriptStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("valse-pt-\(UUID().uuidString)"))
    }

    static func project() async throws -> TestProject {
        var p = TestProject()
        _ = try await p.addVideo(.solid(.black), seconds: 12)
        _ = try await p.addMedia(try await TestMedia.audio(seconds: 2, hz: 440), at: .zero, target: .newTrack)
        _ = try await p.addMedia(try await TestMedia.audio(seconds: 2.5, hz: 660), at: Time(3), target: .newTrack)
        _ = try await p.addMedia(try await TestMedia.audio(seconds: 1.5, hz: 0), at: Time(6), target: .newTrack)
        return p
    }

    static func captions(_ p: Project, _ r: CaptionResult) throws -> [String] {
        var q = p
        try r.command.apply(to: &q)
        return SpeechCaptions.captions(in: q.timeline).map {
            String(format: "%.4f %.4f ", $0.start.seconds, $0.duration.seconds) + (CaptionOps.text($0)?.string ?? "")
        }
    }

    /// A prepared request makes no engine run and gives the same captions as an on-demand one.
    @Test func preparedRequestIsCachedAndIdentical() async throws {
        let p = try await Self.project()
        let o = CaptionOptions(language: nil, engine: .automatic, source: .allTracks)
        let onDemandStore = Self.tempStore(), preStore = Self.tempStore()
        defer { for s in [onDemandStore, preStore] { try? FileManager.default.removeItem(at: s.directory) } }

        let e1 = CaptionBatchTests.FakeEngine()
        let onDemand = try await CaptionGenerator.run(project: p.project, options: o, store: onDemandStore, recognizer: e1.recognizer)

        let e2 = CaptionBatchTests.FakeEngine()
        #expect(PreTranscription.pendingSeconds(p.project, o, store: preStore) > 5)
        let tm = try await PreTranscription.prepare(p.project, o, store: preStore, recognizer: e2.recognizer)
        #expect(tm.engineRuns == 1 && tm.transcribed == 2 && tm.silent == 1)
        #expect(e2.inputs == e1.inputs)   // the same joined input as the request's
        #expect(PreTranscription.pendingSeconds(p.project, o, store: preStore) == 0)

        let warm = try await CaptionGenerator.run(project: p.project, options: o, store: preStore, recognizer: e2.recognizer)
        #expect(e2.inputs.count == 1)   // no engine run
        #expect(warm.timings.cached == warm.timings.ranges && warm.timings.transcribed == 0)
        #expect(try Self.captions(p.project, warm) == Self.captions(p.project, onDemand))

        // another language is another request: not served from the prepared ranges
        let en = try await CaptionGenerator.run(project: p.project, options: CaptionOptions(language: "en"), store: preStore,
                                                recognizer: e2.recognizer)
        #expect(en.timings.cached == 0 && e2.inputs.count == 2)
    }

    /// Only what changed is prepared again; lyrics and the Apple engine are never prepared.
    @Test func onlyNewRangesArePending() async throws {
        var p = try await Self.project()
        let o = CaptionOptions()
        let store = Self.tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        _ = try await PreTranscription.prepare(p.project, o, store: store, recognizer: CaptionBatchTests.FakeEngine().recognizer)
        #expect(PreTranscription.pendingSeconds(p.project, o, store: store) == 0)
        _ = try await p.addMedia(try await TestMedia.audio(seconds: 1.8, hz: 550), at: Time(8), target: .newTrack)
        let pending = PreTranscription.pendingSeconds(p.project, o, store: store)
        #expect(pending > 1.5 && pending < 3)
        #expect(PreTranscription.pendingSeconds(p.project, CaptionOptions(lyrics: true), store: store) == 0)
        #expect(PreTranscription.pendingSeconds(p.project, CaptionOptions(engine: .apple), store: store) == 0)
        let e = CaptionBatchTests.FakeEngine()
        let tm = try await PreTranscription.prepare(p.project, o, store: store, recognizer: e.recognizer)
        #expect(tm.transcribed == 1 && tm.cached == 3)
        #expect(abs((e.inputs.first ?? 0) - 1.8) < 0.2)
    }
}

/// The scheduler: quiet delay, one run at a time, pause in place on activity / system, long pause, resume.
@MainActor @Suite(.serialized) struct PreTranscriberTests {
    final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var _running = 0, _maxRunning = 0, _runs = 0, _cancelled = 0
        private var block = true
        var runs: Int { lock.withLock { _runs } }
        var cancelled: Int { lock.withLock { _cancelled } }
        var maxRunning: Int { lock.withLock { _maxRunning } }
        var isBlocking: Bool { lock.withLock { block } }
        func setBlock(_ b: Bool) { lock.withLock { block = b } }
        func enter() { lock.withLock { _running += 1; _runs += 1; _maxRunning = max(_maxRunning, _running) } }
        func leave(cancelled: Bool) { lock.withLock { _running -= 1; if cancelled { _cancelled += 1 } } }
    }

    /// Waits for a state (hang bound only: the pass runs at background priority, which a loaded test process can
    /// starve for tens of seconds — check_fast saw > 20 s).
    func waitUntil(_ what: String, _ cond: () -> Bool) async {
        let t0 = Date()
        while Date().timeIntervalSince(t0) < 300 {
            if cond() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out waiting for \(what)")
    }

    static func status(_ pid: Int32) -> UInt32? {
        var info = proc_bsdinfo()
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        return n == Int32(MemoryLayout<proc_bsdinfo>.size) ? info.pbi_status : nil
    }

    @Test func pausesInPlaceAndResumes() async throws {
        let store = PreTranscriptionTests.tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let p = try await PreTranscriptionTests.project()
        let probe = Probe()
        let engine = CaptionBatchTests.FakeEngine().recognizer
        let pt = PreTranscriber()
        pt.store = store
        pt.engineReady = { true }
        pt.systemBlocker = { nil }
        pt.recognizer = { wav, req, prog in
            probe.enter()
            do {
                while probe.isBlocking { try await Task.sleep(for: .milliseconds(5)) }
                let t = try await engine(wav, req, prog)
                probe.leave(cancelled: false)
                return t
            } catch { probe.leave(cancelled: true); throw error }
        }
        var clock = Date(timeIntervalSince1970: 1000)
        pt.configureForTests(now: { clock }, quietDelay: 10, startQuietDelay: 5, resumeQuietDelay: 1, maxPause: 30, pollInterval: 0.01)
        var busy = false
        let owner = NSObject()
        let work = PreTranscriber.Work(project: p.project, options: CaptionOptions())
        pt.setSource(owner, busy: { busy }, work: { work })
        pt.isEnabled = true
        #expect(pt.state == .waiting)

        // quiet delay after the kick: nothing starts before it
        for _ in 0..<20 { pt.tick() }
        #expect(pt.started == 0)
        clock += 11
        await waitUntil("run starts") { probe.runs == 1 }
        #expect(pt.state == .running)

        // playback starts: paused in place at the next poll (nothing cancelled, no work lost)
        busy = true
        await waitUntil("pause") { pt.state == .paused }
        #expect(pt.paused == 1 && pt.pauseReason == "activity" && probe.cancelled == 0)
        // idle again, within the resume delay: still paused; after it: running again, same run
        busy = false
        pt.tick()
        clock += 0.5
        for _ in 0..<10 { pt.tick() }
        #expect(pt.state == .paused)
        clock += 1
        await waitUntil("resume") { pt.state == .running }
        #expect(probe.runs == 1 && pt.started == 1)

        // a long pause (export, long playback) terminates the run to free its memory
        busy = true
        await waitUntil("pause 2") { pt.state == .paused }
        clock += 31
        await waitUntil("stop") { probe.cancelled == 1 }
        #expect(pt.stopped == 1 && pt.state == .waiting)
        // after the start delay, a new pass runs and completes; then nothing is left
        busy = false
        pt.tick()
        probe.setBlock(false)
        clock += 6
        await waitUntil("finish") { pt.finished == 1 }
        #expect(probe.runs == 2 && probe.maxRunning == 1 && pt.started == 2)
        await waitUntil("idle") { pt.state == .idle }
        #expect(PreTranscription.pendingSeconds(p.project, CaptionOptions(), store: store) == 0)
        #expect(pt.lastTimings?.transcribed == 2)
        // a caption request now: nothing to stop
        pt.stopRun()
        #expect(pt.started == 2)
    }

    /// A real helper process is stopped / continued in place, and a stopped one still ends when its run is cancelled.
    @Test func passControlStopsTheProcessInPlace() async throws {
        let control = PassControl()
        let task = Task.detached {
            try await ProcessPipes.run(URL(fileURLWithPath: "/bin/sleep"), ["30"], onLaunch: { control.launched($0) })
        }
        await waitUntil("launch") { control.processID != nil }
        let pid = try #require(control.processID)
        control.setPaused(true)
        await waitUntil("stopped") { Self.status(pid) == UInt32(SSTOP) }
        control.setPaused(false)
        await waitUntil("continued") { Self.status(pid) != UInt32(SSTOP) }
        control.setPaused(true)
        await waitUntil("stopped again") { Self.status(pid) == UInt32(SSTOP) }
        task.cancel()
        control.release()
        let r = try await task.value
        #expect(r.uncaughtSignal && r.status == SIGTERM)
    }

    @Test func systemBlockerAndDisabledPreventStart() async throws {
        let store = PreTranscriptionTests.tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let p = try await PreTranscriptionTests.project()
        let pt = PreTranscriber()
        pt.store = store
        var blocker: BackgroundConditions.Blocker? = .thermal
        var ready = true
        pt.systemBlocker = { blocker }
        pt.engineReady = { ready }
        pt.recognizer = CaptionBatchTests.FakeEngine().recognizer
        let clock = Date(timeIntervalSince1970: 1000)
        pt.configureForTests(now: { clock }, quietDelay: 0, startQuietDelay: 0, resumeQuietDelay: 0, pollInterval: 0.01)
        let owner = NSObject()
        var work = PreTranscriber.Work(project: p.project, options: CaptionOptions(lyrics: true))
        pt.setSource(owner, busy: { false }, work: { work })
        // disabled: a kick does nothing
        pt.kick()
        #expect(pt.state == .idle)
        pt.isEnabled = true
        for _ in 0..<10 { pt.tick() }
        #expect(pt.started == 0)                  // thermal pressure
        blocker = nil; ready = false
        for _ in 0..<10 { pt.tick() }
        #expect(pt.started == 0)                  // whisper not installed: never downloads, never starts
        ready = true
        pt.tick()
        #expect(pt.started == 0 && pt.state == .idle)   // Auto lyrics chosen in the panel: nothing preparable
        work.options = CaptionOptions()
        pt.kick()
        pt.tick()
        #expect(pt.started == 1)
        await waitUntil("finish") { pt.finished == 1 }
        // turning it off stops everything
        pt.isEnabled = false
        #expect(pt.state == .idle)
    }
}
