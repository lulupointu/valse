import Testing
import Foundation
import AVFoundation
import MontageCore
import MontageEngine
import MontageTestSupport

/// Preview render cache (W9 PB-005).
@Suite(.serialized) struct RenderCacheTests {
    static func previewFrame(_ project: Project, at t: Double, size: CGSize) async throws -> (Bitmap, BuiltComposition) {
        let built = try await CompositionBuilder.build(project: project, purpose: .preview, renderSize: size)
        let gen = AVAssetImageGenerator(asset: built.composition)
        gen.videoComposition = built.videoComposition
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
        let (img, _) = try await gen.image(at: Time(t).cmTime)
        return (Bitmap(img), built)
    }

    @Test func keyChangesWithContentButNotWithUnrelatedClips() async throws {
        var p = TestProject()
        let a = try await p.addVideo(.solid(.red), seconds: 2)
        let size = CGSize(width: 320, height: 180)
        let r = TimeRange(start: 0, duration: 1)
        let k0 = RenderCache.key(p.project, range: r, size: size)
        try p.addText("later", at: 5, duration: 1)                         // outside the range
        #expect(RenderCache.key(p.project, range: r, size: size) == k0)
        p[a].opacity = 0.5
        #expect(RenderCache.key(p.project, range: r, size: size) != k0)
    }

    @Test func cachedSegmentIsServedAndInvalidatedByEdits() async throws {
        var p = TestProject()
        let id = try await p.addVideo(.split(.red, .green), seconds: 2)
        let size = CGSize(width: 320, height: 180)
        let r = TimeRange(start: 0, duration: 1)
        if let job = await RenderCache.shared.request(p.project, range: r, size: size) { _ = await JobQueue.shared.wait(job) }
        #expect(RenderCache.shared.validSegments(p.project, size: size).count == 1)

        let (img, built) = try await Self.previewFrame(p.project, at: 0.5, size: size)
        #expect(built.state.cacheHits > 0)
        #expect(img[0.25, 0.5].isClose(to: .red) && img[0.75, 0.5].isClose(to: .green))

        // a property edit (no rebuild) must bypass the now-stale segment
        var edited = p.project
        edited.timeline[clip: id]?.opacity = 0
        built.state.update(project: edited)
        let hits = built.state.cacheHits
        let gen = AVAssetImageGenerator(asset: built.composition)
        gen.videoComposition = built.videoComposition
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
        let after = Bitmap(try await gen.image(at: Time(0.4).cmTime).image)
        #expect(built.state.cacheHits == hits)
        #expect(after[0.25, 0.5].luma < 0.08)
        // outside the segment frames are always live
        #expect(RenderCache.shared.validSegments(edited, size: size).isEmpty)
    }

    @Test func heavyRangesFindStackedLayers() async throws {
        var p = TestProject()
        try await p.addVideo(.solid(.red), seconds: 4)
        for _ in 0..<3 { try await p.addVideo(.solid(.blue), seconds: 1, at: 1, target: .newTrack) }
        let h = RenderCache.heavyRanges(p.project)
        #expect(h.count == 1)
        #expect(h.first.map { abs($0.start.seconds - 1) < 0.01 && abs($0.end.seconds - 2) < 0.01 } == true)
    }
}
