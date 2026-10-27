import Testing
import Foundation
import AppKit
import SwiftUI
import ValseCore
import ValseEffects
import ValseEngine
@testable import ValseUI
import ValseTestSupport

/// Inspector tabs per selection type, store-level behaviour of inspector edits, and (with VALSE_SNAPSHOT_DIR set)
/// offscreen PNG renders of every panel for visual review.
@MainActor @Suite(.serialized) struct InspectorTests {
    struct Fixture {
        let store: EditorStore
        let video: ClipID, video2: ClipID, image: ClipID, audio: ClipID, text: ClipID, sticker: ClipID
        let effect: ClipID, filter: ClipID, adjustment: ClipID
    }

    func fixture() async throws -> Fixture {
        var p = TestProject(canvas: Size2(320, 180))
        let v = try await p.addVideo(.movingBox(RGBA(hex: 0x1C5D8A), RGBA(hex: 0xF5F1E3)), seconds: 4, audioHz: 440)
        let v2 = try await p.addVideo(.solid(.red), seconds: 4, at: 10)
        let img = try await p.addImage(.solid(.green), at: 0, duration: 3, target: .newTrack)
        let a = try await p.addMedia(try await TestMedia.audio(seconds: 6), at: 0)
        let t = try p.addText("Title")
        var s = Clip(content: .sticker(id: "valse.sticker.heart"), start: 0, duration: 2)
        s.transform.scale = Vec2(0.5, 0.5)
        try TimelineOps.insert(s, into: &p.project)
        let fx = try p.addAdjustment([Registries.effects["valse.effect.glitch"]!.makeInstance()])
        let fl = try p.addAdjustment([Registries.effects["valse.filter.warm"]!.makeInstance()], at: 3)
        let adj = try p.addAdjustment([BuiltinAdjustments.basic.makeInstance()], at: 6)
        let store = EditorStore(project: p.project)
        store.autosaveEnabled = false
        return Fixture(store: store, video: v, video2: v2, image: img, audio: a, text: t, sticker: s.id, effect: fx, filter: fl, adjustment: adj)
    }

    func tabs(_ s: EditorStore) -> [String] { InspectorRegistry.tabs(for: InspectorContext(store: s)).map(\.id) }
    func subs(_ s: EditorStore, _ tab: String) -> [String] {
        let ctx = InspectorContext(store: s)
        return InspectorRegistry.allTabs.first { $0.id == tab }.map { InspectorRegistry.subTabs(of: $0, ctx: ctx).map(\.id) } ?? []
    }

    @Test func tabsMatchCapCutPerSelectionType() async throws {
        let f = try await fixture()
        let s = f.store
        #expect(tabs(s) == ["details"])
        s.selection = [f.video]
        #expect(tabs(s) == ["video", "audio", "speed", "animation", "adjust"])
        #expect(subs(s, "video") == ["basic", "cutout", "mask"])
        #expect(subs(s, "speed") == ["normal", "curve", "velocity"])
        #expect(subs(s, "animation") == ["in", "out", "combo"])
        s.selection = [f.image]
        #expect(tabs(s) == ["video", "animation", "adjust"])
        s.selection = [f.audio]
        #expect(tabs(s) == ["audioBasic", "audioVoice", "speed"])
        #expect(subs(s, "speed") == ["normal"])
        s.selection = [f.text]
        #expect(tabs(s) == ["text", "animation", "tts", "tracking"])   // CapCut: Text · Animation · Text to speech · Tracking (W10)
        #expect(subs(s, "animation") == ["in", "out", "loop"])
        s.selection = [f.sticker]
        #expect(tabs(s) == ["sticker", "animation", "adjust", "tracking"])   // CV-017: stickers / shapes get Adjust
        s.selection = [f.effect]
        #expect(tabs(s) == ["specialEffects"])
        s.selection = [f.filter]
        #expect(tabs(s) == ["filter"])
        s.selection = [f.adjustment]
        #expect(tabs(s) == ["adjust"])
        s.selection = [f.video, f.image]   // C2: media + media → the full media inspector (image tabs)
        #expect(tabs(s) == ["video", "animation", "adjust"])
        s.selection = [f.video, f.text]
        #expect(tabs(s) == ["properties"])
        s.selection = []
        s.selectedTransition = f.video
        #expect(InspectorContext(store: s).kind == .transition)
    }

