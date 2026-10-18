import Testing
import Foundation
import MontageCore
import MontageEngine
import MontageTestSupport

/// Speed curves / reverse / freeze / smooth slow-mo through the real compositor (W6/W9).
/// `.frameIndex` media: grey level = (frame · 4) % 256, so one source frame = 4 levels.
@Suite(.serialized) struct TimeRemapTests {
    static func level(_ img: Bitmap) -> Double { img.average(x: 0.3, y: 0.3, w: 0.4, h: 0.4).r * 255 }
    static func expectedLevel(frame: Int) -> Double { Double((frame * 4) % 256) }

    @Test func speedCurveIsFrameAccurate() async throws {
        var p = TestProject()
        let id = try await p.addVideo(.frameIndex, seconds: 2)
        let curve = SpeedCurve(points: [SpeedPoint(0, 0.4), SpeedPoint(0.5, 3), SpeedPoint(1, 0.6)])
        try TimelineOps.setSpeed(id, .curve(curve), in: &p.project.timeline)
        let clip = p[id]
        let fd = FrameRate.fps30.frameDuration
        var worst = 0.0
        for k in stride(from: 1, to: Int(clip.duration / fd) - 1, by: 3) {
            let t = fd * Double(k)
            let s = clip.sourceTime(at: t)
            let frame = Int((s.seconds * 30 + 1e-6).rounded(.down))
            let got = Self.level(try await p.render(at: t.seconds))
            worst = max(worst, abs(got - Self.expectedLevel(frame: frame)))
        }
        // < half a source frame (2 levels) everywhere; the old 32-chord approximation was off by several frames
        #expect(worst < 2.0, "worst error \(worst) levels")
    }
}
