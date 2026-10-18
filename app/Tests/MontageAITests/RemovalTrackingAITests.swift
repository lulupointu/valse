import Testing
import Foundation
import CoreGraphics
@testable import MontageAI
import MontageCore
import MontageEngine
import MontageTestSupport

/// AI remove ▸ Track object (AI-041): the brushed mask follows a moving object; camera tracking ▸ Custom box (AI-013).
@Suite(.serialized) struct RemovalTrackingAITests {
    /// `.movingBox` (2 s, 30 fps): 0.25 × 0.25 box, vertically centred, centre x moving 0.125 → 0.875.
    static func boxX(_ seconds: Double) -> Double { (seconds * 30).rounded(.down) / 59 * 0.75 + 0.125 }
    static func strokes(at t: Double) -> [RemovalStroke] {
        let x = boxX(t)
        return [RemovalStroke(points: [Vec2(x - 0.07, 0.45), Vec2(x + 0.07, 0.45), Vec2(x + 0.07, 0.55), Vec2(x - 0.07, 0.55)], radius: 0.07)]
    }

    @Test func trackedBoxesFollowTheObject() async throws {
        try await HeavyWorkGate.run {
            var p = TestProject(canvas: Size2(640, 360))
            let id = try await p.addVideo(.movingBox(.white, RGBA(0.9, 0.1, 0.1)), seconds: 2, size: CGSize(width: 640, height: 360))
            let a = try #require(p[id].mediaID.flatMap(p.project.asset))
            let r = try #require(try await ObjectRemover.trackedBoxes(a, strokes: Self.strokes(at: 1), tracking: RemovalTracking(time: 1)))
            #expect(r.samples.count > 40)
            for t in [0.2, 0.7, 1.3, 1.8] {
                let b = try #require(RemovalTracking.box(at: t, in: r.samples))
                #expect(abs(b.center.x - Self.boxX(t)) < 0.04, "box x at \(t): \(b.center.x) vs \(Self.boxX(t))")
                let moved = RemovalTracking.transform(Self.strokes(at: 1), from: r.ref, to: b)
                #expect(abs(moved[0].points[0].x - (Self.boxX(t) - 0.07)) < 0.05)
            }
        }
    }

    @Test func removesAMovingObjectWithLaMa() async throws {
        try await HeavyWorkGate.run {
            guard LaMaInpainter.isAvailable else { print("skip: LaMa model not installed"); return }
            var p = TestProject(canvas: Size2(640, 360))
            let id = try await p.addVideo(.movingBox(.white, RGBA(0.9, 0.1, 0.1)), seconds: 2, size: CGSize(width: 640, height: 360))
            let cmd = try await ObjectRemovalJob.run(project: p.project, clipID: id, strokes: Self.strokes(at: 1), tracking: RemovalTracking(time: 1))
            try cmd.apply(to: &p.project)
            #expect(p[id].removal?.tracking == RemovalTracking(time: 1))
            for t in [0.3, 1.0, 1.7] {
                let c = try await p.render(at: t)[Self.boxX(t), 0.5]
                print("metric removal_tracked_\(t)=\(c)")
                #expect(c.g > 0.7 && c.b > 0.7, "box removed where it is at \(t): \(c)")
            }
        }
    }

    @Test func cameraLocksOnACustomBox() async throws {
        try await HeavyWorkGate.run {
            var p = TestProject(canvas: Size2(640, 360))
            let id = try await p.addVideo(.movingBox(RGBA(0.3, 0.3, 0.35), RGBA(0.95, 0.85, 0.1)), seconds: 2, size: CGSize(width: 640, height: 360))
            var o = CameraLockOptions(target: .custom, keepSize: false, fill: .fit, zoom: 1.25)
            o.customBox = NormRect(x: Self.boxX(1) - 0.125, y: 0.375, width: 0.25, height: 0.25); o.customTime = 1
            let cmd = try await CameraLockJob.run(project: p.project, clipID: id, options: o)
            try cmd.apply(to: &p.project)
            let k = try #require(p[id].keyframes[ParamKey.position.raw])
            // the layer moves opposite to the box: at the start the box is left of centre → positive x offset
            let v0 = try #require(k.value(at: Time(0.3))?.vec2), v1 = try #require(k.value(at: Time(1.7))?.vec2)
            #expect(v0.x > 0.1 && v1.x < -0.1, "\(v0) \(v1)")
            #expect(p[id].cameraLock?.target == .custom)
        }
    }
}
