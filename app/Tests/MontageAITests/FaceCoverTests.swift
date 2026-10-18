import Testing
import Foundation
import CoreGraphics
import CoreText
import AppKit
@preconcurrency import AVFoundation
@testable import MontageAI
import MontageCore
import MontageEngine
import MontageTestSupport

/// Face mosaic (AI-051): faces matte follows a moving face (a 🧑 glyph Vision detects), cover clip linked above.
@Suite(.serialized) struct FaceCoverTests {
    static func faceVideo() async throws -> URL {
        let url = TestMedia.directory.appendingPathComponent("face-walk-v1.mov")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let (w, h) = (640, 360)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input)
        writer.startWriting(); writer.startSession(atSourceTime: .zero)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "🧑", attributes: [.font: NSFont.systemFont(ofSize: 200)]))
        for f in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var pbOut: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pbOut)
            let pb = pbOut!
            CVPixelBufferLockBaseAddress(pb, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.setFillColor(CGColor(gray: 0.6, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.textPosition = CGPoint(x: 60 + f * 8, y: 90)
            CTLineDraw(line, ctx)
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }

    @Test func facesMatteFollowsTheFaceAndCoverIsLinked() async throws {
        try await HeavyWorkGate.run {
            let url = try await Self.faceVideo()
            var p = TestProject(canvas: Size2(640, 360))
            let id = try await p.addMedia(url)
            let asset = p.project.media[0]
            try? FileManager.default.removeItem(at: MatteStore.shared.matteVideoURL(media: asset, kind: "faces"))
            try await MatteGenerator.generate(asset, mode: .faces)
            let m = try #require(MatteStore.shared.readyMatteVideo(media: asset, kind: "faces"))
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: m))
            g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
            var hits = 0
            for f in [5, 15, 25] {
                let b = Bitmap(try await g.image(at: CMTime(value: CMTimeValue(f), timescale: 30)).image)
                // glyph spans x ≈ 60+8f … +200 px; face in its middle
                let cx = (60 + Double(f) * 8 + 100) / 640
                if b[cx, 0.5].r > 0.5 { hits += 1 }
                #expect(b[0.95, 0.1].r < 0.2, "background clear")
            }
            #expect(hits >= 2, "face matte follows the face")
            try FaceCover.apply(.mosaic, to: id, in: &p.project)
            let cover = try #require(FaceCover.cover(of: id, in: p.project.timeline))
            #expect(cover.effects.first?.typeID == "montage.effect.pixelate" && cover.audio.isMuted)
            #expect(TimelineOps.validate(p.project.timeline).isEmpty)
            _ = try await p.render(at: 0.5)
            FaceCover.remove(from: id, in: &p.project)
            #expect(FaceCover.cover(of: id, in: p.project.timeline) == nil && p.project.timeline.tracks.count == 1)
        }
    }

    @Test func cameraTrackingCentresTheFace() async throws {
        try await HeavyWorkGate.run {
            let url = try await Self.faceVideo()
            var p = TestProject(canvas: Size2(640, 360))
            let id = try await p.addMedia(url)
            let cmd = try await CameraLockJob.run(project: p.project, clipID: id, options: CameraLockOptions(target: .face, zoom: 1.25))
            try cmd.apply(to: &p.project)
            let k = try #require(p[id].keyframes[ParamKey.position.raw])
            #expect(p[id].cameraLock != nil)
            // the face walks right (≈ +8 px/frame) → the clip moves left over time
            let a = try #require(k.value(at: Time(0.2))?.vec2), b = try #require(k.value(at: Time(0.8))?.vec2)
            #expect(b.x < a.x - 0.05, "\(a) → \(b)")
            var clip = p[id]; CameraLock.remove(&clip)
            #expect(clip.keyframes[ParamKey.position.raw] == nil && clip.cameraLock == nil)
        }
    }
}
