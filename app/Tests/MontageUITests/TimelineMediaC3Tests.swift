import Testing
import Foundation
import CoreGraphics
import MontageCore
@testable import MontageUI

/// C3: media drag placeholder (drop plan = what the drop does), clip volume line, tooltip delay, media thumbnails.
@MainActor @Suite(.serialized) struct TimelineMediaC3Tests {
    static func asset(_ name: String, seconds: Double = 4, kind: MediaKind = .video) -> MediaAsset {
        TimelineUITests.asset(name, seconds: seconds, kind: kind)
    }

    /// Main track 0–4, 4–8, 8–12; one overlay video lane with a clip at 1–3.
    func project() throws -> Project {
        var p = Project()
        for i in 0..<3 {
            let a = Self.asset("m\(i)")
            p.media.append(a)
            try TimelineOps.insert(TimelineOps.makeClip(for: a, at: Time(1000)), into: &p)
        }
        let o = Self.asset("ov")
        p.media.append(o)
        try TimelineOps.insert(TimelineOps.makeClip(for: o, at: Time(1)), into: &p, target: .newTrack)
        return p
    }

    func layout(_ tl: Timeline) -> TimelineLayout {
        TimelineLayout(timeline: tl, pixelsPerSecond: 50, scrollTime: 0, scrollY: 0, viewSize: CGSize(width: 1200, height: 400))
    }

    func plan(_ p: Project, _ pt: CGPoint, kind: TrackKind = .video, duration: Double = 2) -> TimelineDropPlan {
        let l = layout(p.timeline)
        return TimelineDropPlan.plan(layout: l, timeline: p.timeline, point: pt, time: l.time(atX: pt.x), duration: Time(duration), kind: kind)
    }

    /// Commits a plan the way the drop does.
    func commit(_ plan: TimelineDropPlan, _ p: inout Project, kind: MediaKind = .video) throws -> Clip {
        let a = Self.asset("drop", seconds: plan.duration.seconds, kind: kind)
        p.media.append(a)
        let c = TimelineOps.makeClip(for: a, at: plan.start)
        try TimelineOps.insert(c, into: &p, target: plan.target)
        return p.timeline.clip(c.id)!
    }

    @Test func mainTrackRipplesAtTheNearestBoundary() throws {
        var p = try project()
        let l = layout(p.timeline)
        let main = l.rows[l.mainRowIndex!]
        // pointer at 5.5 s: past the middle of clip 0 (2 s), before the middle of clip 1 (6 s) → boundary 4 s, index 1
        let pl = plan(p, CGPoint(x: l.x(Time(5.5)), y: main.y + 30))
        #expect(pl.placement == .main(index: 1))
        #expect(pl.start == Time(4))
        #expect(pl.target == .automatic)
        #expect(pl.rippleIndex == 1)
        let c = try commit(pl, &p)
        let clips = p.timeline.mainTrack!.clips
        #expect(clips[1].id == c.id && c.start == Time(4))
        #expect(clips[2].start == Time(6))   // pushed right by the placeholder's 2 s, as previewed
        // past the end → appended
        let end = plan(try project(), CGPoint(x: l.x(Time(30)), y: main.y + 30))
        #expect(end.placement == .main(index: 3) && end.start == Time(12))
    }

    @Test func overlayLaneFitsOrGetsANewLane() throws {
        var p = try project()
        let l = layout(p.timeline)
        let ovRow = l.rows.firstIndex { !$0.isMain }!
        let y = l.rows[ovRow].y + l.rows[ovRow].height / 2
        // free spot on the overlay lane
        let free = plan(p, CGPoint(x: l.x(Time(5)), y: y))
        #expect(free.placement == .lane(row: ovRow))
        #expect(free.target == .track(l.rows[ovRow].trackID))
        // overlapping the overlay clip (1–3) → new lane above it
        let busy = plan(p, CGPoint(x: l.x(Time(2)), y: y))
        #expect(busy.placement == .newLane(slot: ovRow))
        let tracksBefore = p.timeline.tracks.count
        _ = try commit(busy, &p)
        #expect(p.timeline.tracks.count == tracksBefore + 1)
    }

