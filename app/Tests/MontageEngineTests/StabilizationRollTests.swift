import Testing
import Foundation
import CoreGraphics
@preconcurrency import AVFoundation
@testable import MontageEngine
import MontageCore
import MontageTestSupport

/// Content-aware stabilization (AI-059 / CV-013): roll + shift camera shake on a textured scene, with an
/// independently moving subject that must not be mistaken for camera motion.
@Suite(.serialized) struct StabilizationRollTests {
    static let frames = 45
    /// Per-frame camera shake: roll (radians) and shift (fraction of the width).
    static let roll: [Double] = (0..<frames).map { [0.0, 0.012, -0.010, 0.015, -0.012, 0.006, -0.014, 0.010][$0 % 8] }
    static let shift: [Double] = (0..<frames).map { [0.0, 0.010, -0.008, 0.012, -0.006, 0.004, -0.012, 0.008][($0 + 3) % 8] }

    /// A textured "world" (random gray tiles + discs) seen through a shaking camera; a white box walks across it.
    static func shakyVideo() async throws -> URL {
        let url = TestMedia.directory.appendingPathComponent("shake-roll-v1.mp4")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let w = 640, h = 360
        var rng = SplitMix(seed: 7)
        let tiles = (0..<(24 * 14)).map { _ in CGFloat(rng.next() % 200 + 30) / 255 }
        let discs = (0..<60).map { _ in (CGFloat(rng.next() % 900) - 130, CGFloat(rng.next() % 560) - 100, CGFloat(rng.next() % 30 + 8), CGFloat(rng.next() % 2)) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
                                                                            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input)
        writer.startWriting(); writer.startSession(atSourceTime: .zero)
        for f in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var pbOut: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pbOut)
            let pb = pbOut!
            CVPixelBufferLockBaseAddress(pb, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.setFillColor(gray: 0.5, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            // CG is y-up; the image is y-down: a CG rotation by −θ is a clockwise-positive θ in image coordinates
            ctx.saveGState()
            ctx.translateBy(x: CGFloat(w) / 2 + CGFloat(shift[f] * Double(w)), y: CGFloat(h) / 2)
            ctx.rotate(by: -CGFloat(roll[f]))
            ctx.translateBy(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2)
            let ts: CGFloat = 40
            for j in 0..<14 { for i in 0..<24 {
                ctx.setFillColor(gray: tiles[j * 24 + i], alpha: 1)
                ctx.fill(CGRect(x: CGFloat(i) * ts - 160, y: CGFloat(j) * ts - 100, width: ts, height: ts))
            } }
            for (x, y, r, k) in discs { ctx.setFillColor(gray: k, alpha: 1); ctx.fillEllipse(in: CGRect(x: x, y: y, width: r, height: r)) }
            ctx.restoreGState()
            // independently moving subject (not part of the camera motion)
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 80 + CGFloat(f) * 9, y: 140, width: 70, height: 90))
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? NSError(domain: "test", code: 1) }
        return url
    }

    @Test func similarityFitRecoversRollAndIgnoresTheMovingSubject() async throws {
        try await HeavyWorkGate.run {   // CPU-heavy: keep real-time probes from starving
            let url = try await Self.shakyVideo()
            let path = try await StabilizationStore.analyze(url)
            let r = try #require(path.r)
            var errs: [Double] = []
            for i in 1..<16 {
                errs.append(abs((r[i] - r[i - 1]) - (Self.roll[i] - Self.roll[i - 1])))
                #expect(abs((path.x[i] - path.x[i - 1]) - (Self.shift[i] - Self.shift[i - 1])) < 0.006, "x i=\(i)")
            }
            print("metric stabilize_roll_err_deg_max=\((errs.max() ?? 0) * 180 / .pi)")
            #expect((errs.max() ?? 1) < 0.004, "roll error \(errs)")   // < 0.23° per frame
        }
    }

    @Test func rollCorrectionSteadiesTheRender() async throws {
        try await HeavyWorkGate.run {   // CPU-heavy: keep real-time probes from starving
            let url = try await Self.shakyVideo()
            var p = TestProject(canvas: Size2(640, 360))
            let id = try await p.addMedia(url)
            let asset = p.project.media[0]
            try StabilizationStore.shared.store(try await StabilizationStore.analyze(url), for: asset)
            /// Mean abs luma difference between consecutive frames over the left quarter (away from the subject's path).
            func shake(_ imgs: [Bitmap]) -> Double {
                var acc = 0.0, n = 0.0
                for k in 1..<imgs.count {
                    let a = imgs[k - 1], b = imgs[k]
                    for y in stride(from: b.height / 4, to: b.height * 3 / 4, by: 2) {
                        for x in stride(from: b.width * 3 / 4, to: b.width * 15 / 16, by: 2) {
                            acc += abs(a.pixel(x, y).luma - b.pixel(x, y).luma); n += 1
                        }
                    }
                }
                return acc / max(n, 1)
            }
            var raw: [Bitmap] = [], steady: [Bitmap] = []
            for f in 12..<20 { raw.append(try await p.render(at: Double(f) / 30 + 0.001)) }
            p[id].stabilization = Stabilization(level: .mostStable)
            for f in 12..<20 { steady.append(try await p.render(at: Double(f) / 30 + 0.001)) }
            let (s0, s1) = (shake(raw), shake(steady))
            print("metric stabilize_shake_raw=\(s0) steady=\(s1)")
            #expect(s1 < s0 * 0.5, "raw \(s0) steady \(s1)")
            let track = try #require(StabilizationStore.shared.track(media: asset, level: .mostStable))
            #expect(track.dr != nil && track.zoom > 1 && track.zoom < 1.5)
        }
    }
}

/// Deterministic PRNG for test fixtures.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
