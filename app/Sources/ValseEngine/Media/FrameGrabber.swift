@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import ValseCore

/// Exact still extraction from media (freeze frame, "export frame" of a source).
public enum FrameGrabber {
    /// Decodes the source frame shown at media time `time` (frame-exact, display orientation, full resolution).
    /// Pixel values are the decoder's YUV→RGB values tagged sRGB, with no transfer-function conversion — the same
    /// values the compositor shows for the video — so a freeze still matches the moving picture exactly.
    public static func image(of asset: MediaAsset, at time: Time) async throws -> CGImage {
        let av = AVURLAsset(url: asset.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await av.loadTracks(withMediaType: .video).first else { throw MediaProbeError.unsupported(asset.url) }
        let transform = try await track.load(.preferredTransform)
        let fd = (asset.frameRate ?? .fps30).frameDuration
        let t = time.clamped(.zero, max(.zero, asset.duration - fd))
        let reader = try AVAssetReader(asset: av)
        reader.timeRange = CMTimeRange(start: CMTimeMaximum(.zero, CMTimeSubtract(t.cmTime, fd.cmTime)), duration: CMTimeMultiplyByFloat64(fd.cmTime, multiplier: 3))
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? MediaProbeError.unreadable(asset.url, "reader") }
        var chosen: CVPixelBuffer?
        try await OffPool.run { _ in
            while let sb = out.copyNextSampleBuffer() {
                guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
                let pts = Time(cmTime: CMSampleBufferGetPresentationTimeStamp(sb))
                if pts > t + Time(ticks: 1) { if chosen == nil { chosen = pb }; break }
                chosen = pb
            }
        }
        reader.cancelReading()
        guard let pb = chosen else { throw MediaProbeError.unreadable(asset.url, "no frame") }
        return try orientedImage(pb, transform: transform)
    }

    static func orientedImage(_ pb: CVPixelBuffer, transform: CGAffineTransform) throws -> CGImage {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let base = CVPixelBufferGetBaseAddress(pb),
              let src = CGContext(data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: space, bitmapInfo: info)?.makeImage() else { throw MediaProbeError.unreadable(URL(fileURLWithPath: "/"), "frame") }
        let deg = MediaProbe.rotationDegrees(transform)
        guard deg != 0 else { return src }
        let (ow, oh) = deg % 180 == 0 ? (w, h) : (h, w)
        guard let ctx = CGContext(data: nil, width: ow, height: oh, bitsPerComponent: 8, bytesPerRow: ow * 4, space: space, bitmapInfo: info)
        else { return src }
        // CG origin is bottom-left; rotate clockwise by `deg` around the centre
        ctx.translateBy(x: CGFloat(ow) / 2, y: CGFloat(oh) / 2)
        ctx.rotate(by: -CGFloat(deg) * .pi / 180)
        ctx.draw(src, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage() ?? src
    }

}
