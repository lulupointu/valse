import Testing
import Foundation
@preconcurrency import AVFoundation
@testable import MontageCore
@testable import MontageEngine
import MontageEffects
import MontageTestSupport

/// Finisher rows: 3D planar rotation (CV-018), lens correction (CV-015), export motion blur (EX-025), AI ultra HD
/// selection (EX-018).
@Suite struct FinishExportCanvasTests {
    // MARK: CV-018

    @Test func tiltProjectsTheLayerInPerspective() async throws {
        var p = TestProject(canvas: Size2(320, 180), background: .black)
        let id = try p.addSolid(.white)
        p[id].transform.scale = Vec2(0.6, 0.6)
        let flat = try await p.render(at: 0.5)
        #expect(flat[0.25, 0.23].luma > 0.9 && flat[0.75, 0.23].luma > 0.9)
        p[id].transform.tilt = Vec2(0, 60)   // right edge away from the viewer
        let tilted = try await p.render(at: 0.5)
        #expect(tilted[0.5, 0.5].luma > 0.9)
        #expect(tilted[0.75, 0.23].luma < 0.1)   // far side shrinks
        #expect(tilted[0.35, 0.16].luma > 0.9 && flat[0.35, 0.16].luma < 0.1)   // near side grows taller
        // geometry used by the canvas handles / hit-testing matches
        let g = LayerGeometry(sourceSize: Size2(320, 180), canvasSize: Size2(320, 180), transform: p[id].transform)
        let c = g.corners
        #expect(c[1].y > c[0].y && c[3].y < c[2].y)   // right edge shorter than the left
        #expect(g.contains(Vec2(160, 90)) && !g.contains(Vec2(240, 41)))
    }

    @Test func tiltIsKeyframeableAndOldProjectsDecode() throws {
        var c = Clip(content: .solid(.white), start: 0, duration: 2)
        c.setValue(.tilt, .vec2(Vec2(0, 0)), at: 0)
        c.setValue(.tilt, .vec2(Vec2(40, -20)), at: 2)
        #expect(c.resolved(at: 1).transform.tilt.x > 15 && c.resolved(at: 1).transform.tilt.y < -5)
        let old = #"{"position":{"x":0.1,"y":0},"scale":{"x":1,"y":1},"rotation":5,"flipH":false,"flipV":true}"#
        let t = try JSONDecoder().decode(Transform.self, from: Data(old.utf8))
        #expect(t.tilt == .zero && t.rotation == 5 && t.flipV)
        let flat = String(decoding: try JSONEncoder().encode(Transform()), as: UTF8.self)
        #expect(!flat.contains("tilt"))
        var tilted = Transform(); tilted.tilt = Vec2(10, 0)
        #expect(try JSONDecoder().decode(Transform.self, from: JSONEncoder().encode(tilted)) == tilted)
    }

    // MARK: CV-015

    @Test func lensCorrectionFillsTheFrameOrLeavesCornersEmpty() async throws {
        var p = TestProject(canvas: Size2(320, 180), background: .black)
        let id = try await p.addVideo(.solid(.white))
        var lens = BuiltinLensCorrection.descriptor.makeInstance()
        lens.params["distortion"] = .scalar(-1)     // pincushion correction pulls the corners in
        lens.params["fill"] = .bool(false)
        p[id].effects = [lens]
        let open = try await p.render(at: 0.5)
        #expect(open[0.5, 0.5].luma > 0.9)
        #expect(open[0.01, 0.02].luma < 0.1)        // transparent corner → background
        p[id].effects[0].params["fill"] = .bool(true)
        let filled = try await p.render(at: 0.5)
        #expect(filled[0.01, 0.02].luma > 0.9)
        // barrel correction samples inwards: never a hole
        p[id].effects[0].params["distortion"] = .scalar(1)
        p[id].effects[0].params["fill"] = .bool(false)
        #expect(try await p.render(at: 0.5)[0.01, 0.02].luma > 0.9)
    }

    // MARK: EX-025

    /// A white box crossing the canvas fast (keyframed): with export motion blur its edges smear over several pixels.
    @Test func exportMotionBlurSmearsMovingEdges() async throws {
        try await HeavyWorkGate.run {
            var p = TestProject(canvas: Size2(320, 180), background: .black)
            let id = try p.addSolid(.white, duration: 1)
            p[id].transform.scale = Vec2(0.15, 0.3)
            p[id].keyframes[ParamKey.position.raw] = KeyframeTrack([Keyframe(time: 0, value: .vec2(Vec2(-0.45, 0))),
                                                                    Keyframe(time: 1, value: .vec2(Vec2(0.45, 0)))])
            var s = ExportSettings(); s.resolution = .p480; s.includeAudio = false
            let sharp = try await p.export(seconds: 1, settings: s)
            s.motionBlur = .high
            let blurred = try await p.export(seconds: 1, settings: s)
            #expect(abs(blurred.probe.duration - 1) < 0.1)
            if let n = blurred.probe.frameCount { #expect(abs(n - 30) <= 1) }
            let a = try await Self.greyRun(sharp.url), b = try await Self.greyRun(blurred.url)
            print("metric export_motion_blur_edge_px sharp=\(a) blurred=\(b)")
            #expect(b >= a + 8, "sharp \(a) blurred \(b)")
        }
    }

    /// Pixels of intermediate grey along the middle row of the frame at 0.5 s.
    static func greyRun(_ url: URL) async throws -> Int {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
        let img = try await gen.image(at: CMTime(value: 1, timescale: 2)).image
        let bm = Bitmap(img)
        return (0..<bm.width).filter { x in let l = bm.pixel(x, bm.height / 2).luma; return l > 0.12 && l < 0.88 }.count
    }

    // MARK: EX-018

    @Test func aiUltraHDPicksClipsShownLargerThanTheirSource() async throws {
        var p = TestProject(canvas: Size2(320, 180))
        let small = try await p.addVideo(.solid(.blue), seconds: 1, size: CGSize(width: 320, height: 180))
        var s = ExportSettings(); s.resolution = .p1080
        var needs = ExportHooks.clipsNeedingUpscale(p.project, settings: s)
        #expect(needs.map(\.clip) == [small] && abs(needs[0].factor - 6) < 0.01)
        s.resolution = .p480   // 854×480 vs 320×180 → ×2.67
        needs = ExportHooks.clipsNeedingUpscale(p.project, settings: s)
        #expect(abs((needs.first?.factor ?? 0) - 480.0 / 180) < 0.02)
        // a clip shrunk on the canvas or already upscaled is skipped
        p[small].transform.scale = Vec2(0.4, 0.4)
        #expect(ExportHooks.clipsNeedingUpscale(p.project, settings: s).isEmpty)
        p[small].transform.scale = .one
        p[small].enhance = VideoEnhancement(original: p.project.media[0].id, upscale: .hd)
        #expect(ExportHooks.clipsNeedingUpscale(p.project, settings: s).isEmpty)
        #expect(ExportSettings().motionBlur == .off && !ExportSettings().aiUltraHD)
        let decoded = try JSONDecoder().decode(ExportSettings.self, from: Data(#"{"codec":"hevc"}"#.utf8))
        #expect(decoded.motionBlur == .off && !decoded.aiUltraHD)
    }
}
