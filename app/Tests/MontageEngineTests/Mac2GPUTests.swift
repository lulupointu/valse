import Testing
import Foundation
@preconcurrency import Metal
import MontageCore
import MontageEffects
@testable import MontageEngine
import MontageTestSupport

/// macOS 13 on Intel Macs (MTLGPUFamily.mac2: Intel HD/Iris 6xx, AMD Polaris): every runtime library must compile with
/// MSL 3.0 (the newest macOS 13 has), and the Mac2 placement fallback (no framebuffer fetch) must match the Apple path.
@Suite(.serialized) struct Mac2GPUTests {
    static func compile30(_ source: String) -> String? {
        let o = MTLCompileOptions()
        o.languageVersion = GPUCapabilities.baselineLanguageVersion
        do { _ = try MetalContext.shared.device.makeLibrary(source: source, options: o); return nil } catch {
            return String(describing: error)
        }
    }

    /// Every engine library (core, Mac2 core, features, finish, F4, relight, text, effect preview) + every registered
    /// effect / filter / adjustment / transition. MontageUI's timeline canvas is checked in `Mac2UIShaderTests`.
    @Test func everyLibraryCompilesWithMSL30() {
        var sources: [(String, String)] = [
            ("core", CoreShaders.source), ("core-mac2", CoreShaders.mac2Source), ("feature", FeatureShaders.source),
            ("finish", FinishShaders.source), ("f4", F4Shaders.source), ("relight", RelightShaders.source),
            ("text", TextGPU.shader), ("effect-preview-scene", EffectPreviewRenderer.sceneSource),
            ("effect-preview-over", EffectPreviewRenderer.overSource),
        ]
        for d in Registries.effects.all { sources.append((d.id, EffectPipelines.source(d))) }
        for d in Registries.transitions.all { sources.append((d.id, EffectPipelines.source(d))) }
        final class Box: @unchecked Sendable { let lock = NSLock(); var failures: [String: String] = [:] }
        let box = Box(), all = sources
        DispatchQueue.concurrentPerform(iterations: all.count) { i in
            if let e = Self.compile30(all[i].1) { box.lock.withLock { box.failures[all[i].0] = e } }
        }
        let failures = box.failures
        #expect(failures.isEmpty, "MSL 3.0 failures: \(failures.keys.sorted()) — first: \(failures.first?.value ?? "")")
        #expect(sources.count > 100)
    }

    @Test func mac2CoreLibraryHasNoFramebufferFetch() throws {
        #expect(CoreShaders.source.contains("[[color(0)]]"), "Apple path keeps programmable blending")
        #expect(!CoreShaders.mac2Source.contains("[[color("))
        // the fallback pipelines build (on this GPU, from the Mac2 library)
        let f = MetalContext.shared.placeFallback
        _ = (f.over, f.blend)
        #expect(GPUCapabilities(device: MetalContext.shared.device, forceMac2: true).compileOptions?.languageVersion == .version3_0)
        let caps = GPUCapabilities(device: MetalContext.shared.device, forceMac2: true)
        #expect(!caps.framebufferFetch && !caps.sharedTextures && caps.readbackStorageMode == .managed)
    }

    /// The 8-layer blend-mode composite used for the pixel comparison and the benchmark: full-canvas and transformed
    /// layers, opacity, masks, rotation, normal + separable + non-separable blend modes, text on top.
    static let blendModes: [BlendMode] = [.normal, .multiply, .screen, .overlay, .softLight, .difference, .hue, .colorDodge]

