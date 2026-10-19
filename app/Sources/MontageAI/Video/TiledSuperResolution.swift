@preconcurrency import VideoToolbox
import CoreVideo
import Foundation
import MontageEngine

/// Enhance quality's fast path: VideoToolbox's low-latency ML super resolution (×2, ~2–3 ms per 960×540 tile on
/// the ANE) run over overlapping tiles, because the scaler only takes frames up to 960×960. A 1080p frame is 6 tiles
/// (~12 ms) instead of the full `VTSuperResolutionScaler` (×4 only: a 1080p source became an 8K frame, ~1.5 s each,
/// ×50 real time in the AI QA on project 1018). ×3 / ×4 run a second ×2 pass; a non-power-of-two target is a final
/// VTPixelTransferSession (GPU) downscale. The scaler is per-frame (no temporal state), so tiles are independent;
/// each tile reads `pad` extra source pixels around its core and only the core is kept, so seams don't show.
enum SuperResolutionTiles {
    /// One tile along an axis (source pixels): it reads `origin ..< origin + size`, keeps `coreStart ..< coreEnd`.
    struct Span: Equatable { var origin: Int, size: Int, coreStart: Int, coreEnd: Int }

    /// Covers `0 ..< length` with equal-size tiles of at most `maxTile` (even origins / sizes for 4:2:0).
    static func spans(length l: Int, maxTile m: Int = 960, pad p: Int = 16) -> [Span] {
        if l <= m { return [Span(origin: 0, size: l, coreStart: 0, coreEnd: l)] }
        let n = Int((Double(l) / Double(m - 2 * p)).rounded(.up))
        let core = ((l + n - 1) / n + 1) & ~1
        let size = min(l, core + 2 * p) & ~1
        return (0..<n).map { i in
            let cs = i * core, ce = min(l, (i + 1) * core)
            let o = min(max(0, cs - p), l - size) & ~1
            return Span(origin: o, size: size, coreStart: cs, coreEnd: ce)
        }
    }

    /// Number of ×2 passes for an enlargement factor (≤ 2 → 1, else 2; ×4 max).
    static func passes(for factor: Double) -> Int { factor <= 2.001 ? 1 : 2 }
}

