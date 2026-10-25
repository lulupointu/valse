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

/// The ribbon as art: the V's arm drops in from the top edge at the logo's 22° slant, turns, optionally takes a waltz
/// loop (a real self-crossing loop, drawn over / under), and leaves to the right like a clip on a timeline. Drawn as
/// concentric strokes of one centreline (as the logo is), perforations punched in `background` along both burgundy
/// edges. `trim` draws it in along its length, `phase` advances the film, `breath` (0…1) swells the loop.
struct ValseRibbon: View {
    struct Loop { var fromTrailing: CGFloat; var height: CGFloat; var pitch: CGFloat }
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
    var breath: Double = 0

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
        // Over pass: redraw the second passage through the crossing on top, composited as one layer and clipped to a
        // disc around the crossing. Where the disc's edge cuts the strand, the layer is pixel-identical to what is
        // under it (same bands, dash pattern continued), so there is no seam or notch; only the crossing changes.
        if let r = over, k > r.lowerBound {
            let starts = sides.map { lengths(Array($0[0...r.lowerBound])).last ?? 0 }
            let c = pts[(r.lowerBound + r.upperBound) / 2]
            let rad = width * 1.15
            let piece = cut(pts, r.lowerBound, r.upperBound), pieceSides = sides.map { cut($0, r.lowerBound, r.upperBound) }
            ctx.drawLayer { layer in
                layer.clip(to: Path(ellipseIn: CGRect(x: c.x - rad, y: c.y - rad, width: 2 * rad, height: 2 * rad)))
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

    /// Centreline + the index range of the "over" passage through the loop's crossing.
    private func centreline(in size: CGSize) -> ([CGPoint], Range<Int>?) {
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
        guard let lp = loop else { run(to: endX); return (pts, nil) }
        // Waltz loop: a prolate trochoid x = xc + p·s − h·sin s, y = yb − h·(1 + cos s), s ∈ [−π, π]. It leaves and
        // rejoins the run tangentially and crosses itself at ±s*, where p·s* = h·sin s*.
        let h = lp.height / 2 * CGFloat(1 + 0.045 * breath), p = lp.pitch
        let xc = size.width - lp.fromTrailing
        run(to: xc - p * .pi)
        let n = 140
        var sStar = 0.0
        do {   // bisection for s* on (0, π)
            var lo = 0.001, hi = Double.pi
            for _ in 0..<40 { let m = (lo + hi) / 2; if Double(p) * m - Double(h) * sin(m) < 0 { lo = m } else { hi = m } }
            sStar = lo
        }
        let loopStart = pts.count
        var crossIndex = loopStart
        for i in 1..<n {
            let sv = -Double.pi + 2 * Double.pi * Double(i) / Double(n)
            if abs(sv - sStar) < Double.pi / Double(n) { crossIndex = pts.count }
            pts.append(CGPoint(x: xc + p * CGFloat(sv) - h * CGFloat(sin(sv)), y: yb - h * CGFloat(1 + cos(sv))))
        }
        run(to: endX)
        // over range: ± 2 ribbon widths of arc length around the second crossing (longer than the clip disc)
        let cum = lengths(pts)
        let span = width * 2
        var lo = crossIndex, hi = crossIndex
        while lo > loopStart, cum[crossIndex] - cum[lo] < span { lo -= 1 }
        while hi < pts.count - 1, cum[hi] - cum[crossIndex] < span { hi += 1 }
        return (pts, lo..<hi)
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
    func makeBody(configuration: Configuration) -> some View { ValsePressLabel(configuration: configuration, primary: false, compact: compact) }
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
            .onHover { hover = $0 }
    }
}
