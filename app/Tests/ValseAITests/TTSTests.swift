import Testing
import Foundation
@testable import ValseAI
import ValseCore
import ValseEngine
import ValseTestSupport

/// Text to speech (AI-006 / AU-030): French voices, file output, placement on the timeline, round trip through STT.
@Suite(.serialized) struct TTSTests {
    @Test func frenchVoicesAreListedFirst() {
        let v = SpeechSynthesis.voices()
        #expect(v.contains { $0.language.hasPrefix("fr") })
        #expect(v.first?.language.hasPrefix("fr") == true)
        #expect(SpeechSynthesis.defaultVoice("fr")?.isNovelty == false)
    }

    /// AU-030 styles really change the rendered speech: calm (slower + longer pauses) is longer than neutral, excited
    /// shorter; each style is its own cached file; neutral keeps the pre-style cache key.
    @Test func stylesChangeTheSynthesizedSpeech() async throws {
        try await HeavyWorkGate.run {
            guard let voice = SpeechSynthesis.defaultVoice("fr") else { print("skip: no French voice"); return }
            let text = "Bonjour et bienvenue. Voici la suite de la vidéo. Merci beaucoup !"
            #expect(SpeechSynthesis.cacheURL(text: text, voice: voice.id, rate: 1, pitch: 1)
                    == SpeechSynthesis.cacheURL(text: text, voice: voice.id, rate: 1, pitch: 1, style: .neutral))
            #expect(SpeechSynthesis.cacheURL(text: text, voice: voice.id, rate: 1, pitch: 1, style: .calm)
                    != SpeechSynthesis.cacheURL(text: text, voice: voice.id, rate: 1, pitch: 1))
            var seconds: [TTSStyle: Double] = [:]
            for style in [TTSStyle.neutral, .calm, .excited] {
                let url = try await SpeechSynthesis.synthesize(text, voice: voice.id, style: style)
                let asset = try await MediaProbe.probe(url)
                #expect(asset.hasAudio)
                seconds[style] = asset.duration.seconds
            }
            print("metric tts_style_seconds neutral=\(seconds[.neutral]!) calm=\(seconds[.calm]!) excited=\(seconds[.excited]!)")
            #expect(seconds[.calm]! > seconds[.neutral]! * 1.1)
            #expect(seconds[.excited]! < seconds[.neutral]! * 0.95)
        }
    }

    @Test func synthesizeFrenchAndPlaceOnTimeline() async throws {
        try await HeavyWorkGate.run {   // keep real-time probes / ML tests from starving each other
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
}
