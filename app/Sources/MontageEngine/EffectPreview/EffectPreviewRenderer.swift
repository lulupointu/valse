@preconcurrency import Metal
import Accelerate
import CoreGraphics
import Foundation
import MontageCore
import MontageEffects

/// Renders effects / filters / adjustments on a procedural sample frame, through the real effect stack
/// (`FrameRenderer.applyEffects`, same shaders as preview and export). Used for asset-panel thumbnails and hover
/// previews, the per-effect render tests and the effects perf test.
///
/// The sample frame is generated on the GPU (sky, sun, clouds, mountains, meadow, a hot-air balloon and a person),
/// so we ship no image assets. `.subject` is the person alone with alpha (body effects work on the layer alpha).
public final class EffectPreviewRenderer: @unchecked Sendable {
    public static let shared = EffectPreviewRenderer()

    public enum Scene: Int, Sendable {
        case full = 0, subject = 1, background = 2
        /// The subject composited over the background (what body-effect previews look like without an effect).
        case subjectOverBackground = 3
    }

    private let ctx = MetalContext.shared
    private let lock = NSLock()
    private var scenePipe: MTLRenderPipelineState?
    private var sceneCache: [String: MTLTexture] = [:]

    public init() {}

    /// Straight-RGBA float pixels of a render, row-major, top row first.
    public struct Pixels: Sendable {
        public let width: Int
        public let height: Int
        public let data: [Float]
        public subscript(x x: Int, y y: Int) -> SIMD4<Float> {
            let i = (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 4
            return SIMD4(data[i], data[i + 1], data[i + 2], data[i + 3])
        }
        /// Mean RGBA over a normalized rect.
        public func mean(x: Double = 0, y: Double = 0, w: Double = 1, h: Double = 1) -> SIMD4<Float> {
            let x0 = Int(x * Double(width)), x1 = max(x0 + 1, Int((x + w) * Double(width)))
            let y0 = Int(y * Double(height)), y1 = max(y0 + 1, Int((y + h) * Double(height)))
            var acc = SIMD4<Float>(repeating: 0); var n: Float = 0
            for yy in y0..<min(y1, height) { for xx in x0..<min(x1, width) { acc += self[x: xx, y: yy]; n += 1 } }
            return acc / max(n, 1)
        }
    }

    // MARK: Sample scene

    static let sceneSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct QuadOut { float4 pos [[position]]; float2 uv; };
    inline float h21(float2 q) { q = fract(q * float2(123.34, 456.21)); q += dot(q, q + 45.32); return fract(q.x * q.y); }
    inline float vn(float2 x) { float2 i = floor(x), f = fract(x); float2 u = f * f * (3.0 - 2.0 * f);
        return mix(mix(h21(i), h21(i + float2(1, 0)), u.x), mix(h21(i + float2(0, 1)), h21(i + float2(1, 1)), u.x), u.y); }
    inline float fbm(float2 x) { float v = 0, a = 0.5; for (int i = 0; i < 5; i++) { v += a * vn(x); x = x * 2.02 + 7.0; a *= 0.5; } return v; }
    inline float sdBox(float2 q, float2 b, float r) { float2 d = abs(q) - b + r; return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - r; }

