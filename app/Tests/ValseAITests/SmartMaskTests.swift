import Testing
import Foundation
import CoreGraphics
@testable import ValseAI
import ValseCore
import ValseEngine
import ValseTestSupport

/// Smart brush (CL-012) and brush mask tracking (MK-004) on the synthetic moving box (yellow 25 % box on grey).
@Suite(.serialized) struct SmartMaskTests {
    static func boxX(_ seconds: Double) -> Double { MotionTrackingTests.boxX(seconds) }

    static func centroid(_ cs: [[Vec2]]) -> Vec2 {
        let pts = cs.flatMap { $0 }
        return pts.reduce(Vec2(0, 0)) { $0 + $1 } * (1 / Double(max(pts.count, 1)))
    }

    @Test func contourHelpersResampleAndBlend() {
        let sq = [Vec2(0, 0), Vec2(1, 0), Vec2(1, 1), Vec2(0, 1)]
        let r = MaskContours.resample(sq, 8)
        #expect(r.count == 8)
        #expect(abs(r[2].x - 1) < 1e-9 && abs(r[2].y) < 1e-9)
        let moved = sq.map { $0 + Vec2(2, 0) }
        let mid = MaskContours.blend(sq, moved, 0.5)
        let c = Self.centroid([mid])
        #expect(abs(c.x - 1.5) < 1e-6 && abs(c.y - 0.5) < 1e-6)
        // propagation: interpolated between samples, held outside
        let p = MaskPropagation(samples: [MaskShapeSample(time: 1, contours: [moved]), MaskShapeSample(time: 0, contours: [sq])])
        #expect(abs(Self.centroid(p.contours(at: 0.5)).x - 1.5) < 1e-6)
        #expect(abs(Self.centroid(p.contours(at: -3)).x - 0.5) < 1e-6)
        #expect(abs(Self.centroid(p.contours(at: 9)).x - 2.5) < 1e-6)
        // a tracked mask renders as one region stroke
        var m = Mask(shape: .brush, size: Vec2(1, 1)); m.strokes = [MaskStroke(points: [.zero], radius: 0.1)]; m.propagation = p
        let flat = m.atSource(0.5)
        #expect(flat.propagation == nil && flat.strokes?.count == 1 && flat.strokes?.first?.region != nil)
        #expect(Mask(shape: .circle).atSource(1) == Mask(shape: .circle))
    }

    @Test func applyPropagationResetsTheBoxAndKeepsStrokesInPlace() throws {
        var p = TestProject(canvas: Size2(640, 360))
        let id = try p.addSolid(.white)
        var m = Mask(shape: .brush, center: Vec2(0.1, 0), size: Vec2(0.5, 0.5))
        m.strokes = [MaskStroke(points: [Vec2(0.2, 0)], radius: 0.1)]
        p[id].adjustMask = m
        p[id].keyframes[ParamKey.adjustMaskCenter.raw] = KeyframeTrack([Keyframe(time: .zero, value: .vec2(Vec2(0.1, 0)))])
        let sq = [Vec2(0.4, 0.4), Vec2(0.6, 0.4), Vec2(0.6, 0.6), Vec2(0.4, 0.6)]
        try MaskContours.applyPropagation([MaskShapeSample(time: 0, contours: [sq])], clipID: id, mask: \.adjustMask,
                                          center: .adjustMaskCenter, size: .adjustMaskSize, rotation: 0, in: &p.project)
        let out = try #require(p[id].adjustMask)
        #expect(out.center == .zero && out.size == Vec2(1, 1))
        #expect(p[id].keyframes[ParamKey.adjustMaskCenter.raw] == nil)
        // stroke at uv 0.5 + 0.1 + 0.2·0.5 = 0.7 → box 0.2
        #expect(abs(out.strokes![0].points[0].x - 0.2) < 1e-9)
        // raw square centred at 0.5 → box centred at 0
        #expect(abs(Self.centroid(out.propagation!.samples[0].contours).x) < 1e-9)
    }

    @Test func smartBrushSelectsTheWholeBox() async throws {
        try await HeavyWorkGate.run {
            var p = TestProject(canvas: Size2(640, 360))
            let video = try await p.addVideo(.movingBox(RGBA(0.3, 0.3, 0.35), RGBA(0.95, 0.85, 0.1)), seconds: 2, size: CGSize(width: 640, height: 360))
            var m = Mask(shape: .brush, size: Vec2(1, 1)); m.strokes = []
            p[video].adjustMask = m
            // a short dab in the middle of the box at t = 1 s (mask-box units = uv − 0.5)
            let x = Self.boxX(1) - 0.5
            let dab = MaskStroke(points: [Vec2(x - 0.01, 0), Vec2(x + 0.01, 0)], radius: 0.03)
            let raw = try await SmartMask.smartRegion(project: p.project, clipID: video, mask: \.adjustMask, stroke: dab, source: Time(1))
            let b = try #require(MaskContours.bounds(raw))
            // the region is the box (25 % × 25 %), much larger than the dab
            #expect(abs((b.max.x - b.min.x) - 0.25) < 0.05, "width \(b.max.x - b.min.x)")
            #expect(abs((b.max.y - b.min.y) - 0.25) < 0.05, "height \(b.max.y - b.min.y)")
            #expect(abs((b.min.x + b.max.x) / 2 - Self.boxX(1)) < 0.03)
        }
    }

    @Test func brushedRegionIsPropagatedThroughTheClip() async throws {
        try await HeavyWorkGate.run {
            var p = TestProject(canvas: Size2(640, 360))
            let video = try await p.addVideo(.movingBox(RGBA(0.3, 0.3, 0.35), RGBA(0.95, 0.85, 0.1)), seconds: 2, size: CGSize(width: 640, height: 360))
            let x = Self.boxX(1) - 0.5
            var m = Mask(shape: .brush, size: Vec2(1, 1))
            // paint over the box at 1 s
            m.strokes = [MaskStroke(points: [Vec2(x - 0.08, -0.05), Vec2(x + 0.08, -0.05), Vec2(x + 0.08, 0.05), Vec2(x - 0.08, 0.05)], radius: 0.08)]
            p[video].mask = m
            let cmd = try await SmartMask.propagate(project: p.project, clipID: video, mask: \.mask, center: .maskCenter, size: .maskSize,
                                                    from: Time(1), direction: .both)
            try cmd.apply(to: &p.project)
            let prop = try #require(p[video].mask?.propagation)
            #expect(prop.samples.count >= 20, "≈ 15 fps over 2 s: \(prop.samples.count)")
            for t in [0.2, 0.6, 1.4, 1.8] {
                let c = Self.centroid(prop.contours(at: t))
                #expect(abs(c.x - (Self.boxX(t) - 0.5)) < 0.04, "x at \(t): \(c.x) vs \(Self.boxX(t) - 0.5)")
                #expect(abs(c.y) < 0.04)
            }
            // the layer description carries the frame's shape
            let l = try #require(FrameEvaluator.layer(p[video], track: p.project.timeline.tracks.first { $0.clips.contains { $0.id == video } }!, project: p.project, at: Time(0.2)))
            #expect(l.mask?.propagation == nil && l.mask?.strokes?.first?.region != nil)
        }
    }
}
