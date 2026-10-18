import Testing
import MontageTestSupport
import Foundation
import CoreGraphics
import AppKit
import MontageCore
@testable import MontageUI

/// W1 timeline: hit-testing, snapping, store commands and drawing performance.
@MainActor @Suite(.serialized) struct TimelineUITests {
    static func asset(_ name: String = "v", seconds: Double = 10, kind: MediaKind = .video) -> MediaAsset {
        MediaAsset(name: name, kind: kind, url: URL(fileURLWithPath: "/tmp/\(name).mp4"), duration: Time(seconds), pixelSize: .hd1080,
                   frameRate: .fps30, hasVideo: kind != .audio, hasAudio: true, contentHash: UUID().uuidString)
    }

    func project(clips n: Int = 3) throws -> (Project, [ClipID]) {
        var p = Project()
        var ids: [ClipID] = []
        for i in 0..<n {
            let a = Self.asset("v\(i)")
            p.media.append(a)
            var c = TimelineOps.makeClip(for: a, at: Time(1000)); c.duration = 4
            try TimelineOps.insert(c, into: &p)
            ids.append(c.id)
        }
        return (p, ids)
    }

    func layout(_ tl: Timeline, pps: Double = 50) -> TimelineLayout {
        TimelineLayout(timeline: tl, pixelsPerSecond: pps, scrollTime: 0, scrollY: 0, viewSize: CGSize(width: 1200, height: 400))
    }

    @Test func hitTestsTransitionsKeyframesMarkers() throws {
        var (p, ids) = try project()
        try TimelineOps.setTransition(ids[0], TransitionInstance(typeID: "x", duration: 1), in: &p.timeline)
        p.timeline[clip: ids[1]]!.keyframes[ParamKey.opacity.raw] = KeyframeTrack([Keyframe(time: 1, value: .scalar(0))])
        _ = try TimelineOps.addMarker(at: 2, in: &p.timeline)
        let l = layout(p.timeline)
        let row = l.rows[l.mainRowIndex!]
        // transition straddles the cut at 3.5 (clip 0 ends at 4, clip 1 starts at 3)
        #expect(l.hitTest(CGPoint(x: l.x(Time(3.5)), y: row.y + 30), timeline: p.timeline) == .transition(ids[0], edge: nil, row: l.mainRowIndex!))
        #expect(l.hitTest(CGPoint(x: l.x(Time(3)) + 1, y: row.y + 30), timeline: p.timeline) == .transition(ids[0], edge: .head, row: l.mainRowIndex!))
        // keyframe only for selected clips (clip 1 starts at 3 → keyframe at 4)
        let kp = CGPoint(x: l.x(Time(4.0)) + 1, y: row.maxY - 5)
        if case .keyframe(let id, _, let t, _) = l.hitTest(kp, timeline: p.timeline, selection: [ids[1]]) {
            #expect(id == ids[1] && t == Time(1))
        } else { Issue.record("no keyframe hit") }
        #expect(l.hitTest(kp, timeline: p.timeline) != .keyframe(ids[1], key: ParamKey.opacity.raw, time: 1, row: l.mainRowIndex!))
        // marker flag on the ruler
        if case .marker = l.hitTest(CGPoint(x: l.x(Time(2)) + 2, y: 15), timeline: p.timeline) {} else { Issue.record("no marker hit") }
    }

    @Test func insertionSlotsAndMarquee() throws {
        var (p, ids) = try project()
        try TimelineOps.insert(Clip(content: .text(TextContent(string: "t")), start: 1, duration: 2), into: &p)
        let l = layout(p.timeline)
        #expect(l.rows.count == 2)
        #expect(l.insertionSlot(atY: l.rows[0].y - 2) == 0)
        #expect(l.insertionSlot(atY: (l.rows[0].maxY + l.rows[1].y) / 2) == 1)
        #expect(l.insertionSlot(atY: l.rows[1].y + 30) == nil)
        let r = CGRect(x: l.x(Time(0.5)), y: l.rows[0].y, width: l.x(Time(5)) - l.x(Time(0.5)), height: l.rows[1].maxY - l.rows[0].y)
        let hits = l.clips(in: r, timeline: p.timeline)
        #expect(hits.contains(ids[0]) && hits.contains(ids[1]) && !hits.contains(ids[2]) && hits.count == 3)
    }

