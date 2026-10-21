import Testing
import Foundation
import MontageCore
import MontageEffects
import MontageEngine
@testable import MontageUI
import MontageTestSupport

/// W3 UX-gap fixes: locale number formats, per-kind tab memory, curves endpoints/eyedropper, velocity presets,
/// Apply to all / presets of the whole Adjust grade.
@MainActor @Suite(.serialized) struct InspectorPolishTests {
    @Test func numberFormatsFollowTheUILanguage() {
        MontageBootstrap.registerResources()
        defer { L10n.shared.setLanguageForSession("en") }
        L10n.shared.setLanguageForSession("fr")
        #expect(Fmt.degrees(0) == "0,00°")
        #expect(Fmt.speed(1) == "1,00×")
        #expect(Fmt.seconds(5) == "5,0\u{202F}s")
        #expect(Fmt.decibels(-6) == "\u{2212}6,0\u{202F}dB")
        #expect(Fmt.decibels(-.infinity) == "\u{2212}∞\u{202F}dB")
        #expect(Fmt.degrees(-0.001) == "0,00°", "no negative zero")
        L10n.shared.setLanguageForSession("en")
        #expect(Fmt.degrees(12.5) == "12.50°")
        #expect(Fmt.speed(2) == "2.00×")
        #expect(Fmt.seconds(5) == "5.0s")
        #expect(Fmt.int(-30) == "\u{2212}30")
        // what we print parses back
        for s in ["\u{2212}6,0\u{202F}dB", "1,00×", "\u{2212}30", "5.0s"] { #expect(NumberParse.number(s) != nil, "\(s)") }
        #expect(NumberParse.number("\u{2212}6,5 dB") == -6.5)
    }

    @Test func inspectorRemembersTheTabPerClipKind() async throws {
        let p = try await DemoProject.make()
        let s = EditorStore(project: p); s.autosaveEnabled = false
        let tl = s.project.timeline
        let text = tl.tracks.first { $0.kind == .text }!.clips[0].id
        let sticker = tl.tracks.first { $0.kind == .sticker }!.clips[0].id
        let video = tl.mainTrack!.clips[0].id
        s.selection = [text]; s.inspectorTab = "tracking"
        s.selection = [sticker]
        #expect(s.inspectorTab == nil, "a sticker opens on its first tab, not Text's Tracking")
        s.selection = [video]; s.inspectorTab = "speed"
        s.selection = [text]
        #expect(s.inspectorTab == "tracking")
        s.selection = [video]
        #expect(s.inspectorTab == "speed")
    }

    @Test func curvesStartAsEndpointsAndTheEyedropperAddsAPoint() {
        let identity = ColorCurveMath.points(BuiltinColor.curves.makeInstance().params, channel: "luma")
        #expect(CurveEditor.displayed(identity).count == 2)
        let bent: [ColorCurveMath.Point] = [(0, 0), (0.5, 0.7), (1, 1)]
        #expect(CurveEditor.displayed(bent).count == 3)
        let added = CurveEditor.pointAdding(level: 0.3, to: CurveEditor.endpoints)!
        #expect(added.count == 3 && abs(added[1].x - 0.3) < 1e-9 && abs(added[1].y - 0.3) < 1e-6, "on the current curve")
        #expect(CurveEditor.pointAdding(level: 0.005, to: CurveEditor.endpoints) == nil)
        #expect(abs(CurveEditor.level(RGBA(1, 0, 0), channel: "red") - 1) < 1e-9)
    }

    @Test func velocityPresetsAreSpeedCurves() {
        #expect(SpeedCurvePreset.velocity.count >= 6)
        for v in SpeedCurvePreset.velocity {
            #expect(SpeedCurvePreset.preset(v.id)?.id == v.id)
            #expect(tr(v.nameKey) != v.nameKey)
            #expect(v.points.first?.x == 0 && v.points.last?.x == 1)
        }
    }

    @Test func applyToAllCopiesTheWholeGradeAndPresetsRoundTrip() async throws {
        var p = TestProject(canvas: Size2(320, 180))
        let a = try await p.addVideo(.solid(.blue), seconds: 2)
        let b = try await p.addVideo(.solid(.red), seconds: 2, at: 100)
        let s = EditorStore(project: p.project); s.autosaveEnabled = false
        s.perform(UpdateClip(a, nameKey: "cmd.adjust") { c in
            var basic = BuiltinAdjustments.basic.makeInstance(); basic.params["contrast"] = .scalar(0.3)
            var hsl = BuiltinColor.hsl.makeInstance(); hsl.params["red.sat"] = .scalar(-0.5)
            c.effects = [Registries.effects["montage.filter.warm"]!.makeInstance(), basic, hsl]
            c.adjustMask = Mask(shape: .circle)
        })
        s.selection = [a]
        AdjustTools.applyToAll(InspectorContext(store: s))
        let cb = s.project.timeline.clip(b)!
        #expect(cb.effects.map(\.typeID) == [BuiltinAdjustments.basic.id, BuiltinColor.hsl.id], "grade copied, filter not")
        #expect(cb.effects[1].params["red.sat"] == .scalar(-0.5))
        #expect(cb.adjustMask?.shape == .circle)
        #expect(Set(cb.effects.map(\.id)).isDisjoint(with: s.project.timeline.clip(a)!.effects.map(\.id)), "fresh instance ids")
        #expect(s.session.undoStack.last?.nameKey == "cmd.adjust.applyAll")

        let store = AdjustPresets(defaults: AdjustPresets.testDefaults())
        let preset = store.add(effects: AdjustTools.grading(of: s.project.timeline.clip(a)!), mask: nil)
        #expect(store.all.count == 1 && preset.name == tr("adjust.preset.name", 1))
        #expect(AdjustPresets(defaults: UserDefaults(suiteName: "montage.uitest.adjustPresets")!).all.first?.effects.count == 2, "persisted")
        store.remove(preset.id)
        #expect(store.all.isEmpty)
    }

    /// CL-013: Adjustment asset tab ▸ My presets — ⊕ adds an adjustment layer carrying the grade, "Apply to selected
    /// clip" grades only video / image / adjustment clips, one undo step each.
    @Test func myPresetsInTheAdjustmentTab() async throws {
        let nav = EffectLibraryCatalog.nav(.adjustment).map(\.id)
        #expect(Array(nav.prefix(3)) == [EffectLibraryCatalog.favoritesNav, EffectLibraryCatalog.customAdjustNav, EffectLibraryCatalog.myPresetsNav])
        #expect(!EffectLibraryCatalog.nav(.effect).map(\.id).contains(EffectLibraryCatalog.myPresetsNav))

        var p = TestProject(canvas: Size2(320, 180))
        let v = try await p.addVideo(.solid(.blue), seconds: 2)
        let a = try await p.addAudio(seconds: 2)
        let s = EditorStore(project: p.project); s.autosaveEnabled = false
        var basic = BuiltinAdjustments.basic.makeInstance(); basic.params["contrast"] = .scalar(0.3)
        let preset = AdjustPreset(name: "P", effects: [basic], mask: Mask(shape: .circle))

        let layer = try #require(s.addAdjustmentLayer(preset: preset, at: Time(1)))
        let lc = try #require(s.project.timeline.clip(layer))
        #expect(lc.content == .adjustment && lc.start == Time(1))
        #expect(lc.effects.map(\.typeID) == [BuiltinAdjustments.basic.id] && lc.effects[0].params["contrast"] == .scalar(0.3))
        #expect(lc.effects[0].id != basic.id, "fresh instance id")
        #expect(lc.adjustMask?.shape == .circle)
        #expect(s.selection == [layer] && s.inspectorTab == "adjust")
        #expect(s.session.undoStack.last?.nameKey == "cmd.adjustmentLayer")

        #expect(Set(AdjustTools.presetTargets(s.project, selection: [v, a, layer])) == [v, layer])
        s.selection = [a]
        #expect(!s.applyAdjustPresetToSelection(preset), "audio clips take no grade")
        s.selection = [v, a]
        #expect(s.applyAdjustPresetToSelection(preset))
        #expect(s.project.timeline.clip(v)?.effects.first?.params["contrast"] == .scalar(0.3))
        #expect(s.project.timeline.clip(a)?.effects.isEmpty == true)
        #expect(s.session.undoStack.last?.nameKey == "cmd.adjust.preset")
    }
}
