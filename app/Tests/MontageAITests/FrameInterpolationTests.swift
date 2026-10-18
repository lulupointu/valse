import Testing
import Foundation
import CoreGraphics
@testable import MontageAI
import MontageCore
import MontageEngine
import MontageTestSupport

/// Smooth slow-mo optical flow (AI-018 / SP-005) through `FrameInterpolation.provider` (VideoToolbox ML FRC).
@Suite(.serialized) struct FrameInterpolationTests {
    @Test func opticalFlowMovesTheObjectInsteadOfGhosting() async throws {
        AIEngineHooks.install()
        guard AIEngineHooks.hasOpticalFlow else { print("skip: VTFrameProcessor frame-rate conversion unsupported"); return }
        AIEngineHooks.prepareOpticalFlow(width: 640, height: 360, wait: true)   // session start is async in preview
        var p = TestProject(canvas: Size2(640, 360))
        let gray = RGBA(0.5, 0.5, 0.5), red = RGBA(0.95, 0.05, 0.05)
        let id = try await p.addVideo(.movingBox(gray, red), seconds: 1, size: CGSize(width: 640, height: 360))
        try TimelineOps.setSpeed(id, .constant(0.25), in: &p.project.timeline)
        // output t = 42/30 s → source frame 10.5 (half way between frames 10 and 11)
        let t = 42.0 / 30
        p[id].smoothSlowMo = .frameBlending
        let blend = try await p.render(at: t)
        p[id].smoothSlowMo = .opticalFlow
        let flow = try await p.render(at: t)
        // the strip that only frame 11's box covers: blending = half red, flow = box edge half way (sharp)
        let x10 = 10.0 / 29 * 0.75, step = 0.75 / 29
        let probeIn = x10 + 0.25 + step * 0.2      // inside the interpolated box
        let probeOut = x10 + 0.25 + step * 0.85    // ahead of the interpolated edge
        let bIn = blend[probeIn, 0.5], fIn = flow[probeIn, 0.5], fOut = flow[probeOut, 0.5]
        print("blend \(bIn) flowIn \(fIn) flowOut \(fOut)")
        #expect(abs(bIn.g - 0.27) < 0.12, "blend should be a half-way ghost")
        #expect(fIn.g < bIn.g - 0.08, "optical flow keeps the box solid where it moved")
        #expect(fOut.g > fIn.g + 0.1, "background ahead of the moving edge")
        // the box interior is unchanged
        #expect(flow[x10 + 0.15, 0.5].r > 0.8)
    }
}
