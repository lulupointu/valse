@preconcurrency import AVFoundation
import Foundation
import ValseCore

/// Video stabilization ("Stabilize": Minimal cropping / Recommended / Most stable).
///
/// Analysis (background job, once per media): global translation between consecutive frames by coarse-to-fine block
/// matching on a downscaled luma plane (≈ 256 px wide; reads the proxy when one exists), then content-aware
/// similarity motion (W10, AI-059): local shifts of a 5 × 4 grid of textured blocks, fitted to translation + roll +
/// zoom with outlier rejection (blocks on moving subjects are dropped, so the camera — the background — is tracked).
/// Accumulated into a camera path (content displacement in normalized units + roll in radians) stored in
/// `~/Library/Caches/Valse/stabilization/<hash>.v2.json`.
/// Render: `StabilizationTrack.from(path:level:)` smooths the path per level; the compositor applies
/// `correction = smoothed − raw` (shift and roll) plus the uniform zoom that hides the borders, inside the source
/// sampling (`FrameRenderer.uvTransform(stabilize:)`), so preview and export are identical.
public final class StabilizationStore: @unchecked Sendable {
    public static let shared = StabilizationStore()

    public struct Path: Codable, Sendable {
        public var frameDuration: Time; public var x: [Double]; public var y: [Double]
        /// Cumulative roll (radians, y-down image coordinates) and analysed frame aspect; nil for translation-only paths.
        public var r: [Double]? = nil
        public var aspect: Double? = nil
    }

    public let directory: URL
    private let lock = NSLock()
    private var paths: [String: Path] = [:]
    private var tracks: [String: StabilizationTrack] = [:]
    private var pending: [String: JobID] = [:]
    @MainActor public var onReady: ((String) -> Void)?

