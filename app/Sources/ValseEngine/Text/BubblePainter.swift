import CoreGraphics
import Foundation
import ValseCore
import ValseEffects

/// TX-BUBBLE2: geometry and painting of a `TextBubbleStyle` behind the text. Draw order: shadow → neon glow → fill →
/// outline (solid / dashed / dotted line, or neon tube). Styles a v1 preset can express go through the v1 geometry
/// (`BubblePaths`) and the v1 paint calls, so the 24 v1 presets stay pixel-identical. Scene space, y down, em = px.
enum BubblePainter {
    /// What one scene item paints: the whole bubble, or one layer of a flickering neon bubble (the glow and the tube
    /// are their own atlas cells so their brightness is modulated per frame on the GPU, the body stays steady).
    enum Part { case whole, glow, body, tube }

    // MARK: Geometry

    /// The style is expressible by a v1 `BubbleShape` with v1 sizing (no containment, classic tail, no jitter).
    static func isClassic(_ s: TextBubbleStyle) -> Bool {
        guard !s.containsText, s.jitter == 0 else { return false }
        guard let t = s.tail else { return true }
        guard t.position == nil, t.lean == 0, t.length == TextBubbleTail.defaultLength, t.width == TextBubbleTail.defaultWidth else { return false }
        switch s.family {
        case .box: return t.kind == .point && BubbleTail(rawValue: t.side.rawValue) != nil
        case .oval: return t.kind == .dots && t.side == .bottomLeft
        default: return false
        }
    }

    /// Rectangle of the shape: the padded text rect, grown for oval / cloud / burst so they contain it
    /// (rx = w/2·√2, ry = h/2·√2, ry ≥ rx/3).
    static func shapeRect(_ s: TextBubbleStyle, _ r: CGRect) -> CGRect {
        guard s.containsText, [.oval, .cloud, .burst].contains(s.family) else { return r }
        let rx = r.width / 2 * sqrt(2), ry = max(r.height / 2 * sqrt(2), rx / 3)
        return CGRect(x: r.midX - rx, y: r.midY - ry, width: rx * 2, height: ry * 2)
    }

    static func path(_ s: TextBubbleStyle, rect r0: CGRect, em: CGFloat) -> CGPath {
        if isClassic(s) { return BubblePaths.path(TextBubbleDescriptor.shape(of: s), rect: r0, em: em) }
        let r = shapeRect(s, r0)
        let tail = s.family.hasTail ? s.tail : nil
        let joined = tail.flatMap { $0.kind == .dots ? nil : $0 }
        let p = CGMutablePath()
        switch s.family {
        case .box, .pill:
            var rr = s.family == .pill ? min(r.height, r.width) / 2 : min(CGFloat(s.cornerRadius) * em, r.height / 2, r.width / 2)
            // the corners never cut into the text: a radius r cuts r·(1 − 1/√2) into the corner, keep that ≤ padding
            // (a 6-line pill becomes a rounded box instead of a capsule that clips the first and last lines)
            rr = min(rr, CGFloat(min(s.padding.x, s.padding.y)) * em / (1 - 1 / sqrt(2)))
            if let t = joined, t.side == .left || t.side == .right {   // room for the tail base between the corners
                rr = min(rr, max((r.height - tailWidth(t, r, em, vertical: true)) / 2, 0))
            }
            box(p, r, max(rr, 0), joined, em)
        case .oval:
            oval(p, r, joined, em)
        case .cloud:
            cloud(p, r, bumps: s.bumps, jitter: s.jitter, tail: joined, em: em)
        case .burst:
            burst(p, r, spikes: s.spikes, depth: s.depth, jitter: s.jitter, tail: joined, em: em)
        default:
            p.addPath(BubblePaths.path(TextBubbleDescriptor.shape(of: s), rect: r, em: em))
        }
        if let t = tail, t.kind == .dots { dots(p, s, r, t, em) }
        return p
    }

