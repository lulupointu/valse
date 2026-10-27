@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import ValseCore

/// Thumbnails for the media bin and timeline filmstrips. Two levels: memory (NSCache, cost-bounded) and disk (JPEG in
/// ~/Library/Caches/Valse/thumbs/<hash>/). Times are quantized so filmstrips at any zoom reuse tiles.
/// `cached(...)` is synchronous for drawing; `thumbnail(...)` generates asynchronously (off-main, uses proxies when ready).
/// Same media + same request → same pixels: images are owned 8-bit bitmaps decoded from the cached JPEG bytes (see
/// `canonical`). The ±quantum/2 time tolerance is kept: for a given file and request AVAssetImageGenerator picks the
/// same frame regardless of request order, generator reuse or concurrent decoders (measured, FLAKY-THUMB), and it is
/// ~20 % cheaper than exact-frame decoding.
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
        directory = ValsePaths.cacheDirectory.appendingPathComponent("thumbs", isDirectory: true)
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
        // Another caller is making this thumbnail: wait for it instead of answering nil — a nil poster is never asked
        // again (MediaCard), so a card rebuilt while its old instance's request was in flight (language switch, a
        // slow loaded machine) kept its placeholder for good.
        while !lock.withLock({ inflight.insert(k).inserted }) {
            try? await Task.sleep(for: .milliseconds(20))
            if Task.isCancelled { return nil }
            if let img = memory.object(forKey: k as NSString) { return img }
        }
        defer { _ = lock.withLock { inflight.remove(k) } }
        let file = directory.appendingPathComponent(a.contentHash).appendingPathComponent("\(q)-\(height).jpg")
        if let img = Self.loadJPEG(file) { store(img, k); return img }
        await semaphore.wait()
        defer { Task { await semaphore.signal() } }
        let raw: CGImage?
        if a.kind == .image || (PlayableMediaCache.shared.needsConversion(a) && a.conversion != .ffmpeg) {
            raw = Self.imageThumb(a.url, height: height)
        } else {
            let url = ProxyManager.shared.readyProxyURL(for: a) ?? PlayableMediaCache.shared.resolvedURL(for: a)
            raw = await videoThumb(url, at: Double(q) * Self.quantum, height: height)
        }
        // FLAKY-THUMB: memory gets exactly what a later disk load returns (the decoded JPEG, as a plain bitmap), so a
        // thumbnail has the same pixels whether this process generated it or found it on disk.
        guard let raw, let (img, jpeg) = Self.canonical(raw) else { return nil }
        store(img, k)
        Self.save(jpeg, file)
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
        if let img = try? await gen.image(at: CMTime(seconds: seconds + Self.quantum / 2, preferredTimescale: 600)).image { return img }
        // No frame in this quantum (the last one of the media: a filmstrip tile at the clip end): the last frame before
        // it. Without this the request failed, nothing was cached and every timeline redraw generated it again.
        let tail = AVAssetImageGenerator(asset: gen.asset)
        tail.appliesPreferredTrackTransform = true
        tail.requestedTimeToleranceBefore = .positiveInfinity
        tail.requestedTimeToleranceAfter = .zero
        tail.maximumSize = gen.maximumSize
        return try? await tail.image(at: CMTime(seconds: seconds + Self.quantum, preferredTimescale: 600)).image
    }

    /// Deterministic thumbnail pixels (FLAKY-THUMB). A generated frame (IOSurface-backed, decoder colour) and the same
    /// thumbnail read back from the JPEG disk cache differed slightly (JPEG quantisation, ringing at sharp edges), and
    /// which one a card showed depended on cache state. Returns the JPEG bytes to store and the image decoded from them —
    /// what `loadJPEG` returns for that file. Cost: one extra 8-bit decode + copy of a thumbnail-sized image (< 1 ms
    /// at 512 × 288).
    static func canonical(_ img: CGImage) -> (CGImage, Data)? {
        let data = NSMutableData()
        guard let d = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(d, img, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        guard CGImageDestinationFinalize(d), let src = CGImageSourceCreateWithData(data, nil),
              let decoded = decode(src) else { return nil }
        return (decoded, data as Data)
    }

    /// The JPEG at `src` decoded now into a plain CPU bitmap (8-bit RGB, the file's colour space): never a lazily decoded
    /// ImageIO image, which a renderer may decode at a reduced size depending on how it is drawn.
    static func decode(_ src: CGImageSource) -> CGImage? {
        guard let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        return flatten(img)
    }

    /// `img` copied into an owned 8-bit RGBX bitmap in its own RGB colour space (sRGB otherwise).
    public static func flatten(_ img: CGImage) -> CGImage? {
        let cs = img.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return ctx.makeImage()
    }

    static func imageThumb(_ url: URL, height: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: height * 3]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    static func loadJPEG(_ url: URL) -> CGImage? {
        guard let data = try? Data(contentsOf: url), let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return decode(src)
    }

    /// Atomic: a reader never sees a half-written file (it would decode a truncated, partly grey thumbnail).
    static func save(_ jpeg: Data, _ url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? jpeg.write(to: url, options: .atomic)
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