    init() {
        directory = ValsePaths.cacheDirectory.appendingPathComponent("stabilization", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func url(_ hash: String) -> URL { directory.appendingPathComponent("\(hash).v2.json") }

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
        let t = StabilizationTrack.from(path: p.x, p.y, rotation: p.r, aspect: p.aspect, frameDuration: p.frameDuration, level: level)
        lock.withLock { tracks[key] = t }
        return t
    }

    /// Stores an externally computed path (e.g. a Vision-based analyzer in ValseAI).
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
        // the analysis works on ≈ 256 px luma: let the decoder scale (512 px) instead of reading full-size 1080p / 4K
        // frames and box-filtering them on the CPU (AI QA: 32 s of iPhone 1080p HLG took minutes)
        let natural = try await track.load(.naturalSize)
        var settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        if natural.width > 512 {
            settings[kCVPixelBufferWidthKey as String] = 512
            settings[kCVPixelBufferHeightKey as String] = max(16, Int(512 * natural.height / max(natural.width, 1)) / 2 * 2)
        }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        out.alwaysCopiesSampleData = false
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? NSError(domain: "Valse", code: 100) }
        var px: [Double] = [], py: [Double] = [], pr: [Double] = []
        var prev: LumaImage?
        var cx = 0.0, cy = 0.0, cr = 0.0
        var aspect = 16.0 / 9
        try await OffPool.run { ctx in
            while let sb = out.copyNextSampleBuffer() {
                try ctx.checkCancellation()
                guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
                let cur = LumaImage(pb, targetWidth: 256)
                aspect = Double(cur.width) / Double(max(cur.height, 1))
                if let prev {
                    let m = estimateMotion(prev, cur)
                    cx += m.tx / Double(cur.width); cy += m.ty / Double(cur.height); cr += m.roll
                }
                px.append(cx); py.append(cy); pr.append(cr)
                prev = cur
                progress?.report(CMSampleBufferGetPresentationTimeStamp(sb).seconds / max(duration, 0.001))
            }
        }
        if reader.status == .failed { throw reader.error ?? NSError(domain: "Valse", code: 101) }
        return Path(frameDuration: FrameRate.nearest(to: Double(max(rate, 1))).frameDuration, x: px, y: py, r: pr, aspect: aspect)
    }

    /// Frame-to-frame camera motion: translation at the frame centre (pixels of `b`'s grid) and roll (radians).
    struct Motion { var tx: Double, ty: Double, roll: Double, scale: Double, inliers: Int }

    /// Content-aware similarity motion between two frames: the global shift seeds a local search on a 5 × 4 grid of
    /// blocks; flat blocks are skipped; translation + roll + zoom are least-squares fitted and blocks that disagree
    /// (independently moving subjects) are rejected twice. Falls back to the global shift with too few inliers.
    static func estimateMotion(_ a: LumaImage, _ b: LumaImage) -> Motion {
        let (gx, gy) = estimateShift(a, b)
        let fallback = Motion(tx: gx, ty: gy, roll: 0, scale: 0, inliers: 0)
        let cols = 5, rows = 4
        let bw = a.width / (cols + 2), bh = a.height / (rows + 2)
        guard bw >= 8, bh >= 8, a.width == b.width, a.height == b.height else { return fallback }
        let ox = (a.width - cols * bw) / 2, oy = (a.height - rows * bh) / 2
        let cxF = Double(a.width) / 2, cyF = Double(a.height) / 2
        let r = 3
        let (ix, iy) = (Int(gx.rounded()), Int(gy.rounded()))
        struct Sample { var x: Double, y: Double, dx: Double, dy: Double }
        var samples: [Sample] = []
        for j in 0..<rows {
            for i in 0..<cols {
                let x0 = ox + i * bw, y0 = oy + j * bh
                // the search window must stay inside b
                guard x0 + ix - r - 1 >= 0, y0 + iy - r - 1 >= 0, x0 + bw + ix + r + 1 <= b.width, y0 + bh + iy + r + 1 <= b.height,
                      a.blockStdDev(x0, y0, bw, bh) > 4 else { continue }
                var best = (ix, iy), bestV = Double.infinity
                for dy in (iy - r)...(iy + r) { for dx in (ix - r)...(ix + r) {
                    let v = a.blockSAD(b, x0, y0, bw, bh, dx, dy)
                    if v < bestV { bestV = v; best = (dx, dy) }
                } }
                // a minimum on the window border means the true shift is outside: unreliable
                guard abs(best.0 - ix) < r, abs(best.1 - iy) < r else { continue }
                func sad(_ dx: Int, _ dy: Int) -> Double { a.blockSAD(b, x0, y0, bw, bh, dx, dy) }
                func para(_ l: Double, _ c: Double, _ r: Double) -> Double {
                    let den = l - 2 * c + r
                    return den > 1e-9 ? min(max(0.5 * (l - r) / den, -0.5), 0.5) : 0
                }
                let fx = Double(best.0) + para(sad(best.0 - 1, best.1), bestV, sad(best.0 + 1, best.1))
                let fy = Double(best.1) + para(sad(best.0, best.1 - 1), bestV, sad(best.0, best.1 + 1))
                samples.append(Sample(x: Double(x0) + Double(bw) / 2 - cxF, y: Double(y0) + Double(bh) / 2 - cyF, dx: fx, dy: fy))
            }
        }
        func fit(_ s: [Sample]) -> Motion? {
            guard s.count >= 4 else { return nil }
            let n = Double(s.count)
            let mx = s.reduce(0) { $0 + $1.x } / n, my = s.reduce(0) { $0 + $1.y } / n
            let mdx = s.reduce(0) { $0 + $1.dx } / n, mdy = s.reduce(0) { $0 + $1.dy } / n
            var num = 0.0, sc = 0.0, den = 0.0
            for p in s {
                let x = p.x - mx, y = p.y - my, u = p.dx - mdx, v = p.dy - mdy
                num += x * v - y * u; sc += x * u + y * v; den += x * x + y * y
            }
            guard den > 1e-9 else { return nil }
            let th = num / den, k = sc / den
            // d = t + k·p + θ·(−y, x)  → translation at the frame centre
            return Motion(tx: mdx - k * mx + th * my, ty: mdy - k * my - th * mx, roll: th, scale: k, inliers: s.count)
        }
        func residual(_ m: Motion, _ p: Sample) -> Double {
            let ex = m.tx + m.scale * p.x - m.roll * p.y - p.dx, ey = m.ty + m.scale * p.y + m.roll * p.x - p.dy
            return (ex * ex + ey * ey).squareRoot()
        }
        guard var m = fit(samples) else { return fallback }
        var kept = samples
        for _ in 0..<2 {
            let res = kept.map { residual(m, $0) }.sorted()
            let limit = max(0.6, 2.5 * res[res.count / 2])
            let next = kept.filter { residual(m, $0) <= limit }
            guard next.count >= 4, next.count < kept.count, let f = fit(next) else { break }
            kept = next; m = f
        }
        // |roll| above ~3° per frame is not camera shake: keep the translation only
        if abs(m.roll) > 0.05 { m.roll = 0 }
        return m
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

    /// Standard deviation of a block (texture measure: flat blocks have no reliable motion).
    func blockStdDev(_ x0: Int, _ y0: Int, _ w: Int, _ h: Int) -> Double {
        var s: Float = 0, s2: Float = 0
        for y in y0..<(y0 + h) { for x in x0..<(x0 + w) { let v = px[y * width + x]; s += v; s2 += v * v } }
        let n = Float(w * h), m = s / n
        return Double(max(0, s2 / n - m * m)).squareRoot()
    }

    /// Mean absolute difference of the block at (x0, y0) against other(x + dx, y + dy) (caller keeps it in bounds).
    func blockSAD(_ o: LumaImage, _ x0: Int, _ y0: Int, _ w: Int, _ h: Int, _ dx: Int, _ dy: Int) -> Double {
        var acc: Float = 0
        for y in y0..<(y0 + h) {
            let ra = y * width, rb = (y + dy) * o.width + dx
            for x in x0..<(x0 + w) { acc += abs(px[ra + x] - o.px[rb + x]) }
        }
        return Double(acc) / Double(w * h)
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
