import Foundation
import Testing
@testable import MontageCore

@Suite("Long video to shorts planning (AI-031)")
struct ShortsPlanTests {
    func asset(_ seconds: Double, audio: Bool = true, kind: MediaKind = .video) -> MediaAsset {
        MediaAsset(name: "Talk.mov", kind: kind, url: URL(fileURLWithPath: "/tmp/talk.mov"), duration: Time(seconds),
                   pixelSize: .hd1080, frameRate: .fps30, hasVideo: kind == .video, hasAudio: audio, contentHash: "talk-\(seconds)")
    }

    @Test func validation() {
        #expect(ShortsPlanner.validate(asset(30)) == .tooShort)
        #expect(ShortsPlanner.validate(asset(4 * 3600)) == .tooLong)
        #expect(ShortsPlanner.validate(asset(600, audio: false)) == .noAudio)
        #expect(ShortsPlanner.validate(asset(600, kind: .audio)) == .notVideo)
        #expect(ShortsPlanner.validate(asset(600)) == nil)
    }

    /// 60 sentences of 5 s (5 min of speech).
    var sentences: [Highlights.Sentence] {
        (0..<60).map { i in Highlights.Sentence(start: Double(i) * 5, end: Double(i) * 5 + 4.6, text: "Sentence number \(i) about cameras.") }
    }

    @Test func bucketsGiveHighlightsOfTheRightLength() {
        #expect(ShortsPlanner.count(forSeconds: 300) == 3)
        #expect(ShortsPlanner.count(forSeconds: 30) == 1)
        #expect(ShortsPlanner.count(forSeconds: 5 * 3600) == 10)
        for d in ShortsDuration.allCases {
            let hs = Highlights.pick(sentences, range: d.range, count: 3)
            #expect(hs.count == 3, "\(d)")
            #expect(hs.allSatisfy { d.range.contains($0.duration) }, "\(d): \(hs.map(\.duration))")
            // non-overlapping
            let sorted = hs.sorted { $0.start < $1.start }
            #expect(zip(sorted, sorted.dropFirst()).allSatisfy { $0.end <= $1.start })
        }
    }

    @Test func rangeFiltersTranscriptWords() {
        let t = Transcript(engine: "x", language: "en", words: (0..<10).map { TranscriptWord(text: "w\($0)", start: Double($0) * 10, end: Double($0) * 10 + 1, confidence: 1) })
        #expect(ShortsPlanner.words(t, in: 15...55).map(\.text) == ["w2", "w3", "w4", "w5"])
        #expect(ShortsPlanner.words(t, in: nil).count == 10)
    }

    @Test func eachShortIsAVertical916Project() {
        let a = asset(600)
        let h = Highlight(start: 100, end: 145, text: "Hello", score: 1)
        let p = ShortsPlanner.project(for: h, asset: a, index: 0, name: "Talk · Short 1")
        #expect(p.name == "Talk · Short 1")
        #expect(p.settings.aspectPreset == "9:16" && p.settings.canvasSize == Size2(1080, 1920))
        #expect(p.media.count == 1)
        let c = p.timeline.mainTrack!.clips
        #expect(c.count == 1)
        #expect(abs(c[0].sourceStart.seconds - 99.85) < 1e-6 && abs(c[0].duration.seconds - 45.4) < 1e-6)
        // 16:9 in 9:16: fills the frame (cover / fit = (1920/1080) / (1080/1920))
        #expect(abs(c[0].transform.scale.x - (1920.0 / 1080) / (1080.0 / 1920)) < 1e-6)
        #expect(TimelineOps.validate(p.timeline).isEmpty)
    }
}
