import Testing
import Foundation
import Darwin
@testable import ValseAI
import ValseCore
import ValseEngine
import ValseTestSupport

/// PERF-CAPTIONS-2, opt-in measurements on a real project (a COPY: media are read from its `media/` folder).
/// `VALSE_PRETRANS_PROJECT=/path/COPY.valse VALSE_PRETRANS_OUT=/empty/dir scripts/test.sh --filter PreTranscriptionBenchTests`
/// - `benefit`: cold caption request (fresh cache, twice) vs background pass + warm request; captions and per-range
///   transcripts of each written for a diff (`ondemand/`, `ondemand2/`, `pre/`); whisper peak memory.
/// - `cost`: playback (composed fps, dropped %, delivered frames, compose p95) and main-thread lateness, interleaved
///   without / with a background pass running (and with a foreground-priority run for comparison); pause latency
///   from "busy" to the whisper process gone. `VALSE_PRETRANS_ROUNDS` (default 3).
@MainActor @Suite(.serialized) struct PreTranscriptionBenchTests {
    static var env: [String: String] { ProcessInfo.processInfo.environment }

    static func load() throws -> (Project, URL)? {
        guard let path = env["VALSE_PRETRANS_PROJECT"], let outPath = env["VALSE_PRETRANS_OUT"] else { return nil }
        let pkg = URL(fileURLWithPath: path)
        var p = try ProjectPackage.load(from: pkg)
        let own = pkg.appendingPathComponent("media")
        for i in p.media.indices {
            let copy = own.appendingPathComponent(p.media[i].url.lastPathComponent)
            if FileManager.default.fileExists(atPath: copy.path) { p.media[i].url = copy }
        }
        let out = URL(fileURLWithPath: outPath)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        return (p, out)
    }

