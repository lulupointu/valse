import Testing
import Foundation
import MontageCore
import MontageEffects
import MontageEngine
@testable import MontageUI
import MontageTestSupport

/// Finisher P0/P1 UI logic: Custom adjustment (CL-011), eyedropper helpers (CL-024), Adjust paste group (CL-025),
/// sticker / effect-layer inspector tabs (ST-009, FX-005 / MK-006).
@MainActor @Suite(.serialized) struct FinishColorLayerUITests {
    init() { MontageBootstrap.registerResources() }

    func tab(_ id: String, _ ctx: InspectorContext) -> InspectorTab? { InspectorRegistry.tabs(for: ctx).first { $0.id == id } }
    func subs(_ id: String, _ ctx: InspectorContext) -> [String] {
        tab(id, ctx).map { InspectorRegistry.subTabs(of: $0, ctx: ctx).map(\.id) } ?? []
    }

    @Test func customAdjustmentAddsAnEmptyAdjustmentLayerAndOpensAdjust() async throws {
        var p = TestProject()
        try await p.addVideo(.solid(.blue), seconds: 4)
        let s = EditorStore(project: p.project); s.autosaveEnabled = false
        #expect(EffectLibraryCatalog.nav(.adjustment).map(\.id).dropFirst().first == EffectLibraryCatalog.customAdjustNav)
        #expect(!EffectLibraryCatalog.nav(.effect).map(\.id).contains(EffectLibraryCatalog.customAdjustNav))
        s.seek(to: Time(1))
        let id = try #require(s.addCustomAdjustment())
        let c = try #require(s.project.timeline.clip(id))
        #expect(c.content == .adjustment && c.effects.isEmpty && c.start == Time(1) && c.duration == Time(3))
        #expect(s.selection == [id] && s.inspectorTab == "adjust" && s.session.undoNameKey == "cmd.adjustmentLayer")
        let ctx = InspectorContext(store: s)
        #expect(ctx.kind == .adjustment)
        let tabs = InspectorRegistry.tabs(for: ctx).map(\.id)
        #expect(tabs.contains("adjust"))
        let sub = subs("adjust", ctx)
        #expect(sub.contains("basic") && sub.contains("hsl") && sub.contains("mask"))
    }

    @Test func effectAndFilterLayersHaveAMaskSubTabAndStickersAreFullLayers() async throws {
        var p = TestProject()
        try await p.addVideo(.solid(.blue), seconds: 4)
        let s = EditorStore(project: p.project); s.autosaveEnabled = false
        s.applyEffect(Registries.effects["montage.effect.vhs"]!)
        #expect(subs("specialEffects", InspectorContext(store: s)) == ["basic", "mask"])
        s.selection = []
        s.applyEffect(Registries.effects["montage.filter.film400"]!)
        #expect(subs("filter", InspectorContext(store: s)) == ["basic", "mask"])
        s.selection = []
        s.addGeneratorClip(.sticker(id: "montage.sticker.heart"))
        let ctx = InspectorContext(store: s)
        #expect(ctx.kind == .sticker)
        #expect(subs("sticker", ctx) == ["basic", "mask"])
        let ids = InspectorRegistry.sections(tab: tab("sticker", ctx)!, subTab: "basic", ctx: ctx).map(\.id)
        #expect(ids.contains("sticker.transform") && ids.contains("sticker.blend"))
    }

    @Test func hslEyedropperPicksTheNearestRange() {
        let keys = BuiltinColor.hslRanges.map(\.key)
        #expect(keys[HSLSection.nearestRange(RGBA(1, 0.05, 0.05))] == "red")
        #expect(keys[HSLSection.nearestRange(RGBA(0.1, 0.8, 0.2))] == "green")
        #expect(keys[HSLSection.nearestRange(RGBA(0.1, 0.3, 1))] == "blue")
        #expect(keys[HSLSection.nearestRange(RGBA(1, 0.55, 0.1))] == "orange")
        #expect(keys[HSLSection.nearestRange(RGBA(0.95, 0.2, 0.75))] == "magenta")
    }

    @Test func pasteAttributesAdjustGroupIsSeparateFromEffects() async throws {
        var p = TestProject()
        let a = try await p.addVideo(.solid(.blue), seconds: 2)
        let b = try await p.addVideo(.solid(.red), seconds: 2)
        var grade = Registries.effects["montage.adjust.basic"]!.makeInstance()
        grade.params["brightness"] = .scalar(0.4)
        p[a].effects = [grade, Registries.effects["montage.effect.vhs"]!.makeInstance()]
        p[a].adjustMask = Mask(shape: .circle)
        p[b].effects = [Registries.effects["montage.effect.snow"]!.makeInstance()]
        let src = p[a]
        var tl = p.project.timeline
        try TimelineOps.pasteAttributes(from: src, groups: [.adjust], to: [b], in: &tl)
        var dst = try #require(tl.clip(b))
        #expect(dst.effects.map(\.typeID) == ["montage.adjust.basic", "montage.effect.snow"])
        #expect(dst.effects[0].params["brightness"] == .scalar(0.4) && dst.effects[0].id != grade.id)
        #expect(dst.adjustMask?.shape == .circle)
        try TimelineOps.pasteAttributes(from: src, groups: [.effects], to: [b], in: &tl)
        dst = try #require(tl.clip(b))
        #expect(dst.effects.map(\.typeID) == ["montage.adjust.basic", "montage.effect.vhs"])
        #expect(AttributeGroup.allCases.contains(.adjust))
    }
}
