import Testing
import Foundation
import CoreGraphics
@preconcurrency import Metal
import ValseCore
import ValseEffects
@testable import ValseEngine
import ValseTestSupport

/// BUG-BUBBLE-TEXT-LAG: a Size drag on a text with a neon bubble re-rasterized the whole look (50–170 ms of Core
/// Graphics blurs at 1080p) on the main thread at every tick. Interactive frames (paused preview re-render) now draw
/// the previous raster scaled and refine off-thread; once the refine lands the frame is exactly the export's.
/// Load-independent measures: calling-thread CPU time (`CLOCK_THREAD_CPUTIME_ID`, preemption excluded) and stand-in
/// counts; the preview/export equality relies on deterministic rasters (`costlyLookRastersAreIdenticalWhenPaintedConcurrently`).
@Suite(.serialized) struct TextSizeEditPerfTests {
    /// Vertical 1080p, like the owner's project (1080 × 1920 captions with an orange neon burst bubble).
    static let canvas = Size2(1080, 1920)

    func neonCaption() -> TextContent {
        var t = TextContent(string: "pour qu'elle\nne vienne pas.", fontSize: 0.03375)
        t.bold = true
        // the owner's caption: neon letters (set by hand since bubbles no longer restyle the text) in a neon burst
        t.pickBubble(Registries.textBubbles["valse.bubble.neonOrangeBurst"])
        Self.neonLetters(&t, RGBA(hex: 0xFFB020))
        return t
    }

    static func neonLetters(_ t: inout TextContent, _ c: RGBA, flicker: TextNeonFlicker = .off) {
        t.color = .white
        t.neon = TextNeonStyle(color: c, intensity: 0.8, glowSize: 0.3, thickness: 0.05, flicker: flicker)
        t.glow = TextGlowStyle(color: .black, intensity: 0.35, radius: 0.3, mode: .outer)
        t.fontName = "AvenirNextCondensed-Heavy"; t.textCase = .upper; t.letterSpacing = 0.03; t.bold = false
    }

    func project(_ t: TextContent, space: ProjectColorSpace) -> (Project, ClipID) {
        var p = Project(name: "size", settings: ProjectSettings(canvasSize: Self.canvas, frameRate: .fps30, backgroundColor: .black))
        p.settings.colorSpace = space
        let c = Clip(content: .text(t), start: 0, duration: Time(10))
        try! TimelineOps.insert(c, into: &p)
        return (p, c.id)
    }

