import Testing
import Foundation
import CoreGraphics
import CoreText
import AppKit
import ImageIO
import UniformTypeIdentifiers
import Vision
@preconcurrency import AVFoundation
@testable import ValseAI
import ValseCore
import ValseEngine
import ValseTestSupport

/// AI movement (AI-025) on real media + camera tracking hand target (AI-013).
@Suite(.serialized) struct AIMovementAITests {
    /// 960×540 PNG: grey background, one glyph drawn at `x` (left edge, px) at 260 pt.
    static func glyphImage(_ glyph: String, x: Int, name: String) throws -> URL {
        try TestMedia.cachedSync(TestMedia.directory.appendingPathComponent("\(name).png")) { url in   // atomic in the shared cache
        let (w, h) = (960, 540)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.6, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: glyph, attributes: [.font: NSFont.systemFont(ofSize: 260)]))
        ctx.textPosition = CGPoint(x: x, y: 140)
        CTLineDraw(line, ctx)
        let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dst, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dst)
        }
    }

    @Test func stillKenBurnsZoomsOntoTheFace() async throws {
        try await HeavyWorkGate.run {
            let url = try Self.glyphImage("🧑", x: 640, name: "aimove-face-right-v1")
            let s = try SubjectAnalyzer.still(url)
            #expect(s.x > 0.65, "face on the right: \(s)")
            var p = TestProject(canvas: Size2(960, 540))
            let id = try await p.addMedia(url, duration: Time(4))
            let cmd = try await AIMovementJob.run(project: p.project, clipID: id, options: AIMovementOptions(preset: .zoom, strength: 1, syncToBeats: false))
            try cmd.apply(to: &p.project)
            let k = try #require(p[id].keyframes[ParamKey.position.raw])
            let end = try #require(k.value(at: Time(4))?.vec2)
            #expect(end.x < -0.05, "frame pulled towards the face: \(end)")
            #expect(p[id].aiMovement?.preset == .zoom)
            #expect(AIMovementJob.isCached(p.project, id), "re-apply from the cached analysis")
            _ = try await p.render(at: 2)
        }
    }

    @Test func videoMoveFollowsTheSubject() async throws {
        try await HeavyWorkGate.run {
            let url = try await FaceCoverTests.faceVideo()
            var p = TestProject(canvas: Size2(640, 360))
            let id = try await p.addMedia(url)
            let cmd = try await AIMovementJob.run(project: p.project, clipID: id, options: AIMovementOptions(preset: .dynamic, strength: 0.8))
            try cmd.apply(to: &p.project)
            #expect((p[id].keyframes[ParamKey.scale.raw]?.keyframes.count ?? 0) >= 2)
            #expect(p[id].aiMovement?.preset == .dynamic)
            #expect(TimelineOps.validate(p.project.timeline).isEmpty)
        }
    }

    @Test func handTargetFindsARenderedHand() async throws {
        // a raised-hand glyph: Vision's hand-pose model finds its 21 joints
        let url = try Self.glyphImage("✋", x: 560, name: "aimove-hand-v1")
        let h = VNImageRequestHandler(url: url)
        let r = VNDetectHumanHandPoseRequest(); r.maximumHandCount = 2
        try h.perform([r])
        let b = try #require((r.results ?? []).compactMap { CameraTracker.handRect($0) }.first)
        #expect(b.midX > 0.55 && b.midX < 0.95, "hand on the right: \(b)")
    }

    /// 2 s, 640×360: a ✋ glyph walking right (≈ +8 px/frame).
    static func handVideo() async throws -> URL {
        try await TestMedia.cached(TestMedia.directory.appendingPathComponent("hand-walk-v1.mov")) { url in   // atomic in the shared cache
        let (w, h) = (640, 360)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input)
        writer.startWriting(); writer.startSession(atSourceTime: .zero)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "✋", attributes: [.font: NSFont.systemFont(ofSize: 180)]))
        for f in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var pbOut: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pbOut)
            let pb = pbOut!
            CVPixelBufferLockBaseAddress(pb, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.setFillColor(CGColor(gray: 0.6, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.textPosition = CGPoint(x: 60 + f * 8, y: 100)
            CTLineDraw(line, ctx)
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? NSError(domain: "AIMovementAITests", code: 1) }
        }
    }

    @Test func cameraTrackingHandCentresTheHand() async throws {
        try await HeavyWorkGate.run {
            let url = try await Self.handVideo()
            var p = TestProject(canvas: Size2(640, 360))
            let id = try await p.addMedia(url)
            let samples = try await CameraTracker.samples(p.project.media[0], range: p[id].sourceRange, target: .hand)
            #expect(samples.filter { $0.size > 0 }.count >= samples.count / 2, "hand found in most frames")
            let cmd = try await CameraLockJob.run(project: p.project, clipID: id, options: CameraLockOptions(target: .hand, keepSize: true, zoom: 1.25))
            try cmd.apply(to: &p.project)
            let k = try #require(p[id].keyframes[ParamKey.position.raw])
            #expect(p[id].cameraLock?.target == .hand)
            let a = try #require(k.value(at: Time(0.2))?.vec2), b = try #require(k.value(at: Time(0.8))?.vec2)
            #expect(b.x < a.x - 0.03, "the hand walks right → the clip moves left: \(a) → \(b)")
        }
    }
}
