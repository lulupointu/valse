import Testing
import Foundation
import SwiftUI
import MontageCore
import MontageEffects
import MontageEngine
@testable import MontageUI
import MontageTestSupport

/// C2: same-kind multi-selection gets the full inspector, edits apply to every selected clip (one undo step), mixed
/// values read "-"; job progress has one source for the timeline and the inspector.
@MainActor @Suite(.serialized) struct InspectorMultiEditTests {
    struct Fixture { let store: EditorStore; let v1: ClipID, v2: ClipID, t1: ClipID, t2: ClipID, a1: ClipID, a2: ClipID }

    func fixture() async throws -> Fixture {
        var p = TestProject(canvas: Size2(320, 180))
        let v1 = try await p.addVideo(.solid(.blue), seconds: 3, audioHz: 440)
        let v2 = try await p.addVideo(.solid(.red), seconds: 3, at: 10)
        let t1 = try p.addText("One", at: 0)
        let t2 = try p.addText("Two", at: 4)
        let a1 = try await p.addMedia(try await TestMedia.audio(seconds: 3), at: 0)
        let a2 = try await p.addMedia(try await TestMedia.audio(seconds: 4, hz: 330), at: 5)
        let s = EditorStore(project: p.project)
        s.autosaveEnabled = false
        return Fixture(store: s, v1: v1, v2: v2, t1: t1, t2: t2, a1: a1, a2: a2)
    }

    func tabs(_ s: EditorStore) -> [String] { InspectorRegistry.tabs(for: InspectorContext(store: s)).map(\.id) }
    func sectionIDs(_ s: EditorStore, _ tab: String, _ sub: String?) -> [String] {
        let ctx = InspectorContext(store: s)
        let t = InspectorRegistry.allTabs.first { $0.id == tab }!
        return InspectorRegistry.sections(tab: t, subTab: sub, ctx: ctx).map(\.id)
    }
    func clip(_ s: EditorStore, _ id: ClipID) -> Clip { s.project.timeline.clip(id)! }

    @Test func sameKindSelectionShowsTheFullInspector() async throws {
        let f = try await fixture()
        let s = f.store
        s.selection = [f.v2, f.v1]
        let ctx = InspectorContext(store: s)
        #expect(ctx.kind == .video && ctx.isMulti)
        #expect(ctx.clip?.id == f.v1)   // primary = first in timeline order
        #expect(ctx.clips.map(\.id) == [f.v1, f.v2])
        #expect(tabs(s).starts(with: ["video"]) && tabs(s).contains("speed") && tabs(s).contains("adjust"))
        let basic = sectionIDs(s, "video", "basic")
        #expect(basic.contains("video.transform") && basic.contains("video.blend") && basic.contains("video.crop"))
        #expect(!basic.contains("video.reframe") && !basic.contains("video.enhanceQuality"))   // single-clip jobs hidden
        #expect(!sectionIDs(s, "video", "cutout").contains("cutout.auto"))
        s.selection = [f.t1, f.t2]
        #expect(tabs(s).first == "text")
        #expect(sectionIDs(s, "text", "basic").contains("text.stroke"))
        s.selection = [f.a1, f.a2]
        #expect(tabs(s).first == "audioBasic")
        s.selection = [f.v1, f.t1]
        #expect(tabs(s) == ["properties"])   // mixed kinds keep the relative Properties panel
        s.selection = [f.v1]
        #expect(!InspectorContext(store: s).isMulti)
    }

