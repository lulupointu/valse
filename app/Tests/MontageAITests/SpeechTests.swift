import Testing
import Foundation
@testable import MontageAI
import MontageCore
import MontageEngine
import MontageTestSupport

/// Speech-to-text (AI-001 / TX-017): whisper.cpp parsing, accuracy on bench/speech_fr.wav, language auto-detect.
@Suite(.serialized) struct SpeechTests {
    @Test func whisperFullJSONTokensMergeIntoWords() throws {
        let json = """
        {"result": {"language": "fr"}, "transcription": [{"tokens": [
          {"text": "[_BEG_]", "offsets": {"from": 0, "to": 0}, "p": 0.9},
          {"text": " Pour", "offsets": {"from": 10, "to": 200}, "p": 0.99},
          {"text": " l", "offsets": {"from": 200, "to": 260}, "p": 0.98},
          {"text": "'", "offsets": {"from": 260, "to": 270}, "p": 0.97},
          {"text": "end", "offsets": {"from": 270, "to": 400}, "p": 0.96},
          {"text": "roit", "offsets": {"from": 400, "to": 520}, "p": 0.95},
          {"text": ",", "offsets": {"from": 520, "to": 530}, "p": 0.99},
          {"text": " 4", "offsets": {"from": 600, "to": 700}, "p": 0.9},
          {"text": "K", "offsets": {"from": 700, "to": 760}, "p": 0.9},
          {"text": ".", "offsets": {"from": 760, "to": 770}, "p": 0.9},
          {"text": "[_TT_38]", "offsets": {"from": 770, "to": 770}, "p": 0.9}
        ]}]}
        """
        let t = try WhisperEngine.parse(Data(json.utf8), fallbackLanguage: "en")
        #expect(t.language == "fr")
        #expect(t.words.map(\.text) == ["Pour", "l'endroit,", "4K."])
        #expect(abs(t.words[1].start - 0.2) < 1e-9 && abs(t.words[1].end - 0.53) < 1e-9)
        #expect(t.words.allSatisfy { ($0.confidence ?? 0) > 0.8 })
    }

    @Test func modelCatalogKnowsWhisperTurbo() {
        let s = ModelCatalog.whisperTurbo
        #expect(s.url.absoluteString.hasPrefix("https://huggingface.co/ggerganov/whisper.cpp/"))
        #expect(s.sha256.count == 64)
        #expect(ModelCatalog.modelsDirectory.path.contains("Montage"))
    }

    @Test func sha256MatchesKnownDigest() throws {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("montage-sha-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: u)
        defer { try? FileManager.default.removeItem(at: u) }
        #expect(try ModelManager.sha256(of: u) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    /// whisper.cpp large-v3-turbo on the French benchmark clip: WER ≤ 6 %, language auto-detected, word timing sane.
    @Test func whisperFrenchWER() async throws {
        try await HeavyWorkGate.run {   // keep real-time probes / ML tests from starving each other
            guard WhisperRuntime.isAvailable, let wav = AIFixtures.speechFR, let ref = AIFixtures.speechFRReference else {
                print("skip: whisper model/runtime or bench media missing"); return
            }
            let clock = ContinuousClock()
            let t0 = clock.now
            let t = try await Transcriber.transcribe(wav: wav, request: .init(language: nil, engine: .whisper))
            let elapsed = clock.now - t0
            let wer = WordErrorRate.compute(reference: ref, hypothesis: t.text)
            print("metric stt_wer_whisper=\(wer) rtf=\(elapsed / .seconds(45.3)) words=\(t.words.count)")
            #expect(t.engine == "whisper.cpp")
            #expect(t.language == "fr")
            #expect(wer <= 0.06, "WER \(wer): \(t.text)")
            for i in t.words.indices.dropFirst() { #expect(t.words[i].start >= t.words[i - 1].start - 0.05) }
            #expect((t.words.last?.end ?? 0) > 40 && (t.words.last?.end ?? 0) < 46.5)
    
        }
    }

    /// Apple on-device speech (fast fallback): WER ≤ 20 % and French picked by auto-detection.
    @Test func appleSpeechFrenchWithAutoDetect() async throws {
        try await HeavyWorkGate.run {   // keep real-time probes / ML tests from starving each other
            guard let wav = AIFixtures.speechFR, let ref = AIFixtures.speechFRReference else { print("skip: bench media missing"); return }
            let t: Transcript
            do { t = try await Transcriber.transcribe(wav: wav, request: .init(language: nil, engine: .apple)) }
            catch AIToolError.unavailable(let why) { print("skip: Apple speech unavailable (\(why))"); return }
            let wer = WordErrorRate.compute(reference: ref, hypothesis: t.text)
            print("metric stt_wer_apple=\(wer) engine=\(t.engine)")
            #expect(t.language == "fr")
            #expect(wer <= 0.2, "WER \(wer): \(t.text)")
    
        }
    }
}
