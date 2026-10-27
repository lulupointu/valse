import AppKit
import MontageCore

/// Quick cut live preview on the timeline (TL-048, docs/QUICK_CUT.md §1): while the popover is open, every slice the
/// plan removes is drawn over its clip so it reads at a glance without looking like an error: a strong darken, an
/// accent tint, 45° white hatching and an accent outline (thumbnails / waveform stay faintly visible), at least
/// `quickCutMinWidth` wide so tiny slices stay visible on a zoomed-out timeline. Clips Quick cut doesn't work on are
/// dimmed. Drawn after the clips of a row; only visible clips are visited, so a slider tick on a 30-clip timeline is one
/// cheap canvas rebuild.
extension TimelineView {
    static let quickCutDarken = RGBA(0.03, 0.025, 0.02, 0.7)
    static let quickCutTint = Theme.TL.accent(0.25)
    static let quickCutEdge = Theme.TL.accent
    static let quickCutDim = RGBA(0.11, 0.102, 0.09, 0.62)   // panel #1C1A17
    /// Hatch tile side (points); the tile repeats seamlessly.
    static let quickCutHatchSize: CGFloat = 10
    /// Narrowest drawn slice (points), centred on the slice.
    static let quickCutMinWidth: CGFloat = 3
    static let quickCutOutline: CGFloat = 1.5

    /// 10 × 10 pt tile (2× pixels) of 45° stripes, 1.5 pt white lines at 50 %.
    static let quickCutHatch: CGImage? = {
        let px = Int(quickCutHatchSize * 2)
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: px * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.5))
        ctx.setLineWidth(3)   // 1.5 pt
        let s = CGFloat(px)
        // three parallel lines so the stripes continue across tile edges
        for k in -1...1 {
            let o = CGFloat(k) * s
            ctx.move(to: CGPoint(x: o, y: 0)); ctx.addLine(to: CGPoint(x: o + s, y: s))
        }
        ctx.strokePath()
        return ctx.makeImage()
    }()

    /// Drawn rect of a slice from x0 to x1 inside clip rect `r`: at least `quickCutMinWidth` wide, kept in the clip.
    static func quickCutSliceRect(x0: CGFloat, x1: CGFloat, in r: CGRect) -> CGRect? {
        guard x1 > x0, x1 > r.minX, x0 < r.maxX else { return nil }
        var a = max(x0, r.minX), b = min(x1, r.maxX)
        if b - a < quickCutMinWidth {
            let w = min(quickCutMinWidth, r.width), m = (a + b) / 2
            a = min(max(m - w / 2, r.minX), r.maxX - w)
            b = a + w
        }
        return CGRect(x: a, y: r.minY, width: max(1, b - a), height: r.height)
    }

    /// Mouse down while the Quick cut popover is open (QUICK_CUT.md §1): the ruler, empty track space and clip bodies
    /// all act like the ruler (seek + scrub on drag, exact seek on release); the header column seeks to 0 (OB-03).
    /// Nothing is selected or deselected, so the scope and the preview stay as they are. `QuickCutEvents` lets these
    /// clicks through without closing the popover.
    func quickCutMouseDown(_ pt: CGPoint, layout l: TimelineLayout) {
        guard pt.x > TimelineLayout.headerWidth else { store.seek(to: .zero, exact: true); return }
        drag = .scrub
        store.seek(to: l.time(atX: pt.x), exact: false)
    }

    func drawQuickCut(_ c: inout Canvas2D, row: TimelineLayout.Row, track: Track, layout l: TimelineLayout,
                      session s: QuickCutSession) {
        let vis = track.clips(in: l.visibleRange).indices
        guard !vis.isEmpty else { return }
        let lane = c.clip
        let plan = s.plan
        for k in vis {
            let clip = track.clips[k]
            let r = l.clipRect(clip, row: row).insetBy(dx: 0.5, dy: 0)
            guard r.maxX > TimelineLayout.headerWidth, r.minX < bounds.width else { continue }
            guard s.targetClips.contains(clip.id) else { c.rect(r, Self.quickCutDim, radius: 4); continue }
            for slice in plan.slices(for: clip.id) {
                guard let sr = Self.quickCutSliceRect(x0: l.x(slice.start), x1: l.x(slice.end), in: r) else { continue }
                c.rect(sr, Self.quickCutDarken)
                c.rect(sr, Self.quickCutTint)
                if sr.width >= 5, let hatch = Self.quickCutHatch {
                    let inner = sr.insetBy(dx: Self.quickCutOutline, dy: Self.quickCutOutline)
                    let clipRect = lane.map { $0.intersection(inner) } ?? inner
                    if !clipRect.isNull, clipRect.width > 0, clipRect.height > 0 {
                        c.clip = clipRect
                        // tiles anchored to timeline time 0: the hatching scrolls with the clips
                        let t = Self.quickCutHatchSize, origin = l.x(.zero)
                        var x = origin + ((inner.minX - origin) / t).rounded(.down) * t
                        while x < inner.maxX {
                            var y = inner.minY
                            while y < inner.maxY { c.image(hatch, in: CGRect(x: x, y: y, width: t, height: t), fill: false); y += t }
                            x += t
                        }
                        c.clip = lane
                    }
                }
                c.rect(sr, Self.quickCutEdge, radius: 2, border: Self.quickCutOutline)
            }
        }
    }
}
