@preconcurrency import AVFoundation
import Foundation
import MontageCore

/// Video stabilization ("Stabilize": Minimal cropping / Recommended / Most stable).
///
/// Analysis (background job, once per media): global translation between consecutive frames by coarse-to-fine block
/// matching on a downscaled luma plane (≈ 192 px wide; reads the proxy when one exists), accumulated into a camera
/// path (content displacement, normalized units) stored in `~/Library/Caches/Montage/stabilization/<hash>.json`.
/// Render: `StabilizationTrack.from(path:level:)` smooths the path per level; the compositor applies
/// `correction = smoothed − raw` plus the uniform zoom that hides the borders, inside the source sampling
/// (`FrameRenderer.uvTransform(stabilize:)`), so preview and export are identical. Rotation is not corrected yet.
public final class StabilizationStore: @unchecked Sendable {
    public static let shared = StabilizationStore()

    public struct Path: Codable, Sendable { public var frameDuration: Time; public var x: [Double]; public var y: [Double] }

    public let directory: URL
    private let lock = NSLock()
    private var paths: [String: Path] = [:]
    private var tracks: [String: StabilizationTrack] = [:]
    private var pending: [String: JobID] = [:]
    @MainActor public var onReady: ((String) -> Void)?

    init() {
        directory = MontagePaths.cacheDirectory.appendingPathComponent("stabilization", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func url(_ hash: String) -> URL { directory.appendingPathComponent("\(hash).json") }

    public func isAnalyzed(_ a: MediaAsset) -> Bool { path(a.contentHash) != nil }

    public func isPending(_ a: MediaAsset) -> Bool { lock.withLock { pending[a.contentHash] != nil } }

    func path(_ hash: String) -> Path? {
        if let p = lock.withLock({ paths[hash] }) { return p }
        guard let d = try? Data(contentsOf: url(hash)), let p = try? JSONDecoder().decode(Path.self, from: d) else { return nil }
        lock.withLock { paths[hash] = p }
        return p
    }

    /// Correction track for a level (sync; cached). nil until analysed.
    public func track(media a: MediaAsset, level: StabilizationLevel) -> StabilizationTrack? {
        let key = "\(a.contentHash)-\(level.rawValue)"
        if let t = lock.withLock({ tracks[key] }) { return t }
        guard let p = path(a.contentHash) else { return nil }
        let t = StabilizationTrack.from(path: p.x, p.y, frameDuration: p.frameDuration, level: level)
        lock.withLock { tracks[key] = t }
        return t
    }

    /// Stores an externally computed path (e.g. a Vision-based analyzer in MontageAI).
    public func store(_ p: Path, for a: MediaAsset) throws {
        try JSONEncoder().encode(p).write(to: url(a.contentHash), options: .atomic)
        lock.withLock {
            paths[a.contentHash] = p
            for l in StabilizationLevel.allCases { tracks["\(a.contentHash)-\(l.rawValue)"] = nil }
        }
    }

    /// Queues the analysis (idempotent).
    @discardableResult
    public func request(_ a: MediaAsset, subject: String? = nil) async -> JobID? {
        if isAnalyzed(a) { return nil }
        if let j = lock.withLock({ pending[a.contentHash] }) { return j }
        let src = ProxyManager.shared.readyProxyURL(for: a) ?? a.url
        let asset = a
        let id = await JobQueue.shared.enqueue(titleKey: "job.stabilize", detail: a.name, priority: 0, subject: subject ?? a.contentHash) { progress in
            let p = try await StabilizationStore.analyze(src, progress: progress)
            try StabilizationStore.shared.store(p, for: asset)
        }
        lock.withLock { pending[a.contentHash] = id }
        let hash = a.contentHash
        Task {
            let state = await JobQueue.shared.wait(id)
            self.lock.withLock { self.pending[hash] = nil }
            if state == .done { await MainActor.run { self.onReady?(hash) } }
        }
        return id
    }

    // MARK: Analysis

    /// Global-motion camera path of a video (content displacement per frame, normalized to frame width/height).
    public static func analyze(_ url: URL, progress: JobProgress? = nil) async throws -> Path {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw MediaProbeError.unsupported(url) }
        let (rate, duration) = (try await track.load(.nominalFrameRate), try await asset.load(.duration).seconds)
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        out.alwaysCopiesSampleData = false
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? NSError(domain: "Montage", code: 100) }
        var px: [Double] = [], py: [Double] = []
        var prev: LumaImage?
        var cx = 0.0, cy = 0.0
        while let sb = out.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let cur = LumaImage(pb, targetWidth: 192)
            if let prev {
                let (sx, sy) = estimateShift(prev, cur)
                cx += sx / Double(cur.width); cy += sy / Double(cur.height)
            }
            px.append(cx); py.append(cy)
            prev = cur
            progress?.report(CMSampleBufferGetPresentationTimeStamp(sb).seconds / max(duration, 0.001))
        }
        if reader.status == .failed { throw reader.error ?? NSError(domain: "Montage", code: 101) }
        return Path(frameDuration: FrameRate.nearest(to: Double(max(rate, 1))).frameDuration, x: px, y: py)
    }

    /// Translation (in pixels of `b`'s grid) that best maps `a` onto `b` (content moved by +shift): coarse search on
    /// a half-resolution pyramid level, refined at full resolution, with sub-pixel parabola fit.
    static func estimateShift(_ a: LumaImage, _ b: LumaImage) -> (Double, Double) {
        let a2 = a.half(), b2 = b.half(), a4 = a2.half(), b4 = b2.half()
        let (qx, qy) = bestShift(a4, b4, around: (0, 0), radius: 8)
        let (cx, cy) = bestShift(a2, b2, around: (qx * 2, qy * 2), radius: 2)
        let (fx, fy) = bestShift(a, b, around: (cx * 2, cy * 2), radius: 2)
        // sub-pixel refinement
        func sad(_ dx: Int, _ dy: Int) -> Double { a.sad(b, dx, dy) }
        let c = sad(fx, fy)
        let lx = sad(fx - 1, fy), rx = sad(fx + 1, fy), uy = sad(fx, fy - 1), dy = sad(fx, fy + 1)
        func para(_ l: Double, _ c: Double, _ r: Double) -> Double {
            let den = l - 2 * c + r
            return den > 1e-9 ? min(max(0.5 * (l - r) / den, -0.5), 0.5) : 0
        }
        return (Double(fx) + para(lx, c, rx), Double(fy) + para(uy, c, dy))
    }

    static func bestShift(_ a: LumaImage, _ b: LumaImage, around c: (Int, Int), radius r: Int) -> (Int, Int) {
        var best = (c.0, c.1), bestV = Double.infinity
        for dy in (c.1 - r)...(c.1 + r) {
            for dx in (c.0 - r)...(c.0 + r) {
                let v = a.sad(b, dx, dy)
                if v < bestV { bestV = v; best = (dx, dy) }
            }
        }
        return best
    }
}

