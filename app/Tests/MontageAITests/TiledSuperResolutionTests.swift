import Testing
import Foundation
import CoreGraphics
@preconcurrency import AVFoundation
@testable import MontageAI
import MontageCore
import MontageEngine
import MontageTestSupport

/// Enhance quality speed (AI QA: 1629 s for a 32.7 s iPhone 1080p HLG clip, ×50 real time): tiled low-latency super
/// resolution. Tile layout, seamless stitching, real-time budgets and cancellation.
@Suite(.serialized) struct TiledSuperResolutionTests {
    @Test func tileSpansCoverTheFrame() {
        for l in [96, 540, 960, 1080, 1280, 1440, 1920, 2160, 2560, 3840] {
            let s = SuperResolutionTiles.spans(length: l)
            #expect(s.first?.coreStart == 0 && s.last?.coreEnd == l, "\(l)")
            #expect(Set(s.map(\.size)).count == 1, "one session: equal tiles (\(l))")
            for (i, t) in s.enumerated() {
                #expect(t.size <= 960 && t.size % 2 == 0 && t.origin % 2 == 0 && t.origin >= 0 && t.origin + t.size <= l, "\(l): \(t)")
                #expect(t.origin <= t.coreStart && t.coreEnd <= t.origin + t.size, "\(l): \(t)")
                if i > 0 { #expect(s[i - 1].coreEnd == t.coreStart) }
                // interior seams keep ≥ 16 px of context on both sides
                if t.coreStart > 0 { #expect(t.coreStart - t.origin >= 15, "\(l): \(t)") }
                if t.coreEnd < l { #expect(t.origin + t.size - t.coreEnd >= 15, "\(l): \(t)") }
            }
        }
        #expect(SuperResolutionTiles.spans(length: 1920).count == 3 && SuperResolutionTiles.spans(length: 1080).count == 2)
        #expect(SuperResolutionTiles.passes(for: 2) == 1 && SuperResolutionTiles.passes(for: 3) == 2 && SuperResolutionTiles.passes(for: 4) == 2)
    }

    /// A textured 4:2:0 frame (rings + diagonal stripes + noise): what the ML scaler sees at tile borders matters.
    static func texturedFrame(_ w: Int, _ h: Int) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary, &pb)
        let b = pb!
        CVPixelBufferLockBaseAddress(b, [])
        var rng = SplitMix64(seed: 7)
        let y = CVPixelBufferGetBaseAddressOfPlane(b, 0)!.assumingMemoryBound(to: UInt8.self), yb = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
        for j in 0..<h { for i in 0..<w {
            let r = hypot(Double(i - w / 2), Double(j - h / 2))
            let v = 120 + 50 * sin(r / 6) + ((i + j) / 12 % 2 == 0 ? 30 : -30) + Double(Int(rng.next() % 9) - 4)
            y[j * yb + i] = UInt8(min(max(v, 16), 235))
        } }
        let c = CVPixelBufferGetBaseAddressOfPlane(b, 1)!.assumingMemoryBound(to: UInt8.self), cb = CVPixelBufferGetBytesPerRowOfPlane(b, 1)
        for j in 0..<h / 2 { for i in 0..<w / 2 { c[j * cb + 2 * i] = UInt8(100 + i % 50); c[j * cb + 2 * i + 1] = UInt8(150 - j % 40) } }
        CVPixelBufferUnlockBaseAddress(b, [])
        return b
    }

    static func luma(_ pb: CVPixelBuffer) -> (UnsafeMutablePointer<UInt8>, Int) {
        (CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self), CVPixelBufferGetBytesPerRowOfPlane(pb, 0))
    }

