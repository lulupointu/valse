import Testing
import Foundation
import AppKit
import SwiftUI
import MontageCore
import MontageEffects
import MontageEngine
@testable import MontageUI
import MontageTestSupport

/// W5 keyframe flows through the store: ⌘C/⌘V keyframes, reset, ⇧⌥K, curves, keyframe panel + motion path pictures.
@MainActor @Suite(.serialized) struct KeyframeStoreTests {
    func store() async throws -> (EditorStore, [ClipID]) {
        var p = TestProject(canvas: Size2(320, 180))
        let a = try await p.addVideo(.solid(.red), seconds: 4)
        let b = try await p.addVideo(.solid(.blue), seconds: 4, at: 10)
        p[a].toggleKeyframes(ParamKey.transformGroup, at: .zero, tolerance: Time(ticks: 1))
        p[a].setValue(.position, .vec2(Vec2(0.3, -0.2)), at: Time(2))
        p[a].setValue(.scale, .vec2(Vec2(1.5, 1.5)), at: Time(2))
        let s = EditorStore(project: p.project)
        s.autosaveEnabled = false
        return (s, [a, b])
    }

    @Test func copyPasteKeyframesWithTheClipboardShortcuts() async throws {
        let (s, ids) = try await store()
        s.select([ids[0]])
        s.timelineUI.selectedKeyframe = KeyframeRef(clip: ids[0], key: ParamKey.position.raw, time: Time(2))
        s.copySelection()                       // ⌘C on a selected keyframe copies keyframes
        #expect(s.keyframeUI.clipboardActive && s.keyframeUI.clipboard?.entries.count == 2)
        s.select([ids[1]])
        s.transport.playhead = s.project.timeline.clip(ids[1])!.start + Time(1)
        s.paste()                               // ⌘V pastes them at the playhead
        let b = s.project.timeline.clip(ids[1])!
        #expect(b.keyframes[ParamKey.position.raw]?.keyframes.map(\.time) == [Time(1)])
        #expect(b.value(.position, at: Time(1))?.vec2 == Vec2(0.3, -0.2))
        s.undo()
        #expect(s.project.timeline.clip(ids[1])!.keyframes.isEmpty)
        // copying clips makes ⌘V paste clips again
        s.copySelection()
        #expect(!s.keyframeUI.clipboardActive)
    }

    @Test func resetAddAndCurveCommands() async throws {
        let (s, ids) = try await store()
        s.select([ids[0]])
        s.transport.playhead = s.project.timeline.clip(ids[0])!.start + Time(3)
        s.addKeyframeAtPlayhead()               // ⇧⌥K: every keyframed property gets a key at 3 s
        let a = s.project.timeline.clip(ids[0])!
        #expect(a.keyframes[ParamKey.rotation.raw]?.keyframes.count == 2)
        let ref = KeyframeRef(clip: ids[0], key: ParamKey.position.raw, time: .zero)
        s.setKeyframeEasing(.easeOut, ref)
        #expect(s.project.timeline.clip(ids[0])!.keyframes[ParamKey.position.raw]?.keyframes.first?.easing == .easeOut)
        s.setKeyframeEasing(.easeIn, ref, allSegments: true)
        #expect(s.project.timeline.clip(ids[0])!.keyframes[ParamKey.position.raw]!.keyframes.allSatisfy { $0.easing == .easeIn })
        s.resetKeyframes()
        #expect(s.project.timeline.clip(ids[0])!.keyframes.isEmpty)
        s.undo()
        #expect(!s.project.timeline.clip(ids[0])!.keyframes.isEmpty)
        #expect(ShortcutRegistry.all.contains { $0.id == "keyframePanel" && $0.modifiers == .option })
    }

    @Test func timelineMenuUsesTheSharedPresetCurves() {
        #expect(TimelineView.easingPresets.count == EasingPreset.all.count)
    }

    /// Keyframe panel and canvas motion path, drawn offscreen (MONTAGE_SNAPSHOT_DIR=… writes PNGs to look at).
    @Test func keyframePanelAndMotionPathRender() async throws {
        let (s, ids) = try await store()
        s.select([ids[0]])
        s.timelineUI.selectedKeyframe = KeyframeRef(clip: ids[0], key: ParamKey.position.raw, time: .zero)
        s.setKeyframeEasing(EasingPreset.all.first { $0.id == "reboundOut" }!.easing,
                            KeyframeRef(clip: ids[0], key: ParamKey.position.raw, time: .zero))
        s.transport.playhead = s.project.timeline.clip(ids[0])!.start + Time(1)
        let panel = KeyframePanel(store: s).frame(width: 560, height: 420)
        #expect(TransitionStoreTests.snapshot(panel, size: CGSize(width: 560, height: 420)) != nil)

        // motion path into a bitmap the size of a player
        let w = 480, h = 300
        let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        cg.setFillColor(.black); cg.fill(CGRect(x: 0, y: 0, width: w, height: h))
        cg.translateBy(x: 0, y: CGFloat(h)); cg.scaleBy(x: 1, y: -1)   // flipped like the overlay view
        let vp = PlayerViewport(viewSize: CGSize(width: w, height: h), canvas: s.project.settings.canvasSize)
        MotionPathDrawing.draw(cg, viewport: vp, store: s)
        let img = cg.makeImage()!
        let bmp = Bitmap(img)
        // start keyframe at the canvas centre, end keyframe at +0.3 w / -0.2 h
        let start = vp.toView(Vec2(160, 90)), end = vp.toView(Vec2(160 + 0.3 * 320, 90 - 0.2 * 180))
        #expect(bmp.pixel(Int(start.x), Int(start.y)).luma > 0.5)
        #expect(bmp.pixel(Int(end.x), Int(end.y)).luma > 0.5)
        if let dir = ProcessInfo.processInfo.environment["MONTAGE_SNAPSHOT_DIR"] {
            bmp.writePNG(URL(fileURLWithPath: dir).appendingPathComponent("w5-motion-path.png"))
        }
    }

    /// AI QA: camera tracking / reframe / AI movement keyframes (one per analysed frame) drew a band of diamonds over
    /// the subject's face; generated paths are hidden and dense hand-made ones drop their diamonds.
    @Test func motionPathHidesGeneratedAndDenseKeyframes() async throws {
        let (s, ids) = try await store()
        var c = s.project.timeline.clip(ids[0])!
        #expect(MotionPathDrawing.showsPath(c) && MotionPathDrawing.showsDiamonds(c))
        for i in 0..<40 { c.setValue(.position, .vec2(Vec2(Double(i) / 100, 0)), at: Time(Double(i) * 0.1)) }
        #expect(MotionPathDrawing.showsPath(c) && !MotionPathDrawing.showsDiamonds(c))
        c.cameraLock = CameraLockOptions(target: .face)
        #expect(!MotionPathDrawing.showsPath(c))
        c.cameraLock = nil; c.reframe = ReframeOptions()
        #expect(!MotionPathDrawing.showsPath(c))
        c.reframe = nil; c.aiMovement = AIMovementOptions(preset: .soft)
        #expect(!MotionPathDrawing.showsPath(c))
    }
}
