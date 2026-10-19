import Testing
import Foundation
@preconcurrency import AVFoundation
@testable import MontageAI
import MontageCore
import MontageEngine
import MontageTestSupport

/// Opt-in QA pass of the AI engines on REAL footage (a person talking): `MONTAGE_QA_VIDEO=/path/to/talking.mp4`
/// (+ installed models / sidecars). Prints timings (real-time factors) and quality metrics; asserts only gross
/// failures. Nothing runs without the variable, so CI and `scripts/test.sh` are unaffected.
@Suite(.serialized) struct RealMediaQATests {
    static var video: URL? {
        guard let p = ProcessInfo.processInfo.environment["MONTAGE_QA_VIDEO"], FileManager.default.fileExists(atPath: p) else { return nil }
        return URL(fileURLWithPath: p)
    }

    static func asset(_ url: URL) async throws -> MediaAsset {
        var a = try await MediaProbe.probe(url)
        a.contentHash = "qa-\(a.contentHash)"   // own cache entries, never the user's
        return a
    }

    static func rms(_ url: URL, seconds: Double = 600) throws -> Double {
        let x = try VoiceIsolationTests.readMono(url, seconds: seconds)
        return (x.reduce(0) { $0 + Double($1 * $1) } / Double(max(x.count, 1))).squareRoot()
    }

