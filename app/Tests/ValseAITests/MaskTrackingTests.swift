import Testing
import Foundation
import CoreGraphics
@testable import ValseAI
import ValseCore
import ValseEngine
import ValseTestSupport

/// Mask tracking (MK-003): a circle mask placed on the moving box follows it (forward + backward) as keyframes.
@Suite(.serialized) struct MaskTrackingTests {
    @Test func uvAndRawConversionsRoundTripThroughCropFlipAndRotation() {
        var c = Clip(content: .solid(.white), start: 0, duration: 1)
        c.crop = CropRect(left: 0.1, top: 0.2, right: 0.05, bottom: 0)
        c.transform.flipH = true
        for rot in [0, 90, 180, 270] {
            let uv = Vec2(0.3, 0.7)
            let back = MaskTracking.rawToUV(MaskTracking.uvToRaw(uv, clip: c, rotation: rot), clip: c, rotation: rot)
            #expect(abs(back.x - uv.x) < 1e-9 && abs(back.y - uv.y) < 1e-9, "rotation \(rot)")
        }
    }

    @Test func circleMaskFollowsTheMovingBox() async throws {
        try await HeavyWorkGate.run {
            var p = TestProject(canvas: Size2(640, 360))
            let video = try await p.addVideo(.movingBox(RGBA(0.3, 0.3, 0.35), RGBA(0.95, 0.85, 0.1)), seconds: 2, size: CGSize(width: 640, height: 360))
            // mask on the box at t = 1 s (layer uv: centre offset from the layer centre)
            p[video].mask = Mask(shape: .circle, center: Vec2(MotionTrackingTests.boxX(1) - 0.5, 0), size: Vec2(0.2, 0.3))
            let cmd = try await MaskTrackingJob.run(project: p.project, clipID: video, mask: \.mask, center: .maskCenter, size: .maskSize,
                                                    from: Time(1), direction: .both)
            try cmd.apply(to: &p.project)
            let k = try #require(p[video].keyframes[ParamKey.maskCenter.raw])
            #expect(k.keyframes.count > 15)
            for t in [0.2, 0.6, 1.4, 1.8] {
                let v = try #require(k.value(at: Time(t))?.vec2)
                #expect(abs(v.x - (MotionTrackingTests.boxX(t) - 0.5)) < 0.03, "x at \(t): \(v.x)")
                #expect(abs(v.y) < 0.03)
            }
            // forward only: nothing written before the start time
            p[video].keyframes = [:]
            let fwd = try await MaskTrackingJob.run(project: p.project, clipID: video, mask: \.mask, center: .maskCenter, size: .maskSize,
                                                    from: Time(1), direction: .forward)
            try fwd.apply(to: &p.project)
            let f = try #require(p[video].keyframes[ParamKey.maskCenter.raw]?.keyframes)
            #expect(f.first!.time >= Time(0.95))
        }
    }
}
