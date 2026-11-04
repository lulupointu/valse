import SwiftUI
import AppKit
import ValseCore
import ValseEffects
import Perception

/// Bubble ▸ Padding (TX-BUBBLE2): Horizontal and Vertical rows in % of the font size (em × 100; 0 = the shape touches
/// the text box, negative = it hugs the text), slider −50…150 with a tick at 0, field −100…300. A chain on the right
/// links them (UI state, default on): linked, changing one scales the other by the same ratio (by the same amount when
/// one is ≤ 0); ⌥-drag changes one axis only. While a slider is held the canvas draws the text box dashed.
struct BubblePaddingRows: View {
    let ctx: InspectorContext
    let style: TextBubbleStyle?

    static let spec = RowSpec(range: -50...150, origin: 0, ticks: [0], step: 1, fieldRange: -100...300, format: { String(Int($0.rounded())) })

    var body: some View {
        WithPerceptionTracking {
            let ui = TextUIState.shared
            HStack(alignment: .center, spacing: 4) {
                VStack(alignment: .leading, spacing: 4) {
                    row(0, tr("text.bubble.paddingH"), "text.bubble.paddingH")
                    row(1, tr("text.bubble.paddingV"), "text.bubble.paddingV")
                }
                chain(ui)
            }
        }
    }

    private func row(_ axis: Int, _ label: String, _ testID: String) -> ClipParamRow {
        var r = BubbleRows.row(ctx, label, testID, spec: Self.spec,
                               get: { (axis == 0 ? $0.padding.x : $0.padding.y) * 100 },
                               set: { s, v in
                                   let linked = TextUIState.shared.bubblePaddingLinked && !NSEvent.modifierFlags.contains(.option)
                                   s.setPadding(axis: axis, to: v / 100, linked: linked)
                               })
        r.onDrag = { TextUIState.shared.bubblePaddingGuide = $0 }
        return r
    }

    /// ┐ ⛓ ┘ bracket joining the two value fields.
    private func chain(_ ui: TextUIState) -> some View {
        let linked = ui.bubblePaddingLinked
        return VStack(spacing: 2) {
            bracket(top: true)
            Button { ui.bubblePaddingLinked.toggle() } label: {
                ZStack {
                    Image(systemName: "link").font(.system(size: 11, weight: .medium))
                    if !linked { Rectangle().frame(width: 1.3, height: 16).rotationEffect(.degrees(-45)) }
                }
                .foregroundStyle(linked ? Theme.accent : IStyle.iconDim)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tr(linked ? "text.bubble.unlink" : "text.bubble.link"))
            .accessibilityLabel(Text(verbatim: tr(linked ? "text.bubble.unlink" : "text.bubble.link")))
            .accessibilityAddTraits(linked ? [.isButton, .isSelected] : .isButton)
            .testID("text.bubble.paddingLink")
            bracket(top: false)
        }
        .padding(.top, 18)   // the rows' labels sit above their sliders: centre on the two fields
        .frame(width: 20)
    }

    private func bracket(top: Bool) -> some View {
        Path { p in
            if top { p.move(to: CGPoint(x: 4, y: 0.5)); p.addLine(to: CGPoint(x: 10, y: 0.5)); p.addLine(to: CGPoint(x: 10, y: 10)) }
            else { p.move(to: CGPoint(x: 10, y: 0)); p.addLine(to: CGPoint(x: 10, y: 9.5)); p.addLine(to: CGPoint(x: 4, y: 9.5)) }
        }
        .stroke(IStyle.iconDim, lineWidth: 1)
        .frame(width: 20, height: 10)
    }
}
