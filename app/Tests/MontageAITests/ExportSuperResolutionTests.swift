import Testing
import Foundation
@testable import MontageAI
import MontageCore
import MontageEngine
import MontageTestSupport

/// EX-018 AI ultra HD export: small clips are super-resolved into the export copy of the project, the user's project
/// is untouched, and the exported file is produced at the chosen resolution.
@Suite struct ExportSuperResolutionTests {
    @Test func ultraHDExportUpscalesSmallClipsOnACopy() async throws {
        try await HeavyWorkGate.run {
            var p = TestProject(canvas: Size2(480, 270))
            let id = try await p.addVideo(.movingBox(.white, .red), seconds: 0.5, size: CGSize(width: 480, height: 270))
            let a = p.project.media[0]
            var s = ExportSettings(); s.resolution = .p480; s.includeAudio = false; s.aiUltraHD = true   // ×1.78 → HD
            #expect(ExportHooks.clipsNeedingUpscale(p.project, settings: s).map(\.clip) == [id])
            guard VideoEnhancer.tiledSupports(480, 270) else { print("skip: no low-latency super resolution on this Mac"); return }
            let up = try await ExportSuperResolution.run(p.project, s, nil) { _ in }
            let now = try #require(up.timeline.clip(id)?.mediaID.flatMap(up.asset))
            #expect(now.pixelSize == Size2(960, 540) && up.timeline.clip(id)?.enhance?.upscale == .hd)
            #expect(p[id].mediaID == a.id)   // original project unchanged
            ExportHooks.superResolve = ExportSuperResolution.run
            let r = try await p.export(seconds: 0.5, settings: s)
            #expect(r.probe.width == 854 && r.probe.height == 480)
        }
    }
}
