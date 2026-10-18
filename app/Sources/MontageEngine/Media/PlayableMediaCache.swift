@preconcurrency import AVFoundation
import CoreVideo
import Foundation
import ImageIO
import MontageCore

/// Makes media that AVFoundation can't play directly playable, once, in the background (MI-001/MI-013):
/// - animated GIF / APNG / WebP / HEICS and numbered image sequences → frames written with AVAssetWriter
///   (ProRes 4444 with alpha when the source has alpha, else H.264), frame timing preserved;
/// - FFmpeg-only containers/codecs → `FFmpegSidecar` ProRes + PCM mezzanine.
/// Files live in ~/Library/Caches/Montage/converted/<contentHash>.mov and are shared across projects.
/// Every engine path resolves files through `resolvedURL(for:)` (composition, thumbnails, proxies, waveforms).
public final class PlayableMediaCache: @unchecked Sendable {
    public static let shared = PlayableMediaCache()

    public let directory: URL
    private let lock = NSLock()
    private var ready: Set<String> = []
    private var pending: [String: JobID] = [:]
    /// Called on the main actor when a conversion finished (argument = content hash).
    @MainActor public var onReady: ((String) -> Void)?

    init() {
        directory = MontagePaths.cacheDirectory.appendingPathComponent("converted", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        ready = Set(files.filter { $0.hasSuffix(".mov") }.map { String($0.dropLast(4)) })
    }

    public func convertedURL(for a: MediaAsset) -> URL { directory.appendingPathComponent("\(a.contentHash).mov") }

    /// The converted file, if this asset needs one and it is ready.
    public func playableURL(for a: MediaAsset) -> URL? {
        guard a.conversion != nil else { return nil }
        return lock.withLock { ready.contains(a.contentHash) } ? convertedURL(for: a) : nil
    }

    /// File to hand to AVFoundation for this asset (converted file, or the original).
    public func resolvedURL(for a: MediaAsset) -> URL { playableURL(for: a) ?? a.url }

    /// True while the asset can't be played yet (conversion missing).
    public func needsConversion(_ a: MediaAsset) -> Bool { a.conversion != nil && playableURL(for: a) == nil }

    public func isPending(_ a: MediaAsset) -> Bool { lock.withLock { pending[a.contentHash] != nil } }

    /// Queues conversion for assets that need it (idempotent). Interactive priority: the user just imported them.
    public func request(_ assets: [MediaAsset]) async {
        for a in assets where needsConversion(a) {
            let skip = lock.withLock { pending[a.contentHash] != nil }
            if skip { continue }
            let dst = convertedURL(for: a), hash = a.contentHash, asset = a
            let id = await JobQueue.shared.enqueue(titleKey: "job.convert", detail: a.name, priority: 1, subject: hash) { progress in
                try await PlayableMediaCache.convert(asset, to: dst, progress: progress)
            }
            lock.withLock { pending[hash] = id }
            Task {
                let state = await JobQueue.shared.wait(id)
                self.lock.withLock { self.pending[hash] = nil }
                if state == .done {
                    self.lock.withLock { _ = self.ready.insert(hash) }
                    await AssetCache.shared.evict(dst)
                    await MainActor.run { self.onReady?(hash) }
                } else if case .failed(let msg) = state {
                    EngineLog.error("conversion of \(asset.name) failed: \(msg)")
                }
            }
        }
    }

    /// Waits until the asset is playable (tests / export of freshly imported media).
    public func ensurePlayable(_ a: MediaAsset) async throws {
        guard needsConversion(a) else { return }
        let dst = convertedURL(for: a)
        try await Self.convert(a, to: dst)
        lock.withLock { _ = ready.insert(a.contentHash) }
        await AssetCache.shared.evict(dst)
    }

    /// Re-reads which conversions exist (after cache clean-up deleted some files).
    public func reloadFromDisk() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let r = Set(files.filter { $0.hasSuffix(".mov") }.map { String($0.dropLast(4)) })
        lock.withLock { ready = r }
    }

