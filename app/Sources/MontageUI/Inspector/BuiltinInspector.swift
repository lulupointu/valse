import SwiftUI
import MontageCore
import MontageEffects
import MontageEngine

/// Built-in inspector tabs & sections (UX.md §5). A feature adds its UI with one `InspectorSection` (here or via
/// `InspectorRegistry.register`), optionally in a sub-tab (`InspectorRegistry.register(_:in:)`) — the panel, tabs,
/// segmented sub-tabs, headers (checkbox ↺ ‹◇›) and footers pick it up automatically.
///
/// Tabs per selection (CapCut 9.6):
/// - nothing: Details (+ Modify) · transition: Transition (+ Apply to all) · several clips: Properties
/// - video: Video [Basic · Cutout · Mask] · Audio · Speed [Normal · Curve] · Animation [In · Out · Combo] · Adjust [Basic] · Effects
/// - image: Video · Animation · Adjust · audio clip: Basic · Speed
/// - text: Text · Animation [In · Out · Loop] · sticker: Stickers · Animation
/// - effect clip: Special effects · filter clip: Filter · adjustment clip: Adjust
@MainActor
enum BuiltinInspector {
    typealias Ctx = InspectorContext

    static func any(_ kinds: InspectorSelectionKind...) -> @MainActor (Ctx) -> Bool { { kinds.contains($0.kind) } }

    static let tabs: [InspectorTab] = [
        InspectorTab(id: "details", titleKey: "inspector.tab.details", order: -10,
                     footer: { ctx, _ in AnyView(ModifyProjectButton(store: ctx.store)) }, appliesTo: any(.none)),
        InspectorTab(id: "transition", titleKey: "inspector.tab.transition", order: -9,
                     footer: { ctx, _ in AnyView(PillButton(title: tr("inspector.applyToAll")) { TransitionSection.applyToAll(ctx) }.testID("transition.applyAll")) },
                     appliesTo: any(.transition)),
        InspectorTab(id: "properties", titleKey: "inspector.tab.properties", order: -8, appliesTo: any(.multiple)),
        // Text + Captions tabs: text engine (W7), MontageUI/Text/TextInspector.swift
        TextInspector.textTab, TextInspector.captionsTab,
        InspectorTab(id: "sticker", titleKey: "inspector.tab.stickers", order: 0, subTabs: [
            InspectorSubTab(id: "basic", titleKey: "inspector.sub.basic", order: 0),
            InspectorSubTab(id: "mask", titleKey: "inspector.sub.mask", order: 1),
        ], appliesTo: any(.sticker)),
        InspectorTab(id: "video", titleKey: "inspector.tab.video", order: 1, subTabs: [
            InspectorSubTab(id: "basic", titleKey: "inspector.sub.basic", order: 0),
            InspectorSubTab(id: "cutout", titleKey: "inspector.sub.cutout", order: 1),
            InspectorSubTab(id: "mask", titleKey: "inspector.sub.mask", order: 2),
        ], appliesTo: any(.video, .image)),
        InspectorTab(id: "audio", titleKey: "inspector.tab.audio", order: 2, subTabs: [
            InspectorSubTab(id: "basic", titleKey: "inspector.sub.basic", order: 0),
            AudioInspector.voiceSubTab,
        ], appliesTo: { $0.kind == .video && $0.hasAudio }),
        InspectorTab(id: "audioBasic", titleKey: "inspector.sub.basic", order: 2, appliesTo: any(.audio)),
        InspectorTab(id: "speed", titleKey: "inspector.tab.speed", order: 4, subTabs: [
            InspectorSubTab(id: "normal", titleKey: "inspector.speed.normal", order: 0),
            InspectorSubTab(id: "curve", titleKey: "inspector.speed.curve", order: 1),
            InspectorSubTab(id: "velocity", titleKey: "inspector.speed.velocity", order: 2) { $0.kind == .video },
        ], appliesTo: any(.video, .audio)),
        InspectorTab(id: "animation", titleKey: "inspector.tab.animation", order: 5, subTabs: [
            InspectorSubTab(id: "in", titleKey: "anim.phase.in", order: 0),
            InspectorSubTab(id: "out", titleKey: "anim.phase.out", order: 1),
            InspectorSubTab(id: "combo", titleKey: "anim.phase.combo", order: 2) { ![.text, .sticker].contains($0.kind) },
            InspectorSubTab(id: "loop", titleKey: "anim.phase.loop", order: 2) { [.text, .sticker].contains($0.kind) },
        ], appliesTo: any(.video, .image, .text, .sticker)),
        InspectorTab(id: "adjust", titleKey: "inspector.tab.adjust", order: 6, subTabs: [
            InspectorSubTab(id: "basic", titleKey: "inspector.sub.basic", order: 0),
        ] + ColorGradingInspector.subTabs + [
            InspectorSubTab(id: "mask", titleKey: "inspector.sub.mask", order: 4) { [.video, .image, .adjustment].contains($0.kind) },
        ], footer: { ctx, _ in
            // Sticky footer on every Adjust sub-tab (CapCut [32]); adjustment-layer clips have no "Apply to all".
            guard ctx.kind != .adjustment else { return nil }
            return AnyView(AdjustFooter(ctx: ctx))
        }, appliesTo: any(.video, .image, .adjustment)),
        InspectorTab(id: "effects", titleKey: "inspector.tab.effects", order: 7,
                     appliesTo: { $0.kind.isPlacedVisual && ClipEffectBlocks.hasEffects($0) }),
        InspectorTab(id: "specialEffects", titleKey: "inspector.tab.specialEffects", order: 0, subTabs: [
            InspectorSubTab(id: "basic", titleKey: "inspector.sub.basic", order: 0),
            InspectorSubTab(id: "mask", titleKey: "inspector.sub.mask", order: 1),
        ], appliesTo: any(.effect)),
        InspectorTab(id: "filter", titleKey: "inspector.tab.filter", order: 0, subTabs: [
            InspectorSubTab(id: "basic", titleKey: "inspector.sub.basic", order: 0),
            InspectorSubTab(id: "mask", titleKey: "inspector.sub.mask", order: 1),
        ], appliesTo: any(.filter)),
    ] + AudioInspector.tabs + AIInspector.tabs