    @Test func boundaryAboveMainCreatesTheLaneRightThere() throws {
        var p = try project()
        let l = layout(p.timeline)
        let mi = l.mainRowIndex!
        let boundary = (l.rows[mi - 1].maxY + l.rows[mi].y) / 2
        let pl = plan(p, CGPoint(x: l.x(Time(2)), y: boundary))
        #expect(pl.placement == .newLane(slot: mi))
        #expect(pl.target == .newTrackAbove(p.timeline.mainTrack!.id))
        let c = try commit(pl, &p)
        // the new lane is displayed directly above main (below the existing overlay)
        let l2 = layout(p.timeline)
        let mi2 = l2.mainRowIndex!
        #expect(p.timeline.tracks[l2.rows[mi2 - 1].trackIndex].clips.contains { $0.id == c.id })
        #expect(c.start == Time(2))
        // above every lane → new top lane
        let top = plan(try project(), CGPoint(x: l.x(Time(2)), y: TimelineLayout.rulerHeight + 4))
        #expect(top.placement == .newLane(slot: 0))
    }

    @Test func audioGoesToAnAudioLane() throws {
        var p = try project()
        let l = layout(p.timeline)
        let main = l.rows[l.mainRowIndex!]
        let first = plan(p, CGPoint(x: l.x(Time(1)), y: main.y + 30), kind: .audio)
        #expect(first.placement == .newLane(slot: l.rows.count) && first.target == .newTrack)
        let c = try commit(first, &p, kind: .audio)
        let l2 = layout(p.timeline)
        let audioRow = l2.rows.firstIndex { $0.kind == .audio }!
        #expect(p.timeline.tracks[l2.rows[audioRow].trackIndex].clips.first?.id == c.id)
        // a free spot later on that lane: reuses it
        let again = TimelineDropPlan.plan(layout: l2, timeline: p.timeline, point: CGPoint(x: l2.x(Time(6)), y: l2.rows[audioRow].y + 25),
                                          time: Time(6), duration: Time(2), kind: .audio)
        #expect(again.placement == .lane(row: audioRow))
    }

    @Test func magnetOffPlacesAtThePointer() throws {
        var p = try project()
        p.timeline.mainTrackMagnet = false
        let l = layout(p.timeline)
        let main = l.rows[l.mainRowIndex!]
        let pl = plan(p, CGPoint(x: l.x(Time(5.5)), y: main.y + 30))
        #expect(pl.placement == .lane(row: l.mainRowIndex!) && pl.start == l.time(atX: l.x(Time(5.5))))
    }

    @Test func multipleMediaOnANewLaneShareIt() throws {
        var p = try project()
        let a = Self.asset("x1"), b = Self.asset("x2")
        p.media += [a, b]
        let s = EditorStore(project: p)
        s.autosaveEnabled = false
        let before = s.project.timeline.tracks.count
        s.addMediaToTimeline([a.id, b.id], at: Time(2), target: .newTrackAbove(s.project.timeline.mainTrack!.id))
        #expect(s.project.timeline.tracks.count == before + 1)
        #expect(s.selection.count == 2)
        let payload = DragPayload.mediaList([a.id, b.id])
        #expect(s.dropPreviewKind(payload) == .video)
        #expect(s.dropPreviewDuration(payload) == Time(8))
        #expect(s.dropPreviewTitle(payload) == "x1 +1")
    }

    // MARK: Volume line