    /// The same 960×540 frame scaled in one tile and in 3×2 tiles of ≤ 400 px: the stitched result matches, and the
    /// seams are no worse than the rest of the frame.
    @Test func tiledOutputMatchesSingleTile() async throws {
        guard #available(macOS 26.0, *), VideoEnhancer.tiledSupports(960, 540) else { print("skip: no low-latency super resolution"); return }
        try await HeavyWorkGate.run {
            let src = Self.texturedFrame(960, 540)
            let one = try TiledScaler(width: 960, height: 540, passes: 1, outWidth: 1920, outHeight: 1080)
            let many = try TiledScaler(width: 960, height: 540, passes: 1, outWidth: 1920, outHeight: 1080, maxTile: 400)
            defer { one.end(); many.end() }
            #expect(one.passes[0].cols.count == 1 && many.passes[0].cols.count == 3 && many.passes[0].rows.count == 2)
            let a = try await one.scale(src, pts: .zero), b = try await many.scale(src, pts: .zero)
            #expect(CVPixelBufferGetWidth(b) == 1920 && CVPixelBufferGetHeight(b) == 1080)
            CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
            let (pa, ab) = Self.luma(a), (pb, bb) = Self.luma(b)
            var all = 0.0, n = 0.0
            var seam = 0.0, sn = 0.0
            let seamsX = many.passes[0].cols.dropFirst().map { 2 * $0.coreStart }, seamsY = many.passes[0].rows.dropFirst().map { 2 * $0.coreStart }
            for y in 0..<1080 { for x in 0..<1920 {
                let d = abs(Double(pa[y * ab + x]) - Double(pb[y * bb + x]))
                all += d; n += 1
                if seamsX.contains(where: { abs($0 - x) <= 2 }) || seamsY.contains(where: { abs($0 - y) <= 2 }) { seam += d; sn += 1 }
            } }
            // and the output really is the scaled frame (not black / garbage): mean luma close to the source's
            CVPixelBufferLockBaseAddress(src, .readOnly)
            let (ps, sb) = Self.luma(src)
            var ms = 0.0
            for y in 0..<540 { for x in 0..<960 { ms += Double(ps[y * sb + x]) } }
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
            var mb = 0.0
            for y in 0..<1080 { for x in 0..<1920 { mb += Double(pb[y * bb + x]) } }
            print("metric sr_tiles_mad_all=\(all / n) seams=\(seam / sn) mean_src=\(ms / (960 * 540)) mean_out=\(mb / (1920 * 1080))")
            #expect(abs(ms / (960 * 540) - mb / (1920 * 1080)) < 4)
            // the scaler's output depends a little on its input frame as a whole (≈ 4 / 255 everywhere on this noisy
            // texture); what matters is that seams are no worse than anywhere else
            #expect(all / n < 8, "tiled vs single tile mean |Δ| \(all / n)")
            #expect(seam / sn < all / n * 1.3 + 0.5, "seams mean |Δ| \(seam / sn) vs \(all / n)")
        }
    }

    /// Owner targets on this Mac: ≤ 3× real time for 1080p output, ≤ 6× for 4K (load-aware; was ×50 for 1080p → 4K).
    /// Also checks the colour tags / size of the result and that progress is reported.
    @Test func enhanceQualityRunsInRealTimeBudget() async throws {
        guard VideoEnhancer.tiledSupports(1920, 1080) else { print("skip: no low-latency super resolution"); return }
        try await HeavyWorkGate.run {
            for (size, target, out, budget, name) in [(CGSize(width: 960, height: 540), UpscaleTarget.hd, Size2(1920, 1080), 3.0, "1080p"),
                                                      (CGSize(width: 1920, height: 1080), UpscaleTarget.hd, Size2(3840, 2160), 6.0, "4k")] {
                let url = try await TestMedia.video(.movingBox(.white, .red), seconds: 2, size: size)
                let a = try await MediaProbe.probe(url)
                let e = VideoEnhancement(original: a.id, upscale: target)
                try? FileManager.default.removeItem(at: VideoEnhancer.outputURL(a, e))
                let last = Locked(0.0), steps = Locked(0)
                let st = Locked<VideoEnhancer.Stats?>(nil)
                let file = try await VideoEnhancer.process(a, e, progress: { p in last.set(p); steps.mutate { $0 += 1 } }, stats: { s in st.set(s) })
                let probe = try await MediaProbe.probe(file)
                #expect(probe.pixelSize == out && abs(probe.duration.seconds - 2) < 0.1)
                #expect(last.get() == 1 && steps.get() > 10, "progress reported")
                let s = try #require(st.get())
                print("enhance \(name): \(s)")
                TimingBudget.metric("unit_enhance_quality_\(name)_rtf", s.realTimeFactor, "x")
                if let lim = TimingBudget.limit(budget, "enhance quality \(name)") { #expect(s.realTimeFactor < lim, "\(name): \(s)") }
            }
        }
    }

    /// Cancelling the job stops it within a frame or two and leaves no output.
    @Test func enhanceQualityCancels() async throws {
        guard VideoEnhancer.tiledSupports(1920, 1080) else { print("skip: no low-latency super resolution"); return }
        try await HeavyWorkGate.run {
            let url = try await TestMedia.video(.movingBox(.white, .red), seconds: 4, size: CGSize(width: 1920, height: 1080))
            let a = try await MediaProbe.probe(url)
            let e = VideoEnhancement(original: a.id, upscale: .uhd)
            try? FileManager.default.removeItem(at: VideoEnhancer.outputURL(a, e))
            let started = Locked(false)
            let task = Task { try await VideoEnhancer.process(a, e, progress: { if $0 > 0.05 { started.set(true) } }) }
            while !started.get() { try await Task.sleep(nanoseconds: 5_000_000) }
            let t0 = Date()
            task.cancel()
            await #expect(throws: CancellationError.self) { _ = try await task.value }
            #expect(Date().timeIntervalSince(t0) < 2)
            #expect(!FileManager.default.fileExists(atPath: VideoEnhancer.outputURL(a, e).path))
        }
    }
}

/// Small lock-protected box for test callbacks.
final class Locked<T>: @unchecked Sendable {
    private var v: T
    private let l = NSLock()
    init(_ v: T) { self.v = v }
    func get() -> T { l.withLock { v } }
    func set(_ n: T) { l.withLock { v = n } }
    func mutate(_ f: (inout T) -> Void) { l.withLock { f(&v) } }
}
