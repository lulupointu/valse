@preconcurrency import AVFoundation
@preconcurrency import Metal
import CoreGraphics
import Foundation
import ImageIO
import ValseCore

/// Matte input API for AI cutout (ValseAI → compositor).
///
/// - **Video**: a matte is a grey video aligned with the media's own timeline (frame at media time t = matte of the
///   source frame at t; luma = alpha, video range). It is stored at `matteVideoURL(media:kind:)`
///   (`~/Library/Caches/Valse/mattes/<contentHash>-<kind>.mov`). `CompositionBuilder` decodes it in sync with the
///   source as an aux lane (`AuxRole.matte`) using the clip's exact time remap, so the matte follows speed curves,
///   trims and splits for free and costs one extra hardware decode — no per-frame lookups on the render thread.
///   Reversed clips use a reversed matte (ReverseManager, key `<hash>-matte-<kind>`).
/// - **Stills** (image clips): `setStill(_:media:kind:)`, uploaded once as an r8 texture.
/// Produce video mattes with `MatteVideoWriter` (append one mask per source frame), then call `didWriteMatte` so
/// the preview rebuilds. Clips opt in with `Clip.matte = ClipMatte(kind:)`.
public final class MatteStore: @unchecked Sendable {
    public static let shared = MatteStore()

    public let directory: URL
    private let lock = NSLock()
    private var stills: [String: CGImage] = [:]
    private var stillTextures: [String: MTLTexture] = [:]
    /// Main actor: a matte became available (media hash, kind) → the store/engine rebuilds the preview.
    @MainActor public var onMatteReady: ((String, String) -> Void)?

    init() {
        directory = ValsePaths.cacheDirectory.appendingPathComponent("mattes", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static func key(_ hash: String, _ kind: String) -> String {
        "\(hash)-\(kind.replacingOccurrences(of: "/", with: "_"))"
    }

    public func matteVideoURL(media a: MediaAsset, kind: String) -> URL {
        directory.appendingPathComponent("\(Self.key(a.contentHash, kind)).mov")
    }

    /// Ready matte video for a media item (sync, used by the composition builder).
    public func readyMatteVideo(media a: MediaAsset, kind: String) -> URL? {
        let u = matteVideoURL(media: a, kind: kind)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// Reverse-render key of a matte video (for reversed clips).
    public func reverseKey(media a: MediaAsset, kind: String) -> String { "\(Self.key(a.contentHash, kind))-matte" }

    @MainActor public func didWriteMatte(media a: MediaAsset, kind: String) { onMatteReady?(a.contentHash, kind) }

    // MARK: Stills

    public func setStill(_ image: CGImage, media a: MediaAsset, kind: String) {
        let k = Self.key(a.contentHash, kind)
        lock.withLock { stills[k] = image; stillTextures[k] = nil }
        if let d = CGImageDestinationCreateWithURL(directory.appendingPathComponent("\(k).png") as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(d, image, nil)
            CGImageDestinationFinalize(d)
        }
    }

    public func hasStill(media a: MediaAsset, kind: String) -> Bool {
        let k = Self.key(a.contentHash, kind)
        if lock.withLock({ stills[k] }) != nil { return true }
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(k).png").path)
    }

    /// r8Unorm texture of a still matte (cached).
    func stillTexture(media a: MediaAsset, kind: String, device: MTLDevice) -> MTLTexture? {
        let k = Self.key(a.contentHash, kind)
        if let t = lock.withLock({ stillTextures[k] }) { return t }
        var img = lock.withLock { stills[k] }
        if img == nil, let src = CGImageSourceCreateWithURL(directory.appendingPathComponent("\(k).png") as CFURL, nil) {
            img = CGImageSourceCreateImageAtIndex(src, 0, nil)
        }
        guard let img else { return nil }
        let w = img.width, h = img.height
        var buf = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: w, height: h, mipmapped: false)
        d.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: buf, bytesPerRow: w)
        lock.withLock { stillTextures[k] = t }
        return t
    }
}

/// Writes a matte video aligned with a media item: call `append` once per source frame (in order) with the mask
/// (luma or alpha, any size — it is scaled), then `finish()`. Thread: any, but one writer per file.
public final class MatteVideoWriter: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let tmp: URL, dst: URL
    public let width: Int, height: Int

    /// `size`: matte resolution (≤ 1080p recommended; it is bilinearly upsampled by the compositor).
    public init(media a: MediaAsset, kind: String, size: CGSize) throws {
        dst = MatteStore.shared.matteVideoURL(media: a, kind: kind)
        tmp = dst.deletingLastPathComponent().appendingPathComponent("tmp-\(UUID().uuidString).mov")
        width = max(16, Int(size.width) / 2 * 2); height = max(16, Int(size.height) / 2 * 2)
        writer = try AVAssetWriter(outputURL: tmp, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(2_000_000, width * height * 8),
                                              AVVideoMaxKeyFrameIntervalKey: 15, AVVideoAllowFrameReorderingKey: false]])
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "Valse", code: 90) }
        writer.startSession(atSourceTime: .zero)
    }

    /// Appends the matte of the source frame presented at media time `time` (the image's luminance = alpha).
    public func append(_ image: CGImage, at time: Time) async throws {
        // a failed writer never becomes ready again (SyntheticMedia.waitUntilReady throws its error instead of spinning)
        try await SyntheticMedia.waitUntilReady(input, writer)
        guard let pool = adaptor.pixelBufferPool else { throw writer.error ?? NSError(domain: "Valse", code: 91) }
        var pbOut: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
        if pbOut == nil {
            // the writer's encoder failed (its error says why), or transient IOSurface pressure on a loaded machine
            // (a bare "Code=92" flaked RelightRenderTests, FLAKY-SYS-UNIT): a standalone buffer is just as good
            if writer.status == .failed || writer.status == .cancelled { throw writer.error ?? NSError(domain: "Valse", code: 92) }
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary, &pbOut)
        }
        guard let pb = pbOut else { throw writer.error ?? NSError(domain: "Valse", code: 92) }
        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddress(pb),
           let ctx = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                               bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        if !adaptor.append(pb, withPresentationTime: time.cmTime) { throw writer.error ?? NSError(domain: "Valse", code: 93) }
    }

    public func finish() async throws {
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? NSError(domain: "Valse", code: 94) }
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.moveItem(at: tmp, to: dst)
        await AssetCache.shared.evict(dst)
    }

    public func cancel() { writer.cancelWriting(); try? FileManager.default.removeItem(at: tmp) }
}
