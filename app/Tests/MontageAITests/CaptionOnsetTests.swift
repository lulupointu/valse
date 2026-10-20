import Testing
import Foundation
@testable import MontageAI
import MontageCore
import MontageEngine
import MontageTestSupport

/// U2 (owner bug, project 1019 IMG_7251): the first word after seconds of non-speech ("Vous", 3.2 s long caption)
/// started at the beginning of the clip, before the person speaks. Whisper anchors a segment's first word at the
/// segment start (= the 30 s window start / previous segment end) and the energy VAD took the walk-in noise for speech.
/// Fixture: bench/speech_onsets.swift (FR + EN synthetic speech with known word onsets, laid out with known silences,
/// rustle and footsteps), generated on demand into ~/Library/Caches/MontageDev/fixtures.
@Suite(.serialized) struct CaptionOnsetTests {
    struct Fixture { let wav: URL; let words: [(text: String, start: Double)]; let sentenceStarts: [Double] }

    /// Bump when bench/speech_onsets.swift changes.
    static let fixtureVersion = 2

    static func fixture(_ lang: String) async throws -> Fixture? {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MontageDev/fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wav = dir.appendingPathComponent("speech_onsets_\(lang)_v\(fixtureVersion).wav")
        let tsv = dir.appendingPathComponent("speech_onsets_\(lang)_v\(fixtureVersion).tsv")
        if !FileManager.default.fileExists(atPath: tsv.path) {
            let script = TestMedia.repoRoot().appendingPathComponent("bench/speech_onsets.swift")
            guard FileManager.default.fileExists(atPath: script.path) else { return nil }
            // blocking child process: off the cooperative pool (TESTING.md / STATUS gotcha)
            let ok: Bool = await withCheckedContinuation { c in
                DispatchQueue.global().async {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                    p.arguments = ["swift", script.path, lang, wav.path, tsv.path + ".tmp"]
                    p.standardOutput = FileHandle.nullDevice
                    p.standardError = FileHandle.nullDevice
                    do { try p.run(); p.waitUntilExit() } catch { c.resume(returning: false); return }
                    c.resume(returning: p.terminationStatus == 0)
                }
            }
            guard ok else { return nil }
            try FileManager.default.moveItem(at: URL(fileURLWithPath: tsv.path + ".tmp"), to: tsv)
        }
        let rows = try String(contentsOf: tsv, encoding: .utf8).split(separator: "\n").map { $0.split(separator: "\t") }
        let words = rows.compactMap { f -> (String, Double)? in f.count >= 2 ? Double(f[1]).map { (String(f[0]), $0) } : nil }
        var starts: [Double] = []
        var last = -1
        for f in rows where f.count == 3 { if let s = Int(f[2]), s != last, let t = Double(f[1]) { starts.append(t); last = s } }
        return Fixture(wav: wav, words: words, sentenceStarts: starts)
    }

