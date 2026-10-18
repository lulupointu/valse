@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import MontageCore

/// Thumbnails for the media bin and timeline filmstrips. Two levels: memory (NSCache, cost-bounded) and disk (JPEG in
/// ~/Library/Caches/Montage/thumbs/<hash>/). Times are quantized so filmstrips at any zoom reuse tiles.
/// `cached(...)` is synchronous for drawing; `thumbnail(...)` generates asynchronously (off-main, uses proxies when ready).
public final class ThumbnailCache: @unchecked Sendable {
    public static let shared = ThumbnailCache()

    /// Thumbnail time quantum (s).
    public static let quantum = 0.25
    private let memory = NSCache<NSString, CGImage>()
    private let directory: URL
    private let lock = NSLock()
    private var generators: [URL: AVAssetImageGenerator] = [:]
    private var inflight: Set<String> = []
    private let semaphore = AsyncSemaphore(limit: 3)

    init() {
        memory.totalCostLimit = MemoryBudget.thumbnailCacheBytes
        directory = MontagePaths.cacheDirectory.appendingPathComponent("thumbs", isDirectory: true)
    }

    static func quantize(_ t: Time) -> Int { Int((t.seconds / quantum).rounded(.down)) }

    private func key(_ a: MediaAsset, _ q: Int, _ h: Int) -> String { "\(a.contentHash)-\(q)-\(h)" }

    /// Memory-cached thumbnail (nil if not generated yet).
    public func cached(_ a: MediaAsset, at t: Time, height: Int) -> CGImage? {
        memory.object(forKey: key(a, a.kind == .image ? 0 : Self.quantize(t), height) as NSString)
    }

    /// Thumbnail at media time `t`, `height` pixels high.
    public func thumbnail(_ a: MediaAsset, at t: Time, height: Int) async -> CGImage? {
        let q = a.kind == .image ? 0 : Self.quantize(t)
        let k = key(a, q, height)
        if let img = memory.object(forKey: k as NSString) { return img }
        let started = lock.withLock { inflight.insert(k).inserted }
        guard started else { return nil }
        defer { _ = lock.withLock { inflight.remove(k) } }
        let file = directory.appendingPathComponent(a.contentHash).appendingPathComponent("\(q)-\(height).jpg")
        if let img = Self.loadJPEG(file) { store(img, k); return img }
        await semaphore.wait()
        defer { Task { await semaphore.signal() } }
        let img: CGImage?
        if a.kind == .image || (PlayableMediaCache.shared.needsConversion(a) && a.conversion != .ffmpeg) {
            img = Self.imageThumb(a.url, height: height)
        } else {
            let url = ProxyManager.shared.readyProxyURL(for: a) ?? PlayableMediaCache.shared.resolvedURL(for: a)
            img = await videoThumb(url, at: Double(q) * Self.quantum, height: height)
        }
        if let img { store(img, k); Self.saveJPEG(img, file) }
        return img
    }

    private func store(_ img: CGImage, _ k: String) { memory.setObject(img, forKey: k as NSString, cost: img.bytesPerRow * img.height) }

    private func videoThumb(_ url: URL, at seconds: Double, height: Int) async -> CGImage? {
        let gen: AVAssetImageGenerator = lock.withLock {
            if let g = generators[url] { return g }
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            g.appliesPreferredTrackTransform = true
            g.requestedTimeToleranceBefore = CMTime(seconds: Self.quantum / 2, preferredTimescale: 600)
            g.requestedTimeToleranceAfter = CMTime(seconds: Self.quantum / 2, preferredTimescale: 600)
            generators[url] = g
            return g
        }
        gen.maximumSize = CGSize(width: height * 4, height: height)
        return try? await gen.image(at: CMTime(seconds: seconds + Self.quantum / 2, preferredTimescale: 600)).image
    }

    static func imageThumb(_ url: URL, height: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: height * 3]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    static func loadJPEG(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    static func saveJPEG(_ img: CGImage, _ url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(d, img, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        CGImageDestinationFinalize(d)
    }

    public func clearMemory() { memory.removeAllObjects() }
}

/// Minimal async counting semaphore.
public actor AsyncSemaphore {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public init(limit: Int) { available = limit }
    public func wait() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    public func signal() {
        if waiters.isEmpty { available += 1 } else { waiters.removeFirst().resume() }
    }
}
