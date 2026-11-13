import Testing
import Foundation
import Darwin
@testable import ValseAI
import ValseCore
import ValseEngine
import ValseTestSupport

/// PERF-CAPTIONS-2: background pre-transcription of whole media files, reused by caption requests for any range.
@Suite(.serialized) struct PreTranscriptionTests {
    static func w(_ text: String, _ s: Double, _ e: Double) -> TranscriptWord { TranscriptWord(text: text, start: s, end: e) }
    static func tempStore() -> TranscriptStore {
        TranscriptStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("valse-pt-\(UUID().uuidString)"))
    }

    /// The fake engine of CaptionBatchTests, reporting itself as whisper (what a real pass caches).
    final class Engine: @unchecked Sendable {
        let fake = CaptionBatchTests.FakeEngine()
        var recognizer: CaptionBatch.Recognizer {
            let r = fake.recognizer
            return { wav, req, p in
                let t = try await r(wav, req, p)
                return Transcript(engine: "whisper.cpp", language: req.language ?? "fr", words: t.words)
            }
        }
    }

    @Test func sliceKeepsWordsWhoseMiddleIsInTheRange() {
        let t = Transcript(engine: "whisper.cpp", language: "fr", words: [Self.w("a", 0.2, 0.6), Self.w("b", 1.8, 2.4), Self.w("c", 2.5, 3.0), Self.w("d", 4.0, 4.5)])
        let s = PreTranscription.slice(t, to: TimeRange(start: Time(2), end: Time(4.2)))
        #expect(s.words.map(\.text) == ["b", "c"])   // b's middle 2.1 is in; d's 4.25 is not
        #expect(s.words.first?.start == 1.8)         // times untouched (media time)
        #expect(s.language == "fr" && s.engine == "whisper.cpp")
    }

    /// The cache never serves a transcript the request would not have produced.
    @Test func wholeFileLookupMatchesTheRequest() {
        let store = Self.tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let h = "hash1"
        let fr = Transcript(engine: "whisper.cpp", language: "fr", words: [Self.w("Bonjour", 0, 0.5)])
        store.put(fr, PreTranscription.key(hash: h))
        func look(_ l: String?, _ e: SpeechEngine = .automatic, fillers: Bool = false, whisper: Bool = true) -> Transcript? {
            PreTranscription.wholeFile(hash: h, language: l, engine: e, keepFillers: fillers, whisperAvailable: whisper, store: store)
        }
        #expect(look(nil) == fr)                   // auto → auto
        #expect(look("fr") == fr)                  // explicit = detected language
        #expect(look("en") == nil)                 // explicit other language: never the French transcript
        #expect(look(nil, .whisper) == fr)
        #expect(look(nil, .apple) == nil)          // Apple engine asked: whisper's words are not what it would give
        #expect(look(nil, fillers: true) == nil)   // filler prompt changes whisper's output
        #expect(look("fr", whisper: false) == fr)
        // an Apple-engine whole-file transcript (transcript panel without whisper) is not used once whisper is installed
        let h2 = "hash2"
        let apple = Transcript(engine: "SFSpeechRecognizer", language: "en", words: [Self.w("Hi", 0, 0.3)])
        store.put(apple, TranscriptStore.key(hash: h2, range: nil, language: nil, engine: .automatic, fillers: false))
        #expect(PreTranscription.wholeFile(hash: h2, language: nil, engine: .automatic, keepFillers: false, whisperAvailable: true, store: store) == nil)
        #expect(PreTranscription.wholeFile(hash: h2, language: nil, engine: .automatic, keepFillers: false, whisperAvailable: false, store: store) == apple)
        // an explicit-language whole-file transcript serves that language
        let en = Transcript(engine: "whisper.cpp", language: "en", words: [Self.w("Hello", 0, 0.4)])
        store.put(en, TranscriptStore.key(hash: h, range: nil, language: "en", engine: .automatic, fillers: false))
        #expect(look("en") == en)
    }

    /// A pass caches each media as a whole file in one engine run; a caption request then makes no engine run and gives
    /// the same captions as an on-demand request.
    @Test func passThenCaptionsComeFromTheCache() async throws {
        var p = TestProject()
        _ = try await p.addVideo(.solid(.black), seconds: 12)
        _ = try await p.addMedia(try await TestMedia.audio(seconds: 2, hz: 440), at: .zero, target: .newTrack)
        _ = try await p.addMedia(try await TestMedia.audio(seconds: 2.5, hz: 660), at: Time(3), target: .newTrack)
        _ = try await p.addMedia(try await TestMedia.audio(seconds: 1.5, hz: 0), at: Time(6), target: .newTrack)
        let o = CaptionOptions(language: nil, engine: .automatic, source: .allTracks)

        let onDemandStore = Self.tempStore(), preStore = Self.tempStore()
        defer { for s in [onDemandStore, preStore] { try? FileManager.default.removeItem(at: s.directory) } }
        let e1 = Engine()
        let onDemand = try await CaptionGenerator.run(project: p.project, options: o, store: onDemandStore, recognizer: e1.recognizer)

        let e2 = Engine()
        let media = p.project.media
        #expect(media.filter { PreTranscription.qualifies($0, store: preStore) }.count == media.filter(\.hasAudio).count)
        let stats = try await PreTranscription.pass(media, store: preStore, recognizer: e2.recognizer)
        #expect(stats.transcribed == 2 && stats.silent == 1 && stats.engineRuns == 1 && stats.failed == 0)
        #expect(e2.fake.inputs.count == 1)
        #expect(media.allSatisfy { !PreTranscription.qualifies($0, store: preStore) })
        // nothing left: a second pass does nothing
        let again = try await PreTranscription.pass(media, store: preStore, recognizer: e2.recognizer)
        #expect(again.transcribed == 0 && e2.fake.inputs.count == 1)

        let warm = try await CaptionGenerator.run(project: p.project, options: o, store: preStore, recognizer: e2.recognizer)
        #expect(e2.fake.inputs.count == 1)   // no engine run
        #expect(warm.timings.wholeFile == warm.timings.ranges && warm.timings.transcribed == 0)
        var q1 = p.project, q2 = p.project
        try onDemand.command.apply(to: &q1)
        try warm.command.apply(to: &q2)
        let c1 = SpeechCaptions.captions(in: q1.timeline), c2 = SpeechCaptions.captions(in: q2.timeline)
        #expect(c1.count == 2 && c2.count == c1.count)
        for (x, y) in zip(c1, c2) {
            #expect(abs(x.start.seconds - y.start.seconds) < 0.02 && abs(x.duration.seconds - y.duration.seconds) < 0.02)
        }
        // an explicit other language does not use the cache (fake engine reports "fr")
        let en = try await CaptionGenerator.run(project: p.project, options: CaptionOptions(language: "en"), store: preStore,
                                                recognizer: e2.recognizer)
        #expect(en.timings.wholeFile == 0 && e2.fake.inputs.count == 2)
    }

    /// A pass splits its media into runs of ≤ runSeconds, stored run by run: cancelling during the second run keeps
    /// the first run's media cached.
    @Test func cancelledPassKeepsFinishedRuns() async throws {
        var p = TestProject()
        for (i, hz) in [440.0, 550, 660].enumerated() {
            _ = try await p.addMedia(try await TestMedia.audio(seconds: 2, hz: hz), at: Time(Double(i) * 3), target: .newTrack)
        }
        let store = Self.tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let gate = RunGate()
        let e = Engine()
        let inner = e.recognizer
        let recognizer: CaptionBatch.Recognizer = { wav, req, prog in
            if gate.next() > 1 { try await Task.sleep(for: .seconds(60)) }   // the second run "hangs" until cancelled
            return try await inner(wav, req, prog)
        }
        let media = p.project.media
        let task = Task.detached { try await PreTranscription.pass(media, store: store, recognizer: recognizer, runSeconds: 2.5) }
        while gate.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        let r = await task.result
        #expect((try? r.get()) == nil)
        let cached = p.project.media.filter { !PreTranscription.qualifies($0, store: store) }
        #expect(cached.count == 1)
    }

    final class RunGate: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        var count: Int { lock.withLock { n } }
        func next() -> Int { lock.withLock { n += 1; return n } }
    }
}

