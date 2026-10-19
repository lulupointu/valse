import AppKit
import MontageCore

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

    func drawDropPlaceholder(_ c: inout Canvas2D, _ plan: TimelineDropPlan, layout l: TimelineLayout) {
        guard let r = placeholderRect(plan, layout: l) else { return }
        if case .newLane = plan.placement {
            // the new lane: a faint band across the timeline, accent line on its edge
            let lane = CGRect(x: TimelineLayout.headerWidth, y: r.minY, width: bounds.width - TimelineLayout.headerWidth, height: r.height)
            c.rect(lane, RGBA(1, 1, 1, 0.05))
            c.rect(CGRect(x: lane.minX, y: r.maxY - 1, width: lane.width, height: 1), RGBA(0.34, 0.75, 0.8, 0.8))
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
