import Testing
import Foundation
@testable import MontageAI
import MontageCore
import MontageTestSupport

/// AI writer (AI-029): script cleaning + caption segmentation; opt-in generation with the local LLM.
@Suite(.serialized) struct AIWriterTests {
    @Test func cleanStripsDecorations() {
        let raw = "**Script :**\n[Voix calme]\nEn 1760, le monde bascule. (musique douce)\n\n---\nLes usines naissent."
        #expect(AIWriter.clean(raw) == "En 1760, le monde bascule.\nLes usines naissent.")
    }

    @Test func segmentsFollowSentencesAndReadingPace() {
        let s = "En 1760, le monde bascule. La révolution industrielle transforme l'Europe, les villes grossissent et la classe ouvrière grandit très vite. Fin."
        let segs = AIWriter.segments(s, start: 2)
        #expect(segs.count >= 4)
        #expect(segs.allSatisfy { $0.text.count <= 56 })
        #expect(abs(segs[0].start - 2) < 1e-9)
        for (a, b) in zip(segs, segs.dropFirst()) { #expect(abs(a.end - b.start) < 1e-9) }
        #expect(segs.last!.end - segs.last!.start >= 1.2 - 1e-9)
        #expect(AIWriter.segments(s, start: 0, split: false).count == 1)
        var p = Project()
        _ = CaptionOps.addCaptionTrack(segs, to: &p, origin: .script)
        #expect(p.timeline.allClips.count == segs.count)
    }

    @Test func localModelWritesFrenchScript() async throws {
        try await HeavyWorkGate.run {
            guard ProcessInfo.processInfo.environment["MONTAGE_SLOW_TESTS"] == "1" else { print("skip: set MONTAGE_SLOW_TESTS=1"); return }
            guard AIWriter.isAvailable else { print("skip: no on-device language model"); return }
            let clock = ContinuousClock(), t0 = clock.now
            let s = try await AIWriter.write(topic: "les bienfaits de la marche à pied", requirements: "", kind: .talking, language: "fr")
            print("metric writer_seconds=\((clock.now - t0).components.seconds) words=\(s.split(separator: " ").count)")
            #expect(s.split(separator: " ").count > 30)
            #expect(s.lowercased().contains("marche"))
            let shorter = try await AIWriter.revise(s, .shorter, language: "fr")
            #expect(shorter.count < s.count)
        }
    }
}
