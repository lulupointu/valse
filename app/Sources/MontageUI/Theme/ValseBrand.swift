import SwiftUI
import AppKit

/// Valse brand pieces (rename preview, VALSE-HOME): the logo mark, the film ribbon and the Home button styles.
/// The seven-band ribbon (burgundy film edges with perforations, mustard, orange, teal centre) is art only: hero and
/// empty state. It is never a selection or state cue (owner decision, round 3).

/// The logo mark, from PNG renders of the master SVGs in Resources (`small` = the 16–48 px cut with fewer perforations;
/// sized for ≤ 48 pt @3x and ≤ 128 pt @3x). PNG, not PDF: the SVG's perforation mask exported to PDF renders blank in
/// Apple's PDF renderer.
struct ValseMark: View {
    var small = false
    var body: some View {
        if let image = small ? Self.smallImage : Self.image {
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .accessibilityHidden(true)
        } else {
            Color.clear
        }
    }
    static let image: NSImage? = load("ValseMark")
    static let smallImage: NSImage? = load("ValseMarkSmall")
    private static func load(_ name: String) -> NSImage? {
        UIResources.bundle.url(forResource: name, withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    }
}

/// The ribbon as art: the V's arm drops in from the top edge at the logo's 22° slant, turns, optionally takes the
/// logo's loop (`Loop`: the whole "Open turn" mark, scaled to the band width), and leaves to the right like a clip on a
/// timeline. Drawn as concentric strokes of one centreline (as the logo is), perforations punched in `background`
/// along both burgundy edges. `trim` draws it in along its length, `phase` advances the film.
struct ValseRibbon: View {
    /// The logo's path (round 6, owner: "the same loop as in the logo"): arm, turn, climb, loop and the horizontal exit
    /// crossing over the climb. Placed by the bottom of the V's turn (centreline), from the trailing and bottom edges;
    /// `baseline`, `entry` and `turnRadius` do not apply.
    struct Loop { var turnFromTrailing: CGFloat; var bottom: CGFloat }

    /// "Open turn" master geometry (logo/final-open-turn/film-turn-open.svg, in its units: band width 90), measured from
    /// the SVG centreline: a straight arm 22.5° off vertical, a turn of radius 66, the climb tangent to the turn and the
    /// loop, a loop of radius 71.7 turning 290° the same way, and the exit leaving the loop's bottom horizontally. The
    /// logo draws the second half (from the top of the loop on) over the first, so the exit crosses over the climb.
    enum Logo {
        static let band: CGFloat = 90
        static let armHeading = 67.5 * Double.pi / 180
        static let turn = CGPoint(x: 222.4, y: 273.5), turnR: CGFloat = 66
        static let loop = CGPoint(x: 261.3, y: 148.2), loopR: CGFloat = 71.7
        /// Where the over pass starts on the loop (its top, slightly left), as in the SVG.
        static let overFrom = -100 * Double.pi / 180
    }
    /// Ribbon width; the logo proportions are edge 8/36, inner bands 4/36 each.
    var width: CGFloat = 36
    /// Distance of the horizontal run's centreline from the bottom edge.
    var baseline: CGFloat = 40
    /// Where the arm enters the top edge, measured from the trailing edge.
    var entry: CGFloat = 330
    var turnRadius: CGFloat = 70
    var background: Color = Theme.Valse.surface
    var loop: Loop? = nil
    var trim: Double = 1
    var phase: CGFloat = 0

    var body: some View {
        Canvas { ctx, size in draw(in: &ctx, size: size) }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }

    private func draw(in ctx: inout GraphicsContext, size: CGSize) {
        let (pts, over) = centreline(in: size)
        guard pts.count > 1, trim > 0 else { return }
        let s = width / 36, edge = 8 * s
        let d = width / 2 - edge / 2
        let sides = [offset(pts, by: -d), offset(pts, by: d)]
        let cum = lengths(pts)
        // trim: everything is index-aligned with the centreline, so one cut serves the edges too (no poking ends)
        let target = cum[cum.count - 1] * CGFloat(min(trim, 1))
        let k = max(0, (cum.lastIndex(where: { $0 <= target }) ?? 0))
        let frac: CGFloat = k + 1 < cum.count ? (target - cum[k]) / max(0.0001, cum[k + 1] - cum[k]) : 0
        func cut(_ a: [CGPoint], _ lo: Int, _ hi: Int) -> [CGPoint] {
            var out = Array(a[lo...min(hi, k)])
            if hi > k, k + 1 < a.count, frac > 0 { out.append(lerp(a[k], a[k + 1], frac)) }
            return out
        }
        stroke(&ctx, cut(pts, 0, pts.count - 1), sides.map { cut($0, 0, $0.count - 1) }, dashStart: [0, 0])
        // Over pass (the logo's second half, drawn over the first): redraw it on top as one layer, clipped to everything
        // but a disc around where it starts. There the layer is pixel-identical to the strand under it (same bands, dash
        // pattern continued), so the start leaves no seam or notch; only where it crosses another strand changes.
        if let r = over, k > r.lowerBound {
            let starts = sides.map { lengths(Array($0[0...r.lowerBound])).last ?? 0 }
            let c = pts[r.lowerBound]
            let rad = width * 1.2
            let piece = cut(pts, r.lowerBound, r.upperBound), pieceSides = sides.map { cut($0, r.lowerBound, r.upperBound) }
            ctx.drawLayer { layer in
                var clip = Path(CGRect(x: -4 * width, y: -4 * width, width: size.width + 8 * width, height: size.height + 8 * width))
                clip.addEllipse(in: CGRect(x: c.x - rad, y: c.y - rad, width: 2 * rad, height: 2 * rad))
                layer.clip(to: clip, style: FillStyle(eoFill: true))
                stroke(&layer, piece, pieceSides, dashStart: starts)
            }
        }
    }

