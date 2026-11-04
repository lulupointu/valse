import CoreGraphics
import Foundation
import ValseCore

/// Neon tube painter (TX-NEON), reusable for any outline: glyphs (filled tube = the glyph shape) and shapes such as
/// bubble borders (stroked tube: pass `stroked: true`, the path is turned into a tube of `thickness` × 3).
///
/// Look (matched numerically to the owner's reference sign, 2026-11-04: cross-sections sampled perpendicular to the tube
/// of a pink neon speech bubble on black), back to front:
/// - halo: one soft Gaussian in the tube colour cast by the tube grown by 0.24 R (σ ≈ 0.45 R, R = 0.9 × glow size),
///   ~0.65 of the colour right at the tube edge, fading smoothly to nothing ~R beyond it, on both sides of the tube
///   (no wide light spill: the inside of a bubble stays dark);
/// - glass: a thin band of saturated tube colour (0.3 × thickness) hugging the core;
/// - core: near-white (2.5 % of the colour at the default intensity), with a soft coloured inner edge.
/// All sizes scale with `em` (pixels per em), so a 4K export is as sharp as the preview; the context's CTM must map path
/// space to device pixels without scaling (scene space), like every other text item.
enum NeonPainter {
    /// Neon parameters in pixels.
    struct Params {
        var color: RGBA
        var intensity: CGFloat
        var glow: CGFloat
        var thickness: CGFloat
        /// Flicker brightness 0…1 (1 = fully lit).
        var level: CGFloat
        /// The shape is a thin stroked tube (bubble outline) rather than glyphs: a tube casts its halo from a grown
        /// silhouette (a thin line alone is faint); glyphs are wider and close together, so they cast from the glyph
        /// itself, a little dimmer, or the counters would fill with saturated light.
        var stroked = false

        init(_ s: TextNeonStyle, em: CGFloat, level: Double = 1) {
            color = s.color
            intensity = CGFloat(min(max(s.intensity, 0), 1))
            glow = max(CGFloat(s.glowSize) * em, 0.5)
            thickness = max(CGFloat(s.thickness) * em, 0.5)
            self.level = CGFloat(min(max(level, 0), 1))
        }
    }

    /// Paints a whole neon tube along `path` at clip-local time `time` (flicker of `style.flicker`; `faulty` = this
    /// tube is the faulty unit in One letter mode). `stroked`: the path is a line / outline (bubble border) rather
    /// than a filled shape (glyph).
    static func draw(_ path: CGPath, style: TextNeonStyle, em: CGFloat, time: Double, faulty: Bool = true, seed: UInt64 = 0,
                     stroked: Bool = false, in ctx: CGContext) {
        let level = TextNeonStyle.flickerLevel(style.flicker, t: time, faulty: faulty, seed: seed)
        var p = Params(style, em: em, level: level)
        p.stroked = stroked
        let shape = stroked ? tube(path, p) : path
        drawHalo(shape, p, in: ctx)
        drawTube(shape, p, in: ctx)
    }

    /// Halo radius R, px: how far beyond the tube edge the halo fades out (reference: ~3.2 tube widths).
    static func haloRadius(_ p: Params) -> CGFloat { p.glow * 0.9 }

    /// How far the light reaches outside the tube silhouette, px (matches `TextNeonStyle.extentEm`): the grown
    /// silhouette (0.24 R) + 3σ of the Gaussian (σ = 0.45 R), plus the glass band.
    static func reach(_ p: Params) -> CGFloat { haloRadius(p) * 1.75 + glassBand(p) + 1 }

    /// Width of the coloured glass band around the core, px.
    static func glassBand(_ p: Params) -> CGFloat { p.thickness * 0.3 }

    /// Halo strength: the default intensity 0.8 gives the reference's 0.93; above 1 a second cast adds the rest.
    static func haloAlpha(_ p: Params) -> CGFloat { p.intensity * p.level * (p.stroked ? 1.16 : 1.0) }

    /// Silhouette of a stroked tube (the outline `path` becomes a filled shape).
    static func tube(_ path: CGPath, _ p: Params) -> CGPath {
        path.copy(strokingWithWidth: p.thickness * 3, lineCap: .round, lineJoin: .round, miterLimit: 4)
    }

