import Testing
import Foundation
import CoreGraphics
@testable import MontageAI
import MontageCore
import MontageEngine
import MontageTestSupport

/// Video AI on generated media: scene detection, auto reframe, colour auto-adjust / match, tracking.
@Suite(.serialized) struct VideoAITests {
    /// red 1 s | moving box 1 s | green 1 s, exported to one file.
    static func threeShots() async throws -> URL {
        var p = TestProject()
        _ = try await p.addVideo(.solid(RGBA(0.9, 0.1, 0.1)), seconds: 1, at: 0)
        _ = try await p.addVideo(.movingBox(RGBA(0.2, 0.2, 0.7), .white), seconds: 1, at: 10)
        _ = try await p.addVideo(.solid(RGBA(0.1, 0.8, 0.2)), seconds: 1, at: 20)
        return try await p.export().url
    }

    @Test func sceneCutsAreFoundWithoutFalsePositivesOnMotion() async throws {
        let url = try await Self.threeShots()
        let cuts = try await SceneDetector.cuts(url)
        #expect(cuts.count == 2, "\(cuts)")
        if cuts.count == 2 {
            #expect(abs(cuts[0] - 1) < 0.05 && abs(cuts[1] - 2) < 0.05, "\(cuts)")
        }
        // split scene on a trimmed clip of that file
        var p = TestProject()
        let id = try await p.addMedia(url)
        try TimelineOps.trim(id, edge: .head, to: Time(0.5), in: &p.project)
        let clip = p[id]
        let times = SceneSplit.splitTimes(cuts, clip: clip)
        try SceneSplit.apply(times, to: id, in: &p.project.timeline)
        #expect(p.project.timeline.mainTrack!.clips.count == 3)
        #expect(TimelineOps.validate(p.project.timeline).isEmpty)
    }

    @Test func reframePathMaths() {
        let src = Size2(1920, 1080), canvas = Size2(1080, 1920)
        let k = ReframePath.fillScale(source: src, canvas: canvas)
        #expect(abs(k - 1920.0 / 1080.0 * 1920.0 / 1080.0 / (1920.0 / 1080.0)) < 1e-9 || k > 3)   // 16:9 in 9:16 needs ≈ 3.16×
        #expect(abs(k - (1920.0 / 1080.0) * (1920.0 / 1080.0)) < 1e-6)
        // subject at the left edge → the frame slides right but never uncovers the canvas
        let p = ReframePath.position(x: 0, y: 0.5, source: src, canvas: canvas, scale: k)
        let maxX = (1080 * k * 1920 / 1920 - 1080) / 2 / 1080
        #expect(p.x > 0 && p.x <= maxX + 1e-9)
        // smoothing keeps a static subject static, dead zone ignores jitter
        let jitter = (0..<50).map { SubjectSample(time: Double($0) / 5, x: 0.5 + ($0 % 2 == 0 ? 0.02 : -0.02), y: 0.5) }
        let s = ReframePath.smooth(jitter, options: ReframeOptions(stability: .stable))
        #expect(s.allSatisfy { abs($0.x - s[0].x) < 1e-9 })
        #expect(ReframePath.canvas(for: "9:16", current: Size2(1920, 1080)) == Size2(1080, 1920))
    }

    @Test func autoReframeFollowsTheSubject() async throws {
        var p = TestProject(canvas: Size2(640, 360))
        let id = try await p.addVideo(.movingBox(RGBA(0.1, 0.15, 0.5), .white), seconds: 2, size: CGSize(width: 640, height: 360))
        let cmd = try await AutoReframe.run(project: p.project, clipID: id, options: ReframeOptions(ratio: "9:16", speed: .fast, stability: .flexible))
        try cmd.apply(to: &p.project)
        #expect(p.project.settings.canvasSize == Size2(360, 640))
        #expect(p[id].keyframes[ParamKey.position.raw] != nil)
        for t in [0.5, 1.0, 1.5] {
            let img = try await p.render(at: t)
            let c = img.average(x: 0.45, y: 0.45, w: 0.1, h: 0.1)
            #expect(c.r > 0.7 && c.g > 0.7, "subject centred at \(t): \(c)")
        }
    }
}
