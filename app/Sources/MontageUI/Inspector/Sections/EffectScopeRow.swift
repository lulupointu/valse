import SwiftUI
import MontageCore

/// Effect / filter clip ▸ "Apply to  [Main | PiP | All]" (FX-004, CapCut `pc_audio_effects_main/pip/all`): which layers
/// below the clip its effects process (`Clip.effectScope`, rendered by `FrameEvaluator`). One undo step per change.
struct EffectScopeRow: View {
    let ctx: InspectorContext
    static let order: [EffectScope] = [.main, .pip, .all]

    var body: some View {
        let current = ctx.clip?.effectScope ?? .all
        VStack(alignment: .leading, spacing: 4) {
            Rectangle().fill(Theme.separator).frame(height: 1).padding(.vertical, 6)
            InlineRow(label: tr("fx.scope.applyTo")) {
                HStack(spacing: 2) {
                    ForEach(Self.order, id: \.self) { s in
                        Button { set(s) } label: {
                            Text(verbatim: tr(s.nameKey))
                                .font(.system(size: 12, weight: current == s ? .medium : .regular))
                                .foregroundStyle(current == s ? Theme.textPrimary : Theme.textTertiary)
                                .frame(maxWidth: .infinity, minHeight: 24)
                                .background(current == s ? Theme.segmentSelected : .clear, in: RoundedRectangle(cornerRadius: 5))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(verbatim: tr("fx.scope.applyTo") + " " + tr(s.nameKey)))
                        .accessibilityAddTraits(current == s ? .isSelected : [])
                        .testID("fx.scope.\(s.rawValue)")
                    }
                }
                .padding(2)
                .background(Theme.inset, in: RoundedRectangle(cornerRadius: 6))
            }
            Text(verbatim: tr("fx.scope.hint.\(current.rawValue)"))
                .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .testID("fx.scope")
    }

    private func set(_ s: EffectScope) {
        guard let c = ctx.clip, (c.effectScope ?? .all) != s else { return }
        ctx.store.perform(UpdateClip(c.id, nameKey: "cmd.fx.scope") { $0.effectScope = s == .all ? nil : s })
    }
}