    @Test func volumeLineMapsDecibels() {
        #expect(ClipVolumeLine.fraction(gain: 1) == 0.75)
        #expect(ClipVolumeLine.fraction(gain: 0) == 0)
        #expect(ClipVolumeLine.fraction(gain: 100) == 1)
        let area = CGRect(x: 0, y: 100, width: 50, height: 40)
        #expect(ClipVolumeLine.y(gain: 1, in: area) == 110)
        // 8 pt up on a 40 pt area = +16 dB, clamped at +20; down = quieter; sticks to 0 dB
        #expect(ClipVolumeLine.draggedDB(from: 0, dy: -8, areaHeight: 40) == 16)
        #expect(ClipVolumeLine.draggedDB(from: 0, dy: -40, areaHeight: 40) == 20)
        #expect(ClipVolumeLine.draggedDB(from: 0, dy: 3.75, areaHeight: 40) == -7.5)
        #expect(ClipVolumeLine.draggedDB(from: -0.3, dy: 0.05, areaHeight: 40) == 0)
        #expect(ClipVolumeLine.draggedDB(from: -.infinity, dy: 1000, areaHeight: 40) == -60)
        #expect(ClipVolumeLine.gain(db: -60) == 0)
        #expect(abs(ClipVolumeLine.gain(db: -6) - 0.501) < 0.001)
        #expect(AudioBasicSection.dbFormat(-7.5).contains("7.5") || AudioBasicSection.dbFormat(-7.5).contains("7,5"))
    }

    @Test func volumeDragOffsetsKeyframes() {
        var c = Clip(content: .solid(RGBA(1, 0, 0)), start: 0, duration: 4)
        c.audio.volume = 1
        c.keyframes[ParamKey.volume.raw] = KeyframeTrack([Keyframe(time: 0, value: .scalar(1)), Keyframe(time: 2, value: .scalar(0.5))])
        let origin = c
        ClipVolumeLine.apply(db: -6, origin: origin, to: &c)
        #expect(abs(c.audio.volume - 0.501) < 0.001)
        let k = c.keyframes[ParamKey.volume.raw]!.keyframes
        #expect(abs((k[0].value.component(0) ?? 0) - 0.501) < 0.001)
        #expect(abs(AudioProps.decibels(k[1].value.component(0) ?? 0) - (AudioProps.decibels(0.5) - 6)) < 0.01)
        #expect(abs(ClipVolumeLine.gain(of: c, at: Time(2)) - (k[1].value.component(0) ?? 0)) < 1e-9)
    }

    /// The store gesture the timeline runs: live updates, one undo step named "cmd.volume", the inspector value follows.
    @Test func volumeGestureIsOneUndoStep() throws {
        let p = try project()
        let s = EditorStore(project: p)
        s.autosaveEnabled = false
        let id = s.project.timeline.mainTrack!.clips[0].id
        let origin = s.project.timeline.clip(id)!
        let depth = s.session.undoStack.count
        s.beginGesture("cmd.volume")
        for db in [-2.0, -5.0, -7.5] {
            s.updateGesture { p in
                guard var c = p.timeline.clip(id) else { return }
                ClipVolumeLine.apply(db: db, origin: origin, to: &c)
                p.timeline[clip: id] = c
            }
        }
        s.endGesture()
        #expect(abs(AudioProps.decibels(s.project.timeline.clip(id)!.audio.volume) + 7.5) < 0.01)
        #expect(s.session.undoStack.count == depth + 1)
        s.undo()
        #expect(s.project.timeline.clip(id)!.audio.volume == 1)
    }

    // MARK: Tooltips / thumbnails

    @Test func tooltipDelayIsShort() throws {
        let d = try #require(UserDefaults(suiteName: "montage.c3.tooltips.\(UUID().uuidString)"))
        #expect(Tooltips.currentDelayMilliseconds(d) == 1000)
        Tooltips.install(d)
        #expect(Tooltips.currentDelayMilliseconds(d) == Tooltips.initialDelayMilliseconds)
        #expect((150...250).contains(Tooltips.initialDelayMilliseconds))   // C6: CapCut ≈ 0.2 s (MediaLibraryC6Tests)
    }

    @Test func mediaPostersAreRetinaSized() {
        // tiles are up to ~140 pt tall, drawn aspect-fit: at 2× they need ≥ 280 px
        #expect(MediaThumbs.height >= 280)
        let a = Self.asset("p")
        #expect(MediaThumbs.posterKey(a) != MediaThumbs.posterKey(a, height: MediaThumbs.rowHeight))
    }
}