/// The scheduler: quiet delay, one run at a time, pause on activity / system, resume.
@MainActor @Suite(.serialized) struct PreTranscriberTests {
    final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var _running = 0, _maxRunning = 0, _runs = 0, _cancelled = 0
        var block = true
        var runs: Int { lock.withLock { _runs } }
        var cancelled: Int { lock.withLock { _cancelled } }
        var maxRunning: Int { lock.withLock { _maxRunning } }
        var isBlocking: Bool { lock.withLock { block } }
        func setBlock(_ b: Bool) { lock.withLock { block = b } }
        func enter() { lock.withLock { _running += 1; _runs += 1; _maxRunning = max(_maxRunning, _running) } }
        func leave(cancelled: Bool) { lock.withLock { _running -= 1; if cancelled { _cancelled += 1 } } }
    }

    func waitUntil(_ what: String, _ cond: () -> Bool) async {
        for _ in 0..<4000 { if cond() { return }; try? await Task.sleep(for: .milliseconds(5)) }
        Issue.record("timed out waiting for \(what)")
    }

    @Test func pausesOnActivityAndResumes() async throws {
        let store = PreTranscriptionTests.tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        var p = TestProject()
        _ = try await p.addMedia(try await TestMedia.audio(seconds: 2, hz: 440), at: .zero, target: .newTrack)
        _ = try await p.addMedia(try await TestMedia.audio(seconds: 2, hz: 550), at: Time(3), target: .newTrack)
        let probe = Probe()
        let engine = PreTranscriptionTests.Engine().recognizer
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
        pt.configureForTests(now: { clock }, importQuietDelay: 10, startQuietDelay: 5, resumeQuietDelay: 1, maxPause: 30,
                             pollInterval: 0.01)
        var busy = false
        let owner = NSObject()
        pt.setActivitySource(owner) { busy }
        pt.isEnabled = true
        pt.enqueue(p.project.media)
        #expect(pt.pending.count == 2 && pt.state == .waiting)

        // quiet delay after the import: nothing starts before it
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
        #expect(pt.stopped == 1 && pt.state == .waiting && pt.pending.count == 2)
        // after the start delay, the pass starts again and completes
        busy = false
        pt.tick()
        probe.setBlock(false)
        clock += 6
        await waitUntil("finish") { pt.finished == 1 }
        #expect(probe.runs == 2 && probe.maxRunning == 1 && pt.started == 2)
        #expect(pt.pending.isEmpty && pt.state == .idle)
        #expect(p.project.media.allSatisfy { !PreTranscription.qualifies($0, store: store) })
        #expect(pt.lastStats?.transcribed == 2)
    }

    static func status(_ pid: Int32) -> UInt32? {
        var info = proc_bsdinfo()
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        return n == Int32(MemoryLayout<proc_bsdinfo>.size) ? info.pbi_status : nil
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
        var p = TestProject()
        _ = try await p.addMedia(try await TestMedia.audio(seconds: 2, hz: 440), at: .zero, target: .newTrack)
        let pt = PreTranscriber()
        pt.store = store
        var blocker: BackgroundConditions.Blocker? = .thermal
        var ready = true
        pt.systemBlocker = { blocker }
        pt.engineReady = { ready }
        pt.recognizer = { _, _, _ in Transcript(engine: "whisper.cpp", language: "fr", words: []) }
        let clock = Date(timeIntervalSince1970: 1000)
        pt.configureForTests(now: { clock }, importQuietDelay: 0, startQuietDelay: 0, resumeQuietDelay: 0, pollInterval: 0.01)
        // disabled: enqueue ignored
        pt.enqueue(p.project.media)
        #expect(pt.pending.isEmpty)
        pt.isEnabled = true
        pt.enqueue(p.project.media)
        for _ in 0..<10 { pt.tick() }
        #expect(pt.started == 0)                  // thermal pressure
        blocker = nil; ready = false
        for _ in 0..<10 { pt.tick() }
        #expect(pt.started == 0)                  // whisper not installed: never downloads, never starts
        ready = true
        pt.tick()
        #expect(pt.started == 1)
        await pt.waitForRun()
        await waitUntil("finish") { pt.finished == 1 }
        // media without audio / too long never queue
        var long = p.project.media[0]
        long.duration = Time(PreTranscription.maxMediaSeconds + 1)
        long.contentHash = "long"
        var mute = p.project.media[0]
        mute.hasAudio = false
        mute.contentHash = "mute"
        pt.enqueue([long, mute])
        #expect(pt.pending.isEmpty)
        // turning it off stops everything
        pt.isEnabled = false
        #expect(pt.state == .idle)
    }
}
