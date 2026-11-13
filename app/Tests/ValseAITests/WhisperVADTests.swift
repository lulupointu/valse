import Testing
import Foundation
@testable import ValseAI
import ValseCore
import ValseEngine
import ValseTestSupport

/// PERF-CAPTIONS-4: whisper.cpp VAD runs: time map from the stderr log, words mapped back to input time, fallbacks.
@Suite struct WhisperVADTests {
    static let log = """
    whisper_vad: Including segment 0: 7.97 - 11.30 (duration: 3.33)
    whisper_vad: vad_segment_info: orig_start: 7.97, orig_end: 11.20, vad_start: 0.00, vad_end: 3.33
    whisper_vad: vad_segment_info: orig_start: 23.43, orig_end: 24.06, vad_start: 3.43, vad_end: 4.16
    whisper_vad: vad_segment_info: orig_start: 24.23, orig_end: 30.91, vad_start: 4.26, vad_end: 11.04
    """

    static var map: VADTimeMap {
        let c = VADTimeMap.Collector()
        for l in log.components(separatedBy: "\n") { c.add(l) }
        return c.map
    }

    @Test func spansParsedFromStderrLog() {
        #expect(VADTimeMap.span(fromLog: "whisper_vad: detected 13 speech segments") == nil)
        #expect(VADTimeMap.span(fromLog: "progress = 50%") == nil)
        let m = Self.map
        #expect(m.spans == [.init(original: 7.97, start: 0, end: 3.33), .init(original: 23.43, start: 3.43, end: 4.16),
                            .init(original: 24.23, start: 4.26, end: 11.04)])
    }

    @Test func wordsMappedToInputTime() {
        let m = Self.map
        let words = [TranscriptWord(text: "Bonjour", start: 0.05, end: 0.4),
                     // first word after a pause: starts in the previous part (DTW anchor), ends in the next one
                     TranscriptWord(text: "Aujourd'hui,", start: 3.2, end: 3.9),
                     // ends in the 0.1 s gap between two parts: nearest part
                     TranscriptWord(text: "nous", start: 4.1, end: 4.2),
                     TranscriptWord(text: "allons", start: 4.3, end: 4.6)]
        let out = m.original(words)
        #expect(abs(out[0].start - 8.02) < 1e-9 && abs(out[0].end - 8.37) < 1e-9)
        #expect(abs(out[1].start - 23.43) < 1e-9, "start kept inside its own part, not in the pause")
        #expect(abs(out[1].end - 23.90) < 1e-9)
        #expect(abs(out[2].end - 24.16) < 1e-9)
        #expect(abs(out[3].start - 24.27) < 1e-9 && abs(out[3].end - 24.57) < 1e-9)
        for k in 1..<out.count { #expect(out[k].start >= out[k - 1].start) }
        #expect(abs(m.condensed(23.43 + 0.5) - 3.93) < 1e-9)
        #expect(abs(m.condensed(60) - 11.04) < 1e-9, "past the last part: its end")
    }

    static func json(_ segments: [(from: Int, tokens: [(String, Int)])]) -> Data {
        let segs: [[String: Any]] = segments.map { s in
            ["offsets": ["from": s.from, "to": s.from + 1000],
             "tokens": [["text": "[_BEG_]", "offsets": ["from": 0, "to": 0], "t_dtw": -1]]
                + s.tokens.map { ["text": $0.0, "offsets": ["from": $0.1 * 10, "to": $0.1 * 10], "t_dtw": $0.1, "p": 0.9] as [String: Any] }]
        }
        return try! JSONSerialization.data(withJSONObject: ["result": ["language": "fr"], "transcription": segs])
    }

    @Test func parseWithVADMapsDTWWords() throws {
        // segment offsets are already in input time (whisper maps them), tokens in condensed time
        let data = Self.json([(7970, [(" Bonjour", 40), (" et", 62)]), (23430, [(" Aujourd", 375), ("'hui", 394)])])
        let t = try WhisperEngine.parse(data, fallbackLanguage: "fr", vad: Self.map)
        #expect(t.words.map(\.text) == ["Bonjour", "et", "Aujourd'hui"])
        #expect(abs(t.words[0].end - 8.37) < 1e-6)
        #expect(t.words[2].start >= 23.43 && abs(t.words[2].end - 23.94) < 1e-6)
        #expect(t.words[0].start > 7.97 && t.words[0].start < t.words[0].end)
    }

    @Test func parseWithoutTimeMap() throws {
        // VAD found no speech: empty output is fine
        let empty = try JSONSerialization.data(withJSONObject: ["result": ["language": "fr"], "transcription": []])
        #expect(try WhisperEngine.parse(empty, fallbackLanguage: "fr", vad: VADTimeMap(spans: [])).words.isEmpty)
        // words but no map (a whisper build that doesn't log it): refused, so the caller reruns without VAD
        let data = Self.json([(0, [(" Bonjour", 40)])])
        #expect(throws: SpeechFailure.self) { try WhisperEngine.parse(data, fallbackLanguage: "fr", vad: VADTimeMap(spans: [])) }
    }

    /// A failing VAD run (here: a VAD model file that doesn't load) falls back to the usual run.
    @Test func brokenVADModelFallsBack() async throws {
        try await HeavyWorkGate.run {
            guard WhisperRuntime.isAvailable, let cli = WhisperRuntime.cliURL, let model = ModelCatalog.installedURL(ModelCatalog.whisperSmall)
                    ?? ModelCatalog.installedWhisperModel, let wav = AIFixtures.speechFR else {
                print("skip: whisper model/runtime or bench media missing"); return
            }
            let bad = FileManager.default.temporaryDirectory.appendingPathComponent("valse-bad-vad-\(UUID().uuidString).bin")
            try Data(repeating: 7, count: 4096).write(to: bad)
            defer { try? FileManager.default.removeItem(at: bad) }
            let piece = try await AudioExtractor.wav16k(wav, range: TimeRange(start: .zero, end: Time(6)))
            defer { try? FileManager.default.removeItem(at: piece) }
            var o = WhisperEngine.Options(language: "fr", model: model, cli: cli)
            o.vadModel = bad
            let t = try await WhisperEngine.transcribe(wav: piece, options: o)
            #expect(t.words.count >= 5)
            // a fetch that never completed (partial / missing file): same
            o.vadModel = bad.deletingLastPathComponent().appendingPathComponent("valse-missing-\(UUID().uuidString).bin")
            let t2 = try await WhisperEngine.transcribe(wav: piece, options: o)
            #expect(t2.words.map(\.text) == t.words.map(\.text))
        }
    }

    // MARK: automatic fetch (owner decision: the VAD comes with the speech models, silently)

    final class FetchLog: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []
        func add(_ id: String) { lock.withLock { ids.append(id) } }
        var all: [String] { lock.withLock { ids } }
    }

    @MainActor static func manager(_ log: FetchLog, fail: Bool = false) -> ModelManager {
        let mm = ModelManager()
        mm.addOnsEnabled = true
        mm.addOnFetcher = { spec in
            log.add(spec.id)
            if fail { throw URLError(.notConnectedToInternet) }
        }
        return mm
    }

    @MainActor @Test func whisperInstallFetchesTheVADModel() async {
        guard ModelCatalog.installedURL(ModelCatalog.sileroVAD) == nil else { print("skip: VAD model installed"); return }
        let log = FetchLog()
        let mm = Self.manager(log)
        mm.didInstall(ModelCatalog.demucs4)
        await mm.waitForAddOns()
        #expect(log.all.isEmpty, "only the speech models have it")
        mm.didInstall(ModelCatalog.whisperTurbo)
        #expect(!mm.state(ModelCatalog.sileroVAD).isBusy, "silent: not shown as a download")
        await mm.waitForAddOns()
        #expect(log.all == [ModelCatalog.sileroVAD.id])
        #expect(ModelManager.addOns(of: ModelCatalog.whisperSmall) == [ModelCatalog.sileroVAD])
    }

    @MainActor @Test func alreadyInstalledWhisperGetsTheVADModelSilently() async {
        guard ModelCatalog.installedURL(ModelCatalog.sileroVAD) == nil else { print("skip: VAD model installed"); return }
        let log = FetchLog()
        let mm = Self.manager(log)
        let fake = URL(fileURLWithPath: "/tmp/ggml-small-q5_1.bin")
        mm.fetchMissingAddOns(installed: { _ in nil })
        await mm.waitForAddOns()
        #expect(log.all.isEmpty, "no speech model: nothing to fetch")
        mm.fetchMissingAddOns(installed: { $0 == ModelCatalog.whisperSmall ? fake : nil })
        mm.fetchMissingAddOns(installed: { $0 == ModelCatalog.whisperSmall ? fake : nil })   // in flight: not twice
        #expect(!mm.state(ModelCatalog.sileroVAD).isBusy)
        await mm.waitForAddOns()
        #expect(log.all == [ModelCatalog.sileroVAD.id])
        // UI tests (simulated downloads) and unit-test processes never fetch
        let quiet = Self.manager(log)
        quiet.simulation = .complete
        quiet.fetchMissingAddOns(installed: { $0 == ModelCatalog.whisperSmall ? fake : nil })
        quiet.addOnsEnabled = false; quiet.simulation = nil
        quiet.fetchMissingAddOns(installed: { $0 == ModelCatalog.whisperSmall ? fake : nil })
        await quiet.waitForAddOns()
        #expect(log.all.count == 1)
        #expect(ModelManager().addOnsEnabled == false, "off by default in a test process")
    }

    @MainActor @Test func failedFetchIsSilentAndRetriedLater() async {
        guard ModelCatalog.installedURL(ModelCatalog.sileroVAD) == nil else { print("skip: VAD model installed"); return }
        let log = FetchLog()
        let mm = Self.manager(log, fail: true)
        let t0 = Date()
        mm.didInstall(ModelCatalog.whisperTurbo)
        await mm.waitForAddOns()
        #expect(log.all.count == 1)
        #expect(mm.state(ModelCatalog.sileroVAD) == .notInstalled, "no failure shown")
        #expect(mm.failureReasons[ModelCatalog.sileroVAD.id] == nil)
        let fake = URL(fileURLWithPath: "/tmp/ggml-large-v3-turbo-q5_0.bin")
        let installed: (AIModelSpec) -> URL? = { $0 == ModelCatalog.whisperTurbo ? fake : nil }
        mm.fetchMissingAddOns(now: t0.addingTimeInterval(60), installed: installed)
        await mm.waitForAddOns()
        #expect(log.all.count == 1, "not hammered")
        mm.fetchMissingAddOns(now: t0.addingTimeInterval(ModelManager.addOnRetryInterval + 1), installed: installed)
        await mm.waitForAddOns()
        #expect(log.all.count == 2, "retried later")
    }

    @Test func catalogEntry() {
        let s = ModelCatalog.sileroVAD
        #expect(ModelCatalog.spec(s.id) == s)
        #expect(s.license == "MIT" && s.bytes < 2_000_000 && s.kind == .vad)
        #expect(!ModelCatalog.all.filter { $0.kind == .whisper }.contains(s), "not offered as a speech model")
    }

    /// Opt-in A/B bench: `VALSE_VAD_BENCH=<dir with name.wav + name.tsv (word<TAB>onset) [+ name.lang]>
    /// VALSE_WHISPER_VAD=<silero model> scripts/test.sh --filter WhisperVADTests`. Runs each WAV through the app's
    /// whisper path with and without VAD, then the same `SpeechActivity` snapping as captions; prints time, word count
    /// and onset error (matched words).
    @Test func benchVADAgainstPlain() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["VALSE_VAD_BENCH"], let vad = WhisperEngine.defaultVADModel,
              let cli = WhisperRuntime.cliURL, let model = ModelCatalog.preferredWhisperModel else { return }
        let rounds = Int(env["VALSE_VAD_ROUNDS"] ?? "") ?? 3
        let files = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".wav") }.sorted()
        try await HeavyWorkGate.run {
            for f in files {
                let wav = URL(fileURLWithPath: dir).appendingPathComponent(f)
                let base = wav.deletingPathExtension()
                let lang = (try? String(contentsOf: base.appendingPathExtension("lang"), encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let ref: [(text: String, start: Double)] = ((try? String(contentsOf: base.appendingPathExtension("tsv"), encoding: .utf8)) ?? "")
                    .split(separator: "\n").compactMap { l in
                        let p = l.split(separator: "\t"); guard p.count == 2, let t = Double(p[1]) else { return nil }
                        return (String(p[0]), t)
                    }
                let activity = SpeechActivity.analyze(wav: wav)
                for r in 0..<rounds {
                    for useVAD in (r % 2 == 0 ? [false, true] : [true, false]) {
                        var o = WhisperEngine.Options(language: lang, model: model, cli: cli)
                        o.vadModel = useVAD ? vad : nil
                        let t0 = CaptionTimings.now()
                        var words = try await WhisperEngine.transcribe(wav: wav, options: o).words
                        let dt = CaptionTimings.now() - t0
                        if !words.isEmpty, let activity { words = activity.refine(words) }
                        let e = CaptionTimingTests.onsetErrors(words.map { ($0.text, $0.start) }, ref)
                        let mae = CaptionTimingTests.mae(e)
                        print(String(format: "metric vad_bench %@ %@ round %d time %.2fs words %d matched %d/%d onset_mae_ms %.0f p90_ms %.0f load %.1f",
                                     f, useVAD ? "vad" : "plain", r, dt, words.count, e.count, ref.count, mae * 1000,
                                     (e.map(abs).sorted().dropFirst(e.count * 9 / 10).first ?? 0) * 1000, Self.load()))
                        if r == 0 {
                            print("text vad_bench \(f) \(useVAD ? "vad" : "plain"): " + words.map(\.text).joined(separator: " "))
                        }
                    }
                }
            }
        }
    }

    static func load() -> Double {
        var l = [Double](repeating: 0, count: 3)
        return getloadavg(&l, 3) > 0 ? l[0] : -1
    }
}
