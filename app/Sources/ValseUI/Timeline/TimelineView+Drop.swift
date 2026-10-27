import AppKit
import ValseCore

/// Drawing of the media drag placeholder (C3-1, CapCut [6]/[7]): a grey box of the dropped clip's length where it will
/// land, the main-track clips after the insert point pushed right live, and a new lane drawn at a lane boundary.
extension TimelineView {
    static let placeholderFill = RGBA(0.45, 0.45, 0.47, 0.55)

    /// Main track with the clips from `index` on drawn `shift` later (ripple insert preview).
    func drawRipplePreview(_ c: inout Canvas2D, row: TimelineLayout.Row, track: Track, layout l: TimelineLayout, dim: Double,
                           ctx: TimelineFrameContext, index: Int, shift: Time) {
        let shifted = TimelineLayout(timeline: ctx.project.timeline, pixelsPerSecond: l.pixelsPerSecond,
                                     scrollTime: l.scrollTime - shift.seconds, scrollY: l.scrollY, viewSize: l.viewSize)
        for k in track.clips(in: l.visibleRange).indices where k < index {
            drawClip(&c, track.clips[k], row: row, track: track, layout: l, dim: dim, ctx: ctx)
        }
        for k in track.clips(in: shifted.visibleRange).indices where k >= index {
            drawClip(&c, track.clips[k], row: row, track: track, layout: shifted, dim: dim, ctx: ctx)
        }
    }

    /// Rect of the placeholder box for a plan (view coordinates), nil when its row is gone.
    func placeholderRect(_ plan: TimelineDropPlan, layout l: TimelineLayout) -> CGRect? {
        let x = l.x(plan.start)
        let w = max(4, CGFloat(plan.duration.seconds * l.pixelsPerSecond))
        switch plan.placement {
        case .main:
            guard let mi = l.mainRowIndex else { return nil }
            let r = l.rows[mi]
            return CGRect(x: x, y: r.y, width: w, height: r.height)
        case .lane(let ri):
            guard ri < l.rows.count else { return nil }
            let r = l.rows[ri]
            return CGRect(x: x, y: r.y, width: w, height: r.height)
        case .newLane(let slot):
            let h: CGFloat = 28
            guard let first = l.rows.first, let last = l.rows.last else {
                return CGRect(x: x, y: TimelineLayout.rulerHeight + 4, width: w, height: h)
            }
            if slot <= 0 { return CGRect(x: x, y: max(TimelineLayout.rulerHeight + 1, first.y - h - 2), width: w, height: h) }
            if slot >= l.rows.count { return CGRect(x: x, y: last.maxY + 3, width: w, height: h) }
            let boundary = (l.rows[slot - 1].maxY + l.rows[slot].y) / 2
            return CGRect(x: x, y: boundary - h / 2, width: w, height: h)
        }
    }

    // MARK: Moving an existing clip (C3b)

    /// The dragged clip, translucent, centred on the pointer's y (its placeholder shows where it lands).
    func drawMoveGhost(_ c: inout Canvas2D, _ clip: Clip, y: CGFloat, layout l: TimelineLayout, ctx: TimelineFrameContext) {
        let tl = store.project.timeline
        guard let loc = tl.locate(clip.id), let home = l.rows.first(where: { $0.trackIndex == loc.track }) else { return }
        let track = tl.tracks[loc.track]
        let row = TimelineLayout.Row(trackIndex: home.trackIndex, trackID: home.trackID, kind: home.kind, isMain: home.isMain,
                                     y: y - home.height / 2, height: home.height, preset: home.preset)
        let clipRect = c.clip
        c.clip = CGRect(x: TimelineLayout.headerWidth, y: TimelineLayout.rulerHeight, width: bounds.width, height: bounds.height)
        drawClip(&c, clip, row: row, track: track, layout: l, dim: 0.75, ctx: ctx)
        c.clip = clipRect
    }

    func clearMovePreview() { movePreview = nil; moveGhost = nil; dropPlan = nil; dirty = true }

    /// Drop of a moved clip: one undo step ("cmd.move") that lands exactly on the placeholder; no-op when unchanged.
    func commitMove(_ id: ClipID, _ plan: TimelineDropPlan) {
        var p = store.project
        guard (try? TimelineOps.relocate(id, to: plan.start, target: plan.target, in: &p)) != nil,
              p.timeline != store.project.timeline else { return }
        store.edit("cmd.move") { p in try TimelineOps.relocate(id, to: plan.start, target: plan.target, in: &p) }
        store.selection = [id]
    }

    func drawDropPlaceholder(_ c: inout Canvas2D, _ plan: TimelineDropPlan, layout l: TimelineLayout) {
        guard let r = placeholderRect(plan, layout: l) else { return }
        if case .newLane = plan.placement {
            // the new lane: a faint band across the timeline, accent line on its edge
            let lane = CGRect(x: TimelineLayout.headerWidth, y: r.minY, width: bounds.width - TimelineLayout.headerWidth, height: r.height)
            c.rect(lane, RGBA(1, 1, 1, 0.05))
            c.rect(CGRect(x: lane.minX, y: r.maxY - 1, width: lane.width, height: 1), Theme.TL.accent(0.8))
        }
        c.rect(r, Self.placeholderFill, radius: 4)
        c.rect(r, RGBA(1, 1, 1, 0.35), radius: 4, border: 1)
        if let t = dropTitle, r.width > 30 {
            let w = min(c.measure(t) + 8, r.width - 8)
            c.rect(CGRect(x: max(r.minX, TimelineLayout.headerWidth) + 4, y: r.minY + 2.5, width: w, height: 15), RGBA(1, 1, 1, 0.15), radius: 3)
            c.text(t, at: CGPoint(x: max(r.minX, TimelineLayout.headerWidth) + 8, y: r.minY + 3), size: 10.5, color: .white, maxWidth: w - 8)
        }
    }
}