    @Test func applyingTransitionSelectsItAndApplyToAllCoversEveryCut() async throws {
        var p = TestProject(canvas: Size2(320, 180))
        for _ in 0..<3 { try await p.addVideo(.solid(.blue), seconds: 2, at: 100) }
        let s = EditorStore(project: p.project); s.autosaveEnabled = false
        let main = s.project.timeline.mainTrack!.clips
        s.selection = [main[0].id]
        s.applyTransition(Registries.transitions["valse.transition.dissolve"]!)
        #expect(s.selection.isEmpty && s.selectedTransition == main[0].id)
        #expect(tabs(s) == ["transition"])
        TransitionSection.applyToAll(InspectorContext(store: s))
        let after = s.project.timeline.mainTrack!.clips
        #expect(after.dropLast().allSatisfy { $0.transitionOut?.typeID == "valse.transition.dissolve" })
        #expect(TimelineOps.validate(s.project.timeline).isEmpty)
        s.selection = [after[1].id]
        #expect(s.selectedTransition == nil)
    }

    @Test func groupDiamondAndGestureCoalescing() async throws {
        let f = try await fixture()
        let s = f.store
        s.selection = [f.video]
        s.transport.playhead = Time(1)
        let ctx = InspectorContext(store: s)
        // header diamond of Position & Size keys all three properties at once (one undo step)
        let tol = ctx.keyframeTolerance
        s.perform(UpdateClip(f.video, nameKey: "cmd.keyframe.add") { $0.toggleKeyframes(ParamKey.transformGroup, at: 1, tolerance: tol) })
        #expect(ParamKey.transformGroup.allSatisfy { s.project.timeline.clip(f.video)!.hasKeyframes($0) })
        s.undo()
        #expect(s.project.timeline.clip(f.video)!.keyframes.isEmpty)
        // slider drag = begin / many updates / end → one undo entry
        let before = s.session.undoStack.count
        s.beginGesture("cmd.opacity")
        for v in [1.0, 0.8, 0.6, 0.4, 0.2] {
            Bind.apply(s, f.video, "cmd.opacity") { $0.setValue(.opacity, .scalar(v), at: .zero) }
        }
        s.endGesture()
        #expect(s.session.undoStack.count == before + 1)
        #expect(abs(s.project.timeline.clip(f.video)!.opacity - 0.2) < 1e-9)
    }

    @Test func adjustFirstEditCreatesInstanceAndApplyToAllCopies() async throws {
        var p = TestProject(canvas: Size2(320, 180))
        let a = try await p.addVideo(.solid(.blue), seconds: 2)
        let b = try await p.addVideo(.solid(.red), seconds: 2, at: 100)
        let s = EditorStore(project: p.project); s.autosaveEnabled = false
        s.selection = [a]
        #expect(AdjustBasicSection.instance(s.singleSelectedClip) == nil)
        Bind.apply(s, a, "cmd.adjust") { c in
            if AdjustBasicSection.instance(c) == nil { c.effects.append(BuiltinAdjustments.basic.makeInstance()) }
            let i = AdjustBasicSection.instance(c)!
            c.setValue(.effect(i.id, "brightness"), .scalar(0.4), at: .zero)
        }
        #expect(AdjustBasicSection.instance(s.singleSelectedClip)?.params["brightness"] == .scalar(0.4))
        AdjustBasicSection.applyToAll(InspectorContext(store: s))
        #expect(AdjustBasicSection.instance(s.project.timeline.clip(b))?.params["brightness"] == .scalar(0.4))
    }

    @Test func speedScaleRoundTripsThroughTicks() {
        let sc = SpeedNormalSection.scale
        for (v, u) in [(0.1, 0.0), (1, 0.2), (2, 0.4), (5, 0.6), (10, 0.8), (100, 1.0)] {
            #expect(abs(sc.toUnit(v) - u) < 1e-9)
            #expect(abs(sc.fromUnit(u) - v) < 1e-6)
        }
        #expect(abs(sc.fromUnit(sc.toUnit(3.3)) - 3.3) < 1e-9)
    }

