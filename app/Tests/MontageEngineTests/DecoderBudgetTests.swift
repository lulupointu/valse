import Testing
import Foundation
import MontageCore
import MontageEngine

/// Decoder memory limiter (W9).
@Suite struct DecoderBudgetTests {
    func asset(_ w: Double, _ h: Double, _ name: String) -> MediaAsset {
        MediaAsset(name: name, kind: .video, url: URL(fileURLWithPath: "/tmp/\(name).mov"), duration: 10, pixelSize: Size2(w, h),
                   frameRate: .fps30, hasVideo: true, hasAudio: false, contentHash: "budget-\(name)")
    }

    func project(_ assets: [MediaAsset], overlap: Bool) throws -> Project {
        var p = Project()
        p.media = assets
        for (i, a) in assets.enumerated() {
            var c = TimelineOps.makeClip(for: a, at: overlap ? 0 : Time(Double(i) * 10))
            c.duration = 10
            try TimelineOps.insert(c, into: &p, target: i == 0 ? .automatic : .newTrack)
        }
        return p
    }

    @Test func peakCountsOnlySimultaneousStreams() throws {
        let a = (0..<4).map { asset(3840, 2160, "k\($0)") }
        let stacked = try project(a, overlap: true), sequential = try project(a, overlap: false)
        let one = MemoryBudget.decoderCost(Size2(3840, 2160))
        #expect(DecoderBudget.peak(stacked, proxied: { _ in false }) == one * 4)
        #expect(DecoderBudget.peak(sequential, proxied: { _ in false }) == one)
    }

    @Test func auxLanesCostExtraDecoders() throws {
        var p = try project([asset(1920, 1080, "aux")], overlap: true)
        let id = p.timeline.tracks.flatMap(\.clips)[0].id
        p.timeline[clip: id]?.smoothSlowMo = .frameBlending
        p.timeline[clip: id]?.motionBlur = MotionBlur(amount: 1, samples: 4)
        #expect(DecoderBudget.peak(p, proxied: { _ in false }) == MemoryBudget.decoderCost(Size2(1920, 1080)) * 5)
    }

    @Test func overBudgetPicksHeaviestOriginalsUntilItFits() throws {
        let a = [asset(3840, 2160, "big0"), asset(3840, 2160, "big1"), asset(1280, 720, "small")]
        let p = try project(a, overlap: true)
        let budget = MemoryBudget.decoderCost(Size2(3840, 2160)) * 2
        let pick = DecoderBudget.mediaNeedingProxies(p, budget: budget, isReadyOrPending: { _ in false })
        #expect(!pick.isEmpty)
        #expect(pick.allSatisfy { $0.pixelSize.width == 3840 })
        #expect(!pick.contains { $0.name == "small" })
        // already fits → nothing
        #expect(DecoderBudget.mediaNeedingProxies(p, budget: budget * 10, isReadyOrPending: { _ in false }).isEmpty)
    }
}
