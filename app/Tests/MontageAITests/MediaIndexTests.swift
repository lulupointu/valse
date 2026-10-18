import Testing
import Foundation
@testable import MontageAI
import MontageCore
import MontageEngine
import MontageTestSupport

/// Smart media search (AI-028): Vision labels / on-screen text / dialogue / names.
@Suite(.serialized) struct MediaIndexTests {
    @Test func searchFindsByLabelDialogueAndName() async throws {
        try await HeavyWorkGate.run {
            let face = try await MediaProbe.probe(try await FaceCoverTests.faceVideo())
            try await MediaIndex.shared.index(face)
            let e = try #require(MediaIndex.shared.entry(face))
            #expect(!e.labels.isEmpty)
            let top = e.labels.max { $0.value < $1.value }!.key
            #expect(MediaIndex.shared.score(face, query: top.replacingOccurrences(of: "_", with: " ")) > 0.3, "label \(top)")
            #expect(MediaIndex.shared.score(face, query: "zzqx") == 0)
            // dialogue from a cached transcript
            var a = face
            a.contentHash = "mi-test-\(UUID().uuidString.prefix(6))"
            TranscriptStore.shared.put(Transcript(engine: "test", language: "fr", words: [TranscriptWord(text: "Bienvenue", start: 0, end: 0.5),
                                                                                          TranscriptWord(text: "à la plage", start: 0.5, end: 1)]),
                                       TranscriptStore.key(hash: a.contentHash, range: nil, language: nil, engine: .automatic, fillers: true))
            #expect(MediaIndex.shared.score(a, query: "plage") >= 1)
            #expect(MediaIndex.shared.score(a, query: a.name) >= 1)
        }
    }
}
