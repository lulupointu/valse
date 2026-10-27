import CoreGraphics
import Foundation
import ImageIO
import ValseCore
import ValseEffects

/// Frame analysis behind Adjust ▸ Basic ▸ Auto adjust (CL-007). Statistics by default (`AutoColor.analyze`);
/// the AI team (W10) can install a smarter analysis (face-aware white balance, CL-008) with `setProvider`, which may
/// return nil to fall back to the statistics.
public enum AutoAdjustAnalyzer {
    public typealias Provider = @Sendable (CGImage) async -> [String: Double]?

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var provider: Provider?
    }
    private static let box = Box()

    public static func setProvider(_ p: Provider?) { box.lock.withLock { box.provider = p } }

    /// Correction params (keys of `AutoColor.descriptor`) for an image.
    public static func analyze(_ image: CGImage) async -> [String: Double] {
        if let p = box.lock.withLock({ box.provider }), let r = await p(image) { return r }
        guard let (px, w, h) = rgba(image, maxSide: 256) else { return [:] }
        return AutoColor.analyze(rgba: px, width: w, height: h)
    }

    /// The source frame a clip shows at timeline time `t` (video: exact decode; image: the still).
    public static func frame(of clip: Clip, asset: MediaAsset, at t: Time) async throws -> CGImage {
        let url = PlayableMediaCache.shared.resolvedURL(for: asset)
        if asset.kind == .image {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                         kCGImageSourceThumbnailMaxPixelSize: 512,
                                                                         kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
            else { throw MediaProbeError.unreadable(url, "image") }
            return img
        }
        var a = asset
        a.url = url
        return try await FrameGrabber.image(of: a, at: clip.sourceTime(at: t))
    }

    /// 8-bit RGBA copy, downscaled so the longest side is ≤ `maxSide`.
    static func rgba(_ image: CGImage, maxSide: Int) -> ([UInt8], Int, Int)? {
        let s = min(1, Double(maxSide) / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * s)), h = max(1, Int(Double(image.height) * s))
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (buf, w, h) : nil
    }
}
