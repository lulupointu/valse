import AppKit
import MontageCore

/// Quick cut live preview on the timeline (TL-048, docs/QUICK_CUT.md §1): while the popover is open, every slice the
/// plan removes is drawn over its clip (dark translucent veil + diagonal hatching + thin accent edges, the thumbnails and
/// waveform still show through), and clips Quick cut doesn't work on are dimmed. Drawn after the clips of a row; only
/// visible clips are visited, so a slider tick on a 30-clip timeline is one cheap canvas rebuild.
extension TimelineView {
    static let quickCutVeil = RGBA(0.03, 0.03, 0.04, 0.62)
    static let quickCutEdge = RGBA(0.34, 0.75, 0.8, 0.95)
    static let quickCutDim = RGBA(0.106, 0.106, 0.11, 0.62)
    /// Hatch tile side (points); the tile repeats seamlessly.
    static let quickCutHatchSize: CGFloat = 12

    /// 12 × 12 pt tile (2× pixels) of 45° stripes: white at low alpha.
    static let quickCutHatch: CGImage? = {
        let px = Int(quickCutHatchSize * 2)
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: px * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.3))
        ctx.setLineWidth(2.4)
        let s = CGFloat(px)
        // three parallel lines so the stripes continue across tile edges
        for k in -1...1 {
            let o = CGFloat(k) * s
            ctx.move(to: CGPoint(x: o, y: 0)); ctx.addLine(to: CGPoint(x: o + s, y: s))
        }
        ctx.strokePath()
        return ctx.makeImage()
    }()

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
                let x0 = max(l.x(slice.start), r.minX), x1 = min(l.x(slice.end), r.maxX)
                guard x1 > x0 else { continue }
                let sr = CGRect(x: x0, y: r.minY, width: max(1, x1 - x0), height: r.height)
                c.rect(sr, Self.quickCutVeil)
                if sr.width >= 4, let hatch = Self.quickCutHatch {
                    let clipRect = lane.map { $0.intersection(sr) } ?? sr
                    if !clipRect.isNull, clipRect.width > 0 {
                        c.clip = clipRect
                        // tiles anchored to timeline time 0: the hatching scrolls with the clips
                        let t = Self.quickCutHatchSize, origin = l.x(.zero)
                        var x = origin + ((sr.minX - origin) / t).rounded(.down) * t
                        while x < sr.maxX {
                            var y = sr.minY
                            while y < sr.maxY { c.image(hatch, in: CGRect(x: x, y: y, width: t, height: t), fill: false); y += t }
                            x += t
                        }
                        c.clip = lane
                    }
                }
                if sr.width >= 3 {
                    c.rect(CGRect(x: sr.minX, y: sr.minY, width: 1, height: sr.height), Self.quickCutEdge)
                    c.rect(CGRect(x: sr.maxX - 1, y: sr.minY, width: 1, height: sr.height), Self.quickCutEdge)
                }
            }
        }
    }
}
