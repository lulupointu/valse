import SwiftUI
import Perception

/// TL-048: the Quick cut glyph, scissors with two sparkles (owner's 24 × 24 stroke icon, geometry copied verbatim from
/// its SVG: two finger rings, two crossing blades, two four-point sparkles). Drawn like `MagnetShape` (SF Symbols has no
/// equivalent on macOS 13), stroked with the current foreground style.
struct QuickCutShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        let ox = rect.midX - 12 * s, oy = rect.midY - 12 * s
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
        var path = Path()
        // finger rings
        for cy: CGFloat in [9, 17] {
            path.addEllipse(in: CGRect(x: ox + 3.5 * s, y: oy + (cy - 2.5) * s, width: 5 * s, height: 5 * s))
        }
        // blades: "M8.2 10.2 17 16.5", "M8.2 15.8 17 9.5"
        path.move(to: p(8.2, 10.2)); path.addLine(to: p(17, 16.5))
        path.move(to: p(8.2, 15.8)); path.addLine(to: p(17, 9.5))
        // sparkles: "M18 1.5Q18 4.5 21 4.5Q18 4.5 18 7.5Q18 4.5 15 4.5Q18 4.5 18 1.5Z" and the small one at (21, 10.3)
        func sparkle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) {
            path.move(to: p(cx, cy - r))
            path.addQuadCurve(to: p(cx + r, cy), control: p(cx, cy))
            path.addQuadCurve(to: p(cx, cy + r), control: p(cx, cy))
            path.addQuadCurve(to: p(cx - r, cy), control: p(cx, cy))
            path.addQuadCurve(to: p(cx, cy - r), control: p(cx, cy))
            path.closeSubpath()
        }
        sparkle(18, 4.5, 3)
        sparkle(21, 10.3, 2)
        return path
    }
}

/// Toolbar button with the drawn Quick cut glyph, styled like `IconButton` / `MagnetToggleButton` (26 pt hit box,
/// accent when the popover is open, `textPrimary` 85 % otherwise, tooltip = action). The 24-unit glyph is drawn in an
/// 18 pt box so its visible part (≈ 19.5 units) matches the ~14 pt SF Symbols next to it; the SVG's 1.5-unit stroke
/// scales with it (1.125 pt).
struct QuickCutIconButton: View {
    let active: Bool
    let help: String
    let action: () -> Void
    static let glyph: CGFloat = 18

    var body: some View {
        WithPerceptionTracking {
            Button(action: action) {
                QuickCutShape()
                    .stroke(style: StrokeStyle(lineWidth: 1.5 * Self.glyph / 24, lineCap: .round, lineJoin: .round))
                    .frame(width: Self.glyph, height: Self.glyph)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ValseIconButtonStyle(active: active))   // the shared toolbar key: hover fill, mint when on
            .help(help)
            .accessibilityLabel(Text(verbatim: help))
            .accessibilityAddTraits(active ? .isSelected : [])
        }
    }
}