    // Person: returns (rgb, coverage). q in canvas-height units centred on the frame.
    inline float ell(float2 q, float2 c, float2 r) { return (length((q - c) / r) - 1.0) * min(r.x, r.y); }
    inline float4 person(float2 q, float px) {
        float head = ell(q, float2(0.0, -0.10), float2(0.082, 0.104));
        float hairOut = ell(q, float2(0.0, -0.118), float2(0.098, 0.112));
        float hairline = -0.135 + 0.018 * cos(q.x * 30.0);
        float hair = max(hairOut, min(q.y - hairline, -head));          // above the hairline, or around the face
        hair = max(hair, q.y + 0.03);                                     // stops at ear level
        float neck = sdBox(q - float2(0.0, 0.0), float2(0.03, 0.05), 0.012);
        float2 bq = q - float2(0.0, 0.31);
        float body = sdBox(bq, float2(0.19 + max(bq.y, 0.0) * 0.12, 0.25), 0.09);
        float shape = min(min(head, neck), min(body, hair));
        float cov = 1.0 - smoothstep(-px, px, shape);
        float3 skin = float3(0.94, 0.72, 0.58);
        float2 hq = (q - float2(0.0, -0.10)) / float2(0.082, 0.104);
        float lit = 0.80 + 0.22 * hq.x - 0.12 * hq.y - 0.12 * dot(hq, hq);
        float3 c = skin * lit;
        float cheek = exp(-dot(abs(hq) - float2(0.5, -0.25), abs(hq) - float2(0.5, -0.25)) * 14.0);
        c = mix(c, float3(0.92, 0.52, 0.48), 0.30 * cheek);
        float2 eq = float2(abs(q.x) - 0.033, q.y + 0.105);
        float eye = length(eq * float2(1.0, 1.5)) - 0.011;
        c = mix(c, float3(0.10, 0.07, 0.06), 1.0 - smoothstep(-px, px, eye));
        float brow = sdBox(eq - float2(0.0, -0.024), float2(0.017, 0.003), 0.003);
        c = mix(c, float3(0.25, 0.15, 0.10), 1.0 - smoothstep(-px, px, brow));
        float2 mq = q - float2(0.0, -0.045);
        float mouth = abs(length(mq - float2(0.0, -0.03)) - 0.03) - 0.004;
        c = mix(c, float3(0.70, 0.28, 0.30), (1.0 - smoothstep(-px, px, mouth)) * step(-0.01, mq.y));
        if (neck < 0.0 && head > 0.0) { c = skin * (0.62 + 0.1 * smoothstep(0.0, 0.05, q.y)); }
        if (body < 0.0 && neck > -0.004) {
            float stripe = step(0.5, fract((bq.y + 0.3) * 9.0));
            c = mix(float3(0.06, 0.48, 0.58), float3(0.95, 0.95, 0.92), stripe * 0.85);
            c *= 0.72 + 0.32 * saturate(0.5 + bq.x * 2.5);
        }
        if (hair < 0.0) { c = float3(0.24, 0.14, 0.08) * (0.75 + 0.5 * vn(float2(q.x * 90.0, q.y * 20.0))); }
        return float4(c, cov);
    }