/// Small float luma image for motion estimation.
struct LumaImage {
    let width: Int, height: Int
    var px: [Float]

    init(width: Int, height: Int, px: [Float]) { self.width = width; self.height = height; self.px = px }

    /// Box-downsampled Y plane of a 4:2:0 buffer.
    init(_ pb: CVPixelBuffer, targetWidth: Int) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let k = max(1, w / max(targetWidth, 1))
        width = max(1, w / k); height = max(1, h / k)
        var out = [Float](repeating: 0, count: width * height)
        if let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)?.assumingMemoryBound(to: UInt8.self) {
            for y in 0..<height {
                for x in 0..<width {
                    var acc = 0
                    for yy in 0..<k { let row = base + (y * k + yy) * bpr + x * k; for xx in 0..<k { acc += Int(row[xx]) } }
                    out[y * width + x] = Float(acc) / Float(k * k)
                }
            }
        }
        px = out
    }

    func half() -> LumaImage {
        let w = max(1, width / 2), h = max(1, height / 2)
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w {
            let i = (y * 2) * width + x * 2
            out[y * w + x] = (px[i] + px[min(i + 1, px.count - 1)] + px[min(i + width, px.count - 1)] + px[min(i + width + 1, px.count - 1)]) / 4
        } }
        return LumaImage(width: w, height: h, px: out)
    }

    /// Mean absolute difference between self(x, y) and other(x + dx, y + dy) over the central region.
    func sad(_ o: LumaImage, _ dx: Int, _ dy: Int) -> Double {
        let mx = max(abs(dx) + 1, width / 8), my = max(abs(dy) + 1, height / 8)
        guard width - 2 * mx > 4, height - 2 * my > 4 else { return .infinity }
        var acc: Float = 0
        var n = 0
        var y = my
        while y < height - my {
            let ra = y * width, rb = (y + dy) * o.width
            var x = mx
            while x < width - mx { acc += abs(px[ra + x] - o.px[rb + x + dx]); x += 1; n += 1 }
            y += 1
        }
        return Double(acc) / Double(max(n, 1))
    }
}