    /// Angle (y down, 0 = right, 90° = down) the tail points to; `position` slides it ±30° around the side.
    static func angle(_ t: TextBubbleTail) -> CGFloat {
        let deg: CGFloat
        switch t.side {
        case .right: deg = 0
        case .bottomRight: deg = 60
        case .bottom: deg = 90
        case .bottomLeft: deg = 120
        case .left: deg = 180
        case .topLeft: deg = 240
        case .top: deg = 270
        case .topRight: deg = 300
        }
        return (deg + CGFloat(((t.position ?? 0.5) - 0.5) * 60)) * .pi / 180
    }

    /// −1 / 0 / 1: which way a corner tail leans (bottomLeft leans left…), along the side.
    static func cornerLean(_ side: TextBubbleTail.Side) -> CGFloat {
        switch side {
        case .bottomLeft, .topLeft: return -1
        case .bottomRight, .topRight: return 1
        default: return 0
        }
    }

    static func tailWidth(_ t: TextBubbleTail, _ r: CGRect, _ em: CGFloat, vertical: Bool) -> CGFloat {
        min((vertical ? r.height : r.width) * 0.3, CGFloat(t.width) * em)
    }

    static func tailEdges(_ p: CGMutablePath, _ b0: CGPoint, _ tip: CGPoint, _ b1: CGPoint, _ kind: TextBubbleTail.Kind, bend: CGVector) {
        p.addLine(to: b0)
        if kind == .curve {
            p.addQuadCurve(to: tip, control: CGPoint(x: (b0.x + tip.x) / 2 + bend.dx, y: (b0.y + tip.y) / 2 + bend.dy))
            p.addQuadCurve(to: b1, control: CGPoint(x: (tip.x + b1.x) / 2 + bend.dx * 0.5, y: (tip.y + b1.y) / 2 + bend.dy * 0.5))
        } else {
            p.addLine(to: tip); p.addLine(to: b1)
        }
    }

