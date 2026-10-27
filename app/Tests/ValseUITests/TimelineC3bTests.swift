import Testing
import Foundation
import CoreGraphics
import AppKit
import ValseCore
@testable import ValseUI

/// C3b: moving existing clips with a placeholder (lift → plan → relocate), keyframed volume line grabs, flicker-free
/// Metal resizing.
@MainActor @Suite(.serialized) struct TimelineC3bTests {
    func project() throws -> Project { try TimelineMediaC3Tests().project() }   // main 0–4 / 4–8 / 8–12, overlay 1–3

    func layout(_ tl: Timeline) -> TimelineLayout {
        TimelineLayout(timeline: tl, pixelsPerSecond: 50, scrollTime: 0, scrollY: 0, viewSize: CGSize(width: 1200, height: 400))
    }

    /// What a move gesture does: lift, plan against the lifted timeline with the (unchanged) model layout, relocate.
    func move(_ id: ClipID, in p: inout Project, to pt: CGPoint, start: Time) throws -> TimelineDropPlan {
        let l = layout(p.timeline)
        let (lifted, clip) = try TimelineOps.liftForMove(id, from: p.timeline)
        let kind = p.timeline.tracks[p.timeline.locate(id)!.track].kind
        let home = l.rows.firstIndex { $0.trackIndex == p.timeline.locate(id)!.track }
        let plan = TimelineDropPlan.plan(layout: l, timeline: lifted, point: pt, time: start, duration: clip.duration, kind: kind,
                                         mainProbe: start + clip.duration / 2.0, home: home)
        try TimelineOps.relocate(id, to: plan.start, target: plan.target, in: &p)
        #expect(TimelineOps.validate(p.timeline).isEmpty)
        return plan
    }

    @Test func liftKeepsEveryLaneSoRowsDontMoveUnderThePointer() throws {
        let p = try project()
        let ov = p.timeline.tracks.first { !$0.isMain }!.clips[0].id
        let (lifted, _) = try TimelineOps.liftForMove(ov, from: p.timeline)
        // the overlay lane is empty now but still there: same rows as the model while dragging (no flicker)
        #expect(lifted.tracks.count == p.timeline.tracks.count)
        #expect(layout(lifted).rows.map(\.y) == layout(p.timeline).rows.map(\.y))
        let main0 = p.timeline.mainTrack!.clips[0].id
        let (l2, _) = try TimelineOps.liftForMove(main0, from: p.timeline)
        #expect(l2.mainTrack!.clips.map(\.start) == [Time(0), Time(4)])   // re-packed
    }

    @Test func mainClipMovesToTheBoundaryItWasPreviewedAt() throws {
        var p = try project()
        let ids = p.timeline.mainTrack!.clips.map(\.id)
        let l = layout(p.timeline)
        let y = l.rows[l.mainRowIndex!].y + 30
        // drag clip 0 so its centre is past the middle of clip 2 (lifted main: 1 at 0–4, 2 at 4–8)
        let plan = try move(ids[0], in: &p, to: CGPoint(x: l.x(Time(7)), y: y), start: Time(5))
        #expect(plan.placement == .main(index: 2) && plan.start == Time(8))
        #expect(p.timeline.mainTrack!.clips.map(\.id) == [ids[1], ids[2], ids[0]])
        #expect(p.timeline.mainTrack!.clips.map(\.start) == [Time(0), Time(4), Time(8)])
    }

    @Test func overlayClipToANewLaneAboveMainAndBackToMain() throws {
        var p = try project()
        let ovTrack = p.timeline.tracks.first { !$0.isMain }!
        let ov = ovTrack.clips[0].id
        let l = layout(p.timeline)
        let mi = l.mainRowIndex!
        // onto the main track at 2 s → ripple insert at 4 s (centre 3 s is past clip 0's middle); the empty lane goes
        let plan = try move(ov, in: &p, to: CGPoint(x: l.x(Time(3)), y: l.rows[mi].y + 30), start: Time(2))
        #expect(plan.placement == .main(index: 1))
        #expect(p.timeline.mainTrack!.clips[1].id == ov)
        #expect(p.timeline.tracks.count == 1)
        // back above main at the lane boundary: a new lane right above the main track
        let l2 = layout(p.timeline)
        let b = l2.rows[l2.mainRowIndex!].y - 2
        let plan2 = try move(ov, in: &p, to: CGPoint(x: l2.x(Time(1)), y: b), start: Time(1))
        #expect(plan2.placement == .newLane(slot: l2.mainRowIndex!))
        #expect(p.timeline.tracks.count == 2 && p.timeline.mainTrack!.clips.count == 3)
        #expect(p.timeline.clip(ov)?.start == Time(1))
    }