    @Test func projectSettingsSizes() {
        #expect(ProjectSettingsSheet.size(ratio: "16:9", short: 1080, original: nil) == Size2(1920, 1080))
        #expect(ProjectSettingsSheet.size(ratio: "9:16", short: 1080, original: nil) == Size2(1080, 1920))
        #expect(ProjectSettingsSheet.size(ratio: "original", short: 720, original: Size2(4000, 3000)) == Size2(960, 720))
    }

    // MARK: Snapshots (visual review; opt-in)

    @Test func renderSnapshots() async throws {
        guard let dir = ProcessInfo.processInfo.environment["VALSE_SNAPSHOT_DIR"] else { return }
        let lang = ProcessInfo.processInfo.environment["VALSE_SNAPSHOT_LANG"] ?? "en"
        L10n.shared.setLanguagePreference(lang)
        defer { L10n.shared.setLanguagePreference("system") }
        let f = try await fixture()
        let s = f.store
        // give some state to look at
        s.perform(UpdateClip(f.video) { c in
            c.mask = Mask(shape: .rectangle, size: Vec2(0.6, 0.5), feather: 0.2, roundness: 0.3)
            c.keyframes[ParamKey.opacity.raw] = KeyframeTrack([Keyframe(time: 0, value: .scalar(1)), Keyframe(time: 2, value: .scalar(0.5))])
            c.effects = [BuiltinKeying.chromaKey.makeInstance()]
            c.canvas = .blur(level: 2)
        })
        let cases: [(String, Set<ClipID>, String?, String?, ((EditorStore) -> Void)?)] = [
            ("details", [], nil, nil, nil),
            ("video-basic", [f.video], "video", "basic", nil),
            ("video-cutout", [f.video], "video", "cutout", nil),
            ("video-mask", [f.video], "video", "mask", nil),
            ("video-audio", [f.video], "audio", nil, nil),
            ("video-speed", [f.video], "speed", "normal", nil),
            ("video-curve", [f.video], "speed", "curve", { st in
                st.perform(SetSpeed(f.video, .curve(SpeedCurvePreset.montage.curve)))
            }),
            ("video-animation", [f.video], "animation", "in", { st in
                st.perform(UpdateClip(f.video) { $0.animations.inAnim = AnimationInstance(typeID: "valse.anim.in.zoom") })
            }),
            ("video-adjust", [f.video], "adjust", "basic", nil),
            ("audio", [f.audio], nil, nil, nil),
            ("text", [f.text], nil, nil, nil),
            ("sticker", [f.sticker], nil, nil, nil),
            ("effect", [f.effect], nil, nil, nil),
            ("filter", [f.filter], nil, nil, nil),
            ("adjustment", [f.adjustment], nil, nil, nil),
            ("multi", [f.video, f.image], nil, nil, nil),
        ]
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (name, sel, tab, sub, prep) in cases {
            s.selection = sel
            s.inspectorTab = tab
            if let tab, let sub { InspectorUIState.shared.subTab[tab] = sub }
            s.transport.playhead = Time(1)
            prep?(s)
            try snapshot(InspectorPanel(store: s), to: URL(fileURLWithPath: dir).appendingPathComponent("inspector-\(name)-\(lang).png"))
        }
        // transition
        var p = TestProject(canvas: Size2(320, 180))
        for _ in 0..<2 { try await p.addVideo(.solid(.blue), seconds: 2, at: 100) }
        let s2 = EditorStore(project: p.project); s2.autosaveEnabled = false
        s2.selection = [s2.project.timeline.mainTrack!.clips[0].id]
        s2.applyTransition(Registries.transitions["valse.transition.dissolve"]!)
        try snapshot(InspectorPanel(store: s2), to: URL(fileURLWithPath: dir).appendingPathComponent("inspector-transition-\(lang).png"))
    }

    func snapshot<V: View>(_ view: V, to url: URL, size: CGSize = CGSize(width: 523, height: 980)) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).preferredColorScheme(.dark))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
