import Foundation
import Testing
@testable import MontageCore

/// W5: transition validation (TR-007) and overlay-track (PiP) transitions (TR-004).
@Suite struct TransitionOpsTests {
    /// Main track with one clip + an overlay video track holding `clips` (start, duration) pairs.
    static func overlay(_ clips: [(Double, Double)]) -> (Project, TrackID, [ClipID]) {
        var (p, _) = Fx.project(mainClips: 1, seconds: 20)
        let a = Fx.video("o")
        p.media.append(a)
        let tid = TimelineOps.addTrack(.video, to: &p.timeline)
        var ids: [ClipID] = []
        for (s, d) in clips {
            var c = TimelineOps.makeClip(for: a, at: Time(s))
            c.duration = Time(d)
            try! TimelineOps.insert(c, into: &p, target: .track(tid))
            ids.append(c.id)
        }
        return (p, tid, ids)
    }

    @Test func overlayTransitionOverlapsTheRightClip() throws {
        var (p, tid, ids) = Self.overlay([(1, 3), (4, 3), (7, 2)])
        try TimelineOps.setTransition(ids[0], TransitionInstance(typeID: "x", duration: Time(1)), in: &p.timeline)
        let clips = p.timeline.tracks[p.timeline.trackIndex(tid)!].clips
        #expect(clips[1].start == Time(3))      // slid left by the duration
        #expect(clips[2].start == Time(7))      // followers stay
        #expect(clips[0].end == Time(4))
        #expect(TimelineOps.validate(p.timeline).isEmpty)
        // the overlap renders as a transition item
        let f = FrameEvaluator.evaluate(p, at: Time(3.5))
        #expect(f.items.contains { if case .transition = $0 { return true }; return false })
        // longer duration: clamped to half the shorter neighbour
        try TimelineOps.setTransition(ids[0], TransitionInstance(typeID: "x", duration: Time(5)), in: &p.timeline)
        let c2 = p.timeline.tracks[p.timeline.trackIndex(tid)!].clips
        #expect(c2[0].transitionOut?.duration == Time(1.5))
        #expect(c2[1].start == Time(2.5))
        #expect(TimelineOps.validate(p.timeline).isEmpty)
        // removing slides it back
        try TimelineOps.setTransition(ids[0], nil, in: &p.timeline)
        let c3 = p.timeline.tracks[p.timeline.trackIndex(tid)!].clips
        #expect(c3[1].start == Time(4))
        #expect(TimelineOps.validate(p.timeline).isEmpty)
    }

    @Test func removingPushesContiguousFollowers() throws {
        var (p, tid, ids) = Self.overlay([(0, 2), (2, 2)])
        try TimelineOps.setTransition(ids[0], TransitionInstance(typeID: "x", duration: Time(0.5)), in: &p.timeline)
        // fill the freed space right after the second clip
        var c = TimelineOps.makeClip(for: p.media.last!, at: Time(3.5)); c.duration = Time(1)
        try TimelineOps.insert(c, into: &p, target: .track(tid))
        try TimelineOps.setTransition(ids[0], nil, in: &p.timeline)
        let clips = p.timeline.tracks[p.timeline.trackIndex(tid)!].clips
        #expect(clips.map(\.start) == [Time(0), Time(2), Time(4)])
        #expect(TimelineOps.validate(p.timeline).isEmpty)
    }

    @Test func validationRefusesGapsLastClipsAndShortClips() {
        let (p, _, ids) = Self.overlay([(0, 2), (3, 2), (5, 0.1), (5.1, 2)])
        #expect(TimelineOps.transitionIssue(after: ids[0], in: p.timeline) == .noContinuousClips)   // 1 s gap
        #expect(TimelineOps.transitionIssue(after: ids[1], in: p.timeline) == .clipTooShort)        // next is 0.1 s
        #expect(TimelineOps.transitionIssue(after: ids[3], in: p.timeline) == .noContinuousClips)   // last clip
        let (m, mids) = Fx.project(mainClips: 2)
        #expect(TimelineOps.transitionIssue(after: mids[0], in: m.timeline) == nil)
        // a text track never takes transitions
        var t = m
        let tc = Clip(content: .text(TextContent(string: "a")), start: 0, duration: 2)
        let tc2 = Clip(content: .text(TextContent(string: "b")), start: 2, duration: 2)
        try! TimelineOps.insert(tc, into: &t, target: .newTrack)
        let ttrack = t.timeline.tracks.first { $0.kind == .text }!.id
        try! TimelineOps.insert(tc2, into: &t, target: .track(ttrack))
        #expect(TimelineOps.transitionIssue(after: tc.id, in: t.timeline) == .noContinuousClips)
    }

    @Test func transitionCutFindsTheNearestContinuousCut() {
        let (p, tid, ids) = Self.overlay([(0, 2), (2, 2), (5, 2)])
        #expect(TimelineOps.transitionCut(near: Time(2.1), track: tid, in: p.timeline, within: Time(0.5))?.id == ids[0])
        #expect(TimelineOps.transitionCut(near: Time(4.4), track: tid, in: p.timeline, within: Time(0.5)) == nil)   // gap 4…5
    }

    @Test func movingTheRightClipAwayDropsTheTransition() throws {
        var (p, tid, ids) = Self.overlay([(0, 2), (2, 2)])
        try TimelineOps.setTransition(ids[0], TransitionInstance(typeID: "x", duration: Time(0.5)), in: &p.timeline)
        let ti = p.timeline.trackIndex(tid)!
        p.timeline.tracks[ti].clips[1].start = Time(6)
        TimelineOps.clampTransitions(&p.timeline.tracks[ti])
        #expect(p.timeline.tracks[ti].clips[0].transitionOut == nil)
        #expect(TimelineOps.validate(p.timeline).isEmpty)
    }

    @Test func overlayTransitionsSurvivePersistence() throws {
        var (p, _, ids) = Self.overlay([(0, 2), (2, 2)])
        try TimelineOps.setTransition(ids[0], TransitionInstance(typeID: "montage.transition.cubeLeft", duration: Time(0.5),
                                                                  params: ["softness": .scalar(0.3)]), in: &p.timeline)
        let back = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p))
        #expect(back.timeline == p.timeline)
    }
}
