import SwiftUI
import ValseCore
import ValseEffects
import Perception

/// Video ▸ Cutout ▸ ☐ Stroke (CK-005): outline around the cut-out subject — colour (swatch + canvas eyedropper), Size,
/// Opacity, Glow. Shown once the clip is cut out (auto / customized cutout or chroma key). The stroke effect goes last
/// in the stack so it outlines the final alpha.
struct CutoutStrokeSection: View {
    let ctx: InspectorContext

    static func applies(_ ctx: InspectorContext) -> Bool {
        guard let c = ctx.clip, c.mediaID != nil else { return false }
        return (c.matte.map { !$0.isBodyOnly } ?? false) || c.effects.contains { $0.typeID == BuiltinKeying.chromaKeyID || $0.typeID == BuiltinCutoutStroke.id }
    }

    static func instance(_ ctx: InspectorContext) -> EffectInstance? {
        ctx.clip?.effects.first { $0.typeID == BuiltinCutoutStroke.id }
    }

    static func chrome(_ ctx: InspectorContext) -> InspectorSectionChrome {
        let store = ctx.store
        let inst = instance(ctx)
        return InspectorSectionChrome(
            isEnabled: Binding.perceived(get: { inst != nil }, set: { on in
                guard let id = ctx.clip?.id else { return }
                store.performInspector(UpdateClip(id, nameKey: "cmd.cutoutStroke") { c in
                    if on {
                        if !c.effects.contains(where: { $0.typeID == BuiltinCutoutStroke.id }) { c.effects.append(BuiltinCutoutStroke.stroke.makeInstance()) }
                    } else {
                        for e in c.effects where e.typeID == BuiltinCutoutStroke.id { c.clearKeyframes(c.effectParamKeys(e.id)) }
                        c.effects.removeAll { $0.typeID == BuiltinCutoutStroke.id }
                    }
                })
            }),
            reset: {
                guard let id = ctx.clip?.id, let iid = inst?.id else { return }
                let defaults = BuiltinCutoutStroke.stroke.makeInstance().params
                store.performInspector(UpdateClip(id, nameKey: "cmd.cutoutStroke") { c in
                    if let i = c.effects.firstIndex(where: { $0.id == iid }) { c.effects[i].params = defaults }
                    c.clearKeyframes(c.effectParamKeys(iid))
                })
            },
            keyframeKeys: inst.map { i in ["size", "opacity", "glow"].map { ParamKey.effect(i.id, $0) } } ?? [])
    }

    /// Quick colour presets (white sticker look, black, CapCut accent, yellow, pink).
    static let presets: [RGBA] = [RGBA(1, 1, 1), RGBA(0, 0, 0), RGBA(hex: 0x57BECB), RGBA(hex: 0xFFD400), RGBA(hex: 0xFF5FA2)]

    var body: some View {
        WithPerceptionTracking {
            if let inst = Self.instance(ctx) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        ForEach(Array(Self.presets.enumerated()), id: \.offset) { i, c in
                            WithPerceptionTracking {
                                Circle().fill(Color(c)).frame(width: 22, height: 22)
                                    .overlay(Circle().strokeBorder(Color.white.opacity(0.25)))
                                    .contentShape(Circle())
                                    .onTapGesture { setColor(c, inst) }
                                    .testID("cutout.stroke.preset.\(i)")
                            }
                        }
                        Spacer()
                    }
                    .frame(minHeight: IStyle.rowHeight)
                    EffectParamRows(ctx: ctx, instance: inst, descriptor: BuiltinCutoutStroke.stroke)
                }
            } else {
                HintText(text: tr("cutout.stroke.hint"))
            }
        }
    }

    func setColor(_ c: RGBA, _ inst: EffectInstance) {
        guard let id = ctx.clip?.id else { return }
        ctx.store.performInspector(UpdateClip(id, nameKey: "cmd.cutoutStroke") { clip in
            if let i = clip.effects.firstIndex(where: { $0.id == inst.id }) { clip.effects[i].params["color"] = .color(c) }
        })
    }
}
