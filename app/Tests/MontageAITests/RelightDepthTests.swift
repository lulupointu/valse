import Testing
import Foundation
import CoreGraphics
@preconcurrency import AVFoundation
import ImageIO
import UniformTypeIdentifiers
@testable import MontageAI
import MontageCore
import MontageEngine
import MontageTestSupport

/// Relight depth pass (AI-024): Depth Anything V2 (model-gated) and the no-model pseudo-depth on a synthetic scene
/// (sky above a checkered ground plane in perspective: the bottom is nearer), and the video depth matte job.
@Suite(.serialized) struct RelightDepthTests {
    /// Sky gradient over a perspective checkerboard floor (horizon at 40 %).
    static func scene(_ w: Int = 518, _ h: Int = 392) -> CGImage {
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let horizon = Double(h) * 0.4
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                var r = 0.45, g = 0.65, b = 0.95
                if Double(y) > horizon {
                    let dy = Double(y) - horizon
                    let z = 60 / dy                       // distance along the floor
                    let u = (Double(x) - Double(w) / 2) / dy * 0.6
                    let checker = (Int(floor(z * 2)) + Int(floor(u * 2))) & 1 == 0
                    let fog = min(1, z / 6)
                    let c = checker ? 0.85 : 0.25
                    r = c * (1 - fog) + 0.6 * fog; g = (c * 0.9) * (1 - fog) + 0.65 * fog; b = (c * 0.8) * (1 - fog) + 0.7 * fog
                } else {
                    let k = Double(y) / horizon
                    r = 0.35 + 0.3 * k; g = 0.55 + 0.25 * k; b = 0.95
                }
                px[i] = UInt8(r * 255); px[i + 1] = UInt8(g * 255); px[i + 2] = UInt8(b * 255); px[i + 3] = 255
            }
        }
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    static func bandMean(_ d: DepthMap, _ y0: Double, _ y1: Double) -> Float {
        var s: Float = 0, n: Float = 0
        for y in stride(from: y0, to: y1, by: 0.02) { for x in stride(from: 0.1, to: 0.9, by: 0.05) { s += d.value(atX: x, y: y); n += 1 } }
        return s / n
    }

    static func frameCount(_ url: URL) throws -> Int {
        let av = AVURLAsset(url: url)
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var track: AVAssetTrack?
        Task { track = try? await av.loadTracks(withMediaType: .video).first; sem.signal() }
        sem.wait()
        guard let track else { return 0 }
        let r = try AVAssetReader(asset: av)
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        r.add(o); r.startReading()
        var n = 0
        while o.copyNextSampleBuffer() != nil { n += 1 }
        return n
    }

    @Test func modelDepthIsNearerAtTheBottomOfAGroundPlane() async throws {
        try await HeavyWorkGate.run {
            guard RelightDepth.hasModel else { print("skip: depth model not installed"); return }
            let est = try DepthEstimator()
            #expect(est.usesModel)
            let clock = ContinuousClock(), t0 = clock.now
            var norm = DepthNormalizer()
            let d = norm.normalize(try est.depth(cgImage: Self.scene()))
            print("metric depth_frame_seconds=\(clock.now - t0)")
            let top = Self.bandMean(d, 0.05, 0.3), mid = Self.bandMean(d, 0.5, 0.65), bottom = Self.bandMean(d, 0.8, 0.95)
            #expect(bottom > mid && mid > top, "top \(top) mid \(mid) bottom \(bottom)")
        }
    }

    @Test func fallbackPseudoDepthIsNearerAtTheBottom() throws {
        let est = try DepthEstimator.fallback()
        var norm = DepthNormalizer()
        let d = norm.normalize(try est.depth(cgImage: Self.scene()))
        #expect(Self.bandMean(d, 0.8, 0.95) > Self.bandMean(d, 0.05, 0.3))
    }

    @Test func videoJobWritesTheDepthMatte() async throws {
        try await HeavyWorkGate.run {
            var p = TestProject()
            _ = try await p.addVideo(.movingBox(RGBA(0.1, 0.2, 0.3), RGBA(0.9, 0.8, 0.2)), seconds: 1)
            let a = p.project.media[0]
            try? FileManager.default.removeItem(at: MatteStore.shared.matteVideoURL(media: a, kind: RelightOps.depthKind))
            #expect(!RelightDepth.isDepthReady(a))
            let s = RelightSettings.preset(.object)   // target both: no person matte needed
            try await RelightJob.run(a, settings: s)
            #expect(RelightDepth.isReady(a, s))
            let info = try Self.frameCount(MatteStore.shared.matteVideoURL(media: a, kind: RelightOps.depthKind))
            #expect(info >= 10 && info <= 14, "≤ 12 fps sampling: \(info) frames")
        }
    }
}
