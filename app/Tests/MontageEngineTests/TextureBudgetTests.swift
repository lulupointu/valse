import Testing
import Foundation
@preconcurrency import Metal
import MontageCore
import MontageEffects
@testable import MontageEngine
import MontageTestSupport

/// Engine memory policies (perf round 2): byte-budgeted texture pool, in-frame texture recycling, memory pressure.
@Suite(.serialized) struct TextureBudgetTests {
    @Test func poolKeepsIdleTexturesWithinItsByteBudget() {
        let one = MetalContext.shared.pool.acquire(256, 256).allocatedSize
        let pool = TexturePool(device: MetalContext.shared.device, idleBudget: 3 * one)
        let a = (0..<6).map { _ in pool.acquire(256, 256) }
        #expect(pool.allocations == 6)
        for t in a { pool.release(t) }
        #expect(pool.idleBytes == 3 * one)
        _ = (0..<3).map { _ in pool.acquire(256, 256) }
        #expect(pool.allocations == 6, "idle textures are reused")
        pool.idleBudget = 0
        #expect(pool.idleBytes == 0)
    }

    /// Six translucent layers with multi-pass effects, an adjustment layer and text: recycling dead textures inside
    /// the frame gives the same pixels with a fraction of the textures.
    @Test func inFrameRecyclingKeepsPixelsAndShrinksTheWorkingSet() async throws {
        var p = TestProject(canvas: Size2(640, 360), background: .black)
        let colors: [RGBA] = [.red, .green, .blue, RGBA(1, 1, 0), RGBA(0, 1, 1), RGBA(1, 0, 1)]
        for (i, c) in colors.enumerated() {
            let id = try p.addSolid(c, duration: 2)
            p[id].transform.scale = Vec2(0.5, 0.5)
            p[id].transform.position = Vec2(Double(i % 3) * 0.3 - 0.3, i < 3 ? -0.2 : 0.2)
            p[id].opacity = 0.8
            p[id].effects = [EffectInstance(typeID: "montage.effect.blur"), EffectInstance(typeID: "montage.filter.warm"),
                             EffectInstance(typeID: "montage.effect.vignette")]
        }
        try p.addAdjustment([EffectInstance(typeID: "montage.effect.blur")], duration: 2)
        let title = try p.addText("Recycle", duration: 2)
        p[title].effects = [EffectInstance(typeID: "montage.effect.vignette")]   // layer-texture text path
        let frame = FrameEvaluator.evaluate(p.project, at: Time(1))

        func render(_ r: FrameRenderer) -> [UInt8] {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 640, height: 360, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
            let out = MetalContext.shared.device.makeTexture(descriptor: d)!
            let cmd = MetalContext.shared.queue.makeCommandBuffer()!
            r.encode(frame, media: [:], sources: DictionarySourceProvider([:]), output: out, commandBuffer: cmd)
            cmd.commit(); cmd.waitUntilCompleted()
            var bytes = [UInt8](repeating: 0, count: 640 * 360 * 4)
            out.getBytes(&bytes, bytesPerRow: 640 * 4, from: MTLRegionMake2D(0, 0, 640, 360), mipmapLevel: 0)
            return bytes
        }
        let recycling = FrameRenderer(), plain = FrameRenderer()
        plain.allowsTextureRecycling = false
        let a = render(recycling), b = render(plain)
        #expect(a == b, "recycling must not change pixels")
        #expect(a.contains { $0 > 40 })
        #expect(recycling.lastFrameTextureCount * 2 <= plain.lastFrameTextureCount,
                "\(recycling.lastFrameTextureCount) vs \(plain.lastFrameTextureCount) textures")
    }

    @Test func memoryPressureShrinksAndRestoresCaches() {
        let pool = MetalContext.shared.pool
        MemoryPressure.shared.apply(.critical)
        #expect(pool.idleBudget == 0 && pool.idleBytes == 0)
        #expect(FrameRenderer.shared.images.byteBudget < MemoryBudget.imageCacheBytes)
        MemoryPressure.shared.apply(.normal)
        #expect(pool.idleBudget == MemoryBudget.texturePoolIdleBytes)
        #expect(FrameRenderer.shared.images.byteBudget == MemoryBudget.imageCacheBytes)
    }
}
