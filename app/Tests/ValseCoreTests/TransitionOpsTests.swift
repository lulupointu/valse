import Foundation
import Testing
@testable import ValseCore

/// W5: transition validation (TR-007), overlay-track (PiP) transitions (TR-004) and CapCut's transition model
/// (TR-MODEL-CAPCUT): nothing moves, the transition is centred on the cut, max = half of the shorter neighbour.
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

    static func isTransition(_ i: RenderItem) -> Bool { if case .transition = i { return true }; return false }

    @Test func mainTrackTransitionMovesNothing() throws {
        var (p, ids) = Fx.project(mainClips: 3, seconds: 4)
        let before = Fx.main(p).map(\.range), length = p.duration
        try TimelineOps.setTransition(ids[0], TransitionInstance(typeID: "x", duration: Time(1)), in: &p.timeline)
        try TimelineOps.setTransition(ids[1], TransitionInstance(typeID: "x", duration: Time(2)), in: &p.timeline)
        #expect(Fx.main(p).map(\.range) == before)
        #expect(p.duration == length)
        #expect(TimelineOps.validate(p.timeline).isEmpty)
        // window [cut − d/2, cut + d/2]
        let main = p.timeline.mainTrack!
        #expect(main.transitionWindow(after: 0) == TimeRange(start: Time(3.5), duration: Time(1)))
        #expect(main.transitionWindow(after: 1) == TimeRange(start: Time(7), duration: Time(2)))
        #expect(main.activeTransition(at: Time(3.4)) == nil)
        #expect(main.activeTransition(at: Time(3.5))?.a == 0)
        #expect(main.activeTransition(at: Time(4.49))?.a == 0)
        #expect(main.activeTransition(at: Time(4.5)) == nil)
        #expect(main.activeTransition(at: Time(8.9))?.a == 1)
        // removing it moves nothing either
        try TimelineOps.setTransition(ids[0], nil, in: &p.timeline)
        #expect(Fx.main(p).map(\.range) == before)
    }

    @Test func overlayTransitionMovesNothing() throws {
        var (p, tid, ids) = Self.overlay([(1, 3), (4, 3), (7, 2)])
        try TimelineOps.setTransition(ids[0], TransitionInstance(typeID: "x", duration: Time(1)), in: &p.timeline)
        let clips = p.timeline.tracks[p.timeline.trackIndex(tid)!].clips
        #expect(clips.map(\.start) == [Time(1), Time(4), Time(7)])
        #expect(TimelineOps.validate(p.timeline).isEmpty)
        // the window renders as a transition item, on both sides of the cut
        #expect(FrameEvaluator.evaluate(p, at: Time(3.6)).items.contains(where: Self.isTransition))
        #expect(FrameEvaluator.evaluate(p, at: Time(4.4)).items.contains(where: Self.isTransition))
        #expect(!FrameEvaluator.evaluate(p, at: Time(4.6)).items.contains(where: Self.isTransition))
        // longer duration: clamped to twice the shorter neighbour (3 s), still nothing moves
        try TimelineOps.setTransition(ids[0], TransitionInstance(typeID: "x", duration: Time(9)), in: &p.timeline)
        let c2 = p.timeline.tracks[p.timeline.trackIndex(tid)!].clips
        #expect(c2[0].transitionOut?.duration == Time(6))
        #expect(c2.map(\.start) == [Time(1), Time(4), Time(7)])
        try TimelineOps.setTransition(ids[0], nil, in: &p.timeline)
        #expect(p.timeline.tracks[p.timeline.trackIndex(tid)!].clips.map(\.start) == [Time(1), Time(4), Time(7)])
    }

    @Test func durationRulesMatchCapCut() throws {
        // 5 s | 5 s → 10 s; 1 s | 4 s → 2 s (twice the shorter neighbour, frame multiples); min 0.1 s
        var (p, ids) = Fx.project(mainClips: 2, seconds: 5)
        let fps = p.settings.frameRate
        #expect(TimelineOps.maxTransitionDuration(after: ids[0], in: p.timeline, frameRate: fps) == Time(10))
        _ = try TimelineOps.split(ids[0], at: Time(1), in: &p.timeline)
        let left = Fx.main(p)[0].id
        #expect(TimelineOps.maxTransitionDuration(after: left, in: p.timeline, frameRate: fps) == Time(2))
        #expect(TimelineOps.quantizedTransitionDuration(Time(0.01), after: left, in: p.timeline, frameRate: fps) == Time(0.1))
        #expect(TimelineOps.quantizedTransitionDuration(Time(9), after: left, in: p.timeline, frameRate: fps) == Time(2))
        let q = TimelineOps.quantizedTransitionDuration(Time(0.31), after: left, in: p.timeline, frameRate: fps)
        #expect(q.ticks % fps.frameDuration.ticks == 0)
    }

    @Test func splittingAClipClampsItsTransitions() throws {
        var (p, ids) = Fx.project(mainClips: 2, seconds: 4)
        try TimelineOps.setTransition(ids[0], TransitionInstance(typeID: "x", duration: Time(2)), in: &p.timeline)
        _ = try TimelineOps.split(ids[1], at: Time(4.5), in: &p.timeline)   // B → 0.5 s | 3.5 s: max = 1 s
        #expect(Fx.main(p)[0].transitionOut?.duration == Time(1))
        #expect(TimelineOps.validate(p.timeline).isEmpty)
    }

    @Test func transitionsAtBothEndsOfAClipNeverOverlap() throws {
        // 2 s clips: a lone transition may reach 4 s (covers the whole 2 s clip on its side). Set the first to 4 s:
        // the middle clip then has no room left for the second one, which is limited (d_in/2 + d_out/2 <= length).
        var (p, ids) = Fx.project(mainClips: 3, seconds: 2)
        let fps = p.settings.frameRate
        #expect(TimelineOps.maxTransitionDuration(after: ids[0], in: p.timeline, frameRate: fps) == Time(4))
        try TimelineOps.setTransition(ids[0], TransitionInstance(typeID: "x", duration: Time(9)), in: &p.timeline)
        #expect(Fx.main(p)[0].transitionOut?.duration == Time(4))
        #expect(TimelineOps.maxTransitionDuration(after: ids[1], in: p.timeline, frameRate: fps) == TimelineOps.minTransitionDuration)
        try TimelineOps.setTransition(ids[1], TransitionInstance(typeID: "x", duration: Time(9)), in: &p.timeline)
        let c = Fx.main(p)
        #expect(c[0].transitionOut?.duration == Time(3.9))   // only a hair of room is taken back (0.1 s minimum)
        #expect(c[1].transitionOut?.duration == TimelineOps.minTransitionDuration)
        // with the first at 2 s the second gets what is left: 2 * (2 - 1) = 2 s
        try TimelineOps.setTransition(ids[0], TransitionInstance(typeID: "x", duration: Time(2)), in: &p.timeline)
        #expect(TimelineOps.maxTransitionDuration(after: ids[1], in: p.timeline, frameRate: fps) == Time(2))
        for clip in Fx.main(p).dropFirst().dropLast() {
            let used = ((Fx.main(p)[0].transitionOut?.duration ?? .zero) + (clip.transitionOut?.duration ?? .zero)).seconds / 2
            #expect(used <= clip.duration.seconds + 0.0001)
        }
        #expect(TimelineOps.validate(p.timeline).isEmpty)
    }

    @Test func removingAMiddleClipKeepsTheTimelineValid() throws {
        var (p, ids) = Fx.project(mainClips: 3, seconds: 4)
        try TimelineOps.setTransition(ids[0], TransitionInstance(typeID: "x", duration: Time(1)), in: &p.timeline)
        try TimelineOps.setTransition(ids[1], TransitionInstance(typeID: "x", duration: Time(1)), in: &p.timeline)
        try TimelineOps.delete([ids[1]], in: &p.timeline)
        #expect(Fx.main(p).map(\.start) == [Time(0), Time(4)])
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
        // and a gap refuses the transition outright
        var g = p
        #expect(throws: EditError.self) {
            try TimelineOps.setTransition(ids[0], TransitionInstance(typeID: "x", duration: Time(0.5)), in: &g.timeline)
        }
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
        try TimelineOps.setTransition(ids[0], TransitionInstance(typeID: "valse.transition.cubeLeft", duration: Time(0.5),
                                                                  params: ["softness": .scalar(0.3)], isOverlap: false), in: &p.timeline)
        let back = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p))
        #expect(back.timeline == p.timeline)
        #expect(back.timeline.clip(ids[0])?.transitionOut?.overlaps == false)
    }

    // MARK: Frame mapping (FrameEvaluator)

    static func mediaTime(_ l: LayerDescription) -> Time? { if case .media(_, let s) = l.source { return s }; return nil }

    static func transition(_ p: Project, at t: Double) -> (from: LayerDescription, to: LayerDescription, progress: Double)? {
        for i in FrameEvaluator.evaluate(p, at: Time(t)).items {
            if case .transition(let a, let b, _, let pr, _) = i { return (a, b, pr) }
        }
        return nil
    }

    /// Two 4 s clips of 10 s media: A uses source 2…6 (handles both sides), B uses 0…4 (no head handle).
    static func handleProject(overlap: Bool = true, d: Double = 2) throws -> (Project, [ClipID]) {
        var (p, ids) = Fx.project(mainClips: 2, seconds: 4)
        let ti = p.timeline.mainTrackIndex!
        p.timeline.tracks[ti].clips[0].sourceStart = Time(2)
        try TimelineOps.setTransition(ids[0], TransitionInstance(typeID: "x", duration: Time(d), isOverlap: overlap ? nil : false),
                                      in: &p.timeline)
        return (p, ids)
    }

    @Test func overlapUsesHandlesThenFreezesTheEdgeFrame() throws {
        let (p, _) = try Self.handleProject()
        // window [3, 5], progress linear from 0 at 3 s
        let x = try #require(Self.transition(p, at: 3.5))
        #expect(abs(x.progress - 0.25) < 1e-9)
        // A plays normally inside its range; B (no head handle) holds its first frame before its in point
        #expect(Self.mediaTime(x.from) == Time(5.5))
        #expect(Self.mediaTime(x.to) == Time(0))
        // past the cut: A plays its tail handle (source 6…7), B plays normally
        let y = try #require(Self.transition(p, at: 4.5))
        #expect(Self.mediaTime(y.from) == Time(6.5))
        #expect(Self.mediaTime(y.to) == Time(0.5))
        #expect(abs(y.progress - 0.75) < 1e-9)
    }

    @Test func overlapFreezesTheLastFrameWithoutATailHandle() throws {
        var (p, ids) = Fx.project(mainClips: 2, seconds: 4)
        let ti = p.timeline.mainTrackIndex!
        p.timeline.tracks[ti].clips[0].sourceStart = Time(6)   // A = source 6…10: the media's end
        try TimelineOps.setTransition(ids[0], TransitionInstance(typeID: "x", duration: Time(2)), in: &p.timeline)
        let y = try #require(Self.transition(p, at: 4.9))
        let last = Time(10) - FrameRate.fps30.frameDuration
        #expect(Self.mediaTime(y.from) == last)
        #expect(TimelineOps.transitionNeedsDuplicateFrames(after: ids[0], in: p))
        // with handles on both sides: no notice
        p.timeline.tracks[ti].clips[0].sourceStart = Time(2)
        p.timeline.tracks[ti].clips[1].sourceStart = Time(2)
        #expect(!TimelineOps.transitionNeedsDuplicateFrames(after: ids[0], in: p))
    }

    @Test func nonOverlapShowsOneSidePerHalf() throws {
        let (p, ids) = try Self.handleProject(overlap: false)
        let a = try #require(Self.transition(p, at: 3.5))
        #expect(a.from.clipID == ids[0] && a.to.clipID == ids[0])
        let b = try #require(Self.transition(p, at: 4.5))
        #expect(b.from.clipID == ids[1] && b.to.clipID == ids[1])
        #expect(Self.mediaTime(b.from) == Time(0.5))
        // never needs duplicate frames
        #expect(!TimelineOps.transitionNeedsDuplicateFrames(after: ids[0], in: p))
    }
}