    static func line(_ s: String, _ out: URL) {
        print("metric pretrans " + s)
        let f = out.appendingPathComponent("results.txt")
        let d = Data((s + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: f) { h.seekToEndOfFile(); h.write(d); try? h.close() } else { try? d.write(to: f) }
    }

    static func load1() -> String {
        var l = [Double](repeating: 0, count: 3)
        _ = getloadavg(&l, 3)
        return String(format: "load %.1f/%.1f/%.1f", l[0], l[1], l[2])
    }

    static func captionLines(_ p: Project, _ r: CaptionResult) throws -> String {
        var q = p
        try r.command.apply(to: &q)
        return SpeechCaptions.captions(in: q.timeline).map { String(format: "%.2f\t", $0.start.seconds) + (CaptionOps.text($0)?.string ?? "") }
            .joined(separator: "\n")
    }

    static func foregroundRecognizer() -> CaptionBatch.Recognizer {
        { wav, request, progress in
            guard let cli = WhisperRuntime.cliURL, let model = ModelCatalog.preferredWhisperModel else { throw SpeechFailure.speechModelNeeded }
            let o = WhisperEngine.Options(language: request.language, model: model, cli: cli, keepFillers: request.keepFillers)
            return try await WhisperEngine.transcribe(wav: wav, options: o, progress: progress)
        }
    }

    // MARK: Child process watch (whisper-cli is our child)

    final class ChildWatch: @unchecked Sendable {
        private let lock = NSLock()
        private var _peak: UInt64 = 0
        private var _alive = false
        private var stop = false
        var peakMB: Double { lock.withLock { Double(_peak) / 1_048_576 } }
        var alive: Bool { lock.withLock { _alive } }
        func resetPeak() { lock.withLock { _peak = 0 } }
        func start() {
            let t = Thread { [self] in
                while !lock.withLock({ stop }) {
                    let pids = Self.children()
                    var any = false, peak: UInt64 = 0
                    for pid in pids {
                        var info = rusage_info_v4()
                        let ok = withUnsafeMutablePointer(to: &info) { p in
                            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
                        }
                        if ok == 0 { any = true; peak = max(peak, info.ri_phys_footprint) }
                    }
                    lock.withLock { _alive = any; _peak = max(_peak, peak) }
                    usleep(20_000)
                }
            }
            t.start()
        }
        func end() { lock.withLock { stop = true } }
        static func children() -> [pid_t] {
            var buf = [pid_t](repeating: 0, count: 64)
            let n = proc_listchildpids(getpid(), &buf, Int32(buf.count * MemoryLayout<pid_t>.size))
            guard n > 0 else { return [] }
            return buf.prefix(Int(n)).filter { pid in
                guard pid > 0 else { return false }
                var name = [CChar](repeating: 0, count: 256)
                proc_name(pid, &name, UInt32(name.count))
                return String(cString: name).contains("whisper")
            }
        }
    }

    func waitUntil(_ cond: () -> Bool, max seconds: Double = 300) async {
        let t0 = Date()
        while !cond(), Date().timeIntervalSince(t0) < seconds { try? await Task.sleep(for: .milliseconds(20)) }
    }

    // MARK: 1. Benefit + equivalence

    @Test func benefit() async throws {
        guard let (p, out) = try Self.load() else { return }
        try await HeavyWorkGate.run {
            let watch = ChildWatch(); watch.start(); defer { watch.end() }
            let dirs = ["ondemand", "ondemand2", "pre"].map { out.appendingPathComponent($0) }
            for d in dirs { try? FileManager.default.removeItem(at: d); try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
            let onDemand = TranscriptStore(directory: dirs[0]), onDemand2 = TranscriptStore(directory: dirs[1])
            let pre = TranscriptStore(directory: dirs[2])
            let o = CaptionOptions(language: nil, engine: .automatic, source: .allTracks)
            Self.line("benefit start \(Self.load1())", out)

            // cold: what the user waits for today (PERF-CAPTIONS-1), twice (run-to-run variation of whisper itself)
            watch.resetPeak()
            var t0 = CaptionTimings.now()
            let cold = try await CaptionGenerator.run(project: p, options: o, store: onDemand)
            let tCold = CaptionTimings.now() - t0
            Self.line(String(format: "cold_request %.2fs whisper_peak %.0fMB | %@", tCold, watch.peakMB, cold.timings.logLine), out)
            try Self.captionLines(p, cold).write(to: out.appendingPathComponent("captions_cold.txt"), atomically: true, encoding: .utf8)
            t0 = CaptionTimings.now()
            let cold2 = try await CaptionGenerator.run(project: p, options: o, store: onDemand2)
            Self.line(String(format: "cold_request_again %.2fs | %@", CaptionTimings.now() - t0, cold2.timings.logLine), out)
            try Self.captionLines(p, cold2).write(to: out.appendingPathComponent("captions_cold2.txt"), atomically: true, encoding: .utf8)

            // the background pass (what the scheduler runs after import / save), background priority
            Self.line(String(format: "pending before the pass %.1fs of audio", PreTranscription.pendingSeconds(p, o, store: pre)), out)
            watch.resetPeak()
            t0 = CaptionTimings.now()
            let tm = try await Task.detached(priority: .background) { try await PreTranscription.prepare(p, o, store: pre) }.value
            let tPass = CaptionTimings.now() - t0
            Self.line(String(format: "background_pass %.2fs whisper_peak %.0fMB | %@ | %@", tPass, watch.peakMB, tm.logLine, Self.load1()), out)

            // warm: the request after the pass
            t0 = CaptionTimings.now()
            let warm = try await CaptionGenerator.run(project: p, options: o, store: pre)
            let tWarm = CaptionTimings.now() - t0
            Self.line(String(format: "warm_request %.3fs | %@", tWarm, warm.timings.logLine), out)
            try Self.captionLines(p, warm).write(to: out.appendingPathComponent("captions_warm.txt"), atomically: true, encoding: .utf8)
            #expect(warm.timings.transcribed == 0)
        }
    }

    // MARK: 2. Cost

    /// Plays the project's first seconds; returns (composed fps, dropped %, delivered fps, compose p95 ms).
    func play(_ p: Project, seconds: Double) async throws -> (Double, Double, Double, Double) {
        let engine = PlaybackEngine(project: p)
        engine.forceRebuild()
        try await PlaybackProbe.waitReady(engine)
        let r = try await PlaybackProbe.measure(engine, seconds: seconds)
        engine.pause()
        let expected = r.itemSeconds * p.settings.frameRate.fps
        let dropped = expected > 0 ? max(0, 1 - Double(r.composed) / expected) * 100 : 100
        return (r.composedFPS, dropped, r.fps, r.composeCostP95Ms)
    }

    /// Main-actor lateness over `seconds`: a 10 ms timer's delays (p99, max, ms).
    func mainLateness(seconds: Double) async -> (Double, Double) {
        var late: [Double] = []
        let end = CaptionTimings.now() + seconds
        while CaptionTimings.now() < end {
            let t = CaptionTimings.now()
            try? await Task.sleep(nanoseconds: 10_000_000)
            late.append(max(0, (CaptionTimings.now() - t - 0.010) * 1000))
        }
        late.sort()
        return (late[min(late.count - 1, Int(Double(late.count) * 0.99))], late.last ?? 0)
    }

    static func median(_ xs: [Double]) -> Double { let s = xs.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }

    @Test func cost() async throws {
        guard let (p, out) = try Self.load() else { return }
        let rounds = Int(Self.env["VALSE_PRETRANS_ROUNDS"] ?? "") ?? 3
        let seconds = 6.0
        try await HeavyWorkGate.run {
            let watch = ChildWatch(); watch.start(); defer { watch.end() }
            Self.line("cost start \(Self.load1()) rounds \(rounds)", out)
            var rows: [String: [[Double]]] = [:]
            let modes = ["idle", "background", "paused", "foreground"]
            for round in 1...rounds {
                for mode in modes {
                    var task: Task<CaptionTimings, any Error>?
                    let dir = out.appendingPathComponent("cost-\(round)-\(mode)")
                    try? FileManager.default.removeItem(at: dir)
                    let control = PassControl()
                    if mode != "idle" {
                        let store = TranscriptStore(directory: dir)
                        // foreground = what the request itself runs (normal priority)
                        let rec: CaptionBatch.Recognizer? = mode == "foreground" ? CaptionBatch.defaultRecognizer : nil
                        task = Task.detached(priority: mode == "foreground" ? .userInitiated : .background) {
                            try await PreTranscription.prepare(p, CaptionOptions(), store: store, recognizer: rec, control: control)
                        }
                        await waitUntil({ watch.alive })   // whisper running (extraction done for the first run)
                        try await Task.sleep(for: .seconds(2))
                        if mode == "paused" { control.setPaused(true) }   // what playback gets in the app
                    }
                    let (cfps, dropped, dfps, p95) = try await play(p, seconds: seconds)
                    let (lp99, lmax) = await mainLateness(seconds: 3)
                    let whisperAlive = watch.alive
                    task?.cancel()
                    control.release()
                    _ = await task?.result
                    try? FileManager.default.removeItem(at: dir)
                    rows[mode, default: []].append([cfps, dropped, dfps, p95, lp99, lmax])
                    Self.line(String(format: "round %d %@ composed_fps %.1f dropped %.1f%% delivered_fps %.1f compose_p95 %.1fms main_late_p99 %.1fms max %.1fms whisper_alive %@ | %@",
                                     round, mode, cfps, dropped, dfps, p95, lp99, lmax, whisperAlive ? "yes" : "no", Self.load1()), out)
                }
            }
            for mode in modes {
                let r = rows[mode] ?? []
                let m = (0..<6).map { i in Self.median(r.map { $0[i] }) }
                Self.line(String(format: "median %@ composed_fps %.1f dropped %.1f%% delivered_fps %.1f compose_p95 %.1fms main_late_p99 %.1fms max %.1fms",
                                 mode, m[0], m[1], m[2], m[3], m[4], m[5]), out)
            }

            // pause latency through the real scheduler (app delays, real poll): busy → whisper process stopped (SSTOP)
            // (kept: word diff against the uninterrupted runs of `benefit` shows what pausing changes)
            try? FileManager.default.removeItem(at: out.appendingPathComponent("cost-pause"))
            let store = TranscriptStore(directory: out.appendingPathComponent("cost-pause"))
            let pt = PreTranscriber()
            pt.store = store
            pt.configureForTests(now: Date.init, quietDelay: 0, startQuietDelay: 0, resumeQuietDelay: 2, pollInterval: 0.25)
            pt.systemBlocker = { nil }
            var busy = false
            let owner = NSObject()
            let work = PreTranscriber.Work(project: p, options: CaptionOptions())
            pt.setSource(owner, busy: { busy }, work: { work })
            let t0Pass = CaptionTimings.now()
            pt.isEnabled = true
            var latencies: [Double] = []
            for i in 0..<6 {
                await waitUntil({ (pt.processID != nil && pt.state == .running) || pt.finished > 0 })
                guard let pid = pt.processID, pt.finished == 0 else { break }
                try await Task.sleep(for: .milliseconds(1500 + 900 * i))
                let t0 = CaptionTimings.now()
                busy = true
                await waitUntil({ PreTranscriberTests.status(pid) == UInt32(SSTOP) || pt.processID != pid }, max: 10)
                if PreTranscriberTests.status(pid) == UInt32(SSTOP) { latencies.append(CaptionTimings.now() - t0) }
                try await Task.sleep(for: .seconds(3))   // "playback"
                busy = false
            }
            Self.line("pause_latency_s " + latencies.map { String(format: "%.3f", $0) }.joined(separator: " ")
                      + String(format: " median %.3f (poll %.2fs)", Self.median(latencies), pt.pollInterval), out)
            await waitUntil({ pt.finished == 1 }, max: 1800)
            Self.line(String(format: "pass_with_%d_pauses %.1fs (each 3 s + 2 s resume delay) | %@ | %@", latencies.count,
                             CaptionTimings.now() - t0Pass, pt.lastTimings?.logLine ?? "not finished", Self.load1()), out)
            await pt.stopAll()
        }
    }
}
