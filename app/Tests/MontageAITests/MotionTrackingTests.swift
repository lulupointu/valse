import Testing
import Foundation
import CoreGraphics
@testable import MontageAI
import MontageCore
import MontageEngine
import MontageTestSupport

/// Motion tracking (AI-014 / ST-005): a text follows a moving box picked in the middle of the clip (forward and
/// backward tracking), keeping its offset; scale follows the object when asked.
@Suite(.serialized) struct MotionTrackingTests {
    /// `.movingBox` (2 s, 30 fps): left edge 0 → 0.75, 0.25 × 0.25 box, vertically centred.
    static func boxX(_ seconds: Double) -> Double { (seconds * 30).rounded(.down) / 59 * 0.75 + 0.125 }

    @Test func textFollowsTheTrackedObject() async throws {
        try await HeavyWorkGate.run {
            var p = TestProject(canvas: Size2(640, 360))
            let video = try await p.addVideo(.movingBox(RGBA(0.3, 0.3, 0.35), RGBA(0.95, 0.85, 0.1)), seconds: 2, size: CGSize(width: 640, height: 360))
            let text = try p.addText("Hello", duration: 2)
            p[text].transform.position = Vec2(Self.boxX(1) - 0.5, -0.2)   // above the box at t = 1 s
            let box = NormRect(x: Self.boxX(1) - 0.125, y: 0.375, width: 0.25, height: 0.25)
            let info = MotionTrackInfo(referenceClipID: video, startTime: 1, box: box)
            let cmd = try await MotionTrackingJob.run(project: p.project, follower: text, info: info)
            try cmd.apply(to: &p.project)
            let k = try #require(p[text].keyframes[ParamKey.position.raw])
            #expect(k.keyframes.count > 20, "\(k.keyframes.count) keyframes")
            #expect(p[text].tracking == info)
            for t in [0.2, 0.6, 1.0, 1.4, 1.8] {
                let v = try #require(k.value(at: Time(t))?.vec2)
                #expect(abs(v.x - (Self.boxX(t) - 0.5)) < 0.03, "x at \(t): \(v.x) vs \(Self.boxX(t) - 0.5)")
                #expect(abs(v.y + 0.2) < 0.03, "y at \(t): \(v.y)")
            }
            // "None" removes the tracking keyframes
            try MotionTracking.remove(from: text, in: &p.project)
            #expect(p[text].keyframes[ParamKey.position.raw] == nil && p[text].tracking == nil)
        }
    }

    @Test func mappingThroughAScaledOverlayAndScaleFollowing() throws {
        // pure maths: reference layer scaled 0.5 and moved right; a box growing ×2 doubles the follower's scale
        var project = Project(name: "t", settings: ProjectSettings(canvasSize: Size2(1000, 500)))
        let asset = MediaAsset(name: "v", kind: .video, url: URL(fileURLWithPath: "/dev/null"), duration: Time(2), pixelSize: Size2(1000, 500),
                               frameRate: .fps30, hasVideo: true, hasAudio: false, contentHash: "mt-test")
        project.media.append(asset)
        var ref = TimelineOps.makeClip(for: asset, at: .zero)
        ref.transform.scale = Vec2(0.5, 0.5); ref.transform.position = Vec2(0.25, 0)
        try TimelineOps.insert(ref, into: &project, target: .automatic)
        var f = Clip(content: .text(TextContent(string: "x")), start: .zero, duration: Time(2))
        f.transform.position = Vec2(0.25, 0)
        try TimelineOps.insert(f, into: &project, target: .newTrack)
        let samples = [TrackSample(time: 0, box: NormRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1)),
                       TrackSample(time: 1, box: NormRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2))]
        let info = MotionTrackInfo(referenceClipID: ref.id, startTime: 0, box: samples[0].box, scaleWithObject: true)
        try MotionTracking.apply(samples, info: info, follower: f.id, in: &project)
        let c = try #require(project.timeline.clip(f.id))
        #expect(c.keyframes[ParamKey.position.raw]?.value(at: Time(1))?.vec2.map { abs($0.x - 0.25) < 1e-6 } == true)
        #expect(c.keyframes[ParamKey.scale.raw]?.value(at: Time(1))?.vec2.map { abs($0.x - 2) < 1e-6 } == true)
        // the canvas point of the source centre is the reference layer's centre
        let l = try #require(MotionTracking.layer(of: ref.id, in: project, at: Time(0.5)))
        let pt = MotionTracking.canvasPoint(Vec2(0.5, 0.5), layer: l, canvas: project.settings.canvasSize)
        #expect(abs(pt.x - 750) < 1e-6 && abs(pt.y - 250) < 1e-6)
        let back = try #require(MotionTracking.sourcePoint(pt, layer: l, canvas: project.settings.canvasSize, rotation: 0))
        #expect(abs(back.x - 0.5) < 1e-9 && abs(back.y - 0.5) < 1e-9)
    }
}
