import Testing
import Foundation
@testable import ValseCore

/// W1 timeline editing operations (TimelineOps+Editing.swift).
@Suite struct TimelineEditingTests {
    func ok(_ p: Project) { #expect(TimelineOps.validate(p.timeline).isEmpty, "\(TimelineOps.validate(p.timeline))") }

    func text(_ s: String, at t: Time, _ d: Time = 2) -> Clip { Clip(content: .text(TextContent(string: s)), start: t, duration: d) }

    @Test func deleteMainClipDeletesLinkedClipsUnlessExcluded() throws {
        var (p, ids) = Fx.project(mainClips: 3)
        let t1 = text("a", at: 1), t2 = text("b", at: 5)
        try TimelineOps.insert(t1, into: &p)
        try TimelineOps.insert(t2, into: &p)
        #expect(p.timeline.clip(t1.id)!.linkedTo == ids[0])
        try TimelineOps.delete([ids[0]], in: &p.timeline)
        #expect(p.timeline.clip(t1.id) == nil)
        #expect(p.timeline.clip(t2.id)!.start == Time(1))  // followed ids[1] rippling left
        ok(p)
        // text excluded from linkage: neither follows nor gets deleted
        p.timeline.linkageExcluded = [.text]
        try TimelineOps.delete([ids[1]], in: &p.timeline)
        #expect(p.timeline.clip(t2.id)!.start == Time(1))
        ok(p)
    }

    @Test func groupsExpandAndMoveTogether() throws {
        var (p, ids) = Fx.project(mainClips: 2)
        p.timeline.mainTrackMagnet = false
        let a = text("a", at: 1), b = text("b", at: 2)
        try TimelineOps.insert(a, into: &p)
        try TimelineOps.insert(b, into: &p)
        try TimelineOps.group([a.id, b.id], in: &p.timeline)
        #expect(TimelineOps.expandGroups([a.id], in: p.timeline) == [a.id, b.id])
        try TimelineOps.moveClips([a.id, b.id], by: 3, in: &p.timeline)
        #expect(p.timeline.clip(a.id)!.start == Time(4) && p.timeline.clip(b.id)!.start == Time(5))
        try TimelineOps.ungroup([a.id], in: &p.timeline)
        #expect(TimelineOps.expandGroups([a.id], in: p.timeline) == [a.id])
        _ = ids
        ok(p)
    }

    @Test func multiMoveOnMagneticMainMovesBlock() throws {
        var (p, ids) = Fx.project(mainClips: 4)
        try TimelineOps.moveClips([ids[0], ids[1]], by: 12, in: &p.timeline)
        #expect(Fx.main(p).map(\.id) == [ids[2], ids[3], ids[0], ids[1]])
        ok(p)
        // moving below 0 clamps
        try TimelineOps.moveClips([ids[0], ids[1]], by: -100, in: &p.timeline)
        #expect(Fx.main(p).map(\.id) == [ids[0], ids[1], ids[2], ids[3]])
        ok(p)
    }

    @Test func multiMoveCollisionGoesToNewTrack() throws {
        var (p, _) = Fx.project(mainClips: 3)
        let a = text("a", at: 0, 1), b = text("b", at: 1, 1), c = text("c", at: 4, 2)
        for x in [a, b, c] { try TimelineOps.insert(x, into: &p, target: .automatic) }
        let tracksBefore = p.timeline.tracks.count
        try TimelineOps.moveClips([a.id, b.id], by: 3, in: &p.timeline)  // a 3–4, b 4–5 collides with c
        #expect(p.timeline.tracks.count == tracksBefore + 1)
        #expect(p.timeline.locate(a.id)!.track == p.timeline.locate(b.id)!.track)
        ok(p)
    }

    @Test func copyPastePlacesAtTimeAndKeepsTracks() throws {
        var (p, ids) = Fx.project(mainClips: 2)
        let t = text("hello", at: 1)
        try TimelineOps.insert(t, into: &p)
        let items = TimelineOps.copyItems([ids[0], t.id], from: p.timeline)
        #expect(items.count == 2)
        let new = try TimelineOps.paste(items, at: 4, in: &p)
        #expect(new.count == 2)
        #expect(Fx.main(p).count == 3)
        let pastedText = p.timeline.clip(new[1])!
        #expect(pastedText.start == Time(5))
        if case .text(let c) = pastedText.content { #expect(c.string == "hello") } else { Issue.record("not text") }
        ok(p)
        // duplicate after the selection
        let dup = try TimelineOps.duplicate([t.id], in: &p)
        #expect(p.timeline.clip(dup[0])!.start == p.timeline.clip(t.id)!.end)
        ok(p)
    }

    @Test func pasteAttributesWithKeyframeStretch() throws {
        var (p, ids) = Fx.project(mainClips: 2)
        p.timeline[clip: ids[1]]!.duration = 2
        TimelineOps.compactMain(&p.timeline)
        var src = p.timeline.clip(ids[0])!
        src.opacity = 0.3
        src.transform.scale = Vec2(2, 2)
        src.effects = [EffectInstance(typeID: "valse.filter.mono")]
        let eid = src.effects[0].id
        src.keyframes[ParamKey.opacity.raw] = KeyframeTrack([Keyframe(time: 0, value: .scalar(0)), Keyframe(time: 4, value: .scalar(1))])
        src.keyframes[ParamKey.effect(eid, "strength").raw] = KeyframeTrack([Keyframe(time: 2, value: .scalar(0.5))])
        p.timeline[clip: ids[0]] = src
        try TimelineOps.pasteAttributes(from: src, groups: [.basic, .effects, .keyframes], timing: .stretch, to: [ids[1]], in: &p.timeline)
        let dst = p.timeline.clip(ids[1])!
        #expect(dst.opacity == 0.3 && dst.transform.scale == Vec2(2, 2))
        #expect(dst.effects.count == 1 && dst.effects[0].id != eid)
        #expect(dst.keyframes[ParamKey.opacity.raw]!.keyframes.map(\.time) == [Time(0), Time(2)])
        #expect(dst.keyframes[ParamKey.effect(dst.effects[0].id, "strength").raw] != nil)
        // keep timing drops keyframes past the end
        try TimelineOps.pasteAttributes(from: src, groups: [.keyframes], timing: .keep, to: [ids[1]], in: &p.timeline)
        #expect(p.timeline.clip(ids[1])!.keyframes[ParamKey.opacity.raw]!.keyframes.map(\.time) == [Time(0)])
    }

    @Test func freezeFrameInsertsHeldClipAndRipples() throws {
        var (p, ids) = Fx.project(mainClips: 2)
        let f = try TimelineOps.freezeFrame(ids[0], at: 1, in: &p)
        let main = Fx.main(p)
        #expect(main.count == 4)
        #expect(main[1].id == f && main[1].isFreezeFrame && main[1].start == Time(1) && main[1].duration == Time(3))
        #expect(main[1].sourceDuration == p.settings.frameRate.frameDuration)
        #expect(main[1].sourceTime(at: Time(2.5)) - Time(1) < p.settings.frameRate.frameDuration)
        #expect(main[2].start == Time(4) && main[3].id == ids[1] && main[3].start == Time(7))
        ok(p)
        // trimming keeps a one-frame source extent
        try TimelineOps.trim(f, edge: .tail, to: 3, in: &p)
        let fc = p.timeline.clip(f)!
        #expect(fc.duration == Time(2))
        #expect(abs((fc.sourceDuration - p.settings.frameRate.frameDuration).ticks) <= 1)
        ok(p)
    }

    @Test func reverseMirrorsKeyframes() throws {
        var (p, ids) = Fx.project(mainClips: 1)
        p.timeline[clip: ids[0]]!.keyframes[ParamKey.opacity.raw] = KeyframeTrack([Keyframe(time: 1, value: .scalar(0))])
        try TimelineOps.toggleReverse([ids[0]], in: &p.timeline)
        let c = p.timeline.clip(ids[0])!
        #expect(c.reversed)
        #expect(c.keyframes[ParamKey.opacity.raw]!.keyframes[0].time == Time(3))
    }

    @Test func closeGapsOnFreeTracks() throws {
        var (p, ids) = Fx.project(mainClips: 1)
        p.timeline.mainTrackMagnet = false
        let a = Fx.video("b"); p.media.append(a)
        var c2 = TimelineOps.makeClip(for: a, at: 8); c2.duration = 2
        let tid = p.timeline.mainTrack!.id
        try TimelineOps.insert(c2, into: &p, target: .track(tid))
        #expect(TimelineOps.gap(at: 5, on: tid, in: p.timeline) == TimeRange(start: 4, end: 8))
        try TimelineOps.closeGap(at: 5, on: tid, in: &p.timeline)
        #expect(p.timeline.clip(c2.id)!.start == Time(4))
        try TimelineOps.move(ids[0], to: 2, in: &p.timeline)
        // ids[0] 2–6 overlaps c2 4–6 → went to another track; move c2 instead
        ok(p)
        try TimelineOps.closeAllGaps(on: p.timeline.tracks[p.timeline.locate(ids[0])!.track].id, in: &p.timeline)
        #expect(p.timeline.clip(ids[0])!.start == .zero)
        ok(p)
    }

    @Test func rollMovesTheCutOnly() throws {
        var (p, ids) = Fx.project(mainClips: 2)  // 0–4, 4–8 from 10 s media
        p.timeline[clip: ids[1]]!.sourceStart = 2
        try TimelineOps.roll(ids[0], to: 3, in: &p)
        var m = Fx.main(p)
        #expect(m[0].duration == Time(3) && m[1].start == Time(3) && m[1].duration == Time(5) && m[1].sourceStart == Time(1))
        // right clip can't reveal media before 0 → clamped at 2 (sourceStart 1 → 0)
        try TimelineOps.roll(ids[0], to: 0.5, in: &p)
        m = Fx.main(p)
        #expect(m[1].start == Time(2) && m[1].sourceStart == .zero)
        #expect(m[1].end == Time(8))
        ok(p)
    }

    @Test func slipShiftsSourceWithinMedia() throws {
        var (p, ids) = Fx.project(mainClips: 1)  // 4 s of a 10 s media
        try TimelineOps.slip(ids[0], by: 3, in: &p)
        #expect(p.timeline.clip(ids[0])!.sourceStart == Time(3))
        try TimelineOps.slip(ids[0], by: 100, in: &p)
        #expect(p.timeline.clip(ids[0])!.sourceStart == Time(6))
        #expect(p.timeline.clip(ids[0])!.start == .zero)
    }

    @Test func markersAddNavigateRemove() throws {
        var tl = Timeline()
        let a = try TimelineOps.addMarker(at: 2, in: &tl)
        _ = try TimelineOps.addMarker(at: 1, color: TimelineOps.markerColors[1], in: &tl)
        #expect(throws: EditError.nothingToDo) { try TimelineOps.addMarker(at: 2, in: &tl) }
        #expect(tl.markers.map(\.time) == [Time(1), Time(2)])
        #expect(TimelineOps.nextMarker(after: 1, in: tl)?.id == a)
        #expect(TimelineOps.previousMarker(before: 2, in: tl)?.time == Time(1))
        try TimelineOps.updateMarker(a, in: &tl) { $0.label = "x"; $0.note = "n"; $0.time = 0.5 }
        #expect(tl.markers.first?.id == a)
        try TimelineOps.removeMarkers([a], in: &tl)
        #expect(tl.markers.count == 1)
    }

    @Test func beatsToggle() throws {
        var (p, ids) = Fx.project(mainClips: 1)
        try TimelineOps.toggleBeat(ids[0], at: 1, in: &p.timeline)
        try TimelineOps.toggleBeat(ids[0], at: 2, in: &p.timeline)
        #expect(p.timeline.clip(ids[0])!.beats == [Time(1), Time(2)])
        try TimelineOps.toggleBeat(ids[0], at: 1.01, in: &p.timeline)
        #expect(p.timeline.clip(ids[0])!.beats == [Time(2)])
        try TimelineOps.clearBeats([ids[0]], in: &p.timeline)
        #expect(p.timeline.clip(ids[0])!.beats == nil)
    }

    @Test func extractAndRestoreAudio() throws {
        var (p, ids) = Fx.project(mainClips: 2)
        let x = try TimelineOps.extractAudio(ids[0], in: &p)
        let loc = p.timeline.locate(x)!
        #expect(p.timeline.tracks[loc.track].kind == .audio)
        #expect(p.timeline.clip(ids[0])!.audio.isMuted)
        #expect(p.timeline.clip(x)!.linkedTo == ids[0])
        ok(p)
        try TimelineOps.restoreAudio(ids[0], in: &p.timeline)
        #expect(p.timeline.clip(x) == nil && !p.timeline.clip(ids[0])!.audio.isMuted)
        #expect(!p.timeline.tracks.contains { $0.kind == .audio })
    }

    @Test func replaceMediaKeepsSlotAndShortens() throws {
        var (p, ids) = Fx.project(mainClips: 2)
        let short = Fx.video("short", seconds: 2)
        try TimelineOps.replaceMedia(ids[0], with: short, in: &p)
        #expect(p.timeline.clip(ids[0])!.mediaID == short.id && p.timeline.clip(ids[0])!.duration == Time(2))
        #expect(p.timeline.clip(ids[1])!.start == Time(2))
        ok(p)
    }

    @Test func arrangeLayersAndReorderTracks() throws {
        var (p, _) = Fx.project(mainClips: 1)
        let a = text("a", at: 0), b = text("b", at: 0)
        try TimelineOps.insert(a, into: &p)
        try TimelineOps.insert(b, into: &p)  // overlaps → new track above
        func order() -> [ClipID] { p.timeline.tracks.compactMap { $0.isMain ? nil : $0.clips.first?.id } }
        #expect(order() == [a.id, b.id])
        try TimelineOps.arrange(a.id, .front, in: &p.timeline)
        #expect(order() == [b.id, a.id])
        try TimelineOps.arrange(a.id, .back, in: &p.timeline)
        #expect(order() == [a.id, b.id])
        try TimelineOps.arrange(a.id, .forward, in: &p.timeline)
        #expect(order() == [b.id, a.id])
        ok(p)
        let ta = p.timeline.tracks[p.timeline.locate(a.id)!.track].id
        let tb = p.timeline.tracks[p.timeline.locate(b.id)!.track].id
        try TimelineOps.reorderTrack(ta, above: p.timeline.mainTrack!.id, in: &p.timeline)
        #expect(order() == [a.id, b.id])
        _ = tb
        ok(p)
    }

    @Test func selectLeftRightAndCutPoints() throws {
        let (p, ids) = Fx.project(mainClips: 3)
        #expect(TimelineOps.clips(leftOf: 5, in: p.timeline) == [ids[0], ids[1]])
        #expect(TimelineOps.clips(rightOf: 5, in: p.timeline) == [ids[1], ids[2]])
        #expect(TimelineOps.cutPoints(p.timeline) == [0, 4, 8, 12].map { Time($0) })
    }

    @Test func multiTrimAppliesSameDelta() throws {
        var (p, ids) = Fx.project(mainClips: 2)
        p.timeline.mainTrackMagnet = false
        try TimelineOps.trimClips(ids, edge: .tail, by: -1, in: &p)
        #expect(Fx.main(p).map(\.duration) == [Time(3), Time(3)])
    }

    @Test func newFieldsRoundTripAndOldJSONDecodes() throws {
        var (p, ids) = Fx.project(mainClips: 1)
        p.timeline[clip: ids[0]]!.groupID = ClipGroupID()
        p.timeline[clip: ids[0]]!.beats = [1]
        p.timeline.tracks[0].heightPreset = .tall
        p.timeline.linkageExcluded = [.audio]
        p.timeline.inPoint = 1
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(Project.self, from: data)
        #expect(back == p)
        // a clip encoded without the new keys still decodes
        var obj = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(Clip(content: .solid(.red), start: 0, duration: 1))) as! [String: Any]
        obj.removeValue(forKey: "groupID"); obj.removeValue(forKey: "beats")
        _ = try JSONDecoder().decode(Clip.self, from: JSONSerialization.data(withJSONObject: obj))
    }
}