    static func median(_ e: [Double]) -> Double {
        let s = e.map(abs).sorted()
        guard !s.isEmpty else { return .infinity }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    // MARK: Unit (no model)

    /// The owner's whisper output for IMG_7251, trimmed: segment 0 starts at 0, its first token's DTW time is 3.74 s.
    @Test func segmentFirstWordIsNotAnchoredAtTheSegmentStart() throws {
        let json = """
        {"result":{"language":"fr"},"transcription":[
         {"offsets":{"from":0,"to":5760},"tokens":[
          {"text":"[_BEG_]","offsets":{"from":0,"to":0},"t_dtw":-1,"p":0.9},
          {"text":" Vous","offsets":{"from":0,"to":1030},"t_dtw":374,"p":0.88},
          {"text":" allez","offsets":{"from":1050,"to":2350},"t_dtw":390,"p":0.97}]},
         {"offsets":{"from":6140,"to":7980},"tokens":[
          {"text":" Euh","offsets":{"from":6140,"to":6400},"t_dtw":760,"p":0.9},
          {"text":",","offsets":{"from":6400,"to":6400},"t_dtw":762,"p":0.9},
          {"text":" 2026","offsets":{"from":6400,"to":7900},"t_dtw":790,"p":0.9}]}]}
        """
        let t = try WhisperEngine.parse(Data(json.utf8), fallbackLanguage: "fr")
        #expect(t.words.map(\.text) == ["Vous", "allez", "Euh,", "2026"])
        let vous = t.words[0]
        #expect(vous.start >= 3.74 - WhisperEngine.maxTokenDuration(" Vous") - 1e-9, "Vous starts at \(vous.start)")
        #expect(vous.start > 3.1 && vous.end == 3.74)   // was 0.561 (0 + 0.15 × 3.74)
        #expect(abs(t.words[1].start - (3.74 + 0.15 * 0.16)) < 1e-6)   // inside speech: unchanged
        // a held hesitation may last long; the anchor (segment start 6.14) is within its 1.5 s
        #expect(abs(t.words[2].start - (6.14 + 0.15 * 1.46)) < 1e-6)
        #expect(WhisperEngine.maxTokenDuration(" 2026") > 1)
    }

    /// Energy frames (10 ms) → speech flags: noise 25–30 dB under the voice with clicks is not speech; a soft onset
    /// joined to a vowel is.
    @Test func vadNeedsAVoicedCore() {
        var db = [Double](repeating: -70, count: 600)
        for i in 0..<300 { db[i] = i % 55 < 4 ? -42 : -54 }          // 3 s rustle + footsteps (40 ms clicks)
        for i in 340..<346 { db[i] = -48 }                             // soft fricative onset…
        for i in 346..<380 { db[i] = -22 }                             // …into a vowel
        for i in 380..<420 { db[i] = -30 }
        let vad = SpeechActivity(frameDB: db)
        #expect(!vad.speech[0..<300].contains(true))
        #expect(vad.speech[340] && vad.speech[360] && vad.speech[419])
        #expect(!vad.speech[330] && !vad.speech[430])
        // a word whisper started in the noise snaps to the voice
        let w = vad.refine([TranscriptWord(text: "Vous", start: 0.56, end: 3.74), TranscriptWord(text: "allez", start: 3.76, end: 4.0)])
        #expect(abs(w[0].start - 3.40) < 0.011)
        #expect(w[1].start == 3.76)
        // flat recording (no dynamics): nothing is called silence
        #expect(SpeechActivity(frameDB: [Double](repeating: -40, count: 100)).speech.allSatisfy { $0 })
    }

    // MARK: Whisper

    /// Word onsets on speech with known silences / noise: median |error| < 80 ms, max < 200 ms, and no sentence's first
    /// word starts in the silence or noise before it. Both prompts (captions / transcript-with-fillers) are checked.
    @Test(arguments: ["fr", "en"]) func wordOnsetsAfterSilenceAndNoise(lang: String) async throws {
        try await HeavyWorkGate.run {
            guard WhisperRuntime.isAvailable else { print("skip: whisper model/runtime missing"); return }
            guard let fx = try await Self.fixture(lang) else { print("skip: could not build the speech fixture"); return }
            for fillers in [false, true] {
                let t = try await Transcriber.transcribe(wav: fx.wav, request: .init(language: lang, engine: .whisper, keepFillers: fillers))
                let e = CaptionTimingTests.onsetErrors(t.words.map { ($0.text, $0.start) }, fx.words)
                let worst = e.map(abs).max() ?? .infinity
                print("metric u2_onset_\(lang)\(fillers ? "_fillers" : "") median_ms=\(Int(Self.median(e) * 1000)) max_ms=\(Int(worst * 1000)) mae_ms=\(Int(CaptionTimingTests.mae(e) * 1000)) matched=\(e.count)/\(fx.words.count)")
                #expect(e.count >= fx.words.count * 8 / 10, "too few words matched: \(t.text)")
                #expect(Self.median(e) < 0.08)
                #expect(worst < 0.2, "errors: \(e.map { Int($0 * 1000) })")
                // nothing is recognised as starting in the gap before a sentence
                for s in fx.sentenceStarts {
                    let early = t.words.filter { $0.start < s - 0.12 && $0.end > s - 0.3 && $0.end < s + 1.5 }
                    #expect(early.isEmpty, "word(s) starting before the sentence at \(s): \(early.map { "\($0.text)@\($0.start)" })")
                }
            }
        }
    }

    /// Captions on a project: the first caption of each sentence appears with the voice (not at the clip start).
    @Test func captionsStartWithTheVoice() async throws {
        try await HeavyWorkGate.run {
            guard WhisperRuntime.isAvailable, let fx = try await Self.fixture("fr") else { print("skip: whisper or fixture missing"); return }
            let mov = try await CaptionTimingTests.makeAACMovie(from: fx.wav)
            defer { try? FileManager.default.removeItem(at: mov) }
            var p = Project(name: "t", settings: ProjectSettings(canvasSize: Size2(1080, 1920)))
            let dur = Time(Double(fx.words.last!.start) + 2.5)
            let asset = MediaAsset(name: "speech", kind: .video, url: mov, duration: dur, pixelSize: Size2(1080, 1920),
                                   frameRate: .fps30, hasVideo: false, hasAudio: true, contentHash: "u2-\(UUID().uuidString)")
            p.media.append(asset)
            try TimelineOps.insert(TimelineOps.makeClip(for: asset, at: .zero), into: &p, target: .automatic)
            let r = try await CaptionGenerator.run(project: p, options: CaptionOptions(language: "fr", engine: .whisper))
            try r.command.apply(to: &p)
            let caps = SpeechCaptions.captions(in: p.timeline)
            let first = try #require(caps.first)
            print("metric u2_first_caption_start_s=\(first.start.seconds) voice=\(fx.sentenceStarts[0])")
            #expect(abs(first.start.seconds - fx.sentenceStarts[0]) < 0.15)
            for s in fx.sentenceStarts {
                // the caption showing the sentence's first word starts within 150 ms of the voice
                let c = caps.min { abs($0.start.seconds - s) < abs($1.start.seconds - s) }!
                #expect(abs(c.start.seconds - s) < 0.15, "caption \(CaptionOps.text(c)?.string ?? "") at \(c.start.seconds), voice at \(s)")
            }
        }
    }

    /// Owner footage, opt-in: `MONTAGE_U2_FOOTAGE=/path/to/copy/of/IMG_7251.mov`. Onsets read off the 10 ms energy
    /// envelope (voiced "v" burst after each pause): "Vous" 3.68 s, "Vous" 6.17 s, "vous" 9.57 s (before: 0.56 s,
    /// 6.16 s, 9.42 s).
    @Test func ownerClipIMG7251() async throws {
        guard let path = ProcessInfo.processInfo.environment["MONTAGE_U2_FOOTAGE"], WhisperRuntime.isAvailable else { return }
        try await HeavyWorkGate.run {
            let url = URL(fileURLWithPath: path)
            let wav = try await AudioExtractor.wav16k(url, range: nil)
            defer { try? FileManager.default.removeItem(at: wav) }
            for fillers in [false, true] {
                let t = try await Transcriber.transcribe(wav: wav, request: .init(language: nil, engine: .whisper, keepFillers: fillers))
                print("words:", t.words.map { String(format: "%@@%.2f-%.2f", $0.text, $0.start, $0.end) }.joined(separator: " "))
                let vous = t.words.filter { CaptionText.normalize($0.text) == "vous" }
                let ref = [3.68, 6.17, 9.57]
                var errs: [Double] = []
                for r in ref {
                    let w = try #require(vous.min { abs($0.start - r) < abs($1.start - r) })
                    errs.append(w.start - r)
                }
                print("metric u2_img7251\(fillers ? "_fillers" : "") errors_ms=\(errs.map { Int($0 * 1000) })")
                #expect(t.words.first.map { $0.start > 3.5 } ?? false, "first word at \(t.words.first?.start ?? -1)")
                for e in errs { #expect(abs(e) < 0.2) }
            }
        }
    }
}