    fragment float4 sample_scene_fs(QuadOut in [[stage_in]], constant float2& sz [[buffer(0)]], constant int& kind [[buffer(1)]]) {
        float2 uv = in.uv;
        float aspect = sz.x / sz.y;
        float px = 1.5 / sz.y;
        float2 q = (uv - 0.5) * float2(aspect, 1.0);
        float x = q.x;
        // sky
        float3 col = mix(float3(1.0, 0.74, 0.50), float3(0.20, 0.42, 0.82), smoothstep(0.62, 0.02, uv.y));
        float2 sun = float2(0.30 * aspect, -0.22);
        float ds = length(q - sun);
        col += float3(1.0, 0.78, 0.45) * exp(-ds * 7.0) * 0.55;
        col = mix(col, float3(1.0, 0.97, 0.86), 1.0 - smoothstep(0.045 - px, 0.045 + px, ds));
        float cl = smoothstep(0.52, 0.78, fbm(float2(x * 2.2 + 3.0, uv.y * 5.0)) + (0.35 - uv.y) * 0.6);
        col = mix(col, float3(1.0, 0.93, 0.92), cl * 0.75 * smoothstep(0.55, 0.15, uv.y));
        // balloon
        float2 bq = q - float2(-0.30 * aspect, -0.24);
        float bal = length(bq * float2(1.0, 0.86)) - 0.07;
        if (bal < 0.0 || (abs(bq.x) < 0.02 && bq.y > 0.08 && bq.y < 0.11)) {
            float st = step(0.5, fract(atan2(bq.x, 0.08) * 3.0));
            float3 bc = mix(float3(0.92, 0.16, 0.14), float3(1.0, 0.82, 0.12), st);
            bc *= 0.7 + 0.45 * saturate(0.5 + bq.x * 6.0 - bq.y * 4.0);
            if (bq.y > 0.08) bc = float3(0.45, 0.28, 0.15);
            col = mix(col, bc, 1.0 - smoothstep(-px, px, bal < 0.0 ? bal : -px * 2.0));
        }
        // mountains
        float m1 = 0.50 - 0.13 * fbm(float2(x * 2.0 + 11.0, 1.0)) - 0.05 * sin(x * 3.0 + 1.0);
        float3 mc1 = mix(float3(0.42, 0.42, 0.62), float3(0.62, 0.55, 0.65), smoothstep(m1, m1 + 0.12, uv.y) * 0.6);
        col = mix(col, mc1, smoothstep(m1 - px, m1 + px, uv.y));
        float m2 = 0.58 - 0.08 * fbm(float2(x * 3.3 + 4.0, 2.0));
        float3 mc2 = mix(float3(0.20, 0.36, 0.30), float3(0.30, 0.45, 0.28), vn(float2(x * 30.0, uv.y * 30.0)));
        col = mix(col, mc2, smoothstep(m2 - px, m2 + px, uv.y));
        // lake (left) with sky reflection
        float shore = -0.12 + 0.05 * sin(uv.y * 60.0) - (uv.y - 0.62) * 3.0;
        if (uv.y > 0.62 && uv.y < 0.72 && x < shore) {
            float3 refl = mix(float3(0.95, 0.75, 0.55), float3(0.25, 0.5, 0.85), (uv.y - 0.62) * 8.0);
            refl += 0.08 * sin(uv.y * 400.0 + x * 20.0);
            col = refl;
        }
        // meadow
        float g0 = 0.64 + 0.02 * sin(x * 5.0);
        if (uv.y > g0 && !(uv.y < 0.72 && x < shore)) {
            float n = fbm(float2(x * 9.0, uv.y * 14.0));
            float3 gc = mix(float3(0.28, 0.52, 0.16), float3(0.62, 0.72, 0.22), n);
            gc *= 0.8 + 0.4 * (uv.y - g0);
            col = gc;
            float2 cell = floor(float2(x, uv.y) * 70.0);
            float r = h21(cell);
            float2 f = fract(float2(x, uv.y) * 70.0) - 0.5;
            if (r > 0.78 && uv.y > 0.7 && length(f) < 0.28) {
                float k = h21(cell + 3.7);
                col = k < 0.35 ? float3(0.95, 0.2, 0.25) : (k < 0.7 ? float3(1.0, 0.85, 0.2) : float3(0.75, 0.45, 0.95));
            }
        }
        float4 outc = float4(col, 1.0);
        if (kind != 2) {
            float4 pp = person(q - float2(0.08 * aspect, 0.14), px);
            if (kind == 1) return float4(pp.rgb, pp.a);
            outc.rgb = mix(outc.rgb, pp.rgb, pp.a);
        }
        return outc;
    }
    """

    /// The sample frame (cached per size and scene).
    public func sceneTexture(width: Int, height: Int, scene: Scene = .full) -> MTLTexture? {
        let key = "\(width)x\(height)-\(scene.rawValue)"
        if let t = lock.withLock({ sceneCache[key] }) { return t }
        guard let pipe = scenePipeline(), let cmd = ctx.queue.makeCommandBuffer() else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MetalContext.workingFormat, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
        guard let tex = ctx.device.makeTexture(descriptor: d) else { return nil }
        var sz = SIMD2<Float>(Float(width), Float(height))
        var kind = Int32(scene.rawValue)
        FrameRenderer.shared.fullscreen(pipe, target: tex, cmd, label: "sample-scene") { enc in
            enc.setFragmentBytes(&sz, length: 8, index: 0)
            enc.setFragmentBytes(&kind, length: 4, index: 1)
        }
        cmd.commit(); cmd.waitUntilCompleted()
        lock.withLock { if sceneCache.count > 16 { sceneCache.removeAll() }; sceneCache[key] = tex }
        return tex
    }

    private func scenePipeline() -> MTLRenderPipelineState? {
        if let p = lock.withLock({ scenePipe }) { return p }
        do {
            let lib = try ctx.device.makeLibrary(source: Self.sceneSource, options: ctx.caps.compileOptions)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = ctx.fullscreenVS
            d.fragmentFunction = lib.makeFunction(name: "sample_scene_fs")
            d.colorAttachments[0].pixelFormat = MetalContext.workingFormat
            let p = try ctx.device.makeRenderPipelineState(descriptor: d)
            lock.withLock { scenePipe = p }
            return p
        } catch {
            EngineLog.error("sample scene failed: \(error)")
            return nil
        }
    }

    // MARK: Rendering

    /// Body effects (group `effect.group.body`) preview on the cut-out subject, composited over the background.
    public static func usesSubject(_ d: EffectDescriptor) -> Bool { d.groupKey == "effect.group.body" }

    /// Renders `effects` (in order) over the sample frame at clip time `time`. Returns straight RGBA pixels.
    public func render(_ effects: [EffectInstance], time: Double, width: Int, height: Int, scene: Scene? = nil) -> Pixels? {
        let descs = effects.compactMap { Registries.effects[$0.typeID] }
        let subject = (scene == nil && descs.contains(where: Self.usesSubject)) || scene == .subjectOverBackground
        let sc: Scene = subject ? .subject : (scene ?? .full)
        guard let src = sceneTexture(width: width, height: height, scene: sc),
              let cmd = ctx.queue.makeCommandBuffer() else { return nil }
        let scratch = FrameRenderer.FrameScratch()
        let pool = ctx.pool
        func acquire(_ w: Int, _ h: Int) -> MTLTexture { let t = pool.acquire(w, h); scratch.textures.append(t); return t }
        let resolved = effects.map { ResolvedEffect(instanceID: $0.id, typeID: $0.typeID, params: $0.params) }
        // FX-008: effects reading the whole frame behind the person (magic cutout) get the composited sample scene
        let backdrop = subject && descs.contains { $0.inputs.contains(.backdrop) }
            ? sceneTexture(width: width, height: height, scene: .subjectOverBackground) : nil
        var out = FrameRenderer.shared.applyEffects(resolved, to: src, time: Time(time), cmd: cmd, acquire: acquire, backdrop: backdrop)
        if subject, let bg = sceneTexture(width: width, height: height, scene: .background), let over = overPipeline() {
            let target = acquire(width, height)
            let fg = out
            FrameRenderer.shared.fullscreen(over, target: target, cmd, label: "preview-over") { enc in
                enc.setFragmentTexture(fg, index: 0); enc.setFragmentTexture(bg, index: 1)
            }
            out = target
        }
        let bytes = width * height * 8
        guard let buf = ctx.device.makeBuffer(length: bytes, options: .storageModeShared), let blit = cmd.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: out, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1), to: buf, destinationOffset: 0,
                  destinationBytesPerRow: width * 8, destinationBytesPerImage: bytes)
        blit.endEncoding()
        cmd.addCompletedHandler { _ in scratch.textures.forEach(pool.release) }
        cmd.commit(); cmd.waitUntilCompleted()
        let n = width * height * 4
        var data = [Float](repeating: 0, count: n)
        data.withUnsafeMutableBufferPointer { out in
            var srcBuf = vImage_Buffer(data: buf.contents(), height: 1, width: vImagePixelCount(n), rowBytes: n * 2)
            var dstBuf = vImage_Buffer(data: out.baseAddress, height: 1, width: vImagePixelCount(n), rowBytes: n * 4)
            vImageConvert_Planar16FtoPlanarF(&srcBuf, &dstBuf, 0)
        }
        return Pixels(width: width, height: height, data: data)
    }

    /// One effect with its defaults (plus `params` overrides).
    public func render(_ d: EffectDescriptor, params: [String: ParamValue] = [:], time: Double, width: Int, height: Int) -> Pixels? {
        var inst = d.makeInstance()
        for (k, v) in params { inst.params[k] = v }
        return render([inst], time: time, width: width, height: height)
    }

    /// 8-bit sRGB image of a render (thumbnails), composited over opaque dark grey where transparent.
    public func image(_ d: EffectDescriptor, time: Double, width: Int, height: Int) -> CGImage? {
        guard let px = render(d, time: time, width: width, height: height) else { return nil }
        return Self.cgImage(px)
    }

    public static func cgImage(_ px: Pixels) -> CGImage? {
        var bytes = [UInt8](repeating: 255, count: px.width * px.height * 4)
        for i in 0..<(px.width * px.height) {
            let a = max(0, min(1, px.data[i * 4 + 3]))
            for c in 0..<3 {
                let v = px.data[i * 4 + c]
                let f = (v.isFinite ? max(0, min(1, v)) : 0) * a + 0.16 * (1 - a)
                bytes[i * 4 + c] = UInt8(f * 255 + 0.5)
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: px.width, height: px.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: px.width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// GPU time (ms) of one effect at `width`×`height`: best of `runs` command buffers (pipeline compiled beforehand).
    public func gpuMilliseconds(_ d: EffectDescriptor, width: Int = 1920, height: Int = 1080, time: Double = 1.0, runs: Int = 3) -> Double? {
        guard EffectPipelines.shared.effect(d) != nil,
              let src = sceneTexture(width: width, height: height, scene: Self.usesSubject(d) ? .subject : .full) else { return nil }
        let resolved = [ResolvedEffect(instanceID: EffectInstanceID(), typeID: d.id, params: d.makeInstance().params)]
        var best = Double.infinity
        let pool = ctx.pool
        for _ in 0..<max(runs, 1) {
            guard let cmd = ctx.queue.makeCommandBuffer() else { return nil }
            let scratch = FrameRenderer.FrameScratch()
            func acquire(_ w: Int, _ h: Int) -> MTLTexture { let t = pool.acquire(w, h); scratch.textures.append(t); return t }
            _ = FrameRenderer.shared.applyEffects(resolved, to: src, time: Time(time), cmd: cmd, acquire: acquire)
            cmd.addCompletedHandler { _ in scratch.textures.forEach(pool.release) }
            cmd.commit(); cmd.waitUntilCompleted()
            best = min(best, (cmd.gpuEndTime - cmd.gpuStartTime) * 1000)
        }
        return best
    }

    /// Effect-on-scene preview composite (own tiny library).
    static let overSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct QuadOut { float4 pos [[position]]; float2 uv; };
    fragment float4 over_fs(QuadOut in [[stage_in]], texture2d<float> fg [[texture(0)]], texture2d<float> bg [[texture(1)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float4 f = fg.sample(s, in.uv), b = bg.sample(s, in.uv);
        float a = saturate(f.a);
        return float4(mix(b.rgb * 0.85, f.rgb, a), 1.0);
    }
    """
    private var overPipe: MTLRenderPipelineState?
    private func overPipeline() -> MTLRenderPipelineState? {
        if let p = lock.withLock({ overPipe }) { return p }
        guard let lib = try? ctx.device.makeLibrary(source: Self.overSource, options: ctx.caps.compileOptions) else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = ctx.fullscreenVS
        d.fragmentFunction = lib.makeFunction(name: "over_fs")
        d.colorAttachments[0].pixelFormat = MetalContext.workingFormat
        let p = try? ctx.device.makeRenderPipelineState(descriptor: d)
        lock.withLock { overPipe = p }
        return p
    }
}
