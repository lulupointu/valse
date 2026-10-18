import Testing
import Foundation
@testable import MontageCore

/// Speaker ID in captions (AI-005 / TX-038): clustering, smoothing, splitting captions at speaker changes, styling.
@Suite struct SpeakerCaptionTests {
    /// Two well separated groups of noisy unit vectors.
    func blobs(_ a: Int, _ b: Int, noise: Float = 0.25) -> [[Float]] {
        var g = SystemRandomNumberGenerator()
        func v(_ base: [Float]) -> [Float] { base.map { $0 + Float.random(in: -noise...noise, using: &g) } }
        let ca: [Float] = [1, 0, 0, 0.2, 0, 0], cb: [Float] = [0, 1, 0.3, 0, 0, 0.1]
        return (0..<a).map { _ in v(ca) } + (0..<b).map { _ in v(cb) }
    }

    @Test func clusteringFindsTwoSpeakersAutomatically() {
        let x = blobs(8, 6)
        let labels = SpeakerClustering.cluster(x, threshold: 0.5)
        #expect(Set(labels).count == 2)
        #expect(Set(labels[0..<8]).count == 1 && Set(labels[8...]).count == 1)
        #expect(labels[0] == 0)   // numbered by first appearance
    }

    @Test func clusteringHonoursForcedCountAndFoldsTinyClusters() {
        let x = blobs(10, 10)
        #expect(Set(SpeakerClustering.cluster(x, threshold: 0.5, count: 1)).count == 1)
        #expect(Set(SpeakerClustering.cluster(x, threshold: 0.5, count: 2)).count == 2)
        // a single outlier window (5 % of speech) joins its nearest speaker
        var y = blobs(10, 9)
        y.append([0, 0, 0, 0, 1, 0])
        let l = SpeakerClustering.cluster(y, threshold: 0.3, weights: Array(repeating: 1, count: 20))
        #expect(Set(l).count == 2)
    }

    @Test func clusteringLargeInputsUsesSubsample() {
        let x = blobs(400, 400, noise: 0.2)
        let labels = SpeakerClustering.cluster(x, threshold: 0.5, maxDirect: 100)
        #expect(Set(labels).count == 2)
        #expect(Set(labels[0..<400]).count == 1 && Set(labels[400...]).count == 1)
    }

    @Test func smoothingRemovesOneWordFlips() {
        let times = (0..<6).map { (start: Double($0) * 0.3, end: Double($0) * 0.3 + 0.25) }
        #expect(SpeakerCaptions.smooth([0, 0, 1, 0, 0, 0], times: times) == [0, 0, 0, 0, 0, 0])
        #expect(SpeakerCaptions.smooth([0, 0, 1, 1, 1, 1], times: times) == [0, 0, 1, 1, 1, 1])
    }

    @Test func splitsCaptionsAtSpeakerChanges() {
        let s = CaptionSegment(text: "Hello there. Hi you", start: 0, end: 2.4,
                               words: [("Hello", 0, 0.4), ("there.", 0.5, 1.0), ("Hi", 1.4, 1.7), ("you", 1.8, 2.4)])
        let turns = [SpeakerTurn(start: 0, end: 1.1, speaker: 0), SpeakerTurn(start: 1.3, end: 2.5, speaker: 1)]
        let out = SpeakerCaptions.split([s], turns: turns)
        #expect(out.count == 2)
        #expect(out[0].text == "Hello there." && out[0].speaker == "1" && out[0].start == 0 && out[0].end == 1.0)
        #expect(out[1].text == "Hi you" && out[1].speaker == "2" && out[1].start == 1.4 && out[1].end == 2.4)
        // one speaker: unchanged text, tagged
        let one = SpeakerCaptions.split([s], turns: [SpeakerTurn(start: 0, end: 3, speaker: 0)])
        #expect(one.count == 1 && one[0].text == s.text && one[0].speaker == "1")
    }

    func project(_ speakers: [String?]) -> Project {
        var p = Project()
        let segs = speakers.enumerated().map { i, s in
            CaptionSegment(text: "line \(i)", start: Double(i), end: Double(i) + 0.9, words: [("line", Double(i), Double(i) + 0.4), ("\(i)", Double(i) + 0.5, Double(i) + 0.9)], speaker: s)
        }
        CaptionOps.addCaptionTrack(segs, to: &p, origin: .auto)
        return p
    }

    @Test func speakersRegisterWithColoursRenameAndClear() throws {
        var p = project(["1", "2", "1"])
        SpeakerCaptions.finish(in: &p)
        #expect(p.speakers?.map(\.id) == ["1", "2"])
        let caps = SpeechCaptions.captions(in: p.timeline)
        #expect(CaptionOps.text(caps[1])?.color == SpeakerCaptions.defaultColor(1))
        #expect(CaptionOps.text(caps[0])?.color == SpeakerCaptions.defaultColor(0))
        SpeakerCaptions.rename("2", to: "  Bob ", in: &p)
        #expect(p.speakers?[1].name == "Bob")
        SpeakerCaptions.setColor("1", .red, in: &p)
        #expect(CaptionOps.text(SpeechCaptions.captions(in: p.timeline)[2])?.color == .red)
        #expect(CaptionOps.text(SpeechCaptions.captions(in: p.timeline)[1])?.color == SpeakerCaptions.defaultColor(1))
        // apply the look of one caption to its speaker only
        let ti = try #require(CaptionOps.captionTracks(p.timeline).first)
        var c0 = p.timeline.tracks[ti].clips[0]
        if case .text(var t) = c0.content { t.fontSize = 0.2; t.color = .blue; c0.content = .text(t) }
        p.timeline.tracks[ti].clips[0] = c0
        SpeakerCaptions.applyLookToSpeaker(from: c0.id, in: &p)
        let after = p.timeline.tracks[ti].clips
        #expect(CaptionOps.text(after[2])?.fontSize == 0.2 && CaptionOps.text(after[1])?.fontSize != 0.2)
        #expect(p.speakers?[0].color == .blue)
        #expect(CaptionOps.text(after[2])?.caption?.speaker == "1")
        SpeakerCaptions.clear(in: &p)
        #expect(p.speakers == nil && SpeakerCaptions.speakerIDs(in: p.timeline).isEmpty)
    }

    @Test func assignByMajorityVote() {
        var p = project([nil, nil, nil])
        let turns = [SpeakerTurn(start: 0, end: 1.95, speaker: 0), SpeakerTurn(start: 2.0, end: 3, speaker: 1)]
        SpeakerCaptions.assign(turns: turns, in: &p)
        let ids = SpeechCaptions.captions(in: p.timeline).map { CaptionOps.text($0)?.caption?.speaker }
        #expect(ids == ["1", "1", "2"])
        #expect(p.speakers?.count == 2)
        #expect(TimelineOps.validate(p.timeline).isEmpty)
    }

    @Test func oldFilesWithoutSpeakersDecode() throws {
        let p = Project(name: "x")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as! [String: Any]
        json["speakers"] = nil
        let q = try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(q.speakers == nil)
    }
}
