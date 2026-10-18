import Testing
import Foundation
@testable import MontageAI
import MontageCore
import MontageEngine
import MontageTestSupport

/// Text to speech (AI-006 / AU-030): French voices, file output, placement on the timeline, round trip through STT.
@Suite(.serialized) struct TTSTests {
    @Test func frenchVoicesAreListedFirst() {
        let v = SpeechSynthesis.voices()
        #expect(v.contains { $0.language.hasPrefix("fr") })
        #expect(v.first?.language.hasPrefix("fr") == true)
        #expect(SpeechSynthesis.defaultVoice("fr")?.isNovelty == false)
    }

    @Test func synthesizeFrenchAndPlaceOnTimeline() async throws {
        guard let voice = SpeechSynthesis.defaultVoice("fr") else { print("skip: no French voice"); return }
        let text = "Bonjour et bienvenue dans ce tutoriel de montage vidéo."
        let url = try await SpeechSynthesis.synthesize(text, voice: voice.id)
        let asset = try await MediaProbe.probe(url)
        #expect(asset.hasAudio && asset.duration.seconds > 1 && asset.duration.seconds < 6)
        // cached: same request returns the same file instantly
        #expect(try await SpeechSynthesis.synthesize(text, voice: voice.id) == url)

        var p = TestProject()
        _ = try await p.addVideo(.solid(.black), seconds: 4)
        let t = try p.addText(text, at: Time(0.5), duration: 3)
        try TTSOps.placeSpeech(asset, info: TTSInfo(sourceText: t, voice: voice.id, text: text), in: &p.project)
        let speech = try #require(TTSOps.speechClip(for: t, in: p.project.timeline))
        #expect(speech.start == Time(0.5))
        #expect(p.project.timeline.tracks.contains { $0.kind == .audio && $0.clips.contains { $0.id == speech.id } })
        // regenerating replaces, never duplicates
        try TTSOps.placeSpeech(asset, info: TTSInfo(sourceText: t, voice: voice.id, text: text), in: &p.project)
        #expect(p.project.timeline.allClips.filter { $0.tts?.sourceText == t }.count == 1)
        #expect(TimelineOps.validate(p.project.timeline).isEmpty)
        // edited script → stale speech
        p[t].content = .text(TextContent(string: "Au revoir."))
        #expect(TTSOps.staleSpeech(in: p.project.timeline).count == 1)

        // round trip: the speech is recognised back
        if WhisperRuntime.isAvailable {
            let wav = try await AudioExtractor.wav16k(url, range: nil)
            defer { try? FileManager.default.removeItem(at: wav) }
            let tr = try await Transcriber.transcribe(wav: wav, request: .init(language: "fr", engine: .whisper))
            let wer = WordErrorRate.compute(reference: text, hypothesis: tr.text)
            print("metric tts_roundtrip_wer=\(wer) \(tr.text)")
            #expect(wer <= 0.2)
        }
    }
}