    static let sections: [InspectorSection] = [
        InspectorSection(id: "details.project", tab: "details", order: 0, titleKey: nil) { AnyView(DetailsSection(store: $0.store)) },
        InspectorSection(id: "details.colorSpace", tab: "details", order: 1, titleKey: nil) { AnyView(ColorSpaceSection(store: $0.store)) },
        InspectorSection(id: "transition.params", tab: "transition", order: 0, titleKey: "inspector.transition.params",
                         chrome: TransitionSection.chrome) { AnyView(TransitionSection(ctx: $0)) },
        InspectorSection(id: "properties.transform", tab: "properties", order: 0, titleKey: "inspector.transform") {
            AnyView(MultiTransformSection(ctx: $0))
        },

        // Sticker (ST-009: a full layer — Position & Size, Blend (opacity + mode), Mask)
        InspectorSection(id: "sticker.transform", tab: "sticker", subTab: "basic", order: 0, titleKey: "inspector.transform",
                         chrome: TransformSection.chrome) { AnyView(TransformSection(ctx: $0)) },
        InspectorSection(id: "sticker.blend", tab: "sticker", subTab: "basic", order: 10, titleKey: "inspector.blend",
                         chrome: BlendSection.chrome) { AnyView(BlendSection(ctx: $0)) },
        InspectorSection(id: "sticker.mask.shapes", tab: "sticker", subTab: "mask", order: 0, titleKey: "inspector.mask") { AnyView(MaskShapesSection(ctx: $0)) },
        InspectorSection(id: "sticker.mask.settings", tab: "sticker", subTab: "mask", order: 1, titleKey: "inspector.mask.settings",
                         appliesTo: { $0.clip?.mask != nil }, chrome: MaskSettingsSection.chrome) { AnyView(MaskSettingsSection(ctx: $0)) },

        // Video ▸ Basic
        InspectorSection(id: "video.transform", tab: "video", subTab: "basic", order: 0, titleKey: "inspector.transform",
                         chrome: TransformSection.chrome) { AnyView(TransformSection(ctx: $0)) },
        InspectorSection(id: "video.blend", tab: "video", subTab: "basic", order: 10, titleKey: "inspector.blend",
                         chrome: BlendSection.chrome) { AnyView(BlendSection(ctx: $0)) },
        InspectorSection(id: "video.crop", tab: "video", subTab: "basic", order: 20, titleKey: "inspector.crop",
                         chrome: CropSection.chrome) { AnyView(CropSection(ctx: $0)) },
        InspectorSection(id: "video.canvas", tab: "video", subTab: "basic", order: 100, titleKey: "inspector.canvas",
                         appliesTo: { $0.isMainTrack }, chrome: CanvasSection.chrome) { AnyView(CanvasSection(ctx: $0)) },

        // Video ▸ Cutout
        InspectorSection(id: "cutout.chroma", tab: "video", subTab: "cutout", order: 2, titleKey: "key.chroma",
                         chrome: ChromaKeySection.chrome) { AnyView(ChromaKeySection(ctx: $0)) },

        // Video ▸ Mask
        InspectorSection(id: "mask.shapes", tab: "video", subTab: "mask", order: 0, titleKey: "inspector.mask") { AnyView(MaskShapesSection(ctx: $0)) },
        InspectorSection(id: "mask.settings", tab: "video", subTab: "mask", order: 1, titleKey: "inspector.mask.settings",
                         appliesTo: { $0.clip?.mask != nil }, chrome: MaskSettingsSection.chrome) { AnyView(MaskSettingsSection(ctx: $0)) },

        // Audio
        InspectorSection(id: "audio.basic", tab: "audio", subTab: "basic", order: 0, titleKey: "inspector.sub.basic",
                         chrome: AudioBasicSection.chrome) { AnyView(AudioBasicSection(ctx: $0)) },
        InspectorSection(id: "audioBasic.basic", tab: "audioBasic", order: 0, titleKey: "inspector.sub.basic",
                         chrome: AudioBasicSection.chrome) { AnyView(AudioBasicSection(ctx: $0)) },

        // Speed
        InspectorSection(id: "speed.normal", tab: "speed", subTab: "normal", order: 0, titleKey: nil) { AnyView(SpeedNormalSection(ctx: $0)) },
        InspectorSection(id: "speed.curve", tab: "speed", subTab: "curve", order: 0, titleKey: nil,
                         appliesTo: { $0.kind == .video }) { AnyView(SpeedCurveSection(ctx: $0)) },

        InspectorSection(id: "speed.velocity", tab: "speed", subTab: "velocity", order: 0, titleKey: nil,
                         appliesTo: { $0.kind == .video }) { AnyView(VelocityEffectsSection(ctx: $0)) },

        // Animation
        InspectorSection(id: "animation.in", tab: "animation", subTab: "in", order: 0, titleKey: nil) { AnyView(AnimationPickerSection(ctx: $0, phase: .in)) },
        InspectorSection(id: "animation.out", tab: "animation", subTab: "out", order: 0, titleKey: nil) { AnyView(AnimationPickerSection(ctx: $0, phase: .out)) },
        InspectorSection(id: "animation.combo", tab: "animation", subTab: "combo", order: 0, titleKey: nil) { AnyView(AnimationPickerSection(ctx: $0, phase: .combo)) },
        InspectorSection(id: "animation.loop", tab: "animation", subTab: "loop", order: 0, titleKey: nil) { AnyView(AnimationPickerSection(ctx: $0, phase: .combo)) },

        // Adjust ▸ Basic
        InspectorSection(id: "adjust.presets", tab: "adjust", subTab: "basic", order: -1, titleKey: "adjust.preset.section",
                         appliesTo: { $0.kind != .adjustment && !AdjustPresets.shared.all.isEmpty }) { AnyView(AdjustPresetsSection(ctx: $0)) },
        InspectorSection(id: "adjust.filters", tab: "adjust", subTab: "basic", order: 0, titleKey: nil,
                         appliesTo: { ctx in ctx.kind != .adjustment && (ctx.clip?.effects ?? []).contains { Registries.effects[$0.typeID]?.category == .filter } }) {
            AnyView(ClipFilterBlocks(ctx: $0))
        },
        InspectorSection(id: "adjust.lut", tab: "adjust", subTab: "basic", order: 5, titleKey: "inspector.lut",
                         appliesTo: { $0.kind != .adjustment }) { AnyView(LUTSection(ctx: $0)) },
        InspectorSection(id: "adjust.basic", tab: "adjust", subTab: "basic", order: 10, titleKey: "inspector.adjust.section",
                         chrome: AdjustBasicSection.chrome) { AnyView(AdjustBasicSection(ctx: $0)) },
        InspectorSection(id: "adjust.others", tab: "adjust", subTab: "basic", order: 20, titleKey: nil,
                         appliesTo: { ctx in (ctx.clip?.effects ?? []).contains { OtherAdjustmentBlocks.listed($0) } }) {
            AnyView(OtherAdjustmentBlocks(ctx: $0))
        },

        // Adjust ▸ Mask (limits the grade to a region; same component as Video ▸ Mask)
        InspectorSection(id: "adjust.mask.shapes", tab: "adjust", subTab: "mask", order: 0, titleKey: "inspector.mask") {
            AnyView(MaskShapesSection(ctx: $0, target: .adjust))
        },
        InspectorSection(id: "adjust.mask.settings", tab: "adjust", subTab: "mask", order: 1, titleKey: "inspector.mask.settings",
                         appliesTo: { $0.clip?.adjustMask != nil }, chrome: { MaskSettingsSection.chrome($0, target: .adjust) }) {
            AnyView(MaskSettingsSection(ctx: $0, target: .adjust))
        },

        // Clip effects, effect clips, filter clips
        InspectorSection(id: "effects.stack", tab: "effects", order: 0, titleKey: nil) { AnyView(ClipEffectBlocks(ctx: $0)) },
        InspectorSection(id: "specialEffects.details", tab: "specialEffects", subTab: "basic", order: 0, titleKey: nil) { AnyView(EffectClipSection(ctx: $0)) },
        InspectorSection(id: "filter.details", tab: "filter", subTab: "basic", order: 0, titleKey: nil) { AnyView(EffectClipSection(ctx: $0)) },
        // Effect mask (FX-005 / MK-006): effect / filter layers apply inside the mask only (canvas space, `adjustMask`).
    ] + ["specialEffects", "filter"].flatMap { tab in [
        InspectorSection(id: "\(tab).mask.shapes", tab: tab, subTab: "mask", order: 0, titleKey: "inspector.mask") {
            AnyView(MaskShapesSection(ctx: $0, target: .adjust))
        },
        InspectorSection(id: "\(tab).mask.settings", tab: tab, subTab: "mask", order: 1, titleKey: "inspector.mask.settings",
                         appliesTo: { $0.clip?.adjustMask != nil }, chrome: { MaskSettingsSection.chrome($0, target: .adjust) }) {
            AnyView(MaskSettingsSection(ctx: $0, target: .adjust))
        },
    ] } + RenderFeatureInspector.sections + AudioInspector.sections + TextInspector.sections + AIInspector.sections
      + ColorGradingInspector.sections
}
