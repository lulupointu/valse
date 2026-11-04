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
        guard !s.containsText, s.jitter == 0, s.family != .circle else { return false }
        guard let t = s.tail else { return true }
        guard t.position == nil, t.tipOffset == nil, t.lean == 0, t.length == TextBubbleTail.defaultLength, t.width == TextBubbleTail.defaultWidth else { return false }
        switch s.family {
        case .box: return t.kind == .point && BubbleTail(rawValue: t.side.rawValue) != nil
        case .oval: return t.kind == .dots && t.side == .bottomLeft
        default: return false
        }
    }

    /// Rectangle of the shape: the padded text rect, grown for oval / cloud / burst into the ellipse through its
    /// corners (padding 0 = the shape just touches the text box): the same margin m on both axes
    /// (a²/(a+m)² + b²/(b+m)² = 1, tighter than the √2 minimum-area fit on wide text), aspect capped at 3:1.
    /// Circle: centred on the text box, radius = half its diagonal + max(H, V) padding (so negative padding tightens
    /// it too), ≥ 0.2 em. `r` is the padded rect, the text box is recovered from it.
    static func shapeRect(_ s: TextBubbleStyle, _ r: CGRect, em: CGFloat = 1) -> CGRect {
        if s.family == .circle {
            let px = CGFloat(s.padding.x) * em, py = CGFloat(s.padding.y) * em
            let a = max(r.width / 2 - px, 0), b = max(r.height / 2 - py, 0)
            let rad = max(hypot(a, b) + max(px, py), em * 0.2, 0.5)
            return CGRect(x: r.midX - rad, y: r.midY - rad, width: rad * 2, height: rad * 2)
        }
        guard s.containsText, s.family.canContain else { return r }
        let e = containingEllipse(a: max(r.width / 2, 0.5), b: max(r.height / 2, 0.5))
        return CGRect(x: r.midX - e.rx, y: r.midY - e.ry, width: e.rx * 2, height: e.ry * 2)
    }

    /// Radii of the ellipse through the corners (±a, ±b) with equal margins, aspect ≤ 3:1.
    static func containingEllipse(a: CGFloat, b: CGFloat) -> (rx: CGFloat, ry: CGFloat) {
        var lo: CGFloat = 0, hi = max(a, b)   // f(0) = 2 > 1, f(max(a, b)) ≤ 1/4 + 1/4 < 1
        for _ in 0..<40 {
            let m = (lo + hi) / 2
            if a * a / ((a + m) * (a + m)) + b * b / ((b + m) * (b + m)) > 1 { lo = m } else { hi = m }
        }
        var rx = a + hi, ry = b + hi
        let cap: CGFloat = 3
        // still through the corners: rx = cap·ry ⇒ a²/(cap·ry)² + b²/ry² = 1
        if rx > cap * ry { ry = sqrt(a * a / (cap * cap) + b * b); rx = cap * ry }
        else if ry > cap * rx { rx = sqrt(b * b / (cap * cap) + a * a); ry = cap * rx }
        return (rx, ry)
    }

    static func path(_ s: TextBubbleStyle, rect r0: CGRect, em: CGFloat) -> CGPath {
        if isClassic(s) { return BubblePaths.path(TextBubbleDescriptor.shape(of: s), rect: r0, em: em) }
        let r = shapeRect(s, r0, em: em)
        let tail = s.family.hasTail ? s.tail : nil
        let joined = tail.flatMap { $0.kind == .dots ? nil : $0 }
        let aim = tail.flatMap { aimPoint($0, r0, em) }
        let p = CGMutablePath()
        switch s.family {
        case .box, .pill:
            box(p, r, boxRadius(s, r, joined, em, aim: aim), joined, em, aim: aim)
        case .oval, .circle:
            oval(p, r, joined, em, aim: aim)
        case .cloud:
            cloud(p, r, bumps: s.bumps, jitter: s.jitter, tail: joined, em: em, aim: aim)
        case .burst:
            burst(p, r, spikes: s.spikes, depth: s.depth, jitter: s.jitter, tail: joined, em: em, aim: aim)
        default:
            p.addPath(BubblePaths.path(TextBubbleDescriptor.shape(of: s), rect: r, em: em))
        }
        if let t = tail, t.kind == .dots { dots(p, s, r, t, em, aim: aim) }
        return p
    }

    /// Corner radius of a box / pill shape `r` (`tail`: joined tail, `aim`: its free tip).
    static func boxRadius(_ s: TextBubbleStyle, _ r: CGRect, _ tail: TextBubbleTail?, _ em: CGFloat, aim: CGPoint?) -> CGFloat {
        var rr = s.family == .pill ? min(r.height, r.width) / 2 : min(CGFloat(s.cornerRadius) * em, r.height / 2, r.width / 2)
        // the corners never cut into the text: a radius r cuts r·(1 − 1/√2) into the corner, keep that ≤ padding
        // (a 6-line pill becomes a rounded box instead of a capsule that clips the first and last lines)
        // (floor 0.12 em: at padding ≤ 0 a pill stays rounded instead of turning into a sharp box)
        rr = min(rr, CGFloat(max(min(s.padding.x, s.padding.y), 0.12)) * em / (1 - 1 / sqrt(2)))
        if let t = tail, aim.map({ boxEdge(r, $0) % 2 == 1 }) ?? (t.side == .left || t.side == .right) {
            rr = min(rr, max((r.height - tailWidth(t, r, em, vertical: true)) / 2, 0))   // room for the tail base between the corners
        }
        return max(rr, 0)
    }

    // MARK: Free tail tip (TX-BUBBLE-TAIL)

    /// Where a dragged tail points (scene space): the text box centre + `tipOffset` em. nil = placed by its side.
    static func aimPoint(_ t: TextBubbleTail, _ r0: CGRect, _ em: CGFloat) -> CGPoint? {
        t.tipOffset.map { CGPoint(x: r0.midX + CGFloat($0.x) * em, y: r0.midY + CGFloat($0.y) * em) }
    }

    /// Parametric angle of the ellipse inscribed in `r` whose point lies towards `a` (the base of a free tail).
    static func paramAngle(_ r: CGRect, _ a: CGPoint) -> CGFloat {
        atan2((a.y - r.midY) / max(r.height / 2, 1e-6), (a.x - r.midX) / max(r.width / 2, 1e-6))
    }

    /// Direction from a tail base `m` to the aimed point (the tip goes wherever it is dropped, even back over the
    /// shape); `n` (outward) when the aim is on the base itself.
    static func freeDirection(_ m: CGPoint, _ a: CGPoint, _ n: CGVector) -> CGVector {
        let d = CGVector(dx: a.x - m.x, dy: a.y - m.y)
        let l = hypot(d.dx, d.dy)
        guard l > 1e-6 else { return n }
        return CGVector(dx: d.dx / l, dy: d.dy / l)
    }

    /// Tip of a free tail: `len` from its base `m` towards the aimed point.
    static func freeTip(_ m: CGPoint, _ a: CGPoint, _ len: CGFloat, _ n: CGVector) -> CGPoint {
        let u = freeDirection(m, a, n), k = max(len, 0)
        return CGPoint(x: m.x + u.dx * k, y: m.y + u.dy * k)
    }

    /// Edge of the rectangle nearest to `a`: 0 top, 1 right, 2 bottom, 3 left (ties: the edge `a` is further beyond).
    static func boxEdge(_ r: CGRect, _ a: CGPoint) -> Int {
        let cx = min(max(a.x, r.minX), r.maxX), cy = min(max(a.y, r.minY), r.maxY)
        let seg = [hypot(a.x - cx, a.y - r.minY), hypot(a.x - r.maxX, a.y - cy), hypot(a.x - cx, a.y - r.maxY), hypot(a.x - r.minX, a.y - cy)]
        let beyond = [r.minY - a.y, a.x - r.maxX, a.y - r.maxY, r.minX - a.x]
        return (0..<4).min { seg[$0] - beyond[$0] * 1e-3 < seg[$1] - beyond[$1] * 1e-3 }!
    }

    /// Pad side whose direction is nearest to `angle` (y down, 0 = right).
    static func nearestSide(_ angle: CGFloat) -> TextBubbleTail.Side {
        let sides: [(TextBubbleTail.Side, CGFloat)] = [(.right, 0), (.bottomRight, 60), (.bottom, 90), (.bottomLeft, 120), (.left, 180),
                                                       (.topLeft, 240), (.top, 270), (.topRight, 300)]
        let deg = angle * 180 / .pi
        return sides.min { a, b in
            abs(remainder(deg - a.1, 360)) < abs(remainder(deg - b.1, 360))
        }!.0
    }

    /// Base (on the outline) and tip of the tail, scene space before the item transform. nil = no tail drawn.
    static func tailAnchor(_ s: TextBubbleStyle, rect r0: CGRect, em: CGFloat) -> (base: CGPoint, tip: CGPoint)? {
        guard s.family.hasTail, let t = s.tail else { return nil }
        if isClassic(s) {
            let r = r0, w = r.width, h = r.height
            switch TextBubbleDescriptor.shape(of: s) {
            case .speech(let radius, let tail):
                let rr = min(CGFloat(radius) * em, h / 2, w / 2)
                let tw = min(w * 0.18, em * 0.9), tl = min(h * 0.6, em * 0.8)
                switch tail {
                case .top: return (CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.midX, y: r.minY - tl))
                case .right: return (CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.maxX + tl, y: r.midY + tw * 0.2))
                case .left: return (CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.minX - tl, y: r.midY + tw * 0.2))
                case .bottom: return (CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY + tl))
                case .bottomRight:
                    let x = r.maxX - max(rr, w * 0.2)
                    return (CGPoint(x: x - tw / 2, y: r.maxY), CGPoint(x: x + tw * 0.3, y: r.maxY + tl))
                case .bottomLeft:
                    let x = r.minX + max(rr, w * 0.2)
                    return (CGPoint(x: x + tw / 2, y: r.maxY), CGPoint(x: x - tw * 0.3, y: r.maxY + tl))
                case .none: return nil
                }
            case .thought:
                let d1 = h * 0.28, d2 = h * 0.16
                return (CGPoint(x: r.minX + w * 0.18 + d1 / 2, y: r.maxY), CGPoint(x: r.minX + w * 0.1 + d2 / 2, y: r.maxY + h * 0.32 + d2 / 2))
            default: return nil
            }
        }
        let r = shapeRect(s, r0, em: em)
        let aim = aimPoint(t, r0, em)
        if t.kind == .dots {
            let d = dotsLayout(s, r, t, em, aim: aim)
            guard let last = d.dots.last else { return nil }
            return (d.start, last.center)
        }
        switch s.family {
        case .box, .pill:
            let b = boxTail(r, boxRadius(s, r, t, em, aim: aim), t, em, aim: aim)
            return (CGPoint(x: (b.b0.x + b.b1.x) / 2, y: (b.b0.y + b.b1.y) / 2), b.tip)
        case .oval, .circle:
            let o = ovalTail(r, t, em, aim: aim)
            return (o.m, o.tip)
        case .cloud:
            let c = cloudTail(r, bumps: s.bumps, jitter: s.jitter, t, em, aim: aim)
            return (c.m, c.tip)
        case .burst:
            let b = burstTail(r, spikes: s.spikes, depth: s.depth, jitter: s.jitter, t, em, aim: aim)
            return (b.base, b.tip)
        default: return nil
        }
    }

    /// The tail after its tip is dragged to `target` (scene space before the item transform): a free tip aimed there,
    /// `length` = its distance from the re-anchored base (so the tip lands on `target`), the pad side nearest to it.
    static func draggedTail(_ s: TextBubbleStyle, rect r0: CGRect, em: CGFloat, to target: CGPoint) -> TextBubbleTail? {
        guard s.family.hasTail, var t = s.tail, em > 0 else { return nil }
        t.side = nearestSide(atan2(target.y - r0.midY, target.x - r0.midX))   // clears the old free tip
        t.tipOffset = Vec2(Double((target.x - r0.midX) / em), Double((target.y - r0.midY) / em))
        var probe = s
        t.length = 1
        probe.tail = t
        guard let a = tailAnchor(probe, rect: r0, em: em) else { return nil }
        let d = Double(hypot(target.x - a.base.x, target.y - a.base.y) / em)
        // dots: the last dot's centre is 0.26 + 0.625 × scale em from the outline (see `dotsLayout`)
        t.length = t.kind == .dots ? max((d - 0.26) / 0.625, 0.3) * TextBubbleTail.defaultLength : d
        t.length = min(max(t.length, 0.05), maxDragLength)
        return t
    }

    /// Longest tail a drag makes, em (a sanity bound: far beyond any canvas).
    static let maxDragLength = 40.0

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
    static func box(_ p: CGMutablePath, _ r: CGRect, _ rr: CGFloat, _ tail: TextBubbleTail?, _ em: CGFloat, aim: CGPoint? = nil) {
        let bt = tail.map { boxTail(r, rr, $0, em, aim: aim) }
        let kind = tail?.kind ?? .point
        p.move(to: CGPoint(x: r.minX + rr, y: r.minY))
        if let b = bt, b.edge == 0 { tailEdges(p, b.b0, b.tip, b.b1, kind, bend: b.bend) }
        p.addLine(to: CGPoint(x: r.maxX - rr, y: r.minY))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY + rr), radius: rr)
        if let b = bt, b.edge == 1 { tailEdges(p, b.b0, b.tip, b.b1, kind, bend: b.bend) }
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - rr))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX - rr, y: r.maxY), radius: rr)
        if let b = bt, b.edge == 2 { tailEdges(p, b.b0, b.tip, b.b1, kind, bend: b.bend) }
        p.addLine(to: CGPoint(x: r.minX + rr, y: r.maxY))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY - rr), radius: rr)
        if let b = bt, b.edge == 3 { tailEdges(p, b.b0, b.tip, b.b1, kind, bend: b.bend) }
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + rr))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX + rr, y: r.minY), radius: rr)
        p.closeSubpath()
    }

    /// A box tail: the edge it leaves from (0 top, 1 right, 2 bottom, 3 left), its base corners in outline order, tip
    /// and curve bend.
    struct BoxTail { let edge: Int; let b0: CGPoint; let tip: CGPoint; let b1: CGPoint; let bend: CGVector }

    static func boxTail(_ r: CGRect, _ rr: CGFloat, _ t: TextBubbleTail, _ em: CGFloat, aim: CGPoint?) -> BoxTail {
        let tl = CGFloat(t.length) * em
        if let a = aim {   // free tip: base on the nearest edge, under the aimed point (between the corners)
            let e = boxEdge(r, a), vert = e % 2 == 1
            let tw = min(tailWidth(t, r, em, vertical: vert), max((vert ? r.height : r.width) - 2 * rr, 0))
            let lo = (vert ? r.minY : r.minX) + rr + tw / 2, hi = (vert ? r.maxY : r.maxX) - rr - tw / 2
            let c = lo <= hi ? min(max(vert ? a.y : a.x, lo), hi) : (vert ? r.midY : r.midX)
            let n = [CGVector(dx: 0, dy: -1), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: 1), CGVector(dx: -1, dy: 0)][e]
            let m = [CGPoint(x: c, y: r.minY), CGPoint(x: r.maxX, y: c), CGPoint(x: c, y: r.maxY), CGPoint(x: r.minX, y: c)][e]
            let tip = freeTip(m, a, tl, n)
            switch e {
            case 0: return BoxTail(edge: 0, b0: CGPoint(x: c - tw / 2, y: r.minY), tip: tip, b1: CGPoint(x: c + tw / 2, y: r.minY),
                                   bend: CGVector(dx: (tip.x - c) * 0.6, dy: 0))
            case 1: return BoxTail(edge: 1, b0: CGPoint(x: r.maxX, y: c - tw / 2), tip: tip, b1: CGPoint(x: r.maxX, y: c + tw / 2),
                                   bend: CGVector(dx: 0, dy: (tip.y - c) * 0.6))
            case 2: return BoxTail(edge: 2, b0: CGPoint(x: c + tw / 2, y: r.maxY), tip: tip, b1: CGPoint(x: c - tw / 2, y: r.maxY),
                                   bend: CGVector(dx: (tip.x - c) * 0.6, dy: 0))
            default: return BoxTail(edge: 3, b0: CGPoint(x: r.minX, y: c + tw / 2), tip: tip, b1: CGPoint(x: r.minX, y: c - tw / 2),
                                    bend: CGVector(dx: 0, dy: (tip.y - c) * 0.6))
            }
        }
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
        switch t.side {
        case .top, .topLeft, .topRight:
            let h = horizontal(t)
            return BoxTail(edge: 0, b0: CGPoint(x: h.cx - h.tw / 2, y: r.minY), tip: CGPoint(x: h.tipX, y: r.minY - tl),
                           b1: CGPoint(x: h.cx + h.tw / 2, y: r.minY), bend: CGVector(dx: (h.tipX - h.cx) * 0.6, dy: 0))
        case .right:
            let v = vertical(t)
            return BoxTail(edge: 1, b0: CGPoint(x: r.maxX, y: v.cy - v.tw / 2), tip: CGPoint(x: r.maxX + tl, y: v.tipY),
                           b1: CGPoint(x: r.maxX, y: v.cy + v.tw / 2), bend: CGVector(dx: 0, dy: v.tw * 0.5))
        case .bottom, .bottomLeft, .bottomRight:
            let h = horizontal(t)
            return BoxTail(edge: 2, b0: CGPoint(x: h.cx + h.tw / 2, y: r.maxY), tip: CGPoint(x: h.tipX, y: r.maxY + tl),
                           b1: CGPoint(x: h.cx - h.tw / 2, y: r.maxY), bend: CGVector(dx: (h.tipX - h.cx) * 0.6, dy: 0))
        case .left:
            let v = vertical(t)
            return BoxTail(edge: 3, b0: CGPoint(x: r.minX, y: v.cy + v.tw / 2), tip: CGPoint(x: r.minX - tl, y: v.tipY),
                           b1: CGPoint(x: r.minX, y: v.cy - v.tw / 2), bend: CGVector(dx: 0, dy: v.tw * 0.5))
        }
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

    static func oval(_ p: CGMutablePath, _ r: CGRect, _ tail: TextBubbleTail?, _ em: CGFloat, aim: CGPoint? = nil) {
        guard let t = tail else { p.addEllipse(in: r); return }
        let o = ovalTail(r, t, em, aim: aim)
        let a = o.a, half = o.half
        let e = CGAffineTransform(translationX: r.midX, y: r.midY).scaledBy(x: r.width / 2, y: r.height / 2)
        let start = ellipsePoint(r, a + half)
        p.move(to: start)
        p.addArc(center: .zero, radius: 1, startAngle: a + half, endAngle: a - half + 2 * .pi, clockwise: false, transform: e)
        let b0 = ellipsePoint(r, a - half)
        tailEdges(p, b0, o.tip, start, t.kind, bend: o.bend)
        p.closeSubpath()
    }

    /// Oval / circle tail: base angle, half base width (radians), base centre, tip, curve bend.
    static func ovalTail(_ r: CGRect, _ t: TextBubbleTail, _ em: CGFloat, aim: CGPoint?)
        -> (a: CGFloat, half: CGFloat, m: CGPoint, tip: CGPoint, bend: CGVector) {
        let a = aim.map { paramAngle(r, $0) } ?? angle(t)
        let avg = max((r.width + r.height) / 4, 1)
        let tw = min(CGFloat(t.width) * em, avg * 0.7)
        let half = min(tw / 2 / avg, 0.35)
        let m = ellipsePoint(r, a)
        let u = outward(r, a)
        if let aim {
            let tipPt = freeTip(m, aim, CGFloat(t.length) * em, u)
            let d = hypot(tipPt.x - m.x, tipPt.y - m.y)   // bend = how far the tip leaves the straight-out direction
            return (a, half, m, tipPt, CGVector(dx: (tipPt.x - m.x - u.dx * d) * 0.6, dy: (tipPt.y - m.y - u.dy * d) * 0.6))
        }
        let tipPt = tip(m, u, t, tw: tw, tl: CGFloat(t.length) * em)
        let bend = CGVector(dx: (tipPt.x - m.x - u.dx * CGFloat(t.length) * em) * 0.6, dy: (tipPt.y - m.y - u.dy * CGFloat(t.length) * em) * 0.6)
        return (a, half, m, tipPt, bend)
    }

    /// One bump of a cloud: its two outline points, chord middle, outward vector (and its length), bulge.
    static func cloudBump(_ r: CGRect, _ pts: [CGPoint], _ i: Int, jitter: Double)
        -> (a: CGPoint, b: CGPoint, mid: CGPoint, out: CGPoint, len: CGFloat, bulge: CGFloat) {
        let n = pts.count
        let c = CGPoint(x: r.midX, y: r.midY)
        let a = pts[i], b = pts[(i + 1) % n]
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let out = CGPoint(x: mid.x - c.x, y: mid.y - c.y)
        let len = max(hypot(out.x, out.y), 1e-6)
        let k = 1 + CGFloat(jitter) * (CGFloat(glyphRandom(i, seed: 41)) - 0.5) * 1.2
        let bulge = hypot(b.x - a.x, b.y - a.y) * 0.55 * k
        return (a, b, mid, out, len, bulge)
    }

    static func cloudPoints(_ r: CGRect, bumps: Int) -> [CGPoint] {
        let n = max(bumps, 5)
        return (0..<n).map { i in ellipsePoint(r, CGFloat(i) / CGFloat(n) * 2 * .pi) }
    }

    /// Cloud tail: the bump that carries it (the one whose middle is closest to the tail angle), its base, tip.
    static func cloudTail(_ r: CGRect, bumps: Int, jitter: Double, _ t: TextBubbleTail, _ em: CGFloat, aim: CGPoint?)
        -> (index: Int, m: CGPoint, tip: CGPoint) {
        let pts = cloudPoints(r, bumps: bumps)
        let n = pts.count
        let a = aim.map { paramAngle(r, $0) } ?? angle(t)
        var tailBump = 0
        var best = CGFloat.infinity
        for i in 0..<n {
            let mid = (CGFloat(i) + 0.5) / CGFloat(n) * 2 * .pi
            let d = abs(atan2(sin(mid - a), cos(mid - a)))
            if d < best { best = d; tailBump = i }
        }
        let bp = cloudBump(r, pts, tailBump, jitter: jitter)
        let nv = CGVector(dx: bp.out.x / bp.len, dy: bp.out.y / bp.len)
        let m = CGPoint(x: bp.mid.x + nv.dx * bp.bulge * 0.5, y: bp.mid.y + nv.dy * bp.bulge * 0.5)
        if let aim { return (tailBump, m, freeTip(m, aim, CGFloat(t.length) * em, nv)) }
        let u = outward(r, angle(t))
        let tw = hypot(bp.b.x - bp.a.x, bp.b.y - bp.a.y)
        return (tailBump, m, tip(m, u, t, tw: tw * 0.5, tl: CGFloat(t.length) * em))
    }

    static func cloud(_ p: CGMutablePath, _ r: CGRect, bumps: Int, jitter: Double, tail: TextBubbleTail?, em: CGFloat, aim: CGPoint? = nil) {
        let pts = cloudPoints(r, bumps: bumps)
        let n = pts.count
        let ct = tail.map { cloudTail(r, bumps: bumps, jitter: jitter, $0, em, aim: aim) }
        p.move(to: pts[0])
        for i in 0..<n {
            let bp = cloudBump(r, pts, i, jitter: jitter)
            if let ct, i == ct.index, let t = tail {
                let tp = ct.tip, m = ct.m
                tailEdges(p, bp.a, tp, bp.b, t.kind, bend: CGVector(dx: (tp.x - m.x) * 0.2, dy: (tp.y - m.y) * 0.2))   // ends on b
                continue
            }
            p.addQuadCurve(to: bp.b, control: CGPoint(x: bp.mid.x + bp.out.x / bp.len * bp.bulge, y: bp.mid.y + bp.out.y / bp.len * bp.bulge))
        }
        p.closeSubpath()
    }

    /// Point `i` of a burst outline (even = spike tips).
    static func burstPoint(_ r: CGRect, n: Int, _ i: Int, depth: Double, jitter: Double) -> CGPoint {
        let c = CGPoint(x: r.midX, y: r.midY)
        let rx = r.width / 2 * 1.08, ry = r.height / 2 * 1.08
        let a = CGFloat(i) / CGFloat(n) * 2 * .pi - .pi / 2
        var k: CGFloat = 1
        if i % 2 == 0 {
            let j = 1 + CGFloat(jitter) * (CGFloat(glyphRandom(i, seed: 43)) - 0.5) * 1.4
            k = 1 + CGFloat(depth) * max(j, 0.2)
        }
        return CGPoint(x: c.x + rx * k * cos(a), y: c.y + ry * k * sin(a))
    }

    /// Burst tail: the spike closest to the tail angle, pulled out to the tip.
    static func burstTail(_ r: CGRect, spikes: Int, depth: Double, jitter: Double, _ t: TextBubbleTail, _ em: CGFloat, aim: CGPoint?)
        -> (index: Int, base: CGPoint, tip: CGPoint) {
        let n = max(spikes, 5) * 2
        let a = aim.map { paramAngle(r, $0) } ?? angle(t)
        var tailSpike = 0
        var best = CGFloat.infinity
        for i in stride(from: 0, to: n, by: 2) {
            let ai = CGFloat(i) / CGFloat(n) * 2 * .pi - .pi / 2
            let d = abs(atan2(sin(ai - a), cos(ai - a)))
            if d < best { best = d; tailSpike = i }
        }
        let pt = burstPoint(r, n: n, tailSpike, depth: depth, jitter: jitter)
        if let aim {
            let ai = CGFloat(tailSpike) / CGFloat(n) * 2 * .pi - .pi / 2
            return (tailSpike, pt, freeTip(pt, aim, CGFloat(t.length) * em, outward(r, ai)))
        }
        let u = outward(r, angle(t))
        return (tailSpike, pt, CGPoint(x: pt.x + u.dx * CGFloat(t.length) * em, y: pt.y + u.dy * CGFloat(t.length) * em))
    }

    static func burst(_ p: CGMutablePath, _ r: CGRect, spikes: Int, depth: Double, jitter: Double, tail: TextBubbleTail?, em: CGFloat,
                      aim: CGPoint? = nil) {
        let n = max(spikes, 5) * 2
        let bt = tail.map { burstTail(r, spikes: spikes, depth: depth, jitter: jitter, $0, em, aim: aim) }
        for i in 0..<n {
            var pt = burstPoint(r, n: n, i, depth: depth, jitter: jitter)
            if let bt, i == bt.index { pt = bt.tip }
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
    }

    /// Thought-bubble dots: three shrinking circles leaving the shape towards the tail side.
    static func dots(_ p: CGMutablePath, _ s: TextBubbleStyle, _ r: CGRect, _ t: TextBubbleTail, _ em: CGFloat, aim: CGPoint? = nil) {
        for d in dotsLayout(s, r, t, em, aim: aim).dots {
            p.addEllipse(in: CGRect(x: d.center.x - d.size / 2, y: d.center.y - d.size / 2, width: d.size, height: d.size))
        }
    }

    /// Where the dots start on the outline, and each dot (centre, diameter). The last dot's centre is
    /// 0.26 + 0.625 × max(length / 0.8, 0.3) em from the start (with no lean).
    static func dotsLayout(_ s: TextBubbleStyle, _ r: CGRect, _ t: TextBubbleTail, _ em: CGFloat, aim: CGPoint?)
        -> (start: CGPoint, dots: [(center: CGPoint, size: CGFloat)]) {
        let a = aim.map { paramAngle(r, $0) } ?? angle(t)
        var u = outward(r, a)
        var start: CGPoint
        switch s.family {
        case .box, .pill:
            if let aim {   // free: the edge point towards the aimed point
                let d = CGVector(dx: aim.x - r.midX, dy: aim.y - r.midY), l = hypot(d.dx, d.dy)
                if l > 1e-6 { u = CGVector(dx: d.dx / l, dy: d.dy / l) }
            }
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
        if let aim { u = freeDirection(start, aim, u) }
        let scale = CGFloat(t.length / TextBubbleTail.defaultLength)
        let sizes: [CGFloat] = [0.34, 0.22, 0.13].map { $0 * em * max(scale, 0.3) }
        let lean = aim == nil ? cornerLean(t.side) * 0.35 : 0
        var d: CGFloat = em * 0.1
        var out: [(center: CGPoint, size: CGFloat)] = []
        for sz in sizes {
            d += sz / 2
            let side = CGVector(dx: -u.dy, dy: u.dx)
            let sgn: CGFloat = side.dx >= 0 ? 1 : -1
            out.append((CGPoint(x: start.x + u.dx * d + side.dx * lean * sgn * d, y: start.y + u.dy * d + side.dy * lean * sgn * d), sz))
            d += sz / 2 + em * 0.08
        }
        return (start, out)
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

    /// Filled silhouette of the outline (neon tube, shadows). `shape`: the shape rectangle, for the neon tube break.
    static func tube(_ path: CGPath, _ o: TextBubbleOutline, em: CGFloat, breakIn shape: CGRect? = nil, tail: TextBubbleTail? = nil) -> CGPath {
        var line = linePath(path, o, em: em)
        if let r = shape, let x = tubeBreakX(o, r, tail: tail) {
            line = NeonPainter.broken(line, x: x, gap: CGFloat(o.width) * em * 3.1)
        }
        return line.copy(strokingWithWidth: CGFloat(o.width) * em, lineCap: o.dash == .dashed ? .butt : .round,
                         lineJoin: .round, miterLimit: 4)
    }

    /// TX-NEON tube break: where it goes (as in the reference sign, the top right, 78 % of the way from the centre to
    /// the right edge; mirrored to the top left when a tail leaves from the top right). nil = no break.
    static func tubeBreakX(_ o: TextBubbleOutline, _ r: CGRect, tail: TextBubbleTail?) -> CGFloat? {
        guard o.neon != nil, o.tubeBreak, o.dash == .solid, o.width > 0 else { return nil }
        let k: CGFloat = tail?.side == .topRight ? -0.78 : 0.78
        return r.midX + k * r.width / 2
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
        let params = neon.map { n -> NeonPainter.Params in var p = NeonPainter.Params(n, em: em); p.stroked = true; return p }
        let tubePath = s.outline.flatMap { o in
            neon != nil ? tube(path, o, em: em, breakIn: isClassic(s) ? rect : shapeRect(s, rect), tail: s.family.hasTail ? s.tail : nil) : nil
        }
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
        if f == .circle {   // circle through the corners of a small square: diameter 0.8 × the icon height
            s.padding = Vec2(0, 0)
            let side = size.height * 0.4 * sqrt(2)
            r = CGRect(x: size.width / 2 - side / 2, y: size.height / 2 - side / 2, width: side, height: side)
        }
        return BubblePainter.path(s, rect: r, em: em)
    }
}