    @Test func textClipStaysOnTextLanes() throws {
        var p = try project()
        let t = Clip(content: .text(TextContent(string: "t")), start: 1, duration: 2)
        try TimelineOps.insert(t, into: &p)
        let l = layout(p.timeline)
        // over the main track: text can't go there → stays on its own lane at the new time
        _ = try move(t.id, in: &p, to: CGPoint(x: l.x(Time(6)), y: l.rows[l.mainRowIndex!].y + 30), start: Time(6))
        #expect(p.timeline.mainTrack!.clips.count == 3)
        #expect(p.timeline.clip(t.id)?.start == Time(6))
        #expect(p.timeline.tracks.first { $0.clips.contains { $0.id == t.id } }?.kind == .text)
    }

    @Test func storeMoveIsOneUndoStep() throws {
        let p = try project()
        let s = EditorStore(project: p)
        s.autosaveEnabled = false
        let ids = s.project.timeline.mainTrack!.clips.map(\.id)
        let depth = s.session.undoStack.count
        let plan = TimelineDropPlan(placement: .main(index: 2), start: Time(8), duration: Time(4), target: .automatic)
        let v = TimelineView(store: s)
        v.commitMove(ids[0], plan)
        #expect(s.session.undoStack.count == depth + 1 && s.session.undoNameKey == "cmd.move")
        #expect(s.project.timeline.mainTrack!.clips.last?.id == ids[0])
        // dropping where it already is: no undo step
        v.commitMove(ids[0], TimelineDropPlan(placement: .main(index: 2), start: Time(8), duration: Time(4), target: .automatic))
        #expect(s.session.undoStack.count == depth + 1)
        s.undo()
        #expect(s.project.timeline.mainTrack!.clips.map(\.id) == ids)
    }

    // MARK: Keyframed volume line

    func keyed(_ gains: [(Double, Double)]) -> Clip {
        var c = Clip(content: .solid(RGBA(1, 0, 0)), start: 0, duration: 10)
        c.keyframes[ParamKey.volume.raw] = KeyframeTrack(gains.map { Keyframe(time: Time($0.0), value: .scalar($0.1)) })
        return c
    }
    /// AU-VOL-PCT: keyframe values in whole percents.
    func pcts(_ c: Clip) -> [Int] {
        c.keyframes[ParamKey.volume.raw]!.keyframes.map { VolumePercent.percent($0.value.component(0)!) }
    }

    @Test func grabPicksKeyframeOrSegment() {
        let c = keyed([(2, 1), (5, 0.5), (8, 1)])
        let tol = Time(0.1)
        #expect(ClipVolumeLine.grab(Clip(content: .solid(.white), start: 0, duration: 4), at: 1, tolerance: tol) == .whole)
        #expect(ClipVolumeLine.grab(c, at: Time(5.05), tolerance: tol) == .keyframe(1))
        #expect(ClipVolumeLine.grab(c, at: Time(3), tolerance: tol) == .segment(lo: 0, hi: 1))
        #expect(ClipVolumeLine.grab(c, at: Time(1), tolerance: tol) == .segment(lo: nil, hi: 0))
        #expect(ClipVolumeLine.grab(c, at: Time(9), tolerance: tol) == .segment(lo: 2, hi: nil))
    }

    @Test func draggingAKeyframeChangesOnlyIt() {
        let o = keyed([(2, 1), (5, 1), (8, 1)])
        var c = o
        // 4 pt down on a 40 pt area: 100 % (3/4 of the area) → 0.65 → 75 %
        ClipVolumeLine.apply(grab: .keyframe(1), dy: 4, areaHeight: 40, origin: o, to: &c)
        #expect(pcts(c) == [100, 75, 100])
        #expect(c.audio.volume == o.audio.volume)
    }