    /// Outward light cast by the filled tube silhouette `shape`; the silhouette itself is left empty (the tube is
    /// painted over it by `drawTube`). One shadow cast (two above intensity 0.86): cheap at any size.
    static func drawHalo(_ shape: CGPath, _ p: Params, in ctx: CGContext) {
        var a = haloAlpha(p)
        guard a > 0.004 else { return }
        let R = haloRadius(p)
        ctx.saveGState()
        ctx.setFillColor(TextPainter.cg(p.color)); ctx.setStrokeColor(TextPainter.cg(p.color))
        ctx.setLineJoin(.round)
        // Only the light is wanted, not the shape casting it: the shape is drawn far away (outside the clip) and its
        // shadow offset brings the light back under the tube. Shadow offsets live in device space, so the user-space
        // shift is mapped through the CTM (item transforms may rotate / scale).
        let box = shape.boundingBoxOfPath
        let far = box.width + box.height + R * 8 + 4096
        let dev = CGSize(width: far, height: 0).applying(ctx.userSpaceToDeviceSpaceTransform)
        ctx.clip(to: box.insetBy(dx: -reach(p), dy: -reach(p)))   // the far-away shape itself never shows
        ctx.translateBy(x: far, y: 0)
        // A Gaussian of a thin tube is faint and narrow: the light is cast from the tube grown by 0.24 R so the halo
        // has a body (≈ 0.65 of the colour at the tube edge) and a long smooth falloff (CG blur = 2σ).
        let grow = R * (p.stroked ? 0.24 : 0.08)
        while a > 0.004 {
            ctx.setShadow(offset: CGSize(width: -dev.width, height: -dev.height), blur: R * 0.9,
                          color: TextPainter.cg(p.color, alpha: Double(min(a, 1))))
            ctx.addPath(shape); ctx.fillPath()
            if grow > 0 { ctx.addPath(shape); ctx.setLineWidth(grow * 2); ctx.strokePath() }
            a -= 1
        }
        ctx.restoreGState()
    }

