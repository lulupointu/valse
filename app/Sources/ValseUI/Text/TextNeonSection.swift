import SwiftUI
import Perception
import ValseCore

/// Text ▸ Basic ▸ Neon (TX-NEON): glass-tube neon look. Colour swatches (6 classic sign colours + custom), Intensity,
/// Glow size, Tube thickness, Flicker (Off / Subtle / Broken). Defaults look right without tweaking.
struct TextNeonSection: View {
    let ctx: InspectorContext

    static func chrome(_ ctx: InspectorContext) -> InspectorSectionChrome {
        TextInspector.chrome(ctx, isOn: { $0.neon != nil },
                             toggle: { t, on in t.neon = on ? (t.neon ?? TextNeonStyle()) : nil },
                             reset: { t in t.neon = TextNeonStyle() })
    }

    var body: some View {
        WithPerceptionTracking {
            let neon = TextInspector.text(ctx)?.neon ?? TextNeonStyle()
            VStack(alignment: .leading, spacing: 4) {
                InlineRow(label: tr("inspector.color")) {
                    HStack(spacing: 6) {
                        ForEach(TextNeonStyle.swatches, id: \.name) { s in
                            swatch(s.name, s.color, selected: neon.color == s.color)
                        }
                        ColorSwatchButton(color: neon.color, size: 18, testID: "text.neon.color") { col in set { $0.neon?.color = col } }
                            .testID("text.neon.color")
                    }
                }
                TextInspector.row(ctx, tr("text.neon.intensity"), range: 0...100,
                                  get: { ($0.neon?.intensity ?? 0) * 100 }, set: { $0.neon?.intensity = $1 / 100 })
                TextInspector.row(ctx, tr("text.neon.glowSize"), range: 0...100,
                                  get: { ($0.neon?.glowSize ?? 0) / 1.0 * 100 }, set: { $0.neon?.glowSize = max($1, 1) / 100 })
                TextInspector.row(ctx, tr("text.neon.thickness"), range: 0...100,
                                  get: { ($0.neon?.thickness ?? 0) / 0.15 * 100 }, set: { $0.neon?.thickness = max($1, 1) / 100 * 0.15 })
                InlineRow(label: tr("text.neon.flicker")) {
                    SegmentedTabs(TextNeonFlicker.allCases.map { ($0.rawValue, tr("text.neon.flicker.\($0.rawValue)")) },
                                  selection: Binding.perceived(get: { neon.flicker.rawValue }, set: { v in
                                      guard let f = TextNeonFlicker(rawValue: v) else { return }
                                      set { $0.neon?.flicker = f }
                                  }))
                    .testID("text.neon.flicker")
                }
            }
        }
    }

    private func set(_ edit: @escaping (inout TextContent) -> Void) {
        guard let id = ctx.clip?.id else { return }
        ctx.store.updateText(id, edit)
    }

    private func swatch(_ name: String, _ color: RGBA, selected: Bool) -> some View {
        Circle().fill(Color(color))
            .frame(width: 18, height: 18)
            .overlay(Circle().strokeBorder(Color.white.opacity(selected ? 0.95 : 0), lineWidth: 2))
            .padding(2)
            .overlay(Circle().strokeBorder(selected ? Theme.accent : .clear, lineWidth: 1.5))
            .contentShape(Circle())
            .onTapGesture { set { $0.neon?.color = color } }
            .help(tr("text.neon.color.\(name)"))
            .accessibilityLabel(tr("text.neon.color.\(name)"))
            .accessibilityAddTraits(.isButton)
            .testID("text.neon.swatch.\(name)")
    }
}
