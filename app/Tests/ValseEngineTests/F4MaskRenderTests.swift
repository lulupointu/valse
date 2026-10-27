import Testing
import Foundation
import ValseCore
import ValseEffects
import ValseEngine
import ValseTestSupport

/// Smart brush regions (CL-012) and tracked brush masks (MK-004) through the real renderer.
@Suite(.serialized) struct F4MaskRenderTests {
    static func square(_ cx: Double, _ cy: Double, _ r: Double) -> [Vec2] {
        [Vec2(cx - r, cy - r), Vec2(cx + r, cy - r), Vec2(cx + r, cy + r), Vec2(cx - r, cy + r)]
    }

    /// A smart-brush stroke grades its filled region (with a hole: even-odd), not the stroke line.
    @Test func smartRegionGradesTheObjectArea() async throws {
        var p = TestProject(canvas: Size2(320, 180), background: .black)
        let id = try p.addSolid(RGBA(0.3, 0.3, 0.3))
        AdjustMaskRenderTests.brightened(&p, id)
        var m = Mask(shape: .brush, size: Vec2(1, 1))
        // region: square ring left of centre (outer 0.3 half-size in x units, inner hole 0.08)
        m.strokes = [MaskStroke(points: [Vec2(-0.25, 0)], radius: 0.01,
                                region: [Self.square(-0.25, 0, 0.2), Self.square(-0.25, 0, 0.06)])]
        p[id].adjustMask = m
        let img = try await p.render(at: 0.5)
        #expect(img[0.25 - 0.15, 0.5].g > 0.4, "inside the region: graded")
        #expect(img[0.25, 0.5].isClose(to: RGBA(0.3, 0.3, 0.3), tolerance: 0.04), "the hole stays original")
        #expect(img[0.8, 0.5].isClose(to: RGBA(0.3, 0.3, 0.3), tolerance: 0.03), "outside: original")
    }

    /// A tracked brush mask uses the shape of each source frame (left at 0 s, right at 2 s).
    @Test func trackedBrushMaskMovesWithSourceTime() async throws {
        var p = TestProject(canvas: Size2(320, 180), background: .black)
        let id = try p.addSolid(RGBA(0.3, 0.3, 0.3), duration: 2)
        AdjustMaskRenderTests.brightened(&p, id)
        var m = Mask(shape: .brush, size: Vec2(1, 1))
        m.strokes = []
        m.propagation = MaskPropagation(samples: [MaskShapeSample(time: 0, contours: [Self.square(-0.3, 0, 0.12)]),
                                                  MaskShapeSample(time: 2, contours: [Self.square(0.3, 0, 0.12)])])
        p[id].adjustMask = m
        let a = try await p.render(at: 0.0)
        #expect(a[0.2, 0.5].g > 0.4 && a[0.8, 0.5].g < 0.35, "start: left graded")
        let b = try await p.render(at: 1.0)
        #expect(b[0.5, 0.5].g > 0.4 && b[0.2, 0.5].g < 0.35, "middle: interpolated to the centre")
        let c = try await p.render(at: 1.95)
        #expect(c[0.79, 0.5].g > 0.4 && c[0.2, 0.5].g < 0.35, "end: right graded")
    }
}