    @Test func snapIndexFindsBeatsMarkersAndEdges() throws {
        var (p, ids) = try project()
        p.timeline[clip: ids[0]]!.beats = [Time(1.5)]
        _ = try TimelineOps.addMarker(at: 6.5, in: &p.timeline)
        let s = SnapIndex(timeline: p.timeline, excluding: [ids[2]])
        #expect(s.snap(Time(1.45), playhead: nil, pixelsPerSecond: 100).0 == Time(1.5))
        #expect(s.snap(Time(6.45), playhead: nil, pixelsPerSecond: 100).0 == Time(6.5))
        #expect(s.snap(Time(11.9), playhead: nil, pixelsPerSecond: 100).snapped == false)  // clip 2's end excluded
        #expect(s.snap(Time(9.95), playhead: Time(10), pixelsPerSecond: 100).0 == Time(10))
        let span = s.snapSpan(start: Time(2.96), duration: 1, playhead: nil, pixelsPerSecond: 100)
        #expect(span.start == Time(3) && span.line == Time(4))  // end edge snaps to the cut at 4
    }

    func store() throws -> (EditorStore, [ClipID]) {
        let (p, ids) = try project()
        let s = EditorStore(project: p)
        s.autosaveEnabled = false
        return (s, ids)
    }

    @Test func storeCopyPasteDuplicateGroup() throws {
        let (s, ids) = try store()
        s.selection = [ids[0]]
        s.copySelection()
        s.transport.playhead = Time(4)
        s.paste()
        #expect(s.project.timeline.mainTrack!.clips.count == 4)
        #expect(s.selection.count == 1 && !s.selection.contains(ids[0]))
        s.select([ids[1], ids[2]]); s.groupSelection()
        s.select([ids[1]])
        #expect(s.selection == [ids[1], ids[2]])
        s.ungroupSelection()
        s.select([ids[1]])
        #expect(s.selection == [ids[1]])
        s.duplicateSelection()
        #expect(s.project.timeline.mainTrack!.clips.count == 5)
        s.undo()
        #expect(s.project.timeline.mainTrack!.clips.count == 4)
    }

    @Test func storeSplitDefaultsToMainClipAndFreeze() throws {
        var (p, ids) = try project()
        let text = Clip(content: .text(TextContent(string: "t")), start: 0, duration: 6)
        try TimelineOps.insert(text, into: &p)
        let s = EditorStore(project: p)
        s.autosaveEnabled = false
        s.transport.playhead = Time(1)
        s.split()  // nothing selected: main-track clip under the playhead only
        #expect(s.project.timeline.mainTrack!.clips.count == 4)
        #expect(s.project.timeline.clip(text.id)!.duration == Time(6))
        s.selection = [ids[1]]
        s.transport.playhead = Time(5)
        s.freezeFrame()
        let main = s.project.timeline.mainTrack!.clips
        #expect(main.contains { $0.isFreezeFrame && $0.start == Time(5) })
        #expect(s.singleSelectedClip?.isFreezeFrame == true)
    }

    @Test func storeMarkersBeatsAndRange() throws {
        let (s, _) = try store()
        s.transport.playhead = Time(2)
        s.addMarker()
        s.transport.playhead = Time(5)
        s.addMarker(newColor: true)
        #expect(s.project.timeline.markers.count == 2)
        #expect(s.project.timeline.markers[1].color != s.project.timeline.markers[0].color)
        s.setInPoint()
        s.transport.playhead = Time(8)
        s.setOutPoint()
        #expect(s.project.timeline.inPoint == Time(5) && s.project.timeline.outPoint == Time(8))
        s.timelineUI.selectedMarker = s.project.timeline.markers[0].id
        s.deleteSmart()
        #expect(s.project.timeline.markers.count == 1)
    }

