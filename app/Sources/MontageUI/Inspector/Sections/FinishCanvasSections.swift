import SwiftUI
import MontageCore
import MontageEffects
import Perception

// Canvas finisher rows: Video ▸ Basic ▸ ☐ Lens correction (CV-015). 3D rotation (CV-018) lives in TransformSection;
// shape-sticker colour adjustments (CV-017) reuse the Adjust tab (see `BuiltinInspector`).
@MainActor
enum FinishCanvasInspector {
    static let sections: [InspectorSection] = [
        InspectorSection(id: "video.lensCorrection", tab: "video", subTab: "basic", order: 25, titleKey: "lens.correction",
                         appliesTo: { $0.kind == .video || $0.kind == .image }, chrome: LensCorrectionSection.chrome) {
            AnyView(LensCorrectionSection(ctx: $0))
        },
    ]
}

/// ☐ Lens correction: Distortion (−100 pincushion … +100 barrel) ‹◇› and Zoom to fill. Ticking inserts the correction
/// first in the clip's effect stack (one undo step), unticking removes it.
struct LensCorrectionSection: View {
    let ctx: InspectorContext

    static func instance(_ ctx: InspectorContext) -> EffectInstance? {
        ctx.clip?.effects.first { $0.typeID == BuiltinLensCorrection.id }
    }

    static func chrome(_ ctx: InspectorContext) -> InspectorSectionChrome {
        let store = ctx.store
        let inst = instance(ctx)
        return InspectorSectionChrome(
            isEnabled: Binding(get: { inst != nil }, set: { on in
                guard let id = ctx.clip?.id else { return }
                store.performInspector(UpdateClip(id, nameKey: "cmd.lensCorrection") { c in
                    if on {
                        if !c.effects.contains(where: { $0.typeID == BuiltinLensCorrection.id }) {
                            c.effects.insert(BuiltinLensCorrection.descriptor.makeInstance(), at: 0)   // geometry before looks
                        }
                    } else {
                        for e in c.effects where e.typeID == BuiltinLensCorrection.id { c.clearKeyframes(c.effectParamKeys(e.id)) }
                        c.effects.removeAll { $0.typeID == BuiltinLensCorrection.id }
                    }
                })
            }),
            reset: {
                guard let id = ctx.clip?.id, let iid = inst?.id else { return }
                let defaults = BuiltinLensCorrection.descriptor.makeInstance().params
                store.performInspector(UpdateClip(id, nameKey: "cmd.lensCorrection") { c in
                    if let i = c.effects.firstIndex(where: { $0.id == iid }) { c.effects[i].params = defaults }
                    c.clearKeyframes(c.effectParamKeys(iid))
                })
            },
            keyframeKeys: inst.map { [ParamKey.effect($0.id, "distortion")] } ?? [])
    }

    var body: some View {
        WithPerceptionTracking {
            if let inst = Self.instance(ctx) {
                EffectParamRows(ctx: ctx, instance: inst, descriptor: BuiltinLensCorrection.descriptor)
            } else {
                HintText(text: tr("lens.hint"))
            }
        }
    }
}
