import Testing
import Foundation
@testable import MontageAI
import MontageCore
import MontageEngine
import MontageTestSupport

/// AI clipper (AI-031): sentence windows, heuristic picking, main-track rebuild; end to end on bench speech.
@Suite(.serialized) struct ClipperTests {
    /// Words at 2.5 words/s; sentences end with "."; a 1.5 s pause after sentence 3.
    static func words(_ sentences: [String]) -> [TranscriptWord] {
        var t = 0.0, out: [TranscriptWord] = []
        for (i, s) in sentences.enumerated() {
            for w in s.split(separator: " ") { out.append(TranscriptWord(text: String(w), start: t, end: t + 0.35)); t += 0.4 }
            if i == 2 { t += 1.5 }
        }
        return out
    }

    @Test func highlightsAreNonOverlappingCompleteSentencesOfTheRightLength() {
        let s = (0..<30).map { i in i % 5 == 0 ? "Le chiffre clé est \(i * 7) pour la croissance des entreprises françaises." : "Et puis on parle un peu de tout et de rien ici." }
        let sent = Highlights.sentences(Self.words(s))
        #expect(sent.count == 30)
        let hs = Highlights.pick(sent, duration: .upTo15, count: 3)
        #expect(hs.count == 3)
        for h in hs { #expect(h.duration >= 5 - 1e-6 && h.duration <= 15 + 1e-6, "\(h.duration)") }
        let sorted = hs.sorted { $0.start < $1.start }
        for (a, b) in zip(sorted, sorted.dropFirst()) { #expect(a.end <= b.start) }
        // keyword-rich sentences (numbers, rare words) win over filler
        #expect(hs.allSatisfy { $0.text.contains("chiffre") }, "\(hs.map(\.text))")
    }

    @Test func rebuildMainTrack() async throws {
        var p = TestProject()
        _ = try await p.addVideo(.frameIndex, seconds: 10, audioHz: 440)
        let media = p.project.media[0].id
        let hs = [Highlight(start: 6, end: 8, text: "b", score: 2), Highlight(start: 1, end: 3, text: "a", score: 1)]
        try Highlights.rebuildMainTrack(hs, media: media, style: .chronological, in: &p.project)
        let clips = p.project.timeline.mainTrack!.clips
        #expect(clips.count == 2 && abs(clips[0].sourceStart.seconds - 0.85) < 1e-6 && abs(clips[1].start.seconds - clips[0].duration.seconds) < 1e-6)
        #expect(TimelineOps.validate(p.project.timeline).isEmpty)
        try Highlights.rebuildMainTrack(hs, media: media, style: .speech, in: &p.project)
        #expect(abs(p.project.timeline.mainTrack!.clips[0].sourceStart.seconds - 5.85) < 1e-6)
    }

    @Test func clipsBenchSpeech() async throws {
        try await HeavyWorkGate.run {
            guard let speech = AIFixtures.speechFR else { print("skip: bench/media/speech_fr.wav missing"); return }
            let a = try await MediaProbe.probe(speech)
            var o = AIClipper.Options()
            o.duration = .upTo15; o.useLLM = false; o.language = "fr"
            let hs = try await AIClipper.highlights(a, options: o)
            print("metric clipper_highlights=\(hs.count) \(hs.map { "\(Int($0.start))-\(Int($0.end))" })")
            #expect(!hs.isEmpty)
            #expect(hs.allSatisfy { $0.duration <= 15.5 && !$0.text.isEmpty })
        }
    }

    @Test func llmPicksOnBenchSpeech() async throws {
        try await HeavyWorkGate.run {
            guard ProcessInfo.processInfo.environment["MONTAGE_SLOW_TESTS"] == "1" else { print("skip: set MONTAGE_SLOW_TESTS=1"); return }
            guard OnDeviceLLM.isAvailable, let speech = AIFixtures.speechFR else { print("skip: no LLM / bench speech"); return }
            let a = try await MediaProbe.probe(speech)
            var o = AIClipper.Options()
            o.duration = .upTo15; o.language = "fr"; o.count = 2
            let hs = try await AIClipper.highlights(a, options: o)
            print("metric clipper_llm=\(hs.map { "\(Int($0.start))-\(Int($0.end)) \($0.title)" })")
            #expect(hs.count == 2)
        }
    }
}
