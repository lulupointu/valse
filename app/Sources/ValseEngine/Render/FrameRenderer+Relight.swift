@preconcurrency import Metal
import CoreVideo
import Foundation
import simd
import ValseCore

/// Relight shading (AI2, AI-024 / CL-020). Normals come from the depth matte (aux lane `.depth`, near = white) by
/// central differences; each light adds Lambert diffuse × falloff + a Blinn highlight on top of an ambient-darkened
/// copy of the layer; People / Background targets mix the result through the person matte (aux lane `.relightMask`).
/// Before the depth pass is ready the surface is flat, so the lights already show (no relief) — instant feedback.
/// Own Metal library (a broken shader only disables relight). Straight RGBA in and out, alpha untouched.
enum RelightShaders {
    static let maxLights = RelightSettings.maxLights
    /// Float layout of the uniform buffer (`p[]`), see `RelightUniforms.pack`.
    static let headerFloats = 24, lightFloats = 12

    static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct QuadOut { float4 pos [[position]]; float2 uv; };

    static float2 xf(constant float* p, int o, float2 uv) { return float2(p[o] * uv.x + p[o + 2] * uv.y + p[o + 4], p[o + 1] * uv.x + p[o + 3] * uv.y + p[o + 5]); }
    static float grey(texture2d<float> t, sampler s, float2 uv, float videoRange) {
        float v = t.sample(s, uv).r;
        return videoRange > 0.5 ? saturate((v - 16.0 / 255.0) * (255.0 / 219.0)) : v;
    }