    private func stroke(_ ctx: inout GraphicsContext, _ c: [CGPoint], _ sides: [[CGPoint]], dashStart: [CGFloat]) {
        guard c.count > 1 else { return }
        let s = width / 36
        let widths: [CGFloat] = [36, 20, 12, 4].map { $0 * s }
        let path = polyline(c)
        for (col, w) in zip(Theme.Valse.bands, widths) {
            ctx.stroke(path, with: .color(col), style: StrokeStyle(lineWidth: w, lineCap: .butt, lineJoin: .round))
        }
        for (side, start) in zip(sides, dashStart) where side.count > 1 {
            ctx.stroke(polyline(side), with: .color(background),
                       style: StrokeStyle(lineWidth: 3.4 * s, lineCap: .butt, dash: [4.6 * s, 3.9 * s], dashPhase: start - phase))
        }
    }

    /// Centreline + the index range drawn over the rest (the logo loop's second half; none without a loop).
    private func centreline(in size: CGSize) -> ([CGPoint], Range<Int>?) {
        if let lp = loop {
            let (pts, over) = Self.logoCentreline(in: size, width: width, lp)
            return (pts, over)
        }
        let a = 22.1 * Double.pi / 180
        let yb = size.height - baseline
        let start = CGPoint(x: size.width - entry, y: -width)   // just above the top edge
        let r = turnRadius
        // Arc centre C = (cx, yb - R); the arc starts where its tangent is the arm direction (θ = 180° - a), ends at 90°.
        let th0 = Double.pi - a
        let cy = yb - r
        let arcStartY = cy + r * CGFloat(sin(th0))
        let t = (arcStartY - start.y) / CGFloat(cos(a))
        let arcStartX = start.x + t * CGFloat(sin(a))
        let cx = arcStartX - r * CGFloat(cos(th0))
        var pts: [CGPoint] = []
        for i in 0..<24 { let f = CGFloat(i) / 24; pts.append(CGPoint(x: start.x + (arcStartX - start.x) * f, y: start.y + (arcStartY - start.y) * f)) }
        for i in 0...32 {
            let th = th0 + (Double.pi / 2 - th0) * Double(i) / 32
            pts.append(CGPoint(x: cx + r * CGFloat(cos(th)), y: cy + r * CGFloat(sin(th))))
        }
        let endX = size.width + width
        func run(to x: CGFloat) {
            let x0 = pts.last!.x
            let n = max(2, Int((x - x0) / 8))
            for i in 1...n { pts.append(CGPoint(x: x0 + (x - x0) * CGFloat(i) / CGFloat(n), y: yb)) }
        }
        run(to: endX)
        return (pts, nil)
    }

