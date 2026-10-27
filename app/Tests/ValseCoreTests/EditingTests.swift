import Testing
@testable import ValseCore

@Suite struct EditingTests {
    @Test func magnetPacksMainTrack() {
        let (p, ids) = Fx.project(mainClips: 3)
        let main = Fx.main(p)
        #expect(main.map(\.id) == ids)
        #expect(main.map(\.start) == [Time(0), Time(4), Time(8)])
        #expect(TimelineOps.validate(p.timeline).isEmpty)
    }

    @Test func insertAtCutPosition() throws {
        var (p, ids) = Fx.project(mainClips: 2)
        let a = Fx.video("x"); p.media.append(a)
        var c = TimelineOps.makeClip(for: a, at: Time(3.9)); c.duration = 2  // nearer the cut at 4
        try TimelineOps.insert(c, into: &p)
        #expect(Fx.main(p).map(\.id) == [ids[0], c.id, ids[1]])
        #expect(Fx.main(p)[2].start == Time(6))
    }

    @Test func splitKeepsSourceContinuity() throws {
        var (p, ids) = Fx.project(mainClips: 1, seconds: 6)
        p.timeline[clip: ids[0]]!.sourceStart = 1
        let right = try TimelineOps.split(ids[0], at: 2.5, in: &p.timeline)
        let l = p.timeline.clip(ids[0])!, r = p.timeline.clip(right)!
        #expect(l.duration == Time(2.5) && r.start == Time(2.5) && r.duration == Time(3.5))
        #expect(r.sourceStart == Time(3.5))
        #expect(l.sourceTime(at: l.end) == r.sourceTime(at: r.start))
        #expect(TimelineOps.validate(p.timeline).isEmpty)
        #expect(throws: EditError.invalidTime) { try TimelineOps.split(ids[0], at: 0.001, in: &p.timeline) }
    }

    @Test func splitWithSpeedAndKeyframes() throws {
        var (p, ids) = Fx.project(mainClips: 1, seconds: 4)
        try TimelineOps.setSpeed(ids[0], .constant(2), in: &p.timeline)
        #expect(p.timeline.clip(ids[0])!.duration == Time(2))
        p.timeline[clip: ids[0]]!.keyframes[ParamKey.opacity.raw] =
            KeyframeTrack([Keyframe(time: 0, value: .scalar(0)), Keyframe(time: 2, value: .scalar(1))])
        let r = try TimelineOps.split(ids[0], at: 1, in: &p.timeline)
        let right = p.timeline.clip(r)!
        #expect(right.sourceStart == Time(2))
        #expect(right.resolved(at: 0).opacity == 0.5)
        #expect(right.resolved(at: 1).opacity == 1)
    }

    @Test func trimHeadAndTailRespectMedia() throws {
        var (p, ids) = Fx.project(mainClips: 2, seconds: 4)
        // tail: media is 10 s → can extend to 10 s
        try TimelineOps.trim(ids[0], edge: .tail, to: 20, in: &p)
        #expect(p.timeline.clip(ids[0])!.duration == Time(10))
        #expect(p.timeline.clip(ids[1])!.start == Time(10))  // rippled by magnet
        // head: trimming in moves sourceStart; magnet keeps the clip at 0
        try TimelineOps.trim(ids[0], edge: .head, to: 3, in: &p)
        let c = p.timeline.clip(ids[0])!
        #expect(c.start == .zero && c.sourceStart == Time(3) && c.duration == Time(7))
        // head can't reveal media before 0
        try TimelineOps.trim(ids[0], edge: .head, to: -100, in: &p)
        #expect(p.timeline.clip(ids[0])!.sourceStart == .zero)
        #expect(TimelineOps.validate(p.timeline).isEmpty)
    }

    @Test func deleteRipplesMainAndKeepsLinkedClipsAttached() throws {
        var (p, ids) = Fx.project(mainClips: 3)
        var text = Clip(content: .text(TextContent(string: "Hi")), start: 9, duration: 2)
        text.name = "t"
        try TimelineOps.insert(text, into: &p)
        #expect(p.timeline.clip(text.id)!.linkedTo == ids[2])
        try TimelineOps.delete([ids[0]], in: &p.timeline)
        #expect(Fx.main(p).map(\.start) == [Time(0), Time(4)])
        #expect(p.timeline.clip(text.id)!.start == Time(5))  // followed its main clip
        #expect(TimelineOps.validate(p.timeline).isEmpty)
    }