/// ×2 / ×4 tiled low-latency super resolution of 8-bit 4:2:0 frames, then an optional downscale to (outWidth, outHeight).
@available(macOS 26.0, *)
final class TiledScaler: @unchecked Sendable {
    /// One ×2 pass over a `width × height` input.
    final class Pass: @unchecked Sendable {   // immutable after init; VTFrameProcessor takes concurrent requests
        let width: Int, height: Int
        let cols: [SuperResolutionTiles.Span], rows: [SuperResolutionTiles.Span]
        let processor = VTFrameProcessor()
        let tilePool: CVPixelBufferPool, tileOutPool: CVPixelBufferPool, outPool: CVPixelBufferPool
        init(width: Int, height: Int, maxTile: Int = 960) throws {
            self.width = width; self.height = height
            cols = SuperResolutionTiles.spans(length: width, maxTile: maxTile); rows = SuperResolutionTiles.spans(length: height, maxTile: maxTile)
            let cfg = VTLowLatencySuperResolutionScalerConfiguration(frameWidth: cols[0].size, frameHeight: rows[0].size, scaleFactor: 2)
            try processor.startSession(configuration: cfg)
            tilePool = try Self.pool(cfg.sourcePixelBufferAttributes)
            tileOutPool = try Self.pool(cfg.destinationPixelBufferAttributes)
            outPool = try Self.pool(TiledScaler.attributes(width * 2, height * 2))
        }
        static func pool(_ attrs: [String: Any]) throws -> CVPixelBufferPool {
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 3] as CFDictionary, attrs as CFDictionary, &p)
            guard let p else { throw AIToolError.noInput }
            return p
        }

        func run(_ src: CVPixelBuffer, pts: CMTime) async throws -> CVPixelBuffer {
            let out = try TiledScaler.make(outPool)
            // tiles are scaled concurrently (the scaler queues them; CPU copies overlap the inference): 1080p → 4K
            // 26 ms / frame vs 40 ms one tile after the other (AI QA, IMG_9079 copy). Even a single
            // tile is copied: the scaler's buffers carry the extended rows it needs (e.g. 540 → 544).
            try await withThrowingTaskGroup(of: Void.self) { g in
                let s = UncheckedSendable(src), o = UncheckedSendable(out)
                for r in rows { for c in cols {
                    g.addTask { [self] in
                        let tile = try TiledScaler.make(tilePool), tileOut = try TiledScaler.make(tileOutPool)
                        TiledScaler.copy(s.value, x: c.origin, y: r.origin, w: c.size, h: r.size, to: tile, dx: 0, dy: 0)
                        try await scale(tile, into: tileOut, pts: pts)
                        TiledScaler.copy(tileOut, x: 2 * (c.coreStart - c.origin), y: 2 * (r.coreStart - r.origin),
                                         w: 2 * (c.coreEnd - c.coreStart), h: 2 * (r.coreEnd - r.coreStart),
                                         to: o.value, dx: 2 * c.coreStart, dy: 2 * r.coreStart)
                    }
                } }
                try await g.waitForAll()
            }
            return out
        }

        func scale(_ src: CVPixelBuffer, into dst: CVPixelBuffer, pts: CMTime) async throws {
            guard let fs = VTFrameProcessorFrame(buffer: src, presentationTimeStamp: pts),
                  let fd = VTFrameProcessorFrame(buffer: dst, presentationTimeStamp: pts) else { throw AIToolError.noInput }
            let params = UncheckedSendable(VTLowLatencySuperResolutionScalerParameters(sourceFrame: fs, destinationFrame: fd))
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                processor.process(parameters: params.value) { _, err in if let err { c.resume(throwing: err) } else { c.resume() } }
            }
        }
        func end() { processor.endSession() }
    }

    let passes: [Pass]
    let outWidth: Int, outHeight: Int
    private let transfer: VTPixelTransferSession?
    private let finalPool: CVPixelBufferPool?

    /// - Parameters: `passes` 1 (×2) or 2 (×4) before the resize to `outWidth × outHeight`.
    init(width: Int, height: Int, passes n: Int, outWidth: Int, outHeight: Int, maxTile: Int = 960) throws {
        var ps: [Pass] = []
        var (w, h) = (width, height)
        for _ in 0..<max(1, n) { ps.append(try Pass(width: w, height: h, maxTile: maxTile)); w *= 2; h *= 2 }
        passes = ps
        self.outWidth = outWidth; self.outHeight = outHeight
        if (w, h) != (outWidth, outHeight) {
            var t: VTPixelTransferSession?
            VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &t)
            guard let t else { throw AIToolError.noInput }
            transfer = t
            finalPool = try Pass.pool(Self.attributes(outWidth, outHeight))
        } else { transfer = nil; finalPool = nil }
    }

    static func attributes(_ w: Int, _ h: Int) -> [String: Any] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
         kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
         kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
    }

    static func make(_ pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let pb else { throw AIToolError.noInput }
        return pb
    }

    func scale(_ src: CVPixelBuffer, pts: CMTime) async throws -> CVPixelBuffer {
        var cur = src
        for p in passes { cur = try await p.run(cur, pts: pts) }
        if let transfer, let finalPool {
            let out = try Self.make(finalPool)
            guard VTPixelTransferSessionTransferImage(transfer, from: cur, to: out) == noErr else { throw AIToolError.noInput }
            return out
        }
        return cur
    }

    func end() {
        for p in passes { p.end() }
        if let transfer { VTPixelTransferSessionInvalidate(transfer) }
    }

    /// Copies a `w × h` rectangle (even origin / size) of an 8-bit 4:2:0 bi-planar buffer into another at (dx, dy).
    static func copy(_ src: CVPixelBuffer, x: Int, y: Int, w: Int, h: Int, to dst: CVPixelBuffer, dx: Int, dy: Int) {
        CVPixelBufferLockBaseAddress(src, .readOnly); CVPixelBufferLockBaseAddress(dst, [])
        defer { CVPixelBufferUnlockBaseAddress(src, .readOnly); CVPixelBufferUnlockBaseAddress(dst, []) }
        for plane in 0..<2 {
            guard let s = CVPixelBufferGetBaseAddressOfPlane(src, plane), let d = CVPixelBufferGetBaseAddressOfPlane(dst, plane) else { continue }
            let sb = CVPixelBufferGetBytesPerRowOfPlane(src, plane), db = CVPixelBufferGetBytesPerRowOfPlane(dst, plane)
            let sh = plane == 0 ? 0 : 1   // chroma rows are halved; CbCr pairs keep the byte width
            let rows = min(h >> sh, CVPixelBufferGetHeightOfPlane(src, plane) - (y >> sh), CVPixelBufferGetHeightOfPlane(dst, plane) - (dy >> sh))
            let bytes = min(w, CVPixelBufferGetWidthOfPlane(src, plane) << sh - x, CVPixelBufferGetWidthOfPlane(dst, plane) << sh - dx)
            guard rows > 0, bytes > 0 else { continue }
            let sp = s + (y >> sh) * sb + x, dp = d + (dy >> sh) * db + dx
            for r in 0..<rows { memcpy(dp + r * db, sp + r * sb, bytes) }
        }
    }
}