    public func deleteAll() {
        lock.withLock { ready.removeAll() }
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: Conversion

    public static func convert(_ a: MediaAsset, to dst: URL, progress: JobProgress? = nil) async throws {
        let tmp = dst.deletingLastPathComponent().appendingPathComponent("tmp-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tmp) }
        switch a.conversion {
        case .animatedImage:
            guard let src = CGImageSourceCreateWithURL(a.url as CFURL, nil), let timing = AnimatedImage.timing(src) else {
                throw MediaProbeError.unsupported(a.url)
            }
            let n = timing.delays.count
            var starts: [Double] = []; var acc = 0.0
            for d in timing.delays { starts.append(acc); acc += d }
            let pts = starts
            let box = UncheckedSendable(src)
            try await writeFrames(to: tmp, size: a.pixelSize, alpha: a.techInfo?.hasAlpha ?? true, count: n, end: acc,
                                  pts: { pts[$0] }, progress: progress) { i in
                CGImageSourceCreateImageAtIndex(box.value, i, [kCGImageSourceShouldCache: false] as CFDictionary)
            }
        case .imageSequence:
            guard let seq = a.sequence else { throw MediaProbeError.unsupported(a.url) }
            let dir = a.url.deletingLastPathComponent()
            let fd = (a.frameRate ?? .fps30).frameDuration.seconds
            try await writeFrames(to: tmp, size: a.pixelSize, alpha: a.techInfo?.hasAlpha ?? false, count: seq.count,
                                  end: Double(seq.count) * fd, pts: { Double($0) * fd }, progress: progress) { i in
                guard let s = CGImageSourceCreateWithURL(dir.appendingPathComponent(seq.fileName(i)) as CFURL, nil) else { return nil }
                return CGImageSourceCreateImageAtIndex(s, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
            }
        case .ffmpeg:
            try await FFmpegSidecar.transcode(a.url, to: tmp, duration: a.duration, alpha: a.techInfo?.hasAlpha ?? false, progress: progress)
        case nil:
            return
        }
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.moveItem(at: tmp, to: dst)
    }

    /// Writes `count` CGImages as a movie: ProRes 4444 (alpha kept, straight) or H.264. `end` = duration of the last frame's end.
    static func writeFrames(to url: URL, size: Size2, alpha: Bool, count: Int, end: Double, pts: @escaping @Sendable (Int) -> Double,
                            progress: JobProgress?, frame: @escaping @Sendable (Int) -> CGImage?) async throws {
        func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded(.up)) * 2) }
        let w = alpha ? max(2, Int(size.width)) : even(size.width), h = alpha ? max(2, Int(size.height)) : even(size.height)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var settings: [String: Any] = [AVVideoWidthKey: w, AVVideoHeightKey: h,
                                       AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                                                   AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                                                   AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]]
        if alpha {
            settings[AVVideoCodecKey] = AVVideoCodecType.proRes4444
        } else {
            settings[AVVideoCodecKey] = AVVideoCodecType.h264
            settings[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey: max(2_000_000, w * h * 8),
                                                         AVVideoMaxKeyFrameIntervalKey: 15,
                                                         AVVideoAllowFrameReorderingKey: false]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "Montage", code: 80) }
        writer.startSession(atSourceTime: .zero)
        let scale: CMTimeScale = 6000
        for i in 0..<count {
            try Task.checkCancellation()
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            guard let pool = adaptor.pixelBufferPool else { throw writer.error ?? NSError(domain: "Montage", code: 81) }
            var pbOut: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
            guard let pb = pbOut else { throw NSError(domain: "Montage", code: 82) }
            if let img = frame(i) { draw(img, into: pb, w: w, h: h, straight: alpha) }
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue((pts(i) * Double(scale)).rounded()), timescale: scale))
            progress?.report(Double(i + 1) / Double(count))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue((end * Double(scale)).rounded()), timescale: scale))
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? NSError(domain: "Montage", code: 83) }
    }

    /// Draws an image into a BGRA buffer. With `straight`, colours are un-premultiplied (the compositor treats decoded
    /// BGRA media as straight alpha).
    static func draw(_ img: CGImage, into pb: CVPixelBuffer, w: Int, h: Int, straight: Bool) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        guard let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        if !straight { ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h)) }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard straight else { return }
        for y in 0..<h {
            let row = (base + y * bpr).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w {
                let p = row + x * 4
                let a = Int(p[3])
                if a > 0 && a < 255 {
                    p[0] = UInt8(min(255, Int(p[0]) * 255 / a)); p[1] = UInt8(min(255, Int(p[1]) * 255 / a)); p[2] = UInt8(min(255, Int(p[2]) * 255 / a))
                }
            }
        }
    }
}