    @Test func overlappingOverlayGoesToNewTrack() throws {
        var (p, _) = Fx.project(mainClips: 2)
        let a = Fx.video("o"); p.media.append(a)
        var o1 = TimelineOps.makeClip(for: a, at: 1); o1.duration = 3
        let t1 = try TimelineOps.insert(o1, into: &p, target: .newTrack)
        var o2 = TimelineOps.makeClip(for: a, at: 2); o2.duration = 3
        let t2 = try TimelineOps.insert(o2, into: &p, target: .track(t1))
        #expect(t1 != t2)
        #expect(p.timeline.tracks.count == 3)
        // moving o2 so it no longer overlaps lands on t1 and the empty track is removed
        try TimelineOps.move(o2.id, to: 5, track: t1, in: &p.timeline)
        #expect(p.timeline.tracks.count == 2)
        #expect(TimelineOps.validate(p.timeline).isEmpty)
    }

    @Test func moveReordersMainTrack() throws {
        var (p, ids) = Fx.project(mainClips: 3)
        try TimelineOps.move(ids[0], to: 9, in: &p.timeline)
        #expect(Fx.main(p).map(\.id) == [ids[1], ids[2], ids[0]])
        #expect(TimelineOps.validate(p.timeline).isEmpty)
    }

    @Test func transitionsOverlapNeighbours() throws {
        var (p, ids) = Fx.project(mainClips: 2)
        try TimelineOps.setTransition(ids[0], TransitionInstance(typeID: "x", duration: 1), in: &p.timeline)
        #expect(p.timeline.clip(ids[1])!.start == Time(3))
        let f = FrameEvaluator.evaluate(p, at: 3.5)
        guard case .transition(_, _, _, let progress, _) = f.items.first else { Issue.record("no transition"); return }
        #expect(abs(progress - 0.5) < 1e-9)
        // clamped to half the shorter neighbour
        try TimelineOps.setTransition(ids[0], TransitionInstance(typeID: "x", duration: 10), in: &p.timeline)
        #expect(p.timeline.clip(ids[0])!.transitionOut!.duration == Time(2))
        #expect(TimelineOps.validate(p.timeline).isEmpty)
    }

    @Test func magnetOffAllowsGaps() throws {
        var (p, ids) = Fx.project(mainClips: 2)
        p.timeline.mainTrackMagnet = false
        try TimelineOps.move(ids[1], to: 10, in: &p.timeline)
        #expect(p.timeline.clip(ids[1])!.start == Time(10))
    }
}

@Suite struct HistoryTests {
    @Test func undoRedoRestoresSnapshots() throws {
        let (p, ids) = Fx.project(mainClips: 2)
        var s = EditSession(project: p)
        try s.perform(SplitClips([ids[0]], at: 1))
        #expect(Fx.main(s.project).count == 3)
        try s.perform(DeleteClips([ids[1]]))
        #expect(Fx.main(s.project).count == 2)
        #expect(s.undo() == "cmd.delete")
        #expect(Fx.main(s.project).count == 3)
        #expect(s.undo() == "cmd.split")
        #expect(s.project.timeline == p.timeline)
        #expect(s.redo() == "cmd.split")
        #expect(Fx.main(s.project).count == 3)
        #expect(s.canRedo)
        try s.perform(UpdateClip(ids[0]) { $0.opacity = 0.5 })
        #expect(!s.canRedo)
    }

    @Test func failedCommandLeavesNoTrace() {
        let (p, _) = Fx.project(mainClips: 1)
        var s = EditSession(project: p)
        #expect(throws: EditError.self) { try s.perform(DeleteClips([ClipID()])) }
        #expect(!s.canUndo && s.project == p)
    }

    @Test func gestureCoalescesIntoOneStep() {
        let (p, ids) = Fx.project(mainClips: 1)
        var s = EditSession(project: p)
        s.beginGesture("cmd.opacity")
        for v in [0.9, 0.7, 0.5, 0.2] {
            s.updateGesture { $0.timeline[clip: ids[0]]!.opacity = v }
        }
        s.endGesture()
        #expect(s.undoStack.count == 1)
        #expect(abs(s.project.timeline.clip(ids[0])!.opacity - 0.2) < 1e-9)
        s.undo()
        #expect(s.project.timeline.clip(ids[0])!.opacity == 1)
    }

    @Test func dirtyTracking() throws {
        let (p, ids) = Fx.project(mainClips: 1)
        var s = EditSession(project: p)
        #expect(!s.isDirty)
        try s.perform(UpdateClip(ids[0]) { $0.opacity = 0.3 })
        #expect(s.isDirty)
        s.markSaved()
        #expect(!s.isDirty)
    }
}