    @Test func draggingASegmentMovesBothEnds() {
        let o = keyed([(2, 1), (5, 1), (8, 1)])
        var c = o
        ClipVolumeLine.apply(grab: .segment(lo: 1, hi: 2), dy: 4, areaHeight: 40, origin: o, to: &c)
        #expect(pcts(c) == [100, 75, 75])
    }

    @Test func draggingBeforeTheFirstKeyframeChangesTheStart() {
        let o = keyed([(2, 1), (5, 1)])
        var c = o
        ClipVolumeLine.apply(grab: .segment(lo: nil, hi: 0), dy: 4, areaHeight: 40, origin: o, to: &c)
        #expect(pcts(c) == [75, 100])
        // everything from the clip start up to that keyframe is at 75 % (held before the first keyframe)
        #expect(abs(ClipVolumeLine.gain(of: c, at: Time(0.5)) - 0.75) < 1e-9)
        #expect(abs(ClipVolumeLine.gain(of: c, at: Time(2)) - 0.75) < 1e-9)
    }

    @Test func draggingAfterTheLastKeyframeChangesTheEnd() {
        let o = keyed([(2, 1), (5, 1)])
        var c = o
        ClipVolumeLine.apply(grab: .segment(lo: 1, hi: nil), dy: -2, areaHeight: 40, origin: o, to: &c)
        // 2 pt up from 100 %: 0.80 of the area = 2^0.4 ≈ 132 %
        #expect(pcts(c) == [100, 132])
        #expect(abs(ClipVolumeLine.gain(of: c, at: Time(9)) - 1.32) < 1e-9)
    }

    @Test func noKeyframesDragsTheWholeClip() {
        var o = Clip(content: .solid(.white), start: 0, duration: 4)
        o.audio.volume = 1
        var c = o
        ClipVolumeLine.apply(grab: .whole, dy: 3.75, areaHeight: 40, origin: o, to: &c)
        #expect(abs(c.audio.volume - 0.77) < 1e-9)   // 0.65625 of the area
    }

    @Test func keyframeDragIsOneUndoStep() throws {
        var p = try project()
        let id = p.timeline.mainTrack!.clips[0].id
        p.timeline[clip: id]!.keyframes[ParamKey.volume.raw] = KeyframeTrack([Keyframe(time: 1, value: .scalar(1)), Keyframe(time: 3, value: .scalar(1))])
        let s = EditorStore(project: p)
        s.autosaveEnabled = false
        let origin = s.project.timeline.clip(id)!
        let depth = s.session.undoStack.count
        s.beginGesture("cmd.volume")
        for dy in [1.0, 2.0, 4.0] {
            s.updateGesture { p in
                guard var c = p.timeline.clip(id) else { return }
                ClipVolumeLine.apply(grab: .keyframe(0), dy: CGFloat(dy), areaHeight: 40, origin: origin, to: &c)
                p.timeline[clip: id] = c
            }
        }
        s.endGesture()
        #expect(s.session.undoStack.count == depth + 1)
        #expect(pcts(s.project.timeline.clip(id)!) == [75, 100])
        s.undo()
        #expect(pcts(s.project.timeline.clip(id)!) == [100, 100])
    }

    // MARK: Flicker-free resize

    @Test func resizePresentsInTheLayoutTransaction() async throws {
        let s = EditorStore(project: try project())
        s.autosaveEnabled = false
        let w = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 900, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        let v = TimelineView(store: s)
        v.frame = CGRect(x: 0, y: 0, width: 900, height: 300)
        w.contentView?.addSubview(v)
        v.layoutSubtreeIfNeeded()
        let before = MetalResize.presentedInTransaction
        for wd in [700.0, 650, 820] {
            v.setFrameSize(CGSize(width: wd, height: 300))
            v.layoutSubtreeIfNeeded()
        }
        // every geometry change drew its frame synchronously (no stretched / blank frame until the next tick)
        #expect(MetalResize.presentedInTransaction - before == 3)
        #expect(v.metalLayer.presentsWithTransaction == false)
        v.removeFromSuperview()
    }
}
