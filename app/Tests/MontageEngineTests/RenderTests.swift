import Testing
import Foundation
import MontageCore
import MontageEffects
import MontageEngine
import MontageTestSupport

/// Render tests: build a tiny project, render a frame through the real compositor, assert pixels.
@Suite(.serialized) struct RenderTests {
    @Test func solidVideoFillsCanvas() async throws {
        var p = TestProject()
        try await p.addVideo(.solid(.red))
        let img = try await p.render(at: 0.5)
        #expect(img[0.5, 0.5].isClose(to: .red))
        #expect(img[0.05, 0.05].isClose(to: .red))
    }

    @Test func opacityBlendsOverBackground() async throws {
        var p = TestProject(background: .black)
        let id = try await p.addVideo(.solid(.white))
        p[id].opacity = 0.5
        #expect(try await p.render(at: 0.5)[0.5, 0.5].isClose(to: RGBA(0.5, 0.5, 0.5)))
    }

    @Test func overlayTransformScalesAndMoves() async throws {
        var p = TestProject()
        try await p.addVideo(.solid(.blue))
        let o = try await p.addVideo(.solid(.green), target: .newTrack)
        p[o].transform.scale = Vec2(0.5, 0.5)
        p[o].transform.position = Vec2(0.25, 0)  // centre at x = 0.75
        let img = try await p.render(at: 0.5)
        #expect(img[0.75, 0.5].isClose(to: .green))
        #expect(img[0.25, 0.5].isClose(to: .blue))
    }

    @Test func aspectFitLetterboxesWithBackground() async throws {
        var p = TestProject(canvas: Size2(320, 180), background: RGBA(0, 0, 1))
        try await p.addVideo(.solid(.red), size: CGSize(width: 180, height: 320))  // portrait in landscape canvas
        let img = try await p.render(at: 0.5)
        #expect(img[0.5, 0.5].isClose(to: .red))
        #expect(img[0.05, 0.5].isClose(to: .blue))
    }

    @Test func filterFromRegistryApplies() async throws {
        var p = TestProject()
        let id = try await p.addVideo(.solid(RGBA(1, 0, 0)))
        p[id].effects = [Registries.effects["montage.filter.mono"]!.makeInstance()]
        let c = try await p.render(at: 0.5)[0.5, 0.5]
        #expect(abs(c.r - c.g) < 0.05 && abs(c.g - c.b) < 0.05)
        #expect(c.r > 0.1)
    }

    @Test func keyframedOpacityIsEvaluatedPerFrame() async throws {
        var p = TestProject()
        let id = try await p.addVideo(.solid(.white))
        p[id].keyframes[ParamKey.opacity.raw] = KeyframeTrack([Keyframe(time: 0, value: .scalar(0)), Keyframe(time: 1, value: .scalar(1))])
        #expect(try await p.render(at: 0.0)[0.5, 0.5].luma < 0.08)
        #expect(try await p.render(at: 0.5)[0.5, 0.5].isClose(to: RGBA(0.5, 0.5, 0.5)))
        #expect(try await p.render(at: 1.5)[0.5, 0.5].isClose(to: .white))
    }

    @Test func multiplyBlendMode() async throws {
        var p = TestProject()
        try await p.addVideo(.solid(RGBA(1, 1, 0)))
        let o = try await p.addVideo(.solid(RGBA(0, 1, 1)), target: .newTrack)
        p[o].blendMode = .multiply
        #expect(try await p.render(at: 0.5)[0.5, 0.5].isClose(to: RGBA(0, 1, 0)))
    }

    @Test func circleMaskCutsCorners() async throws {
        var p = TestProject(background: .black)
        let id = try await p.addVideo(.solid(.white))
        p[id].mask = Mask(shape: .circle, size: Vec2(0.5, 0.9))
        let img = try await p.render(at: 0.5)
        #expect(img[0.5, 0.5].isClose(to: .white))
        #expect(img[0.03, 0.05].isClose(to: .black))
    }

    @Test func transitionMixesBothSides() async throws {
        var p = TestProject()
        let a = try await p.addVideo(.solid(.red))
        try await p.addVideo(.solid(.blue), at: 5)
        try TimelineOps.setTransition(a, TransitionInstance(typeID: "montage.transition.dissolve", duration: 1), in: &p.project.timeline)
        // transition spans [1, 2): midpoint is 50/50
        let c = try await p.render(at: 1.5)[0.5, 0.5]
        #expect(c.isClose(to: RGBA(0.5, 0, 0.5), tolerance: 0.1))
        #expect(try await p.render(at: 2.5)[0.5, 0.5].isClose(to: .blue))
    }

    @Test func adjustmentLayerAffectsLayersBelow() async throws {
        var p = TestProject()
        try await p.addVideo(.solid(RGBA(0.2, 0.6, 1.0)))
        try p.addAdjustment([Registries.effects["montage.filter.invert"]!.makeInstance()])
        #expect(try await p.render(at: 0.5)[0.5, 0.5].isClose(to: RGBA(0.8, 0.4, 0.0)))
    }

    @Test func textAndStickersRender() async throws {
        var p = TestProject(background: .black)
        try p.addText("████") { $0.fontSize = 0.3; $0.color = .white }
        let img = try await p.render(at: 0.5)
        #expect(img[0.5, 0.5].luma > 0.5)
        #expect(img[0.02, 0.02].luma < 0.05)
    }

    @Test func imageClipsRender() async throws {
        var p = TestProject()
        try await p.addImage(.split(.red, .green))
        let img = try await p.render(at: 0.5)
        #expect(img[0.4, 0.5].isClose(to: .red))
        #expect(img[0.6, 0.5].isClose(to: .green))
    }

    @Test func speedRemapsSourceFrames() async throws {
        // frameIndex pattern: gray = (frame * 4) % 256. At 2x, timeline 0.5 s shows source 1.0 s = frame 30 → 120/255.
        var p = TestProject()
        let id = try await p.addVideo(.frameIndex, seconds: 2)
        try TimelineOps.setSpeed(id, .constant(2), in: &p.project.timeline)
        #expect(p[id].duration == Time(1))
        let g = try await p.render(at: 0.5).average(x: 0.4, y: 0.4, w: 0.2, h: 0.2).r
        #expect(abs(g - 120.0 / 255) < 0.03)
    }

    @Test func trimmedClipStartsAtInPoint() async throws {
        var p = TestProject()
        let id = try await p.addVideo(.frameIndex, seconds: 2)
        try TimelineOps.trim(id, edge: .head, to: 0.5, in: &p.project)  // in-point at frame 15 → 60/255
        let g = try await p.render(at: 0).average(x: 0.4, y: 0.4, w: 0.2, h: 0.2).r
        #expect(abs(g - 60.0 / 255) < 0.03)
    }

    @Test func everyBuiltinShaderCompiles() {
        #expect(EffectPipelines.shared.validateAll().isEmpty)
    }
}