    fragment float4 relight_fs(QuadOut in [[stage_in]], texture2d<float> t [[texture(0)]], texture2d<float> dtex [[texture(1)]],
                               texture2d<float> mtex [[texture(2)]], constant float* p [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float4 c = t.sample(s, in.uv);
        float aspect = p[19];
        float d = 0.5;
        float3 n = float3(0.0, 0.0, 1.0);
        if (p[22] > 0.5) {
            float2 duv = xf(p, 0, in.uv);
            float2 tx = float2(p[20], p[21]);
            float vr = p[12];
            d = grey(dtex, s, duv, vr);
            // smoothed central differences (wide taps, averaged across the other axis): robust to codec noise
            float gx = 0.0, gy = 0.0;
            for (int j = -1; j <= 1; j++) {
                for (int r = 1; r <= 2; r++) {
                    float o = float(r) * 4.0;
                    float2 ax = float2(tx.x * o, 0.0), ay = float2(0.0, tx.y * o);
                    float2 px = float2(0.0, tx.y * 4.0 * float(j)), py = float2(tx.x * 4.0 * float(j), 0.0);
                    gx += (grey(dtex, s, duv - ax + px, vr) - grey(dtex, s, duv + ax + px, vr)) / float(r);
                    gy += (grey(dtex, s, duv - ay + py, vr) - grey(dtex, s, duv + ay + py, vr)) / float(r);
                }
            }
            float k = (3.0 + 24.0 * p[17]) / 6.0;
            n = normalize(float3(gx * k, gy * k, 1.0));
        }
        float m = 1.0;
        if (p[14] < 1.5 && p[15] > 0.5) {
            float mv = grey(mtex, s, xf(p, 6, in.uv), p[13]);
            m = p[14] < 0.5 ? mv : 1.0 - mv;
        }
        float3 P = float3(in.uv.x * aspect, in.uv.y, d * 0.25);
        float diag = length(float2(aspect, 1.0));
        float3 acc = float3(0.0), spec = float3(0.0);
        int count = int(p[18]);
        for (int i = 0; i < \(maxLights); i++) {
            if (i >= count) { break; }
            int o = \(headerFloats) + i * \(lightFloats);
            float3 col = float3(p[o], p[o + 1], p[o + 2]);
            float lx = p[o + 3], ly = p[o + 4], kind = p[o + 5], height = p[o + 6];
            float inten = p[o + 7], bright = p[o + 8], radius = p[o + 9], hl = p[o + 10];
            float3 L; float att;
            if (kind < 0.5) {
                float3 LP = float3(lx * aspect, ly, 0.25 + height * 0.8);
                float3 v = LP - P;
                float r = max(radius, 0.02) * diag * 0.8;
                float dist = length(v.xy) / r;
                att = exp(-dist * dist * 2.2);
                L = normalize(v);
            } else {
                float2 dir = float2((lx - 0.5) * aspect, ly - 0.5);
                L = normalize(float3(dir, 0.15 + height * 1.5));
                // directional: a soft gradient towards the light side
                float side = length(dir) < 1e-3 ? 0.0 : dot(float2(P.x - 0.5 * aspect, P.y - 0.5), normalize(dir)) / (0.5 * diag);
                att = saturate(0.7 + 0.3 * side);
            }
            float diff = saturate(dot(n, L));
            float g = inten * 2.0 * att * diff * (0.5 + bright);
            acc += col * g;
            float3 H = normalize(L + float3(0.0, 0.0, 1.0));
            spec += col * pow(saturate(dot(n, H)), 24.0) * hl * att * inten * 1.2;
        }
        float3 base = c.rgb * (1.0 - p[16] * 0.75);
        float3 lit = base + c.rgb * acc + spec * c.a;
        return float4(mix(c.rgb, lit, m), c.a);
    }
    """
}

final class RelightPipeline: @unchecked Sendable {
    static let shared = RelightPipeline()
    let state: MTLRenderPipelineState?
    /// 1×1 placeholder bound when a matte isn't ready.
    let blank: MTLTexture?

    private init() {
        let ctx = MetalContext.shared
        var st: MTLRenderPipelineState?
        do {
            let lib = try ctx.device.makeLibrary(source: RelightShaders.source, options: ctx.caps.compileOptions)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = ctx.fullscreenVS
            d.fragmentFunction = lib.makeFunction(name: "relight_fs")
            d.colorAttachments[0].pixelFormat = MetalContext.workingFormat
            st = try ctx.device.makeRenderPipelineState(descriptor: d)
        } catch { EngineLog.info("relight shader failed: \(error)") }
        state = st
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 1, height: 1, mipmapped: false)
        td.usage = .shaderRead
        let b = ctx.device.makeTexture(descriptor: td)
        var v: UInt8 = 128
        b?.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &v, bytesPerRow: 1)
        blank = b
    }
}

/// Packs `RelightSettings` (resolved at this frame) into the shader's float buffer.
enum RelightUniforms {
    static func pack(_ r: RelightSettings, depthXform: simd_float3x2, depthVideoRange: Bool, maskXform: simd_float3x2,
                     maskVideoRange: Bool, hasDepth: Bool, hasMask: Bool, aspect: Double, depthTexel: SIMD2<Float>) -> [Float] {
        var p = [Float](repeating: 0, count: RelightShaders.headerFloats + RelightShaders.maxLights * RelightShaders.lightFloats)
        func put(_ m: simd_float3x2, at o: Int) {
            p[o] = m.columns.0.x; p[o + 1] = m.columns.0.y; p[o + 2] = m.columns.1.x
            p[o + 3] = m.columns.1.y; p[o + 4] = m.columns.2.x; p[o + 5] = m.columns.2.y
        }
        put(depthXform, at: 0); put(maskXform, at: 6)
        p[12] = depthVideoRange ? 1 : 0
        p[13] = maskVideoRange ? 1 : 0
        p[14] = Float(RelightSettings.Target.allCases.firstIndex(of: r.target) ?? 2)
        p[15] = hasMask ? 1 : 0
        p[16] = Float(min(max(r.ambientDarkening, 0), 1))
        p[17] = Float(min(max(r.relief, 0), 1))
        let lights = Array(r.lights.prefix(RelightShaders.maxLights))
        p[18] = Float(lights.count)
        p[19] = Float(aspect)
        p[20] = depthTexel.x; p[21] = depthTexel.y
        p[22] = hasDepth ? 1 : 0
        for (i, l) in lights.enumerated() {
            let o = RelightShaders.headerFloats + i * RelightShaders.lightFloats
            p[o] = Float(l.color.r); p[o + 1] = Float(l.color.g); p[o + 2] = Float(l.color.b)
            p[o + 3] = Float(l.x); p[o + 4] = Float(l.y); p[o + 5] = l.kind == .point ? 0 : 1
            p[o + 6] = Float(min(max(l.distance, 0), 1)); p[o + 7] = Float(min(max(l.intensity, 0), 1))
            p[o + 8] = Float(min(max(l.brightness, 0), 1)); p[o + 9] = Float(min(max(l.radius, 0), 1))
            p[o + 10] = Float(min(max(l.highlights, 0), 1))
        }
        return p
    }
}

extension FrameRenderer {
    /// Grey matte texture of an aux lane (video) — (texture, needs video-range expansion).
    func auxGreyTexture(_ l: LayerDescription, role: AuxRole, sources: any FrameSourceProvider, scratch: FrameScratch) -> (MTLTexture, Bool)? {
        guard let pb = sources.auxPixelBuffer(for: l.clipID, role: role) else { return nil }
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        let planar = CVPixelBufferIsPlanar(pb)
        let yFormat: MTLPixelFormat
        switch fmt {
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: yFormat = .r16Unorm
        case kCVPixelFormatType_32BGRA: yFormat = .bgra8Unorm
        default: yFormat = .r8Unorm
        }
        guard let (t, tc) = ctx.texture(pb, plane: 0, format: yFormat) else { return nil }
        scratch.retained += [tc, pb]
        let full = fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange || !planar
        return (t, !full)
    }

    func applyRelight(_ r: RelightSettings, layer l: LayerDescription, to input: MTLTexture, uv cu: ConvertUniforms,
                      media: [MediaID: MediaAsset], sources: any FrameSourceProvider, cmd: MTLCommandBuffer,
                      scratch: FrameScratch, acquire: (Int, Int) -> MTLTexture) -> MTLTexture {
        let rp = RelightPipeline.shared
        guard let state = rp.state, let blank = rp.blank, !r.lights.isEmpty else { return input }
        var depth: (MTLTexture, Bool)?, mask: (MTLTexture, Bool)?
        var xform = cu.uvXform
        switch l.source {
        case .media:
            depth = auxGreyTexture(l, role: .depth, sources: sources, scratch: scratch)
            if r.target.usesPersonMatte { mask = auxGreyTexture(l, role: .relightMask, sources: sources, scratch: scratch) }
        case .image(let id):
            if let a = media[id] {
                depth = MatteStore.shared.stillTexture(media: a, kind: RelightOps.depthKind, device: ctx.device).map { ($0, false) }
                if r.target.usesPersonMatte {
                    mask = MatteStore.shared.stillTexture(media: a, kind: RelightOps.personKind, device: ctx.device).map { ($0, false) }
                }
                xform = Self.uvTransform(crop: l.crop, flipH: l.transform.flipH, flipV: l.transform.flipV, rotation: 0,
                                         aspect: a.pixelSize.width / max(a.pixelSize.height, 1))
            }
        default: return input
        }
        let dt = depth?.0 ?? blank, mt = mask?.0 ?? blank
        var p = RelightUniforms.pack(r, depthXform: xform, depthVideoRange: depth?.1 ?? false, maskXform: xform,
                                     maskVideoRange: mask?.1 ?? false, hasDepth: depth != nil, hasMask: mask != nil,
                                     aspect: Double(input.width) / Double(max(input.height, 1)),
                                     depthTexel: SIMD2(1 / Float(max(dt.width, 1)), 1 / Float(max(dt.height, 1))))
        let out = acquire(input.width, input.height)
        fullscreen(state, target: out, cmd, label: "relight") { enc in
            enc.setFragmentTexture(input, index: 0); enc.setFragmentTexture(dt, index: 1); enc.setFragmentTexture(mt, index: 2)
            enc.setFragmentBytes(&p, length: p.count * 4, index: 0)
        }
        return out
    }
}