    /// The glass tube itself: thin saturated glass band, near-white core with a soft coloured inner edge. Unlit
    /// (`level` 0) it is a dim tinted glass tube.
    static func drawTube(_ shape0: CGPath, _ p: Params, in ctx: CGContext) {
        // glyph outlines often overlap (variable fonts): merge them so the edge line has no inner seams (macOS 14+)
        var shape = shape0
        if #available(macOS 14, *) { shape = shape0.normalized() }
        let lit = p.level
        let col = p.color
        let unlit = col.mix(RGBA(0.35, 0.35, 0.38), 0.65)
        // core: white-hot with a faint tint of the tube colour (more when dimmer)
        let hot = RGBA.white.mix(col, Double(0.015 + 0.3 * max(0, 0.8 - p.intensity)))
        let core = unlit.mix(hot, Double(lit))
        let edgeCol = unlit.mix(col, Double(lit))
        ctx.saveGState()
        ctx.setLineJoin(.round)
        // glass: a thin band of saturated colour just outside the core
        ctx.addPath(shape)
        ctx.setStrokeColor(TextPainter.cg(edgeCol, alpha: 0.85)); ctx.setLineWidth(glassBand(p) * 2)
        ctx.strokePath()
        // core
        ctx.setFillColor(TextPainter.cg(core))
        ctx.addPath(shape); ctx.fillPath()
        // soft inner edge: colour bleeding in from the glass = a blurred line on the outline, clipped to the core
        // (non-zero winding, so overlapping contours stay solid)
        ctx.addPath(shape); ctx.clip()
        ctx.setShadow(offset: .zero, blur: p.thickness * 0.8, color: TextPainter.cg(edgeCol, alpha: 0.5))
        ctx.setStrokeColor(TextPainter.cg(edgeCol, alpha: 0.5)); ctx.setLineWidth(max(p.thickness * 0.4, 0.5))
        ctx.addPath(shape); ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: Tube break

    /// `path` with one small break in its first subpath, as in bent-glass signs (the tube is several segments): the
    /// gap (`gap` px between the two cap centres; the tube's round caps close it to ~1.8 tube widths) sits where the
    /// vertical line `x` crosses the top of the outline. Only a closed first subpath is broken (an open line such as
    /// brackets already has ends); other subpaths (thought dots) are kept as they are. The broken subpath is returned
    /// as an open polyline (curves flattened to ≤ 1.5 px segments) starting right after the gap.
    static func broken(_ path: CGPath, x: CGFloat, gap: CGFloat) -> CGPath {
        let rest = CGMutablePath()
        var sub = -1   // index of the current subpath
        var pts: [CGPoint] = [], line: [Bool] = [], closed = false   // the first subpath, flattened
        func curve(_ c: [CGPoint]) {
            guard let a = pts.last else { return }
            let all = [a] + c
            var len: CGFloat = 0
            for i in 1..<all.count { len += hypot(all[i].x - all[i - 1].x, all[i].y - all[i - 1].y) }
            let n = min(max(Int((len / 1.5).rounded(.up)), 2), 512)
            for k in 1...n {
                let t = CGFloat(k) / CGFloat(n), u = 1 - t
                let q: CGPoint
                if c.count == 2 {
                    q = CGPoint(x: u * u * a.x + 2 * u * t * c[0].x + t * t * c[1].x, y: u * u * a.y + 2 * u * t * c[0].y + t * t * c[1].y)
                } else {
                    let (b, d, e) = (u * u * u, 3 * u * u * t, 3 * u * t * t)
                    q = CGPoint(x: b * a.x + d * c[0].x + e * c[1].x + t * t * t * c[2].x,
                                y: b * a.y + d * c[0].y + e * c[1].y + t * t * t * c[2].y)
                }
                pts.append(q); line.append(false)
            }
        }
        path.applyWithBlock { el in
            let e = el.pointee, p = e.points
            switch e.type {
            case .moveToPoint:
                sub += 1
                if sub == 0 { pts = [p[0]] } else { rest.move(to: p[0]) }
            case .addLineToPoint:
                if sub == 0 { pts.append(p[0]); line.append(true) } else { rest.addLine(to: p[0]) }
            case .addQuadCurveToPoint:
                if sub == 0 { curve([p[0], p[1]]) } else { rest.addQuadCurve(to: p[1], control: p[0]) }
            case .addCurveToPoint:
                if sub == 0 { curve([p[0], p[1], p[2]]) } else { rest.addCurve(to: p[2], control1: p[0], control2: p[1]) }
            case .closeSubpath:
                if sub == 0 { closed = true } else { rest.closeSubpath() }
            @unknown default: break
            }
        }
        guard closed, pts.count >= 3 else { return path }
        // closed polyline: segment i goes from v[i] to v[i + 1] (the last one closes the loop)
        var v = pts, isLine = line
        if let f = v.first, let l = v.last, hypot(f.x - l.x, f.y - l.y) > 0.01 { v.append(f); isLine.append(true) }
        var cum: [CGFloat] = [0]
        for i in 1..<v.count { cum.append(cum[i - 1] + hypot(v[i].x - v[i - 1].x, v[i].y - v[i - 1].y)) }
        let total = cum[cum.count - 1]
        guard total > gap * 4 else { return path }
        // topmost crossing of the vertical line x
        var best: (y: CGFloat, s: CGFloat, seg: Int)?
        for i in 0..<(v.count - 1) {
            let a = v[i], b = v[i + 1]
            guard (a.x - x) * (b.x - x) <= 0, a.x != b.x else { continue }
            let t = (x - a.x) / (b.x - a.x)
            let y = a.y + (b.y - a.y) * t
            if best == nil || y < best!.y { best = (y, cum[i] + (cum[i + 1] - cum[i]) * t, i) }
        }
        guard var hit = best else { return path }
        // on a straight edge, keep the gap off the corners at its ends
        if isLine[hit.seg] {
            let s0 = cum[hit.seg], s1 = cum[hit.seg + 1]
            if s1 - s0 > gap * 2.5 { hit.s = min(max(hit.s, s0 + gap * 1.2), s1 - gap * 1.2) }
        }
        func point(at s0: CGFloat) -> (CGPoint, Int) {
            let s = (s0.truncatingRemainder(dividingBy: total) + total).truncatingRemainder(dividingBy: total)
            var lo = 0, hi = cum.count - 1
            while hi - lo > 1 { let m = (lo + hi) / 2; if cum[m] <= s { lo = m } else { hi = m } }
            let span = max(cum[hi] - cum[lo], 1e-9), t = (s - cum[lo]) / span
            return (CGPoint(x: v[lo].x + (v[hi].x - v[lo].x) * t, y: v[lo].y + (v[hi].y - v[lo].y) * t), lo)
        }
        let out = CGMutablePath()
        let (start, i0) = point(at: hit.s + gap / 2)
        let (end, i1) = point(at: hit.s - gap / 2)
        out.move(to: start)
        // vertices v[i0 + 1] … v[i1], wrapping around the loop (v[n] == v[0]); the gap is short, so when both ends
        // fall in one segment the tube goes all the way round
        let n = v.count - 1
        var count = ((i1 - i0) % n + n) % n
        if count == 0 { count = n }
        for k in 1...count { out.addLine(to: v[(i0 + k) % n]) }
        out.addLine(to: end)
        out.addPath(rest)
        return out
    }
}