    static func eightLayerFrame(_ canvas: Size2, modes: [BlendMode] = blendModes) throws -> FrameDescription {
        var p = TestProject(canvas: canvas, background: RGBA(0.1, 0.12, 0.15))
        let colors: [RGBA] = [RGBA(0.9, 0.2, 0.1), RGBA(0.2, 0.8, 0.3), RGBA(0.1, 0.3, 0.9), RGBA(1, 0.9, 0.2),
                              RGBA(0.2, 0.9, 0.9), RGBA(0.9, 0.3, 0.8), RGBA(0.6, 0.6, 0.6), RGBA(0.95, 0.6, 0.2)]
        for (i, c) in colors.enumerated() {
            let id = try p.addSolid(c, duration: 2)
            if i > 0 {
                p[id].transform.scale = Vec2(0.6, 0.6)
                p[id].transform.position = Vec2(Double(i % 4) * 0.2 - 0.3, i < 4 ? -0.15 : 0.15)
                p[id].transform.rotation = Double(i) * 7
            }
            p[id].opacity = i == 0 ? 1 : 0.85
            p[id].blendMode = modes[i]
            if i == 3 { p[id].mask = Mask(shape: .circle, feather: 0.2) }
            if i == 6 { p[id].mask = Mask(shape: .star) }
        }
        _ = try p.addText("Mac2", duration: 2)
        return FrameEvaluator.evaluate(p.project, at: Time(1))
    }

    static func render(_ r: FrameRenderer, _ frame: FrameDescription, _ w: Int, _ h: Int) -> [UInt8] {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        let ctx = MetalContext.shared
        let out = ctx.makeReadbackTexture(d)!
        let cmd = ctx.queue.makeCommandBuffer()!
        r.encode(frame, media: [:], sources: DictionarySourceProvider([:]), output: out, commandBuffer: cmd)
        ctx.synchronizeForReadback(out, cmd)
        cmd.commit(); cmd.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        out.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        return bytes
    }

    @Test func mac2PlacementMatchesFramebufferFetch() throws {
        let frame = try Self.eightLayerFrame(Size2(640, 360))
        let mac2 = FrameRenderer()
        mac2.useFramebufferFetch = false
        let b = Self.render(mac2, frame, 640, 360)
        #expect(b.contains { $0 > 40 })
        guard MetalContext.shared.place != nil else { return }   // real Mac2 GPU: nothing to compare against
        let apple = FrameRenderer()
        #expect(apple.useFramebufferFetch)
        let a = Self.render(apple, frame, 640, 360)
        var maxDiff = 0, differing = 0
        for i in a.indices {
            let d = abs(Int(a[i]) - Int(b[i]))
            maxDiff = max(maxDiff, d); if d > 0 { differing += 1 }
        }
        print("mac2 placement vs framebuffer fetch: max diff \(maxDiff)/255, \(differing) of \(a.count) channels differ")
        #expect(maxDiff <= 1, "max diff \(maxDiff)")
    }

    /// GPU ms per 1080p frame of the 8-layer blend composite, framebuffer fetch vs the Mac2 fallback (this host's GPU;
    /// says nothing about Intel / AMD speed).
    @Test(arguments: [true, false]) func mac2PlacementCost(blendModes: Bool) throws {
        guard MetalContext.shared.place != nil else { return }
        let frame = try Self.eightLayerFrame(Size2(1920, 1080), modes: blendModes ? Self.blendModes : Array(repeating: .normal, count: 8))
        let ctx = MetalContext.shared
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1920, height: 1080, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
        let out = ctx.device.makeTexture(descriptor: d)!
        func gpuMs(_ r: FrameRenderer) -> Double {
            var samples: [Double] = []
            for _ in 0..<40 {
                let cmd = ctx.queue.makeCommandBuffer()!
                r.encode(frame, media: [:], sources: DictionarySourceProvider([:]), output: out, commandBuffer: cmd)
                cmd.commit(); cmd.waitUntilCompleted()
                samples.append((cmd.gpuEndTime - cmd.gpuStartTime) * 1000)
            }
            return samples.sorted()[samples.count / 2]
        }
        let apple = FrameRenderer(), mac2 = FrameRenderer()
        mac2.useFramebufferFetch = false
        _ = gpuMs(apple); _ = gpuMs(mac2)   // warm-up (pipelines, pool)
        var a = 0.0, b = 0.0
        for _ in 0..<3 { a += gpuMs(apple); b += gpuMs(mac2) }   // interleaved: same GPU load for both
        a /= 3; b /= 3
        print(String(format: "8-layer %@ composite 1080p GPU median: fetch %.3f ms, mac2 fallback %.3f ms (%+.0f%%)",
                     blendModes ? "blend-mode" : "normal", a, b, (b / a - 1) * 100))
        #expect(a > 0 && b > 0)
    }
}