    @Test func zoomKeepsPlayheadFixed() throws {
        let (s, _) = try store()
        s.timelineUI.viewWidth = 1200
        s.pixelsPerSecond = 40
        s.transport.playhead = Time(10)
        s.timelineUI.scrollTime = 2
        let before: Double = 8.0 * 40.0
        s.zoomTimeline(by: 2)
        let after = (10.0 - s.timelineUI.scrollTime) * s.pixelsPerSecond
        #expect(abs(before - after) < 1e-6)
    }

    /// TL-047: 600 clips on 8 tracks; building the display list must stay well under a frame.
    @Test func canvasBuildScalesTo600Clips() throws {
        var p = Project()
        let a = Self.asset("big", seconds: 10000)
        p.media = [a]
        p.timeline.mainTrackMagnet = true
        for i in 0..<300 {
            var c = TimelineOps.makeClip(for: a, at: Time(100000)); c.duration = 2; c.sourceStart = Time(Double(i))
            try TimelineOps.insert(c, into: &p)
        }
        for k in 0..<6 {
            for i in 0..<50 {
                let c = Clip(content: .text(TextContent(string: "t\(k)-\(i)")), start: Time(Double(i) * 12 + Double(k)), duration: 3)
                try TimelineOps.insert(c, into: &p, target: i == 0 ? .newTrack : .track(p.timeline.tracks.last!.id))
            }
        }
        #expect(p.timeline.allClips.count == 600)
        let s = EditorStore(project: p)
        s.autosaveEnabled = false
        s.pixelsPerSecond = 2   // whole timeline visible: worst case
        let v = TimelineView(store: s)
        v.frame = CGRect(x: 0, y: 0, width: 1600, height: 420)
        _ = v.buildCanvas()  // warm label cache
        let t0 = Date()
        for _ in 0..<10 { _ = v.buildCanvas() }
        let ms = Date().timeIntervalSince(t0) * 100
        TimingBudget.metric("unit_timeline_canvas_600_ms", ms, "ms")
        if let lim = TimingBudget.limit(30, "buildCanvas 600 clips") { #expect(ms < lim, "buildCanvas took \(ms) ms") }
        // hit-testing is O(log n) per row
        let l = v.layoutNow
        let t1 = Date()
        for i in 0..<1000 { _ = l.hitTest(CGPoint(x: 200 + Double(i % 1000), y: l.rows[l.mainRowIndex!].y + 20), timeline: p.timeline) }
        let hitMs = Date().timeIntervalSince(t1) * 1000
        TimingBudget.metric("unit_timeline_hittest_1000_ms", hitMs, "ms")
        if let lim = TimingBudget.limit(50, "1000 hit tests") { #expect(hitMs < lim, "1000 hit tests took \(hitMs) ms") }
    }

    @Test func dynamicTimelineKeysAreTranslated() {
        MontageBootstrap.registerResources()
        var keys: [String] = []
        keys += LinkageCategory.allCases.map(\.nameKey) + AttributeGroup.allCases.map(\.nameKey)
        keys += KeyframeTiming.allCases.map(\.nameKey) + LayerArrangement.allCases.map(\.nameKey) + TrackHeight.allCases.map(\.nameKey)
        keys += TimelineView.easingPresets.map(\.key)
        keys += TimelineOps.markerColors.indices.map { "marker.color.\($0)" }
        keys += TimelineView.labelColors.indices.map { "tlmenu.colorLabel.\($0)" }
        keys += ["cmd.trackLock", "cmd.trackHide", "cmd.trackMute", "cmd.beat", "cmd.range", "cmd.colorLabel"]
        let en = L10n.shared.keys(for: "en"), fr = L10n.shared.keys(for: "fr")
        let missing = Set(keys).filter { !en.contains($0) || !fr.contains($0) }.sorted()
        #expect(missing.isEmpty, "missing: \(missing)")
    }
}
