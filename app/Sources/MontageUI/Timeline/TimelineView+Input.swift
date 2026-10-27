import AppKit
import MontageCore
import MontageEffects
import MontageEngine

/// Mouse, scroll, zoom and drag-and-drop handling of the timeline (UX.md §6.6).
///
/// Gestures: click/⇧/⌘-click select (groups expand), marquee on empty space, drag to move (between lanes, onto a new
/// track at a lane boundary, ⌥ = duplicate), edge drag = trim (multi-selection trims together, ⌥ at a cut = roll),
/// ⌘⌥ body drag = slip, transition edges = duration, keyframe diamonds = retime, ruler markers = move, audio fade dots,
/// header drag = track reorder, blade clicks in split mode. Every drag is one undo step (EditSession gestures).
extension TimelineView {
    func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }
    var snappingOn: Bool { store.project.timeline.snapping }

    // MARK: Mouse down

    override func mouseDown(with e: NSEvent) {
        let pt = point(e)
        let l = layoutNow
        let tl = store.project.timeline
        let mods = e.modifierFlags
        lastDrag = nil; lastAutoscrollTime = nil   // U1-7
        clickSeeks = false
        if let anchor = previewAnchor { previewAnchor = nil; _ = anchor }
        // Clicking the timeline ends inspector field editing so shortcuts (⇧⌥K, ⌘B…) reach the editor again.
        if window?.firstResponder is NSTextView { window?.makeFirstResponder(nil) }
        defer { dirty = true }
        // Empty timeline: only the dashed drop lane is shown (no headers, ruler or clips to hit).
        if Self.isEmpty(tl) { store.deselectAll(); return }

        // scrollbar
        if pt.y >= bounds.height - TimelineLayout.scrollbarHeight - 2, pt.x > TimelineLayout.headerWidth, let thumb = scrollbarThumb(l) {
            if thumb.insetBy(dx: 0, dy: -3).contains(pt) { drag = .scrollbar(grab: pt.x - thumb.minX) }
            else { scrollTime += (pt.x < thumb.minX ? -1 : 1) * l.visibleRange.duration.seconds * 0.9 }
            return
        }
        // TL-048: while Quick cut is open a click only moves the playhead (no selection change, popover stays open)
        if ui.quickCut != nil { quickCutMouseDown(pt, layout: l); return }
        // audio fade handles of selected clips
        for id in store.selection {
            guard let loc = tl.locate(id), tl.tracks[loc.track].kind == .audio, !tl.tracks[loc.track].isLocked,
                  let row = l.row(for: tl.tracks[loc.track].id) else { continue }
            let clip = tl.tracks[loc.track].clips[loc.clip]
            let r = l.clipRect(clip, row: row)
            for fadeIn in [true, false] where fadeHandleRect(clip, rect: r, fadeIn: fadeIn, layout: l).insetBy(dx: -3, dy: -3).contains(pt) {
                drag = .fade(id, fadeIn: fadeIn)
                store.beginGesture("cmd.fade")
                return
            }
        }

        // clip volume line (C3-2), split tool excluded
        if ui.tool != .split, !mods.contains(.command), beginVolumeDrag(pt, layout: l) { return }

        var hit = l.hitTest(pt, timeline: tl, selection: store.selection)
        // volume keyframes live on the volume line (C3b): the generic mid-height diamond band doesn't grab them there
        if case .keyframe(let id, let key, _, let ri) = hit, key == ParamKey.volume.raw, let c = tl.clip(id),
           volumeArea(c, row: l.rows[ri], track: tl.tracks[l.rows[ri].trackIndex], layout: l) != nil {
            hit = .clip(id, region: .body, row: ri)
        }
        switch hit {
        case .ruler:
            drag = .scrub
            store.seek(to: l.time(atX: pt.x), exact: false)
        case .marker(let id):
            store.deselectAll()
            ui.selectedMarker = id
            if let m = tl.markers.first(where: { $0.id == id }) {
                store.seek(to: m.time)
                if e.clickCount == 2 { editMarker(id); return }
                drag = .marker(id, startX: pt.x, original: m.time)
                store.beginGesture("cmd.marker.move")
                snapIndex = SnapIndex(timeline: tl)
            }
        case .track, .newTrack, .none:
            let additive = mods.contains(.shift) || mods.contains(.command)
            // OB-02: with a selection a plain click only deselects; OB-03: the grey header column = a click at 0
            clickSeeks = TimelineClickPolicy.emptyClickSeeks(hadSelection: store.hasTimelineSelection, additive: additive)
            if !additive { store.deselectAll() }
            drag = .marquee(anchor: MarqueeAnchor(viewPoint: pt, layout: l), current: pt, base: additive ? store.selection : [])
        case .header(let ri):
            headerMouseDown(ri, pt: pt, layout: l, event: e)
        case .transition(let left, let edge, _):
            store.selection = []
            ui.selectedMarker = nil; ui.selectedKeyframe = nil
            ui.selectedTransition = left
            if let edge, let d = tl.clip(left)?.transitionOut?.duration {
                drag = .transition(left: left, edge: edge, startX: pt.x, original: d)
                store.beginGesture("cmd.transition")
            }
        case .keyframe(let id, let key, let time, _):
            let ref = KeyframeRef(clip: id, key: key, time: time)
            ui.selectedKeyframe = ref
            ui.selectedTransition = nil
            if let c = tl.clip(id) { store.seek(to: c.start + time) }
            drag = .keyframe(ref, startX: pt.x)
            store.beginGesture("cmd.keyframe")
        case .clip(let id, let region, let ri):
            if ui.tool == .split {
                var t = l.time(atX: pt.x)
                if snappingOn, !mods.contains(.command) {
                    t = SnapIndex(timeline: tl).snap(t, playhead: store.transport.playhead, pixelsPerSecond: l.pixelsPerSecond).0
                }
                store.blade(id, at: t)
                return
            }
            let additive = mods.contains(.shift) || mods.contains(.command)
            // OB-02: only a click on the clip that already is the sole selection moves the playhead (on mouse-up)
            clickSeeks = TimelineClickPolicy.clipClickSeeks(selectionBefore: store.selection,
                                                            clickedGroup: TimelineOps.expandGroups([id], in: tl), additive: additive)
            if additive {
                let group = TimelineOps.expandGroups([id], in: tl)
                if store.selection.contains(id) { store.selection.subtract(group) } else { store.select(group, adding: true) }
            } else if !store.selection.contains(id) {
                store.select([id])
            }
            ui.selectedTransition = nil; ui.selectedMarker = nil
            if tl.tracks[l.rows[ri].trackIndex].isLocked {
                if clickSeeks { store.seek(to: l.time(atX: pt.x), exact: true) }   // no drag on a locked track
                return
            }
            drag = .pending(pt, id, region, ri)
        }
    }

    // MARK: Mouse dragged

    override func mouseDragged(with e: NSEvent) {
        let pt = point(e)
        lastDrag = (pt, e.modifierFlags)
        dragUpdate(to: pt, mods: e.modifierFlags)
    }

    /// One drag step at view point `pt` — from a mouse event, or replayed by the edge autoscroll after it scrolled.
    func dragUpdate(to pt: CGPoint, mods: NSEvent.ModifierFlags) {
        let l = layoutNow
        let freeSnap = snappingOn && !mods.contains(.command)
        defer { dirty = true }
        if case .pending(let p0, let id, let region, let ri) = drag {
            guard hypot(pt.x - p0.x, pt.y - p0.y) > 3 else { return }
            startDrag(id: id, region: region, row: ri, at: p0, mods: mods, layout: l)
        }
        let tl = store.project.timeline
        switch drag {
        case .none, .pending: break
        case .scrub:
            store.seek(to: l.time(atX: pt.x), exact: false)
            store.scrubAudio(at: l.time(atX: pt.x))
        case .scrollbar(let grab):
            guard let thumb = scrollbarThumb(l) else { return }
            let trackW = l.clipAreaWidth - 8 - thumb.width
            let total = scrollableDuration, vis = l.visibleRange.duration.seconds
            noteUserScroll()
            scrollTime = Double((pt.x - grab - TimelineLayout.headerWidth - 4) / max(trackW, 1)) * max(total - vis, 0)
        case .marquee(let a, _, let base):
            drag = .marquee(anchor: a, current: pt, base: base)
            let r = a.rect(to: pt, l)   // U1-7: grows from its anchored start while the view scrolls (live selection)
            if r.width > 2 || r.height > 2 {
                store.selection = base.union(TimelineOps.expandGroups(l.clips(in: r, timeline: tl), in: tl))
            }
        case .move(var m):
            let raw = max(.zero, m.anchorStart + (l.time(atX: pt.x) - m.grabTime))
            var start = raw
            snapLine = nil
            if freeSnap, let s = snapIndex?.snapSpan(start: raw, duration: m.anchorDuration, playhead: store.transport.playhead,
                                                       pixelsPerSecond: l.pixelsPerSecond) {
                start = s.start; snapLine = s.line
            }
            let delta = start - m.anchorStart
            if m.duplicate {
                let ids = m.ids
                store.updateGesture { p in
                    let items = TimelineOps.copyItems(ids, from: p.timeline)
                    let minStart = items.map(\.clip.start).min() ?? .zero
                    self.duplicatedIDs = try TimelineOps.paste(items, at: max(.zero, minStart + delta), in: &p)
                }
            } else if m.ids.count > 1 {
                let ids = m.ids
                store.updateGesture { p in try TimelineOps.moveClips(ids, by: delta, in: &p.timeline) }
            } else if let lifted = m.lifted, let clip = store.project.timeline.clip(m.anchor) {
                // C3b: placeholder at the target (ripple on main, lane, new lane), the clip follows the pointer
                dropPlan = TimelineDropPlan.plan(layout: l, timeline: lifted, point: pt, time: start, duration: m.anchorDuration,
                                                 kind: m.kind, mainProbe: start + m.anchorDuration / 2.0, home: m.homeRow)
                dropTitle = nil
                var ghost = clip
                ghost.start = start
                moveGhost = (ghost, pt.y)
            } else {
                moveSingle(&m, start: start, pt: pt, layout: l)
                drag = .move(m)
            }
        case .trim(let ids, let anchor, let edge, let origin):
            // unclamped: a head drag left of 0 still grows the clip (TimelineOps clamps to media / track rules)
            var t = l.unclampedTime(atX: pt.x)
            snapLine = nil
            if freeSnap, let s = snapIndex?.snap(t, playhead: store.transport.playhead, pixelsPerSecond: l.pixelsPerSecond), s.snapped {
                t = s.0; snapLine = t
            }
            if ids.count > 1 {
                let delta = t - origin
                store.updateGesture { p in try TimelineOps.trimClips(ids, edge: edge, by: delta, in: &p) }
            } else {
                store.updateGesture { p in try TimelineOps.trim(anchor, edge: edge, to: t, in: &p) }
            }
            if let c = store.project.timeline.clip(anchor) {
                store.seek(to: edge == .head ? c.start : c.end - Time(ticks: 1), exact: false)
                trimLabel = (l.x(edge == .head ? c.start : c.end), pt.y, Timecode.shortDuration(c.duration))
            }
        case .roll(let left):
            var t = l.time(atX: pt.x)
            snapLine = nil
            if freeSnap, let s = snapIndex?.snap(t, playhead: store.transport.playhead, pixelsPerSecond: l.pixelsPerSecond), s.snapped {
                t = s.0; snapLine = t
            }
            store.updateGesture { p in try TimelineOps.roll(left, to: t, in: &p) }
            if let c = store.project.timeline.clip(left) { store.seek(to: c.end, exact: false) }
        case .slip(let id, let startX):
            guard let c = tl.clip(id) else { return }
            let delta = l.duration(points: startX - pt.x) * c.speed.averageRate
            store.updateGesture { p in try TimelineOps.slip(id, by: delta, in: &p) }
            if let c2 = store.project.timeline.clip(id) {
                trimLabel = (pt.x, pt.y, Timecode.shortDuration(c2.sourceStart))
                store.seek(to: store.transport.playhead.clamped(c2.start, c2.end), exact: false)
            }
        case .transition(let left, let edge, let startX, let original):
            let dx = l.duration(points: pt.x - startX)
            let d = max(Time(0.1), original + (edge == .tail ? dx : -dx) * 2)
            store.updateGesture { p in
                guard var tr = p.timeline.clip(left)?.transitionOut else { return }
                tr.duration = d
                try TimelineOps.setTransition(left, tr, in: &p.timeline)
            }
            if let c = store.project.timeline.clip(left), let tr = c.transitionOut {
                trimLabel = (pt.x, pt.y, Timecode.shortDuration(tr.duration))
            }
        case .keyframe(let ref, let startX):
            guard let c = tl.clip(ref.clip) else { return }
            var nt = (ref.time + l.duration(points: pt.x - startX)).clamped(.zero, c.duration)
            if freeSnap {
                let s = SnapIndex(timeline: Timeline()).snap(c.start + nt, playhead: store.transport.playhead, pixelsPerSecond: l.pixelsPerSecond)
                if s.snapped { nt = s.0 - c.start; snapLine = s.0 } else { snapLine = nil }
            }
            store.updateGesture { p in
                guard var clip = p.timeline.clip(ref.clip), var track = clip.keyframes[ref.key],
                      let i = track.index(near: ref.time, tolerance: Time(ticks: 1000)) else { return }
                let k = track.keyframes[i]
                track.remove(near: ref.time, tolerance: Time(ticks: 1000))
                track.set(k.value, at: nt, easing: k.easing)
                clip.keyframes[ref.key] = track
                p.timeline[clip: ref.clip] = clip
            }
            ui.selectedKeyframe = KeyframeRef(clip: ref.clip, key: ref.key, time: nt)
            store.seek(to: c.start + nt, exact: false)
        case .marker(let id, let startX, let original):
            var t = max(.zero, original + l.duration(points: pt.x - startX))
            snapLine = nil
            if freeSnap, let s = snapIndex?.snap(t, playhead: nil, pixelsPerSecond: l.pixelsPerSecond), s.snapped, s.0 != original {
                t = s.0; snapLine = t
            }
            store.updateGesture { p in try TimelineOps.updateMarker(id, in: &p.timeline) { $0.time = t } }
        case .fade(let id, let fadeIn):
            guard let c = tl.clip(id), let loc = tl.locate(id), let row = l.row(for: tl.tracks[loc.track].id) else { return }
            let r = l.clipRect(c, row: row)
            let v = l.duration(points: fadeIn ? pt.x - r.minX - 6 : r.maxX - 6 - pt.x).clamped(.zero, c.duration / 2.0)
            store.updateGesture { p in
                if fadeIn { p.timeline[clip: id]?.audio.fadeIn = v } else { p.timeline[clip: id]?.audio.fadeOut = v }
            }
            trimLabel = (pt.x, pt.y, Timecode.shortDuration(v))
        case .volume(let id, let grabY, let origin, let grab):
            updateVolumeDrag(id, grabY: grabY, origin: origin, grab: grab, at: pt, layout: l)
        case .trackReorder(let id, _):
            drag = .trackReorder(id, y: pt.y)
            insertionSlot = l.rowIndex(atY: pt.y).map { ri in
                let r = l.rows[ri]
                return pt.y < r.y + r.height / 2 ? ri : ri + 1
            }
        }
    }

    private func startDrag(id: ClipID, region: TimelineLayout.ClipRegion, row ri: Int, at p0: CGPoint, mods: NSEvent.ModifierFlags, layout l: TimelineLayout) {
        let tl = store.project.timeline
        guard let clip = tl.clip(id), let loc = tl.locate(id) else { drag = .none; return }
        let track = tl.tracks[loc.track]
        switch region {
        case .leadingEdge, .trailingEdge:
            let edge: TrimEdge = region == .leadingEdge ? .head : .tail
            if mods.contains(.option) {
                // roll at a cut
                let neighbour = edge == .tail ? (loc.clip + 1 < track.clips.count ? track.clips[loc.clip + 1] : nil)
                                              : (loc.clip > 0 ? track.clips[loc.clip - 1] : nil)
                if let n = neighbour, (edge == .tail ? n.start == clip.end : n.end == clip.start) {
                    let left = edge == .tail ? clip.id : n.id
                    drag = .roll(left: left)
                    snapIndex = SnapIndex(timeline: tl, excluding: [clip.id, n.id])
                    store.beginGesture("cmd.roll")
                    return
                }
            }
            var ids = [id]
            if store.selection.count > 1, store.selection.contains(id) { ids = Array(store.selection) }
            drag = .trim(ids: ids, anchor: id, edge: edge, origin: edge == .head ? clip.start : clip.end)
            snapIndex = SnapIndex(timeline: tl, excluding: Set(ids))
            store.beginGesture("cmd.trim")
        case .body:
            if mods.contains(.command) && mods.contains(.option), clip.mediaID != nil {
                drag = .slip(id: id, startX: p0.x)
                store.beginGesture("cmd.slip")
                return
            }
            let ids = store.selection.contains(id) ? store.selection : TimelineOps.expandGroups([id], in: tl)
            let dup = mods.contains(.option)
            var m = MoveDrag(anchor: id, ids: ids, grabTime: l.time(atX: p0.x), anchorStart: clip.start,
                             anchorDuration: clip.duration, kind: track.kind, duplicate: dup, newTrackAbove: nil)
            duplicatedIDs = []
            snapIndex = SnapIndex(timeline: tl, excluding: ids)
            if !dup, ids.count == 1, let lifted = try? TimelineOps.liftForMove(id, from: tl) {
                // single clip: nothing changes until the drop (no live re-layout under the pointer = no flicker, C3b)
                m.lifted = lifted.timeline
                m.homeRow = ri
                movePreview = lifted.timeline
                drag = .move(m)
                return
            }
            drag = .move(m)
            store.beginGesture(dup ? "cmd.duplicate" : "cmd.move")
        }
    }

    /// Single-clip move with lane targeting: compatible lane under the cursor, or a new track at a lane boundary.
    private func moveSingle(_ m: inout MoveDrag, start: Time, pt: CGPoint, layout l: TimelineLayout) {
        let id = m.anchor, kind = m.kind
        insertionSlot = nil
        var target: TrackID?
        var newAbove: TrackID?? = nil
        if let slot = l.insertionSlot(atY: pt.y) {
            let ref = slot < l.rows.count ? l.rows[slot] : nil
            if kind == .audio {
                if ref == nil || ref!.kind == .audio { newAbove = .some(nil); insertionSlot = slot }
            } else if let ref, ref.kind != .audio {
                newAbove = .some(ref.trackID); insertionSlot = slot
            }
        }
        if newAbove == nil, let ri = l.rowIndex(atY: pt.y) {
            let row = l.rows[ri]
            if TimelineOps.compatible(row.kind, kind) { target = row.trackID }
        } else if newAbove == nil {
            // above all rows: new top track; below all: new audio track
            if let first = l.rows.first, pt.y < first.y, kind != .audio { newAbove = .some(nil); insertionSlot = 0 }
        }
        if let n = newAbove { m.newTrackAbove = n }
        let remembered = m.newTrackAbove
        let wantNew = newAbove != nil
        store.updateGesture { p in
            var tid = target
            if let t = tid, p.timeline.trackIndex(t) == nil {
                // a track created by this gesture: recreate it the same way
                guard let r = remembered else { return }
                tid = Self.addTrack(kind, above: r, in: &p.timeline)
            } else if wantNew, let r = remembered {
                tid = Self.addTrack(kind, above: r, in: &p.timeline)
            }
            try TimelineOps.move(id, to: start, track: tid, in: &p.timeline)
        }
    }

    /// Adds a track visually above `ref` (nil = top of the visual stack; audio always appended).
    static func addTrack(_ kind: TrackKind, above ref: TrackID?, in tl: inout Timeline) -> TrackID {
        let k: TrackKind = kind
        if k == .audio { return TimelineOps.addTrack(.audio, to: &tl) }
        if let ref, let i = tl.trackIndex(ref) { return TimelineOps.addTrack(k, to: &tl, above: i) }
        return TimelineOps.addTrack(k, to: &tl)
    }

    // MARK: Mouse up

    override func mouseUp(with e: NSEvent) {
        let pt = point(e)
        let l = layoutNow
        defer {
            drag = .none; snapLine = nil; snapIndex = nil; trimLabel = nil; insertionSlot = nil; dirty = true
            lastDrag = nil; lastAutoscrollTime = nil
        }
        switch drag {
        case .pending(let p0, let id, _, _):
            if !e.modifierFlags.contains(.shift), !e.modifierFlags.contains(.command), store.selection.count > 1 {
                let g = TimelineOps.expandGroups([id], in: store.project.timeline)
                if g != store.selection { store.select([id]) }
            }
            if clickSeeks { store.seek(to: l.time(atX: p0.x), exact: true) }   // OB-02: click inside the sole selection
            if e.clickCount == 2, let c = store.project.timeline.clip(id) {
                if case .compound = c.content { store.enterCompound(id); return }   // TL-021 edit inside
                if c.groupID != nil { store.enterGroup(id); return }                // TL-020 enter the group
                store.seek(to: c.start)
            }
        case .scrub: store.seek(to: l.time(atX: pt.x), exact: true)
        case .marquee(let a, _, _):
            let o = a.viewPoint(l)
            // a click (no marquee): OB-02 seeks only when nothing was selected; OB-03 the header column = time 0
            if hypot(pt.x - o.x, pt.y - o.y) <= 3, clickSeeks {
                store.seek(to: pt.x > TimelineLayout.headerWidth ? l.time(atX: pt.x) : .zero, exact: true)
            }
        case .move(let m) where m.lifted != nil:
            let plan = dropPlan
            clearMovePreview()
            guard let plan else { break }
            commitMove(m.anchor, plan)
        case .move(let m):
            store.endGesture()
            if m.duplicate, !duplicatedIDs.isEmpty { store.selection = Set(duplicatedIDs) }
        case .trim, .roll, .slip, .transition, .keyframe, .marker, .fade, .volume:
            store.endGesture()
        case .trackReorder(let id, let y):
            guard let ri = l.rowIndex(atY: y) else { break }
            let row = l.rows[ri]
            let tl = store.project.timeline
            if row.trackID == id { headerZeroClick(); break }   // released on its own header: a click (OB-03)
            guard row.kind.isVisual else { break }
            var above: TrackID? = row.trackID
            if y >= row.y + row.height / 2 {
                // below this row = right below it in compositing order
                let visual = tl.tracks.indices.filter { tl.tracks[$0].kind.isVisual }
                if let pos = visual.firstIndex(of: row.trackIndex), pos > 0 { above = tl.tracks[visual[pos - 1]].id } else { above = nil }
                if row.isMain { break }
            }
            guard let above else { break }
            store.edit("cmd.trackReorder") { p in try TimelineOps.reorderTrack(id, above: above, in: &p.timeline) }
        case .none, .scrollbar: break
        }
    }

    // MARK: Hover

    override func mouseMoved(with e: NSEvent) {
        guard !ModalHoverGate.isBlocked(e.locationInWindow, in: window) else { return }   // FB-07: a dialog covers it
        let pt = point(e)
        let l = layoutNow
        hoverPoint = pt
        hoverTime = pt.x > TimelineLayout.headerWidth && pt.y > TimelineLayout.rulerHeight ? l.time(atX: pt.x) : nil
        let hit = l.hitTest(pt, timeline: store.project.timeline, selection: store.selection)
        hoverClip = nil
        hoverVolumeClip = ui.tool == .split ? nil : volumeLineHit(pt, layout: l)?.id
        switch hit {
        case .clip(let id, let region, _):
            hoverClip = id
            if ui.tool == .split { Self.bladeCursor.set() }
            else if hoverVolumeClip != nil { NSCursor.resizeUpDown.set() }
            else if region != .body { NSCursor.resizeLeftRight.set() }
            else { NSCursor.arrow.set() }
        case .transition(_, let edge, _): (edge != nil ? NSCursor.resizeLeftRight : NSCursor.pointingHand).set()
        case .keyframe, .marker: NSCursor.pointingHand.set()
        default: NSCursor.arrow.set()
        }
        // Preview axis: the player follows the mouse; the playhead comes back on exit.
        if ui.previewAxis, !store.transport.isPlaying, let h = hoverTime {
            if previewAnchor == nil { previewAnchor = store.transport.playhead }
            store.seek(to: h, exact: false)
            if ui.previewAxisAudio { store.previewAxisAudio(at: h) }   // TL-031 "video + audio" mode
        } else if !ui.previewAxis, let a = previewAnchor {
            previewAnchor = nil; store.seek(to: a)
        }
        dirty = true
    }

    override func mouseExited(with event: NSEvent) {
        hoverTime = nil; hoverPoint = nil; hoverClip = nil; hoverVolumeClip = nil
        // preview axis: back to the playhead — unless playback started meanwhile (it would jump mid-play, C3-5)
        if let a = previewAnchor { previewAnchor = nil; if !store.transport.isPlaying { store.seek(to: a) } }
        dirty = true
    }

    static let bladeCursor: NSCursor = {
        let size = NSSize(width: 20, height: 20)
        let img = NSImage(size: size, flipped: false) { r in
            if let s = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 14, weight: .bold)) {
                let shadow = NSShadow(); shadow.shadowBlurRadius = 2; shadow.shadowColor = .black; shadow.set()
                s.draw(in: r.insetBy(dx: 2, dy: 2))
                NSColor.white.set(); r.fill(using: .sourceAtop)
            }
            return true
        }
        return NSCursor(image: img, hotSpot: NSPoint(x: 10, y: 10))
    }()

    // MARK: Header

    private func headerMouseDown(_ ri: Int, pt: CGPoint, layout l: TimelineLayout, event e: NSEvent) {
        let row = l.rows[ri]
        let track = store.project.timeline.tracks[row.trackIndex]
        if row.isMain, coverButtonRect(row).contains(pt) { store.openCoverEditor(); return }

        if let item = headerItems(track, row: row).first(where: { $0.rect.insetBy(dx: -3, dy: -4).contains(pt) }), item.id != "type" {
            let tid = track.id
            switch item.id {
            case "lock": store.toggleTrack(tid, \.isLocked, key: "cmd.trackLock")
            case "eye": store.toggleTrack(tid, \.isHidden, key: "cmd.trackHide")
            case "mute": store.toggleTrack(tid, \.isMuted, key: "cmd.trackMute")
            case "solo": store.toggleSolo(tid)
            case "more": NSMenu.popUpContextMenu(trackMenu(track), with: e, for: self)
            default: break
            }
            return
        }
        // OB-03: the empty header space is a click at time 0 (OB-02 rule); a reorderable header decides on mouse-up
        clickSeeks = TimelineClickPolicy.emptyClickSeeks(hadSelection: store.hasTimelineSelection, additive: false)
        if !row.isMain, track.kind.isVisual { drag = .trackReorder(track.id, y: pt.y) } else { headerZeroClick() }
    }

    /// OB-03: a click on the grey header column = a click at time 0: deselect when something is selected, else seek to 0.
    func headerZeroClick() {
        if clickSeeks { store.seek(to: .zero, exact: true) } else { store.deselectAll() }
    }

    /// U1-7: display-link edge autoscroll (see `EdgeAutoscroll`): horizontal for every positional drag, vertical too for
    /// the marquee and clip moves; the drag step is replayed at the same pointer so the marquee / clip / trim edge keeps up.
    func autoscrollTick() {
        guard let (pt, mods) = lastDrag else { lastAutoscrollTime = nil; return }
        let vertical: Bool
        switch drag {
        case .marquee, .move: vertical = true
        case .trim, .roll, .keyframe, .marker, .scrub: vertical = false
        default: lastAutoscrollTime = nil; return
        }
        let now = CACurrentMediaTime()
        let dt = lastAutoscrollTime.map { now - $0 } ?? 0
        lastAutoscrollTime = now
        let vx = EdgeAutoscroll.speed(pt.x, lower: TimelineLayout.headerWidth, upper: bounds.width)
        let vy = vertical ? EdgeAutoscroll.speed(pt.y, lower: TimelineLayout.rulerHeight, upper: bounds.height) : 0
        guard vx != 0 || vy != 0, dt > 0 else { return }
        var moved = false
        if vx != 0 {
            let t0 = scrollTime
            scrollTime = min(max(0, t0 + EdgeAutoscroll.step(speed: vx, dt: dt) / store.pixelsPerSecond), scrollableDuration)
            moved = moved || scrollTime != t0
        }
        if vy != 0 {
            let y0 = scrollY, maxY = max(0, layoutNow.contentHeight - bounds.height)
            scrollY = min(max(0, y0 + CGFloat(EdgeAutoscroll.step(speed: vy, dt: dt))), maxY)
            moved = moved || scrollY != y0
        }
        if moved { dragUpdate(to: pt, mods: mods) }
    }

    // MARK: Scroll & zoom

    override func scrollWheel(with e: NSEvent) {
        // Settings ▸ Edit ▸ Mouse (SE-016): wheel direction and zoom modifier
        let s = AppPreferences.shared.settings
        let action = TimelineScrollMapping.action(
            dx: Double(e.scrollingDeltaX), dy: Double(e.scrollingDeltaY),
            command: e.modifierFlags.contains(.command), option: e.modifierFlags.contains(.option),
            shift: e.modifierFlags.contains(.shift), precise: e.hasPreciseScrollingDeltas,
            wheel: TimelineScrollMapping.WheelScroll(rawValue: s.mouseWheelScroll) ?? .vertical,
            zoomModifier: TimelineScrollMapping.ZoomModifier(rawValue: s.mouseZoomModifier) ?? .command)
        switch action {
        case .none: return
        case .zoom(let k): noteUserScroll(); zoom(by: k, around: point(e).x)
        case .scroll(let dx, let dy):
            if dx != 0 {
                noteUserScroll()
                scrollTime = min(max(0, scrollTime - dx / store.pixelsPerSecond), scrollableDuration)
            }
            if dy != 0 {
                let maxY = max(0, layoutNow.contentHeight - bounds.height)
                scrollY = min(max(0, scrollY - CGFloat(dy)), maxY)
            }
        }
    }

    override func magnify(with e: NSEvent) { noteUserScroll(); zoom(by: 1 + e.magnification, around: point(e).x) }

    func zoom(by k: Double, around x: CGFloat) {
        let l = layoutNow
        let anchor = l.time(atX: x).seconds
        store.zoom(by: k)
        scrollTime = max(0, anchor - Double(x - TimelineLayout.headerWidth) / store.pixelsPerSecond)
    }

    // MARK: Drag & drop

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let pt = convert(sender.draggingLocation, from: nil)
        let l = layoutNow
        var t = l.time(atX: pt.x)
        if let s = sender.draggingPasteboard.string(forType: .string), case .transition = DragPayload.parse(s) {
            let (cut, row) = transitionDropCut(at: pt, l)
            if let cut { t = cut.end - (cut.transitionOut?.duration ?? .zero) / 2.0 }
            dropIndicator = (t, row ?? l.mainRowIndex)
        } else {
            if snappingOn { t = l.snap(t, timeline: store.project.timeline, playhead: store.transport.playhead).0 }
            // C3-1: media (video / image / audio, one or several): grey placeholder where it lands, main-track ripple.
            if let s = sender.draggingPasteboard.string(forType: .string), let kind = store.dropPreviewKind(s),
               let d = store.dropPreviewDuration(s), d > .zero {
                dropPlan = TimelineDropPlan.plan(layout: l, timeline: store.project.timeline, point: pt, time: t, duration: d, kind: kind)
                dropTitle = store.dropPreviewTitle(s)
                dropIndicator = nil; insertionSlot = nil; dropGhost = nil
                dirty = true
                return .copy
            }
            dropPlan = nil
            insertionSlot = l.insertionSlot(atY: pt.y)
            dropIndicator = (t, insertionSlot == nil ? l.rowIndex(atY: pt.y) : nil)
        }
        // W13: ghost of the clip(s) the drop would create (asset-panel payloads with a known length).
        dropGhost = sender.draggingPasteboard.string(forType: .string).flatMap { store.dropPreviewDuration($0) }
        dirty = true
        return .copy
    }

    /// Leaving the timeline cancels the placeholder (C3-1).
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { clearDropFeedback() }
    override func draggingEnded(_ sender: any NSDraggingInfo) { clearDropFeedback() }

    func clearDropFeedback() { dropIndicator = nil; insertionSlot = nil; dropGhost = nil; dropPlan = nil; dropTitle = nil; dirty = true }

    /// Cut a transition dragged at `pt` attaches to: a continuous cut on the hovered overlay video track (PiP, TR-004)
    /// within 40 pt, else the main-track cut nearest the cursor. Returns the left clip and its row.
    func transitionDropCut(at pt: CGPoint, _ l: TimelineLayout) -> (Clip?, Int?) {
        let t = l.time(atX: pt.x)
        if let ri = l.rowIndex(atY: pt.y), !l.rows[ri].isMain, l.rows[ri].kind == .video,
           let c = TimelineOps.transitionCut(near: t, track: l.rows[ri].trackID, in: store.project.timeline, within: l.duration(points: 40)) {
            return (c, ri)
        }
        return (nearestCut(to: t), l.mainRowIndex)
    }

    /// Main-track clip whose end is the cut nearest `t`.
    func nearestCut(to t: Time) -> Clip? {
        guard let main = store.project.timeline.mainTrack, main.clips.count > 1 else { return nil }
        return main.clips.dropLast().min { abs(($0.end - t).ticks) < abs(($1.end - t).ticks) }
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let plan = dropPlan
        defer { clearDropFeedback() }
        let pt = convert(sender.draggingLocation, from: nil)
        let l = layoutNow
        let time = plan?.start ?? dropIndicator?.time ?? l.time(atX: pt.x)
        let hit = l.hitTest(pt, timeline: store.project.timeline)
        let target = plan?.target ?? (insertionSlot != nil ? InsertTarget.newTrack : insertTarget(hit, l))
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            // MI-001 (F3): files dropped anywhere on an empty timeline start the main track (CapCut), not an overlay lane
            if store.project.timeline.allClips.isEmpty { store.importFiles(urls, thenInsertAt: .zero, target: .automatic); return true }
            store.importFiles(urls, thenInsertAt: time, target: target)
            return true
        }
        if let s = pb.string(forType: .string), store.handleLibraryDrop(s, at: time, target: target) { return true }   // W13 library payloads
        guard let s = pb.string(forType: .string), let payload = DragPayload.parse(s) else { return false }
        switch payload {
        case .media(let id):
            store.addToTimeline(id, at: time, target: target)
        case .effect(let typeID):
            if typeID == DragPayload.customAdjustmentID { store.addCustomAdjustment(at: time); return true }
            guard let d = Registries.effects[typeID] else { return false }
            // Onto a media/text clip = that clip only; elsewhere (or onto another effect/filter layer) = a new layer clip.
            if case .clip(let cid, _, _) = hit, let c = store.project.timeline.clip(cid), c.content != .adjustment {
                store.selection = [cid]
            } else { store.selection = []; store.seek(to: time) }
            store.applyEffect(d)
        case .transition(let typeID):
            guard let d = Registries.transitions[typeID] else { return false }
            if let cut = transitionDropCut(at: pt, l).0 { store.selection = [cut.id] }
            store.applyTransition(d)
        case .sticker(let id):
            store.seek(to: time); store.addGeneratorClip(.sticker(id: id))
        case .text(let styleID):
            store.seek(to: time); store.addTextPayload(styleID)
        }
        return true
    }

    private func insertTarget(_ hit: TimelineLayout.Hit, _ l: TimelineLayout) -> InsertTarget {
        switch hit {
        case .track(let ri), .clip(_, _, let ri), .transition(_, _, let ri), .keyframe(_, _, _, let ri):
            let row = l.rows[ri]
            return row.isMain ? .automatic : .track(row.trackID)
        case .newTrack(above: true): return .newTrack
        default: return .automatic
        }
    }
}