    static func time<T>(_ body: () async throws -> T) async rethrows -> (T, Double) {
        let c = ContinuousClock(), t0 = c.now
        let r = try await body()
        let d = c.now - t0
        return (r, Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
    }

    @Test func transcribeRealVideo() async throws {
        guard let v = Self.video, WhisperRuntime.isAvailable else { print("skip: MONTAGE_QA_VIDEO / whisper"); return }
        try await HeavyWorkGate.run {
            let a = try await Self.asset(v)
            let (wav, tw) = try await Self.time { try await AudioExtractor.wav16k(v, range: nil) }
            let (t, tt) = try await Self.time { try await Transcriber.transcribe(wav: wav, request: .init(language: nil, engine: .whisper)) }
            let dur = a.duration.seconds
            print("QA transcribe: dur=\(dur)s wav=\(tw)s whisper=\(tt)s rtf=\(tt / dur) lang=\(t.language) words=\(t.words.count)")
            print("QA transcript: \(t.text)")
            #expect(!t.words.isEmpty)
        }
    }

    @Test func translateCaptions() async throws {
        guard Self.video != nil else { print("skip: MONTAGE_QA_VIDEO"); return }
        let items = [(0, "Bonjour à tous, aujourd'hui je vous présente mon nouveau projet."), (1, "Merci de nous avoir suivis, et à bientôt.")]
        for (s, d) in [("fr", "en"), ("en", "fr")] {
            print("QA translate status \(s)→\(d): \(await CaptionTranslator.status(from: s, to: d))")
        }
        guard await CaptionTranslator.status(from: "fr", to: "en") == .installed else { print("skip: fr→en pack not installed"); return }
        let (out, t) = try await Self.time { try await CaptionTranslator.translate(items, from: "fr", to: "en") }
        print("QA translate fr→en (\(t)s): \(out.sorted { $0.key < $1.key }.map(\.value))")
        #expect(out.count == 2)
    }

    @Test func stemsOnRealVideo() async throws {
        guard let v = Self.video, DemucsRuntime.isAvailable else { print("skip: MONTAGE_QA_VIDEO / demucs"); return }
        try await HeavyWorkGate.run {
            let a = try await Self.asset(v)
            let (_, t) = try await Self.time { try await StemSeparator.separate(a) }
            print("QA demucs: model=\(DemucsRuntime.model?.id ?? "-") dur=\(a.duration.seconds)s took=\(t)s rtf=\(t / a.duration.seconds)")
            for s in StemSeparator.availableStems {
                guard let u = AudioStemStore.shared.readyStem(media: a, kind: s.storeKind) else { print("QA stem \(s) MISSING"); continue }
                print("QA stem \(s.rawValue) rms=\(try Self.rms(u))")
            }
            #expect(AudioStemStore.shared.readyStem(media: a, kind: StemSeparator.Stem.vocals.storeKind) != nil)
        }
    }

    @Test func voiceIsolationOnRealVideo() async throws {
        guard let v = Self.video, VoiceIsolator.isAvailable else { print("skip: MONTAGE_QA_VIDEO / AUSoundIsolation"); return }
        try await HeavyWorkGate.run {
            let a = try await Self.asset(v)
            let (_, t) = try await Self.time { try await VoiceIsolator.separate(a) }
            let voice = AudioStemStore.shared.readyStem(media: a, kind: "voice"), rest = AudioStemStore.shared.readyStem(media: a, kind: "novoice")
            print("QA voice isolation: took=\(t)s rtf=\(t / a.duration.seconds) voice=\(try voice.map { try Self.rms($0) } ?? -1) novoice=\(try rest.map { try Self.rms($0) } ?? -1)")
            #expect(voice != nil)
        }
    }

    @Test func scenesOnRealVideo() async throws {
        guard let v = Self.video else { print("skip: MONTAGE_QA_VIDEO"); return }
        try await HeavyWorkGate.run {
            let a = try await Self.asset(v)
            let (cuts, t) = try await Self.time { try await SceneDetector.cuts(v) }
            print("QA scenes: \(cuts.count) cuts in \(t)s (rtf \(t / a.duration.seconds)): \(cuts.map { String(format: "%.1f", $0) })")
        }
    }

    @Test func diarizeRealVideo() async throws {
        guard let v = Self.video, WhisperRuntime.isAvailable else { print("skip: MONTAGE_QA_VIDEO / whisper"); return }
        try await HeavyWorkGate.run {
            var p = TestProject()
            let id = try await p.addMedia(v, at: .zero, target: .newTrack)
            let clip = try #require(p.project.timeline.clip(id))
            let wav = try await AudioExtractor.wav16k(v, range: nil)
            let tr = try await Transcriber.transcribe(wav: wav, request: .init(language: nil, engine: .whisper))
            var segs: [CaptionSegment] = []
            for i in stride(from: 0, to: tr.words.count, by: 8) {
                let w = Array(tr.words[i..<min(i + 8, tr.words.count)])
                segs.append(CaptionSegment(text: w.map(\.text).joined(separator: " "), start: w.first!.start, end: w.last!.end,
                                           words: w.map { (text: $0.text, start: $0.start, end: $0.end) }))
            }
            let (turns, t) = try await Self.time { try await SpeakerDiarizer.turns(segments: segs, clips: [clip], project: p.project) }
            print("QA diarization (\(type(of: SpeakerDiarizer.defaultEmbedder()))): \(Set(turns.map(\.speaker)).count) speakers, \(turns.count) turns in \(t)s")
        }
    }

    @Test func shortsFromRealVideo() async throws {
        guard let v = Self.video, WhisperRuntime.isAvailable else { print("skip: MONTAGE_QA_VIDEO / whisper"); return }
        try await HeavyWorkGate.run {
            let a = try await Self.asset(v)
            let (projects, t) = try await Self.time { try await LongToShorts.run(a, options: .init()) }
            print("QA shorts: \(projects.count) projects in \(t)s (rtf \(t / a.duration.seconds)), LLM=\(OnDeviceLLM.isAvailable)")
            for p in projects {
                let caps = p.timeline.allClips.compactMap { c -> String? in if case .text(let tc) = c.content { return tc.string }; return nil }
                print("QA short \(p.name): \(String(format: "%.1f", p.timeline.duration.seconds))s \(p.settings.aspectPreset) captions=\(caps.count) “\(caps.prefix(4).joined(separator: " | "))”")
            }
            #expect(!projects.isEmpty)
        }
    }

    @Test func ttsRoundTrip() async throws {
        guard Self.video != nil else { print("skip: MONTAGE_QA_VIDEO"); return }
        for (lang, text) in [("fr", "Bonjour et bienvenue dans ce tutoriel de montage vidéo."), ("en", "Hello and welcome to this video editing tutorial.")] {
            guard let voice = SpeechSynthesis.defaultVoice(lang) else { print("QA tts \(lang): no voice"); continue }
            let (url, t) = try await Self.time { try await SpeechSynthesis.synthesize(text, voice: voice.id) }
            let d = try await AVURLAsset(url: url).load(.duration).seconds
            print("QA tts \(lang) voice=\(voice.name) took=\(t)s dur=\(d)s rms=\(try Self.rms(url))")
            if WhisperRuntime.isAvailable {
                let wav = try await AudioExtractor.wav16k(url, range: nil)
                let tr = try await Transcriber.transcribe(wav: wav, request: .init(language: lang, engine: .whisper))
                print("QA tts \(lang) back-transcribed: \(tr.text) (WER \(WordErrorRate.compute(reference: text, hypothesis: tr.text)))")
            }
        }
    }

    @Test func superResolution() async throws {
        guard let v = Self.video else { print("skip: MONTAGE_QA_VIDEO"); return }
        try await HeavyWorkGate.run {
            let a = try await Self.asset(v)
            print("QA super-res canUpscale=\(VideoEnhancer.canUpscale(a)) size=\(a.pixelSize)")
            guard VideoEnhancer.canUpscale(a) else { return }
            let e = VideoEnhancement(original: a.id, upscale: .hd)
            try? FileManager.default.removeItem(at: VideoEnhancer.outputURL(a, e))
            let (out, t) = try await Self.time { try await VideoEnhancer.process(a, e, stats: { print("QA super-res stats: \($0)") }) }
            let o = try await MediaProbe.probe(out)
            print("QA super-res: took=\(t)s rtf=\(t / a.duration.seconds) out=\(o.pixelSize) transfer=\(o.transfer) bits=\(o.bitDepth ?? 0) \(out.path)")
        }
    }
}