    func target(shared: Bool) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(Self.canvas.width),
                                                         height: Int(Self.canvas.height), mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = shared ? .shared : .private
        return MetalContext.shared.device.makeTexture(descriptor: d)!
    }

    /// Calling-thread CPU ms of encoding one frame (what the paused preview's re-render costs the main thread).
    @discardableResult
    func tick(_ p: Project, _ r: FrameRenderer, _ out: MTLTexture, interactive: Bool) -> Double {
        let f = FrameEvaluator.evaluate(p, at: Time(1))
        let c0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let cmd = MetalContext.shared.queue.makeCommandBuffer()!
        r.encode(f, media: [:], sources: DictionarySourceProvider([:]), output: out, commandBuffer: cmd, interactive: interactive)
        cmd.commit()
        let ms = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - c0) / 1e6
        cmd.waitUntilCompleted()
        return ms
    }

    func pixels(_ p: Project, _ r: FrameRenderer, interactive: Bool) -> [UInt8] {
        let out = target(shared: true)
        tick(p, r, out, interactive: interactive)
        var b = [UInt8](repeating: 0, count: out.width * out.height * 4)
        out.getBytes(&b, bytesPerRow: out.width * 4, from: MTLRegionMake2D(0, 0, out.width, out.height), mipmapLevel: 0)
        return b
    }

    /// Waits for the off-thread refine (a hang bound, not a speed budget).
    func waitForRefine(_ r: FrameRenderer) {
        let deadline = Date().addingTimeInterval(60)
        while r.text.isRefining, Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        #expect(!r.text.isRefining, "text refine never finished")
    }

    @Test(arguments: [ProjectColorSpace.sdr709, .hdrHLG])
    func neonBubbleSizeDragFitsOneFrame(_ space: ProjectColorSpace) {
        let base = neonCaption()
        var (p, id) = project(base, space: space)
        let r = FrameRenderer()
        let out = target(shared: false)
        tick(p, r, out, interactive: true)   // first sight of the look: exact, synchronous
        // before the fix every tick was an exact raster: a few of them for the record
        var exact: [Double] = []
        for i in 1...3 {
            var t = base; t.fontSize = base.fontSize * (1 - Double(i) * 0.01)
            p.timeline[clip: id]?.content = .text(t)
            exact.append(tick(p, r, out, interactive: false))
        }
        let n = 40
        var cost: [Double] = []
        let standIns = r.text.standInCount
        for i in 1...n {
            var t = base; t.fontSize = base.fontSize * (1 + Double(i) * 0.01)   // a Size drag: a new size every tick
            p.timeline[clip: id]?.content = .text(t)
            cost.append(tick(p, r, out, interactive: true))
        }
        let median = cost.sorted()[n / 2], p95 = cost.sorted()[n * 95 / 100]
        let tag = space == .sdr709 ? "sdr" : "hdr"
        TimingBudget.metric("unit_text_bubble_size_tick_\(tag)_ms", median, "ms")
        print("BUG-BUBBLE-TEXT-LAG \(tag): exact tick \(exact.sorted()[1]) ms → interactive median \(median) ms, p95 \(p95) ms")
        #expect(r.text.standInCount - standIns >= n / 2, "size ticks still rasterize on the calling thread")
        #expect(median < TimingBudget.cpuLimit(16), "size tick costs \(median) ms of calling-thread CPU")
        // once the drag stops and the refine lands, the preview is exactly the export's frame
        waitForRefine(r)
        let preview = pixels(p, r, interactive: true)
        let export = pixels(p, FrameRenderer(), interactive: false)
        #expect(preview == export, "preview after the drag differs from the exact render")
    }

    /// FLAKY-ENG: `neonBubbleSizeDragFitsOneFrame` failed once (preview ≠ export in a 44-row band, ≤ 25/255) because
    /// Core Graphics rasters of this look are not bit-identical when other threads paint costly looks at the same
    /// time (the refine thread vs any other raster in the process). Costly looks now paint under one lock
    /// (`TextPainter.painting`): rasters made on 32 threads at once all equal the single-threaded one. Before the
    /// lock, 3-22 of 128 such concurrent rasters differed.
    @Test func costlyLookRastersAreIdenticalWhenPaintedConcurrently() {
        let t = neonCaption()
        let px = Self.canvas.height * t.fontSize * 1.4
        func bytes(_ img: CGImage) -> [UInt8] {
            var b = [UInt8](repeating: 0, count: img.width * img.height * 4)
            let ctx = CGContext(data: &b, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            return b
        }
        guard let refImg = TextRasterizer.image(t, fontPx: px, canvasWidthPx: Self.canvas.width) else { Issue.record("no raster"); return }
        let ref = bytes(refImg)
        final class Diffs: @unchecked Sendable { let lock = NSLock(); var runs: [Int] = [] }
        let diffs = Diffs()
        DispatchQueue.concurrentPerform(iterations: 64) { i in
            let img = TextRasterizer.image(t, fontPx: px, canvasWidthPx: Self.canvas.width)
            if img.map(bytes) != ref { diffs.lock.withLock { diffs.runs.append(i) } }
        }
        #expect(diffs.runs.isEmpty, "\(diffs.runs.count) of 64 concurrent rasters differ from the single-threaded one")
    }

    @Test func cheapTextStaysExactWhileEditing() {
        var base = TextContent(string: "Plain caption", fontSize: 0.05); base.bold = true
        var (p, id) = project(base, space: .sdr709)
        let r = FrameRenderer()
        let out = target(shared: false)
        tick(p, r, out, interactive: true)
        let before = r.text.standInCount
        for i in 1...5 {
            var t = base; t.fontSize = base.fontSize * (1 + Double(i) * 0.02)
            p.timeline[clip: id]?.content = .text(t)
            tick(p, r, out, interactive: true)
        }
        #expect(r.text.standInCount == before, "a cheap text should rasterize exactly, not stand in")
        #expect(pixels(p, r, interactive: true) == pixels(p, FrameRenderer(), interactive: false))
    }

    @Test func flickeringNeonBubbleSizeDragUsesTheAtlasStandIn() {
        var base = neonCaption()
        base.pickBubble(Registries.textBubbles["valse.bubble.neonFlicker"])
        Self.neonLetters(&base, RGBA(hex: 0x19E6FF), flicker: .oneLetter)
        var (p, id) = project(base, space: .sdr709)
        let r = FrameRenderer()
        let out = target(shared: false)
        tick(p, r, out, interactive: true)
        let before = r.text.standInCount
        var cost: [Double] = []
        for i in 1...10 {
            var t = base; t.fontSize = base.fontSize * (1 + Double(i) * 0.01)
            p.timeline[clip: id]?.content = .text(t)
            cost.append(tick(p, r, out, interactive: true))
        }
        #expect(r.text.standInCount > before, "flickering bubble re-rasterized its atlas on every tick")
        let median = cost.sorted()[cost.count / 2]
        #expect(median < TimingBudget.cpuLimit(16), "flickering size tick costs \(median) ms")
        waitForRefine(r)
        #expect(pixels(p, r, interactive: true) == pixels(p, FrameRenderer(), interactive: false))
    }
}