    @Test func editsApplyToEveryClipAsOneUndoStep() async throws {
        let f = try await fixture()
        let s = f.store
        s.selection = [f.v1, f.v2]
        Bind.apply(s, f.v1, "cmd.transform") { $0.transform.rotation = 30 }
        #expect(clip(s, f.v1).transform.rotation == 30 && clip(s, f.v2).transform.rotation == 30)
        s.performInspector(UpdateClip(f.v1, nameKey: "cmd.blend") { $0.blendMode = .screen })
        #expect(clip(s, f.v2).blendMode == .screen)
        s.undo()
        #expect(clip(s, f.v1).blendMode == .normal && clip(s, f.v2).blendMode == .normal)
        s.undo()
        #expect(clip(s, f.v1).transform.rotation == 0 && clip(s, f.v2).transform.rotation == 0)

        // slider drag: live on both, one undo step
        s.beginInspectorGesture("cmd.opacity")
        for o in [0.8, 0.5] { Bind.apply(s, f.v1, "cmd.opacity") { $0.opacity = o } }
        s.endGesture()
        #expect(clip(s, f.v1).opacity == 0.5 && clip(s, f.v2).opacity == 0.5)
        s.undo()
        #expect(clip(s, f.v1).opacity == 1 && clip(s, f.v2).opacity == 1)

        // Speed for both
        s.performInspector(SetSpeed(f.v1, .constant(2)))
        #expect(clip(s, f.v1).speed.averageRate == 2 && clip(s, f.v2).speed.averageRate == 2)
        s.undo()
        #expect(clip(s, f.v2).speed.averageRate == 1)

        // Adjust panel (instance created per clip on first edit)
        let row = ColorGradingInspector.row(InspectorContext(store: s), BuiltinColor.hsl, key: "red.hue", label: "")
        Bind.apply(s, f.v1, "cmd.adjust") { c in row.set(&c, 40, .zero) }
        let h1 = ColorGradingInspector.value(clip(s, f.v1), BuiltinColor.hsl, "red.hue")
        let h2 = ColorGradingInspector.value(clip(s, f.v2), BuiltinColor.hsl, "red.hue")
        #expect(h1 == h2 && h1 != 0)

        // text / audio multi-selections
        s.selection = [f.t1, f.t2]
        s.updateText(f.t1) { $0.fontSize = 0.2 }
        #expect(TextContentOf(clip(s, f.t1))?.fontSize == 0.2 && TextContentOf(clip(s, f.t2))?.fontSize == 0.2)
        #expect(TextContentOf(clip(s, f.t2))?.string == "Two")   // style shared, words kept
        s.selection = [f.a1, f.a2]
        Bind.apply(s, f.a1, "cmd.volume") { $0.audio.volume = 0.5 }
        #expect(clip(s, f.a2).audio.volume == 0.5)
        s.selection = [f.v1]   // single selection: the edit stays on that clip
        Bind.apply(s, f.v1, "cmd.transform") { $0.transform.rotation = 10 }
        #expect(clip(s, f.v2).transform.rotation == 0)
    }

    @Test func mixedValuesReadDash() async throws {
        let f = try await fixture()
        let s = f.store
        s.selection = [f.v1, f.v2]
        #expect(!InspectorMultiEdit.isMixed(InspectorContext(store: s).clips.map(\.transform.rotation)))
        _ = s.perform(UpdateClip(f.v2) { $0.transform.rotation = 45 })
        #expect(InspectorMultiEdit.isMixed(InspectorContext(store: s).clips.map(\.transform.rotation)))
        #expect(InspectorMultiEdit.mixedText == "-")
        #expect(!InspectorMultiEdit.isMixed([1, 1 + 1e-12]))
    }

    @Test func effectRowsReachTheSameEffectOnEveryClip() async throws {
        let f = try await fixture()
        let s = f.store
        let warm = Registries.effects["montage.filter.warm"]!
        for id in [f.v1, f.v2] { _ = s.perform(UpdateClip(id) { $0.effects.append(warm.makeInstance()) }) }
        let i1 = clip(s, f.v1).effects[0].id, i2 = clip(s, f.v2).effects[0].id
        #expect(i1 != i2)
        #expect(EffectParamRow.resolve(clip(s, f.v2), i1, warm.id) == i2)
        #expect(EffectParamRow.resolve(clip(s, f.v2), i1, nil) == nil)
    }

    @Test func jobProgressHasOneSource() {
        #expect(JobInfo.percent(0.519) == 51 && JobInfo.percent(1.2) == 100 && JobInfo.percent(-1) == 0)
    }
}

private func TextContentOf(_ c: Clip) -> TextContent? { if case .text(let t) = c.content { return t }; return nil }
