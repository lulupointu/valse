import Testing
import Foundation
@testable import ValseAI
import ValseCore
import ValseEngine
import ValseTestSupport

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

    /// AI QA (project 1018): a talking person is labelled "people" / "adult" by Vision, but "person", "personne",
    /// "femme" found nothing (embedding too far, no translation pack installed). Built-in FR/EN synonyms cover them.
    @Test func everydayFrenchAndEnglishWordsFindPeople() throws {
        let a = MediaAsset(name: "IMG_0001", kind: .video, url: URL(fileURLWithPath: "/tmp/x.mov"), duration: Time(10),
                           pixelSize: Size2(1080, 1920), frameRate: nil, hasVideo: true, hasAudio: false,
                           contentHash: "mi-syn-\(UUID().uuidString.prefix(6))")
        let e = MediaIndex.Entry(labels: ["people": 0.9, "adult": 0.9], text: "")
        try FileManager.default.createDirectory(at: MediaIndex.shared.directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(e).write(to: MediaIndex.shared.url(a.contentHash))
        defer { try? FileManager.default.removeItem(at: MediaIndex.shared.url(a.contentHash)) }
        for q in ["person", "personne", "femme", "Homme", "gens", "woman"] {
            #expect(MediaIndex.shared.score(a, query: q) > 0.5, "\(q)")
        }
        #expect(MediaIndex.shared.score(a, query: "voiture") == 0)
    }
}
