import SwiftUI
import Perception

/// OB-08: horseshoe magnet glyph for the "main track magnet" toggle. SF Symbols has no magnet (on any macOS), so the
/// former IconButton with the "magnet" name rendered an empty 26 pt button: the owner only saw its tooltip. Drawn as a path:
/// U-shaped body plus two pole tips separated by a small gap, stroked in the button's foreground colour.
struct MagnetShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let ox = rect.midX - s / 2, oy = rect.midY - s / 2
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
        let l: CGFloat = 0.2, rr: CGFloat = 0.8, radius = (rr - l) / 2, arcY: CGFloat = 0.55
        var path = Path()
        // Body: two legs and the rounded bottom (cubic approximation of a half circle).
        path.move(to: p(l, 0.34))
        path.addLine(to: p(l, arcY))
        path.addCurve(to: p(rr, arcY), control1: p(l, arcY + radius * 4 / 3), control2: p(rr, arcY + radius * 4 / 3))
        path.addLine(to: p(rr, 0.34))
        // Pole tips, separated from the body by a visible gap.
        path.move(to: p(l, 0.0)); path.addLine(to: p(l, 0.25))
        path.move(to: p(rr, 0.0)); path.addLine(to: p(rr, 0.25))
        return path
    }
}

/// Toolbar toggle with the drawn magnet, styled like `IconButton` (26 pt, accent when on, tooltip = action).
struct MagnetToggleButton: View {
    let isOn: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        WithPerceptionTracking {
            Button(action: action) {
                MagnetShape()
                    .stroke(style: StrokeStyle(lineWidth: 3, lineCap: .butt, lineJoin: .round))
                    .frame(width: 15, height: 15)
                    .rotationEffect(.degrees(45))   // tilted horseshoe: reads as a magnet, not a "U"
                    .frame(width: 26, height: 26)
                    .foregroundStyle(isOn ? Theme.accent : Theme.textPrimary.opacity(0.85))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)
            .accessibilityLabel(Text(verbatim: help))
            .accessibilityAddTraits(isOn ? .isSelected : [])
        }
    }
}
