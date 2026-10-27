import Testing
import Foundation
import CoreGraphics
import ValseCore
import ValseEffects
import ValseEngine
import ValseTestSupport

/// Render checks for inspector features whose pixels come from model data (W3): chroma key, canvas, crop keyframes.
@Suite(.serialized) struct InspectorRenderTests {
    @Test func chromaKeyRemovesPickedColourOnly() async throws {
        var p = TestProject(background: RGBA(0, 0, 1))
        let id = try await p.addVideo(.split(RGBA(0, 1, 0), RGBA(1, 0, 0)))   // left green, right red
        var key = Registries.effects[BuiltinKeying.chromaKeyID]!.makeInstance()
        // not picked yet → passthrough
        p[id].effects = [key]
        #expect(try await p.render(at: 0.5)[0.25, 0.5].isClose(to: RGBA(0, 1, 0)))
        key.params["color"] = .color(RGBA(0, 1, 0))
        key.params["intensity"] = .scalar(0.4)
        p[id].effects = [key]
        let img = try await p.render(at: 0.5)
        #expect(img[0.25, 0.5].isClose(to: RGBA(0, 0, 1)))   // green keyed out → background
        #expect(img[0.75, 0.5].isClose(to: RGBA(1, 0, 0)))   // red kept
    }

    @Test func colorCanvasFillsLetterbox() async throws {
        var p = TestProject(canvas: Size2(320, 180), background: .black)
        let id = try await p.addVideo(.solid(.white), size: CGSize(width: 180, height: 320))
        p[id].canvas = .color(RGBA(1, 0, 0))
        let img = try await p.render(at: 0.5)
        #expect(img[0.05, 0.5].isClose(to: .red))
        #expect(img[0.5, 0.5].isClose(to: .white))
    }

    @Test func blurCanvasFillsLetterboxWithClipContent() async throws {
        var p = TestProject(canvas: Size2(320, 180), background: .black)
        let id = try await p.addVideo(.solid(RGBA(0, 0.8, 0)), size: CGSize(width: 180, height: 320))
        p[id].canvas = .blur(level: 2)
        let img = try await p.render(at: 0.5)
        let edge = img[0.05, 0.5]
        #expect(edge.g > 0.5 && edge.r < 0.2)       // blurred green fill instead of black bars
    }

    @Test func styleCanvasDrawsPattern() async throws {
        var p = TestProject(canvas: Size2(320, 180), background: .black)
        let id = try await p.addVideo(.solid(.white), size: CGSize(width: 180, height: 320))
        p[id].canvas = .style(id: "valse.canvas.sunset")
        let img = try await p.render(at: 0.5)
        #expect(img[0.05, 0.1].luma > 0.3)          // not the black background
        #expect(img[0.5, 0.5].isClose(to: .white))
    }

    @Test func canvasStyleShadersCompile() async throws {
        for d in Registries.effects(in: .canvas) + Registries.effects(in: .key) {
            var p = TestProject(canvas: Size2(64, 36))
            let id = try await p.addVideo(.solid(.white), size: CGSize(width: 36, height: 64))
            if d.category == .canvas { p[id].canvas = .style(id: d.id) } else { p[id].effects = [d.makeInstance()] }
            _ = try await p.render(at: 0.2)
            #expect(EffectPipelines.shared.effect(d) != nil, "\(d.id) failed to compile")
        }
    }

    @Test func keyframedCropAnimates() async throws {
        var p = TestProject(background: .black)
        let id = try await p.addVideo(.solid(.white))
        p[id].keyframes[ParamKey.cropLeft.raw] = KeyframeTrack([Keyframe(time: 0, value: .scalar(0)), Keyframe(time: 1, value: .scalar(0.5))])
        // at t=1 the left half is cropped away; the remaining half is centred where it was (CapCut keeps position)
        let img = try await p.render(at: 1.2)
        #expect(img[0.25, 0.5].luma < 0.1)
        #expect(img[0.75, 0.5].isClose(to: .white))
    }
}
