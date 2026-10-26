import SwiftUI
import Perception

/// OB-08 / FB-05: horseshoe magnet glyph for the "main track magnet" toggle. SF Symbols has no magnet (on any macOS),
/// so it is drawn: a monoline OUTLINE of a horseshoe (outer and inner U joined at the poles) with a band line across
/// each pole, stroked at the weight of the neighbouring 14 pt regular SF Symbols (FB-05: the former filled, 3 pt
/// thick glyph looked heavier and bolder than every other toolbar icon).
struct MagnetShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let ox = rect.midX - s / 2, oy = rect.midY - s / 2
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
        // Legs: outer x 0.12 / 0.88, inner x 0.38 / 0.62; poles at the top (y 0.08), arcs centred at y 0.5.
        let ol: CGFloat = 0.12, or_: CGFloat = 0.88, il: CGFloat = 0.38, ir: CGFloat = 0.62
        let top: CGFloat = 0.08, arcY: CGFloat = 0.5, band: CGFloat = 0.3
        let k: CGFloat = 0.5523   // cubic quarter-circle constant
        let ro = (or_ - ol) / 2, ri = (ir - il) / 2
        var path = Path()
        path.move(to: p(ol, top))
        path.addLine(to: p(ol, arcY))
        // outer half circle (two quarter arcs) down and around to the right leg
        path.addCurve(to: p(0.5, arcY + ro), control1: p(ol, arcY + ro * k), control2: p(0.5 - ro * k, arcY + ro))
        path.addCurve(to: p(or_, arcY), control1: p(0.5 + ro * k, arcY + ro), control2: p(or_, arcY + ro * k))
        path.addLine(to: p(or_, top))
        path.addLine(to: p(ir, top))
        path.addLine(to: p(ir, arcY))
        // inner half circle back to the left
        path.addCurve(to: p(0.5, arcY + ri), control1: p(ir, arcY + ri * k), control2: p(0.5 + ri * k, arcY + ri))
        path.addCurve(to: p(il, arcY), control1: p(0.5 - ri * k, arcY + ri), control2: p(il, arcY + ri * k))
        path.addLine(to: p(il, top))
        path.closeSubpath()
        // pole bands
        path.move(to: p(ol, band)); path.addLine(to: p(il, band))
        path.move(to: p(ir, band)); path.addLine(to: p(or_, band))
        return path
    }
}

/// Toolbar toggle with the drawn magnet, styled exactly like `IconButton` (26 pt hit box, ~14 pt glyph, 1.2 pt
/// monoline stroke, accent tint when on, `textPrimary` 85 % when off; tooltip = action), like snapping / linkage.
struct MagnetToggleButton: View {
    let isOn: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        WithPerceptionTracking {
            Button(action: action) {
                MagnetShape()
                    .stroke(style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                    .frame(width: 14, height: 14)
                    .rotationEffect(.degrees(45))   // tilted horseshoe (poles up-right): reads as a magnet, not a "U"
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ValseIconButtonStyle(active: isOn))   // the shared toolbar key: hover fill, mint when on
            .help(help)
            .accessibilityLabel(Text(verbatim: help))
            .accessibilityAddTraits(isOn ? .isSelected : [])
        }
    }
}