    /// Rounded rectangle (clockwise in y-down space) with an optional tail joined into the outline (no inner seam).
    static func box(_ p: CGMutablePath, _ r: CGRect, _ rr: CGFloat, _ tail: TextBubbleTail?, _ em: CGFloat) {
        let tl = tail.map { CGFloat($0.length) * em } ?? 0
        // tail on a horizontal edge: base centre x, base width, tip x
        func horizontal(_ t: TextBubbleTail) -> (cx: CGFloat, tw: CGFloat, tipX: CGFloat) {
            let tw = min(tailWidth(t, r, em, vertical: false), max(r.width - 2 * rr, 0))
            let lean = cornerLean(t.side)
            let cx: CGFloat
            if let pos = t.position {
                cx = r.minX + rr + tw / 2 + CGFloat(pos) * max(r.width - 2 * rr - tw, 0)
            } else if lean < 0 {
                cx = r.minX + max(rr, r.width * 0.2) + tw / 2
            } else if lean > 0 {
                cx = r.maxX - max(rr, r.width * 0.2) - tw / 2
            } else { cx = r.midX }
            return (cx, tw, cx + (lean * 0.8 + CGFloat(t.lean)) * tw)
        }
        func vertical(_ t: TextBubbleTail) -> (cy: CGFloat, tw: CGFloat, tipY: CGFloat) {
            let tw = min(tailWidth(t, r, em, vertical: true), max(r.height - 2 * rr, 0))
            let cy = t.position.map { r.minY + rr + tw / 2 + CGFloat($0) * max(r.height - 2 * rr - tw, 0) } ?? r.midY
            return (cy, tw, cy + (0.2 + CGFloat(t.lean)) * tw)
        }
        let side = tail?.side
        let kind = tail?.kind ?? .point
        p.move(to: CGPoint(x: r.minX + rr, y: r.minY))
        if let t = tail, side == .top || side == .topLeft || side == .topRight {
            let h = horizontal(t)
            tailEdges(p, CGPoint(x: h.cx - h.tw / 2, y: r.minY), CGPoint(x: h.tipX, y: r.minY - tl), CGPoint(x: h.cx + h.tw / 2, y: r.minY), kind,
                      bend: CGVector(dx: (h.tipX - h.cx) * 0.6, dy: 0))
        }
        p.addLine(to: CGPoint(x: r.maxX - rr, y: r.minY))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY + rr), radius: rr)
        if let t = tail, side == .right {
            let v = vertical(t)
            tailEdges(p, CGPoint(x: r.maxX, y: v.cy - v.tw / 2), CGPoint(x: r.maxX + tl, y: v.tipY), CGPoint(x: r.maxX, y: v.cy + v.tw / 2), kind,
                      bend: CGVector(dx: 0, dy: v.tw * 0.5))
        }
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - rr))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX - rr, y: r.maxY), radius: rr)
        if let t = tail, side == .bottom || side == .bottomLeft || side == .bottomRight {
            let h = horizontal(t)
            tailEdges(p, CGPoint(x: h.cx + h.tw / 2, y: r.maxY), CGPoint(x: h.tipX, y: r.maxY + tl), CGPoint(x: h.cx - h.tw / 2, y: r.maxY), kind,
                      bend: CGVector(dx: (h.tipX - h.cx) * 0.6, dy: 0))
        }
        p.addLine(to: CGPoint(x: r.minX + rr, y: r.maxY))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY - rr), radius: rr)
        if let t = tail, side == .left {
            let v = vertical(t)
            tailEdges(p, CGPoint(x: r.minX, y: v.cy + v.tw / 2), CGPoint(x: r.minX - tl, y: v.tipY), CGPoint(x: r.minX, y: v.cy - v.tw / 2), kind,
                      bend: CGVector(dx: 0, dy: v.tw * 0.5))
        }
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + rr))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX + rr, y: r.minY), radius: rr)
        p.closeSubpath()
    }

    static func ellipsePoint(_ r: CGRect, _ a: CGFloat) -> CGPoint {
        CGPoint(x: r.midX + r.width / 2 * cos(a), y: r.midY + r.height / 2 * sin(a))
    }

    /// Direction a tail at angle `a` points to (the side's own direction, not the ellipse radius: on a wide shape a
    /// bottom-left tail still points down-left instead of almost sideways).
    static func outward(_ r: CGRect, _ a: CGFloat) -> CGVector { CGVector(dx: cos(a), dy: sin(a)) }

    /// Tail tip for a tail whose base is centred on `m` (pointing along `u`): length `tl`, leaning along the side.
    static func tip(_ m: CGPoint, _ u: CGVector, _ t: TextBubbleTail, tw: CGFloat, tl: CGFloat) -> CGPoint {
        let side = CGVector(dx: -u.dy, dy: u.dx)   // along the edge
        let lean = CGFloat(t.lean)
        return CGPoint(x: m.x + u.dx * tl + side.dx * lean * tw, y: m.y + u.dy * tl + side.dy * lean * tw)
    }

    static func oval(_ p: CGMutablePath, _ r: CGRect, _ tail: TextBubbleTail?, _ em: CGFloat) {
        guard let t = tail else { p.addEllipse(in: r); return }
        let a = angle(t)
        let avg = max((r.width + r.height) / 4, 1)
        let tw = min(CGFloat(t.width) * em, avg * 0.7)
        let half = min(tw / 2 / avg, 0.35)
        let m = ellipsePoint(r, a)
        let u = outward(r, a)
        let tipPt = tip(m, u, t, tw: tw, tl: CGFloat(t.length) * em)
        let e = CGAffineTransform(translationX: r.midX, y: r.midY).scaledBy(x: r.width / 2, y: r.height / 2)
        let start = ellipsePoint(r, a + half)
        p.move(to: start)
        p.addArc(center: .zero, radius: 1, startAngle: a + half, endAngle: a - half + 2 * .pi, clockwise: false, transform: e)
        let b0 = ellipsePoint(r, a - half)
        let bend = CGVector(dx: (tipPt.x - m.x - u.dx * CGFloat(t.length) * em) * 0.6, dy: (tipPt.y - m.y - u.dy * CGFloat(t.length) * em) * 0.6)
        tailEdges(p, b0, tipPt, start, t.kind, bend: bend)
        p.closeSubpath()
    }

    static func cloud(_ p: CGMutablePath, _ r: CGRect, bumps: Int, jitter: Double, tail: TextBubbleTail?, em: CGFloat) {
        let n = max(bumps, 5)
        let c = CGPoint(x: r.midX, y: r.midY)
        let pts = (0..<n).map { i in ellipsePoint(r, CGFloat(i) / CGFloat(n) * 2 * .pi) }
        // bump that carries the tail: the one whose middle is closest to the tail angle
        var tailBump = -1
        if let t = tail {
            let a = angle(t)
            var best = CGFloat.infinity
            for i in 0..<n {
                let mid = (CGFloat(i) + 0.5) / CGFloat(n) * 2 * .pi
                let d = abs(atan2(sin(mid - a), cos(mid - a)))
                if d < best { best = d; tailBump = i }
            }
        }
        p.move(to: pts[0])
        for i in 0..<n {
            let a = pts[i], b = pts[(i + 1) % n]
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let out = CGPoint(x: mid.x - c.x, y: mid.y - c.y)
            let len = max(hypot(out.x, out.y), 1e-6)
            let k = 1 + CGFloat(jitter) * (CGFloat(glyphRandom(i, seed: 41)) - 0.5) * 1.2
            let bulge = hypot(b.x - a.x, b.y - a.y) * 0.55 * k
            if i == tailBump, let t = tail {
                let n = CGVector(dx: out.x / len, dy: out.y / len)
                let u = outward(r, angle(t))
                let m = CGPoint(x: mid.x + n.dx * bulge * 0.5, y: mid.y + n.dy * bulge * 0.5)
                let tw = hypot(b.x - a.x, b.y - a.y)
                let tp = tip(m, u, t, tw: tw * 0.5, tl: CGFloat(t.length) * em)
                tailEdges(p, a, tp, b, t.kind, bend: CGVector(dx: (tp.x - m.x) * 0.2, dy: (tp.y - m.y) * 0.2))   // ends on b
                continue
            }
            p.addQuadCurve(to: b, control: CGPoint(x: mid.x + out.x / len * bulge, y: mid.y + out.y / len * bulge))
        }
        p.closeSubpath()
    }

    static func burst(_ p: CGMutablePath, _ r: CGRect, spikes: Int, depth: Double, jitter: Double, tail: TextBubbleTail?, em: CGFloat) {
        let n = max(spikes, 5) * 2
        let c = CGPoint(x: r.midX, y: r.midY)
        let rx = r.width / 2 * 1.08, ry = r.height / 2 * 1.08
        var tailSpike = -1
        if let t = tail {
            let a = angle(t)
            var best = CGFloat.infinity
            for i in stride(from: 0, to: n, by: 2) {
                let ai = CGFloat(i) / CGFloat(n) * 2 * .pi - .pi / 2
                let d = abs(atan2(sin(ai - a), cos(ai - a)))
                if d < best { best = d; tailSpike = i }
            }
        }
        for i in 0..<n {
            let a = CGFloat(i) / CGFloat(n) * 2 * .pi - .pi / 2
            var k: CGFloat = 1
            if i % 2 == 0 {
                let j = 1 + CGFloat(jitter) * (CGFloat(glyphRandom(i, seed: 43)) - 0.5) * 1.4
                k = 1 + CGFloat(depth) * max(j, 0.2)
            }
            var pt = CGPoint(x: c.x + rx * k * cos(a), y: c.y + ry * k * sin(a))
            if i == tailSpike, let t = tail {
                let u = outward(r, angle(t))
                pt = CGPoint(x: pt.x + u.dx * CGFloat(t.length) * em, y: pt.y + u.dy * CGFloat(t.length) * em)
            }
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
    }

    /// Thought-bubble dots: three shrinking circles leaving the shape towards the tail side.
    static func dots(_ p: CGMutablePath, _ s: TextBubbleStyle, _ r: CGRect, _ t: TextBubbleTail, _ em: CGFloat) {
        let a = angle(t)
        let u = outward(r, a)
        var start: CGPoint
        switch s.family {
        case .box, .pill:
            // the point of the rectangle edge in that direction
            let k = min(r.width / 2 / max(abs(u.dx), 1e-6), r.height / 2 / max(abs(u.dy), 1e-6))
            start = CGPoint(x: r.midX + u.dx * k, y: r.midY + u.dy * k)
        case .cloud:
            let q = ellipsePoint(r, a)
            let chord = .pi * (r.width + r.height) / 2 / CGFloat(max(s.bumps, 5))
            start = CGPoint(x: q.x + u.dx * chord * 0.3, y: q.y + u.dy * chord * 0.3)
        default:
            start = ellipsePoint(r, a)
        }
        let scale = CGFloat(t.length / TextBubbleTail.defaultLength)
        let sizes: [CGFloat] = [0.34, 0.22, 0.13].map { $0 * em * max(scale, 0.3) }
        let lean = cornerLean(t.side) * 0.35
        var d: CGFloat = em * 0.1
        for sz in sizes {
            d += sz / 2
            let side = CGVector(dx: -u.dy, dy: u.dx)
            let sgn: CGFloat = side.dx >= 0 ? 1 : -1
            let cpt = CGPoint(x: start.x + u.dx * d + side.dx * lean * sgn * d, y: start.y + u.dy * d + side.dy * lean * sgn * d)
            p.addEllipse(in: CGRect(x: cpt.x - sz / 2, y: cpt.y - sz / 2, width: sz, height: sz))
            d += sz / 2 + em * 0.08
        }
    }

    // MARK: Paint

    /// Neon parameters of a bubble outline: tube colour = outline colour, tube = outline width (thickness × 3).
    static func neonStyle(_ o: TextBubbleOutline) -> TextNeonStyle? {
        guard var n = o.neon else { return nil }
        n.color = o.color
        n.thickness = o.width / 3
        return n
    }

    /// The outline as a line path (dashes applied).
    static func linePath(_ path: CGPath, _ o: TextBubbleOutline, em: CGFloat) -> CGPath {
        let w = CGFloat(o.width) * em
        switch o.dash {
        case .solid: return path
        case .dashed: return path.copy(dashingWithPhase: 0, lengths: [w * 3, w * 2])
        case .dotted: return path.copy(dashingWithPhase: 0, lengths: [w * 0.001, w * 2])
        }
    }

    /// Filled silhouette of the outline (neon tube, shadows).
    static func tube(_ path: CGPath, _ o: TextBubbleOutline, em: CGFloat) -> CGPath {
        linePath(path, o, em: em).copy(strokingWithWidth: CGFloat(o.width) * em, lineCap: o.dash == .dashed ? .butt : .round,
                                       lineJoin: .round, miterLimit: 4)
    }

    /// Scene-space AABB of everything the bubble paints (outline, glow, shadow, tail), before the item transform.
    static func bounds(_ s: TextBubbleStyle, rect: CGRect, em: CGFloat) -> CGRect {
        let p = path(s, rect: rect, em: em)
        let ow = s.outline.map { $0.width > 0 ? CGFloat($0.width) * em : 0 } ?? 0
        var pad = ow + 1   // v1: stroke width + 1 px
        if let o = s.outline, let n = neonStyle(o) {
            pad = ow / 2 + NeonPainter.reach(NeonPainter.Params(n, em: em)) + 2
        }
        var b = p.boundingBoxOfPath.insetBy(dx: -pad, dy: -pad)
        if let sh = s.shadow {
            let d = shadowOffset(sh, em: em)
            b = b.union(b.offsetBy(dx: d.x, dy: d.y).insetBy(dx: -CGFloat(sh.blurEm) * em * 1.5 - 1, dy: -CGFloat(sh.blurEm) * em * 1.5 - 1))
        }
        return b
    }

    static func shadowOffset(_ sh: TextBubbleShadow, em: CGFloat) -> CGPoint {
        let a = sh.angleDegrees * .pi / 180
        return CGPoint(x: CGFloat(cos(a) * sh.offsetEm) * em, y: CGFloat(sin(a) * sh.offsetEm) * em)
    }

    static func draw(_ s: TextBubbleStyle, rect: CGRect, em: CGFloat, part: Part, itemTransform M: CGAffineTransform, in ctx: CGContext) {
        let path = path(s, rect: rect, em: em)
        let neon = s.outline.flatMap(neonStyle)
        let params = neon.map { NeonPainter.Params($0, em: em) }
        let tubePath = s.outline.flatMap { o in neon != nil ? tube(path, o, em: em) : nil }
        let body = part == .whole || part == .body
        // shadow
        if body, let sh = s.shadow { drawShadow(sh, path: path, s: s, tube: tubePath, params: params, em: em, M: M, in: ctx) }
        // neon glow
        if part == .whole || part == .glow, let t = tubePath, let pr = params { NeonPainter.drawHalo(t, pr, in: ctx) }
        // fill
        if body, s.fill.a > 0 { ctx.addPath(path); ctx.setFillColor(TextPainter.cg(s.fill)); ctx.fillPath() }
        // outline
        guard let o = s.outline, o.width > 0 else { return }
        if let t = tubePath, let pr = params {
            if part == .whole || part == .tube { NeonPainter.drawTube(t, pr, in: ctx) }
        } else if body {
            ctx.saveGState()
            ctx.addPath(path); ctx.setStrokeColor(TextPainter.cg(o.color)); ctx.setLineWidth(CGFloat(o.width) * em); ctx.setLineJoin(.round)
            let w = CGFloat(o.width) * em
            switch o.dash {
            case .solid: break
            case .dashed: ctx.setLineDash(phase: 0, lengths: [w * 3, w * 2])
            case .dotted: ctx.setLineCap(.round); ctx.setLineDash(phase: 0, lengths: [w * 0.001, w * 2])
            }
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    /// Soft = blurred drop shadow; hard = solid offset copy (comic). Cast by the fill and the outline; a neon outline
    /// with a hard shadow casts a second tube in the shadow colour (double-tube look).
    static func drawShadow(_ sh: TextBubbleShadow, path: CGPath, s: TextBubbleStyle, tube: CGPath?, params: NeonPainter.Params?,
                           em: CGFloat, M: CGAffineTransform, in ctx: CGContext) {
        let d = shadowOffset(sh, em: em)
        let silhouette = CGMutablePath()
        if s.fill.a > 0.001 { silhouette.addPath(path) }
        if let t = tube { silhouette.addPath(t) }
        else if let o = s.outline, o.width > 0 {
            silhouette.addPath(linePath(path, o, em: em).copy(strokingWithWidth: CGFloat(o.width) * em, lineCap: o.dash == .dotted ? .round : .butt,
                                                              lineJoin: .round, miterLimit: 10))
        }
        guard !silhouette.isEmpty else { return }
        let l = TextPainter.toLocal(d, M)
        if sh.kind == .hard, let t = tube, var pr = params {
            pr.color = sh.color
            ctx.saveGState(); ctx.translateBy(x: l.x, y: l.y)
            NeonPainter.drawHalo(t, pr, in: ctx); NeonPainter.drawTube(t, pr, in: ctx)
            ctx.restoreGState()
            return
        }
        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        if sh.kind == .hard {
            ctx.saveGState(); ctx.translateBy(x: l.x, y: l.y)
            ctx.addPath(silhouette); ctx.setFillColor(TextPainter.cg(sh.color)); ctx.fillPath()
            ctx.restoreGState()
        } else {
            ctx.setShadow(offset: CGSize(width: d.x, height: -d.y), blur: CGFloat(sh.blurEm) * em, color: TextPainter.cg(sh.color))
            ctx.addPath(silhouette); ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fillPath()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
        }
        // only the part outside the bubble shows (the shadow never darkens a see-through fill)
        ctx.setBlendMode(.clear)
        ctx.addPath(silhouette); ctx.fillPath()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}

/// Outline of a bubble family fitted in `size` (y down), for the inspector's Shape icons (same geometry as the render).
public enum BubbleIcons {
    public static func path(_ f: TextBubbleStyle.Family, size: CGSize) -> CGPath {
        var s = TextBubbleStyle(family: f, fill: .white)
        s.cornerRadius = 0.25
        let em = size.height * 0.22
        let inset: CGFloat
        switch f {
        case .burst: inset = size.height * 0.2
        case .banner, .ribbon, .tag, .hexagon, .arrow: inset = size.height * 0.24
        default: inset = size.height * 0.12
        }
        var r = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: size.height * 0.24)
        if f == .burst { r = r.insetBy(dx: 0, dy: -size.height * 0.02) }
        return BubblePainter.path(s, rect: r, em: em)
    }
}