    /// The logo's centreline (`Logo`), scaled so its band is `width` wide, the bottom of the turn at `loop`'s place, the
    /// arm extended up past the top edge and the exit to past the trailing edge. Samples ≈ 4 pt apart. Returns the
    /// index range drawn over (from the top of the loop to the end).
    static func logoCentreline(in size: CGSize, width: CGFloat, _ lp: Loop) -> ([CGPoint], Range<Int>) {
        let s = width / Logo.band
        let lowest = CGPoint(x: Logo.turn.x, y: Logo.turn.y + Logo.turnR)
        let o = CGPoint(x: size.width - lp.turnFromTrailing - lowest.x * s, y: size.height - lp.bottom - lowest.y * s)
        let step = 4 / s   // logo units between samples
        var pts: [CGPoint] = []
        func view(_ p: CGPoint) -> CGPoint { CGPoint(x: o.x + p.x * s, y: o.y + p.y * s) }
        func line(_ a: CGPoint, _ b: CGPoint) {
            let n = max(2, Int((hypot(b.x - a.x, b.y - a.y) / step).rounded(.up)))
            for i in 0..<n {
                let f = CGFloat(i) / CGFloat(n)
                pts.append(view(CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)))
            }
        }
        func arc(_ c: CGPoint, _ r: CGFloat, _ a0: Double, _ a1: Double) {
            let n = max(4, Int((abs(a1 - a0) * Double(r) / Double(step)).rounded(.up)))
            for i in 0..<n {
                let a = a0 + (a1 - a0) * Double(i) / Double(n)
                pts.append(view(CGPoint(x: c.x + r * CGFloat(cos(a)), y: c.y + r * CGFloat(sin(a)))))
            }
        }
        // left normal of a direction (y down): the side the ribbon turns towards
        func left(_ d: CGPoint) -> CGPoint { CGPoint(x: d.y, y: -d.x) }
        // arm: tangent to the turn
        let d1 = CGPoint(x: cos(Logo.armHeading), y: sin(Logo.armHeading))
        let n1 = left(d1)
        let p1 = CGPoint(x: Logo.turn.x - Logo.turnR * n1.x, y: Logo.turn.y - Logo.turnR * n1.y)
        let topY = (-width - o.y) / s   // one band width above the top edge
        let back = (p1.y - topY) / d1.y
        line(CGPoint(x: p1.x - d1.x * back, y: p1.y - d1.y * back), p1)
        // climb: the outer tangent of the turn and the loop, both on its left
        let dx = Logo.loop.x - Logo.turn.x, dy = Logo.loop.y - Logo.turn.y
        let psi = atan2(Double(dy), Double(dx)) + asin(Double((Logo.loopR - Logo.turnR) / hypot(dx, dy)))
        let n2 = left(CGPoint(x: cos(psi), y: sin(psi)))
        let t1 = CGPoint(x: Logo.turn.x - Logo.turnR * n2.x, y: Logo.turn.y - Logo.turnR * n2.y)
        let t2 = CGPoint(x: Logo.loop.x - Logo.loopR * n2.x, y: Logo.loop.y - Logo.loopR * n2.y)
        let a0 = atan2(Double(-n1.y), Double(-n1.x)), aT = atan2(Double(-n2.y), Double(-n2.x))
        arc(Logo.turn, Logo.turnR, a0, aT)            // the turn, counter-clockwise on screen (angles decrease)
        line(t1, t2)
        arc(Logo.loop, Logo.loopR, aT, Logo.overFrom)  // up and over the top of the loop
        let overStart = pts.count
        arc(Logo.loop, Logo.loopR, Logo.overFrom, Double.pi / 2 - 2 * Double.pi)   // down the left, out at the bottom
        let exitY = Logo.loop.y + Logo.loopR
        line(CGPoint(x: Logo.loop.x, y: exitY), CGPoint(x: (size.width + width - o.x) / s, y: exitY))
        pts.append(view(CGPoint(x: (size.width + width - o.x) / s, y: exitY)))
        return (pts, overStart..<(pts.count - 1))
    }

    private func lengths(_ pts: [CGPoint]) -> [CGFloat] {
        var out: [CGFloat] = [0]
        out.reserveCapacity(pts.count)
        for i in 1..<max(1, pts.count) { out.append(out[i - 1] + hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)) }
        return out
    }

    private func lerp(_ a: CGPoint, _ b: CGPoint, _ f: CGFloat) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f) }

    private func offset(_ pts: [CGPoint], by d: CGFloat) -> [CGPoint] {
        pts.indices.map { i in
            let p0 = pts[max(0, i - 1)], p1 = pts[min(pts.count - 1, i + 1)]
            let dx = p1.x - p0.x, dy = p1.y - p0.y, len = max(0.0001, (dx * dx + dy * dy).squareRoot())
            return CGPoint(x: pts[i].x - dy / len * d, y: pts[i].y + dx / len * d)
        }
    }

    private func polyline(_ pts: [CGPoint]) -> Path {
        var p = Path()
        p.addLines(pts)
        return p
    }
}

/// Filled primary action (teal, ink text, 6.2:1), springy press.
struct ValsePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { ValsePressLabel(configuration: configuration, primary: true, compact: false) }
}

/// Neutral secondary action on the warm control surface, springy press.
struct ValseSecondaryButtonStyle: ButtonStyle {
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        ValsePressLabel(configuration: configuration, primary: false, compact: compact)
    }
}

private struct ValsePressLabel: View {
    let configuration: ButtonStyleConfiguration
    let primary: Bool
    let compact: Bool
    @State private var hover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let r = ValseShape.control
        let pressed = configuration.isPressed
        configuration.label
            .font(.system(size: 12.5, weight: primary ? .semibold : .medium))
            .lineLimit(1).fixedSize()
            .foregroundStyle(primary ? Theme.Valse.ink : Theme.Valse.text)
            .padding(.horizontal, compact ? 10 : 14).frame(height: compact ? 26 : 30)
            .background(primary ? Theme.Valse.teal.opacity(pressed ? 0.85 : 1)
                                : (hover ? Theme.Valse.controlHover : Theme.Valse.control).opacity(pressed ? 0.75 : 1),
                        in: RoundedRectangle(cornerRadius: r))
            .overlay(RoundedRectangle(cornerRadius: r).stroke(primary ? .clear : Theme.Valse.stroke))
            .scaleEffect(pressed && !reduceMotion ? 0.95 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.55), value: pressed)
            .valseHover($hover)
    }
}
