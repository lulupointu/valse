import SwiftUI
import AppKit

// TEMPORARY (VALSE-HOME round 2): style switches so one build can screenshot every combination for the owner.
// Read once from the environment, Home views only. Once the owner picks, delete the losers and this switch.
//   VALSE_HOME_STYLE = calm (default) | playful
//   VALSE_SELECTION  = a (pill) | b (bottom edge) | c (ribbon turn) | d (striped badge, default)
//   VALSE_DEBUG_HOVER = hero | card0 | feature0 | nav.<id> (forces that hover state for screenshots; any other
//                       value, e.g. "off", just ignores the real pointer)

enum ValseHomeStyle: String {
    case calm, playful
    static let current = ValseHomeStyle(rawValue: ProcessInfo.processInfo.environment["VALSE_HOME_STYLE"] ?? "") ?? .calm
    static var isPlayful: Bool { current == .playful }
}

enum ValseSelection: String {
    case a, b, c, d
    static let current = ValseSelection(rawValue: ProcessInfo.processInfo.environment["VALSE_SELECTION"]?.lowercased() ?? "") ?? .d
}

enum ValseDebugHover {
    static let target = ProcessInfo.processInfo.environment["VALSE_DEBUG_HOVER"] ?? ""
    static func forced(_ id: String) -> Bool { !id.isEmpty && target == id }
    /// Any value set: ignore the real pointer (offscreen screenshots otherwise pick up stray hovers).
    static let ignoreReal = !target.isEmpty
    static func merge(_ real: Bool, _ id: String) -> Bool { (real && !ignoreReal) || forced(id) }
}

/// Radii per style (playful = rounder).
enum ValseShape {
    static var control: CGFloat { ValseHomeStyle.isPlayful ? 9 : Theme.Valse.Radius.control }
    static var card: CGFloat { ValseHomeStyle.isPlayful ? 14 : Theme.Valse.Radius.card }
    static var hero: CGFloat { ValseHomeStyle.isPlayful ? 20 : Theme.Valse.Radius.hero }
}

/// The three brand bands of the selection motif, outside → in.
private let selBands: [Color] = [Theme.Valse.mustard, Theme.Valse.orange, Theme.Valse.teal]

// MARK: - Selection decorations (one per option, shared by sidebar row, list row and selection bar)

/// Where the decoration sits. Rows reserve leading space for option A's pill so content never jumps.
enum ValseSelectionHost { case navRow, listRow, bar }

extension ValseSelection {
    /// Extra leading inset a host needs so the pill (A) has breathing room; 0 for the others.
    var leadingInset: CGFloat { self == .a ? 12 : 0 }
}

/// A: a rounded pill of three 2 pt bands (6 × 18 pt), inside the row with 6 pt of air on each side.
struct ValseSelPill: View {
    var height: CGFloat = 18
    var body: some View {
        HStack(spacing: 0) { ForEach(0..<3, id: \.self) { i in Rectangle().fill(selBands[i]).frame(width: 2) } }
            .frame(height: height)
            .clipShape(Capsule())
            .accessibilityHidden(true)
    }
}

/// B: the three bands (1 pt each) as the bottom edge of the selected shape, clipped by its corners.
struct ValseSelBottomEdge: View {
    var radius: CGFloat
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            ForEach(0..<3, id: \.self) { i in Rectangle().fill(selBands[2 - i]).frame(height: 1) }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// C: the ribbon's turn. The bands run down the leading edge, follow the corner and leave along the bottom like the
/// logo's exit, fading out. 1 pt bands on half-point centres so they stay crisp at 1x and 2x.
struct ValseSelTurn: View {
    var radius: CGFloat
    var body: some View {
        Canvas { ctx, size in
            let h = size.height, r = max(radius, 4)
            for i in 0..<3 {
                let k = CGFloat(i) + 0.5
                let ri = r - k
                var p = Path()
                p.move(to: CGPoint(x: k, y: h * 0.18))
                p.addLine(to: CGPoint(x: k, y: h - r))
                p.addArc(center: CGPoint(x: r, y: h - r), radius: ri, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
                p.addLine(to: CGPoint(x: size.width * 0.72, y: h - k))
                ctx.stroke(p, with: .color(selBands[i]), style: StrokeStyle(lineWidth: 1, lineCap: .round))
            }
        }
        .mask(LinearGradient(stops: [.init(color: .white, location: 0), .init(color: .white, location: 0.3), .init(color: .clear, location: 0.72)],
                             startPoint: .leading, endPoint: .trailing))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// D: a small rounded badge filled with the three bands at the logo's 22° slant, ink glyph or text on top.
struct ValseStripedBadge<Content: View>: View {
    var size: CGFloat = 22
    var width: CGFloat? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        let w = width ?? size
        ZStack {
            Canvas { ctx, s in
                // three bands across the diagonal, slanted like the V's arm
                let slant = s.height * tan(22.1 * .pi / 180)
                let bw = (s.width + slant) / 3
                for i in 0..<3 {
                    let x0 = -slant + CGFloat(i) * bw
                    var p = Path()
                    p.move(to: CGPoint(x: x0 + slant, y: 0)); p.addLine(to: CGPoint(x: x0 + slant + bw + 0.5, y: 0))
                    p.addLine(to: CGPoint(x: x0 + bw + 0.5, y: s.height)); p.addLine(to: CGPoint(x: x0, y: s.height)); p.closeSubpath()
                    ctx.fill(p, with: .color(selBands[i]))
                }
            }
            content().foregroundStyle(Theme.Valse.ink)
        }
        .frame(width: w, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.32))
    }
}

/// Applies the chosen option's decoration on a selected row-like shape (A pill, B bottom edge, C turn). D lives in
/// the row content (the icon / cover badge), so it adds nothing here.
struct ValseSelectionOverlay: ViewModifier {
    let selected: Bool
    let radius: CGFloat
    var pillHeight: CGFloat = 18
    func body(content: Content) -> some View {
        content.overlay(alignment: .leading) {
            if selected {
                switch ValseSelection.current {
                case .a: ValseSelPill(height: pillHeight).padding(.leading, 5)
                case .b: ValseSelBottomEdge(radius: radius)
                case .c: ValseSelTurn(radius: radius)
                case .d: EmptyView()
                }
            }
        }
    }
}

extension View {
    func valseSelection(_ selected: Bool, radius: CGFloat, pillHeight: CGFloat = 18) -> some View {
        modifier(ValseSelectionOverlay(selected: selected, radius: radius, pillHeight: pillHeight))
    }
}

// MARK: - Playful helpers

/// Spring for hover micro-interactions; nil under Reduce Motion (state still changes, without movement).
@MainActor func valseSpring(_ reduceMotion: Bool) -> Animation? {
    reduceMotion || !ValseHomeStyle.isPlayful ? nil : .spring(response: 0.32, dampingFraction: 0.62)
}

/// Folder icon tints (playful): small colour moments that rotate through the palette.
enum ValsePlayfulTint {
    static let cycle: [Color] = [Theme.Valse.teal, Theme.Valse.mustard, Theme.Valse.mint, Theme.Valse.orange]
    static func folder(_ i: Int) -> Color { cycle[i % cycle.count] }
}
