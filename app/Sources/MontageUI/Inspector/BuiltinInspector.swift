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
                     footer: { ctx, _ in AnyView(PillButton(title: tr("inspector.applyToAll")) { TransitionSection.applyToAll(ctx) }) },
                     appliesTo: any(.transition)),
        InspectorTab(id: "properties", titleKey: "inspector.tab.properties", order: -8, appliesTo: any(.multiple)),
        InspectorTab(id: "text", titleKey: "inspector.tab.text", order: 0, subTabs: [
            InspectorSubTab(id: "basic", titleKey: "inspector.sub.basic", order: 0),
        ], appliesTo: any(.text)),
        InspectorTab(id: "sticker", titleKey: "inspector.tab.stickers", order: 0, appliesTo: any(.sticker)),
        InspectorTab(id: "video", titleKey: "inspector.tab.video", order: 1, subTabs: [
            InspectorSubTab(id: "basic", titleKey: "inspector.sub.basic", order: 0),
            InspectorSubTab(id: "cutout", titleKey: "inspector.sub.cutout", order: 1),
            InspectorSubTab(id: "mask", titleKey: "inspector.sub.mask", order: 2),
        ], appliesTo: any(.video, .image)),
        InspectorTab(id: "audio", titleKey: "inspector.tab.audio", order: 2, subTabs: [
            InspectorSubTab(id: "basic", titleKey: "inspector.sub.basic", order: 0),
        ], appliesTo: { $0.kind == .video && $0.hasAudio }),
        InspectorTab(id: "audioBasic", titleKey: "inspector.sub.basic", order: 2, appliesTo: any(.audio)),
        InspectorTab(id: "speed", titleKey: "inspector.tab.speed", order: 3, subTabs: [
            InspectorSubTab(id: "normal", titleKey: "inspector.speed.normal", order: 0),
            InspectorSubTab(id: "curve", titleKey: "inspector.speed.curve", order: 1),
        ], appliesTo: any(.video, .audio)),
        InspectorTab(id: "animation", titleKey: "inspector.tab.animation", order: 4, subTabs: [
            InspectorSubTab(id: "in", titleKey: "anim.phase.in", order: 0),
            InspectorSubTab(id: "out", titleKey: "anim.phase.out", order: 1),
            InspectorSubTab(id: "combo", titleKey: "anim.phase.combo", order: 2) { ![.text, .sticker].contains($0.kind) },
            InspectorSubTab(id: "loop", titleKey: "anim.phase.loop", order: 2) { [.text, .sticker].contains($0.kind) },
        ], appliesTo: any(.video, .image, .text, .sticker)),
        InspectorTab(id: "adjust", titleKey: "inspector.tab.adjust", order: 5, subTabs: [
            InspectorSubTab(id: "basic", titleKey: "inspector.sub.basic", order: 0),
        ], footer: { ctx, sub in
            guard sub == nil || sub == "basic", ctx.kind != .adjustment, AdjustBasicSection.instance(ctx.clip) != nil else { return nil }
            return AnyView(PillButton(title: tr("inspector.applyToAll")) { AdjustBasicSection.applyToAll(ctx) })
        }, appliesTo: any(.video, .image, .adjustment)),
        InspectorTab(id: "effects", titleKey: "inspector.tab.effects", order: 6,
                     appliesTo: { $0.kind.isPlacedVisual && ClipEffectBlocks.hasEffects($0) }),
        InspectorTab(id: "specialEffects", titleKey: "inspector.tab.specialEffects", order: 0, subTabs: [
            InspectorSubTab(id: "basic", titleKey: "inspector.sub.basic", order: 0),
        ], appliesTo: any(.effect)),
        InspectorTab(id: "filter", titleKey: "inspector.tab.filter", order: 0, appliesTo: any(.filter)),
    ]

    static let sections: [InspectorSection] = [
        InspectorSection(id: "details.project", tab: "details", order: 0, titleKey: nil) { AnyView(DetailsSection(store: $0.store)) },
        InspectorSection(id: "transition.params", tab: "transition", order: 0, titleKey: "inspector.transition.params",
                         chrome: TransitionSection.chrome) { AnyView(TransitionSection(ctx: $0)) },
        InspectorSection(id: "properties.transform", tab: "properties", order: 0, titleKey: "inspector.transform") {
            AnyView(MultiTransformSection(ctx: $0))
        },

        // Text (shell — the text team owns styling)
        InspectorSection(id: "text.content", tab: "text", subTab: "basic", order: 0, titleKey: nil) { AnyView(TextContentSection(ctx: $0)) },
        InspectorSection(id: "text.transform", tab: "text", subTab: "basic", order: 10, titleKey: "inspector.transform",
                         chrome: TransformSection.chrome) { AnyView(TransformSection(ctx: $0, rotateLabelKey: "inspector.planeRotation")) },
        InspectorSection(id: "text.opacity", tab: "text", subTab: "basic", order: 20, titleKey: nil) { AnyView(OpacityRow(ctx: $0)) },

        // Sticker
        InspectorSection(id: "sticker.transform", tab: "sticker", order: 0, titleKey: "inspector.transform",
                         chrome: TransformSection.chrome) { AnyView(TransformSection(ctx: $0)) },

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
        InspectorSection(id: "cutout.auto", tab: "video", subTab: "cutout", order: 0, titleKey: "inspector.cutout.auto",
                         chrome: { _ in InspectorSectionChrome(isEnabled: .constant(false),
                                                               disabledReason: CutoutAvailability.matteCompositingAvailable ? nil : tr("inspector.cutout.unavailable")) }) { _ in AnyView(EmptyView()) },
        InspectorSection(id: "cutout.custom", tab: "video", subTab: "cutout", order: 1, titleKey: "inspector.cutout.custom",
                         chrome: { _ in InspectorSectionChrome(isEnabled: .constant(false),
                                                               disabledReason: CutoutAvailability.matteCompositingAvailable ? nil : tr("inspector.cutout.unavailable")) }) { _ in AnyView(EmptyView()) },
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

        // Animation
        InspectorSection(id: "animation.in", tab: "animation", subTab: "in", order: 0, titleKey: nil) { AnyView(AnimationPickerSection(ctx: $0, phase: .in)) },
        InspectorSection(id: "animation.out", tab: "animation", subTab: "out", order: 0, titleKey: nil) { AnyView(AnimationPickerSection(ctx: $0, phase: .out)) },
        InspectorSection(id: "animation.combo", tab: "animation", subTab: "combo", order: 0, titleKey: nil) { AnyView(AnimationPickerSection(ctx: $0, phase: .combo)) },
        InspectorSection(id: "animation.loop", tab: "animation", subTab: "loop", order: 0, titleKey: nil) { AnyView(AnimationPickerSection(ctx: $0, phase: .combo)) },

        // Adjust ▸ Basic
        InspectorSection(id: "adjust.filters", tab: "adjust", subTab: "basic", order: 0, titleKey: nil,
                         appliesTo: { ctx in ctx.kind != .adjustment && (ctx.clip?.effects ?? []).contains { Registries.effects[$0.typeID]?.category == .filter } }) {
            AnyView(ClipFilterBlocks(ctx: $0))
        },
        InspectorSection(id: "adjust.basic", tab: "adjust", subTab: "basic", order: 10, titleKey: "inspector.adjust.section",
                         chrome: AdjustBasicSection.chrome) { AnyView(AdjustBasicSection(ctx: $0)) },
        InspectorSection(id: "adjust.others", tab: "adjust", subTab: "basic", order: 20, titleKey: nil,
                         appliesTo: { ctx in (ctx.clip?.effects ?? []).contains { $0.typeID != BuiltinAdjustments.basic.id && Registries.effects[$0.typeID]?.category == .adjustment } }) {
            AnyView(OtherAdjustmentBlocks(ctx: $0))
        },

        // Clip effects, effect clips, filter clips
        InspectorSection(id: "effects.stack", tab: "effects", order: 0, titleKey: nil) { AnyView(ClipEffectBlocks(ctx: $0)) },
        InspectorSection(id: "specialEffects.details", tab: "specialEffects", subTab: "basic", order: 0, titleKey: nil) { AnyView(EffectClipSection(ctx: $0)) },
        InspectorSection(id: "filter.details", tab: "filter", order: 0, titleKey: nil) { AnyView(EffectClipSection(ctx: $0)) },
    ]
}
