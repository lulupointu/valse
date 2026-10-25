import SwiftUI
import AppKit

/// Valse brand pieces (rename preview, VALSE-HOME): the logo mark, the striped ribbon motif and the Home button styles.
/// Motif rules: the full seven-band ribbon (burgundy film edges with perforations, mustard, orange, teal centre) appears
/// once per screen at most (hero art, empty state); smaller UI uses a three-band stripe (mustard / orange / teal) and
/// never as the only state cue.

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

/// Parallel colour bands (the ribbon's stripes) as a small solid motif: selection tab, rules.
struct ValseStripe: View {
    var axis: Axis = .horizontal
    var bands: [Color] = [Theme.Valse.mustard, Theme.Valse.orange, Theme.Valse.teal]
    var band: CGFloat = 2
    var body: some View {
        let stack = ForEach(Array(bands.enumerated()), id: \.offset) { _, c in
            Rectangle().fill(c).frame(width: axis == .vertical ? band : nil, height: axis == .horizontal ? band : nil)
        }
        Group {
            if axis == .horizontal { VStack(spacing: 0) { stack } } else { HStack(spacing: 0) { stack } }
        }
        .clipShape(RoundedRectangle(cornerRadius: band * 0.75))
        .accessibilityHidden(true)
    }
}

/// The ribbon as hero art: the V's arm drops in from the top edge at the logo's 22° slant, turns, and leaves to the right
/// like a clip on a timeline. Drawn as concentric strokes of one centreline (as the logo is), with perforations punched
/// in `background` along both burgundy edges.
struct ValseRibbon: View {
    /// Ribbon width; the logo proportions are edge 8/36, inner bands 4/36 each.
    var width: CGFloat = 36
    /// Distance of the horizontal run's centreline from the bottom edge.
    var baseline: CGFloat = 40
    /// Where the arm enters the top edge, measured from the trailing edge.
    var entry: CGFloat = 330
    var turnRadius: CGFloat = 70
    var background: Color = Theme.Valse.surface
    /// Playful: a waltz loop (a full turn) on the run, this far from the trailing edge; nil = no loop.
    var loopFromTrailing: CGFloat? = nil
    var loopRadius: CGFloat = 34
    /// Perforation offset along the film (animate it to make the film advance).
    var phase: CGFloat = 0

    var body: some View {
        Canvas { ctx, size in
            let (pts, split) = centreline(in: size)
            // Two passes so the second half of the loop passes over the first (over / under, not a merged blob).
            let segments = split.map { [Array(pts[...$0]), Array(pts[$0...])] } ?? [pts]
            let s = width / 36
            let widths: [CGFloat] = [36, 20, 12, 4].map { $0 * s }
            let edge = 8 * s
            for seg in segments {
                for (c, w) in zip(Theme.Valse.bands, widths) {
                    ctx.stroke(polyline(seg), with: .color(c), style: StrokeStyle(lineWidth: w, lineCap: .butt, lineJoin: .round))
                }
                for side in [-1.0, 1.0] {
                    let off = offset(seg, by: CGFloat(side) * (width / 2 - edge / 2))
                    ctx.stroke(polyline(off), with: .color(background),
                               style: StrokeStyle(lineWidth: 3.4 * s, lineCap: .butt, dash: [4.6 * s, 3.9 * s], dashPhase: -phase))
                }
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func centreline(in size: CGSize) -> ([CGPoint], Int?) {
        var pts = baseCentreline(in: size)
        guard let lf = loopFromTrailing else { return (pts, nil) }
        // Insert a full counter-clockwise turn (rising above the run) where the run passes x = width - lf.
        let lx = size.width - lf, yb = size.height - baseline
        guard let i = pts.firstIndex(where: { $0.x >= lx && abs($0.y - yb) < 0.5 }) else { return (pts, nil) }
        var loop: [CGPoint] = []
        let steps = 72
        for k in 1..<steps {
            let th = Double.pi / 2 - 2 * Double.pi * Double(k) / Double(steps)   // θ decreasing = moving +x at the bottom
            loop.append(CGPoint(x: lx + loopRadius * CGFloat(cos(th)), y: yb - loopRadius + loopRadius * CGFloat(sin(th))))
        }
        pts.insert(CGPoint(x: lx, y: yb), at: i)
        pts.insert(contentsOf: loop + [CGPoint(x: lx, y: yb)], at: i + 1)
        return (pts, i + 1 + steps / 2)
    }

    private func baseCentreline(in size: CGSize) -> [CGPoint] {
        let a = 22.1 * Double.pi / 180
        let yb = size.height - baseline
        let start = CGPoint(x: size.width - entry, y: -width)   // just above the top edge
        // Arc centre C = (xc, yb - R); arc starts where the tangent is the arm direction (θ = 180° - a), ends at θ = 90°.
        let r = turnRadius
        // Arm: start + t·(sin a, cos a) must reach C + r(cos θ0, sin θ0); solve for xc from the y equation.
        let th0 = Double.pi - a
        let cy = yb - r
        let arcStartY = cy + r * CGFloat(sin(th0))
        let t = (arcStartY - start.y) / CGFloat(cos(a))
        let arcStartX = start.x + t * CGFloat(sin(a))
        let cx = arcStartX - r * CGFloat(cos(th0))
        var pts: [CGPoint] = []
        let armSteps = 24
        for i in 0..<armSteps { let f = CGFloat(i) / CGFloat(armSteps); pts.append(CGPoint(x: start.x + (arcStartX - start.x) * f, y: start.y + (arcStartY - start.y) * f)) }
        let arcSteps = 32
        for i in 0...arcSteps {
            let th = th0 + (Double.pi / 2 - th0) * Double(i) / Double(arcSteps)
            pts.append(CGPoint(x: cx + r * CGFloat(cos(th)), y: cy + r * CGFloat(sin(th))))
        }
        let endX = size.width + width
        let runSteps = 40
        for i in 1...runSteps { pts.append(CGPoint(x: cx + (endX - cx) * CGFloat(i) / CGFloat(runSteps), y: yb)) }
        return pts
    }

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

/// Filled primary action (teal, ink text, 6.2:1).
struct ValsePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Theme.Valse.ink)
            .padding(.horizontal, 14).frame(height: 30)
            .background(Theme.Valse.teal.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: Theme.Valse.Radius.control))
    }
}

/// Neutral secondary action on the warm control surface.
struct ValseSecondaryButtonStyle: ButtonStyle {
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        ValseSecondaryLabel(configuration: configuration, compact: compact)
    }
}

private struct ValseSecondaryLabel: View {
    let configuration: ButtonStyleConfiguration
    let compact: Bool
    @State private var hover = false
    var body: some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .lineLimit(1).fixedSize()
            .foregroundStyle(Theme.Valse.text)
            .padding(.horizontal, compact ? 10 : 14).frame(height: compact ? 26 : 30)
            .background((hover ? Theme.Valse.controlHover : Theme.Valse.control).opacity(configuration.isPressed ? 0.7 : 1),
                        in: RoundedRectangle(cornerRadius: Theme.Valse.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Theme.Valse.Radius.control).stroke(Theme.Valse.stroke))
            .onHover { hover = $0 }
    }
}
