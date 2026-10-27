@preconcurrency import Metal
import Foundation
import simd

/// Finisher passes (colour / cutout rows): skin tone protection (CL-010) and cutout edge blending (CK-008).
/// Separate library like `FeatureShaders` (vertex stage = core `fullscreen_vs`); straight RGBA in and out.
enum FinishShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct QuadOut { float4 pos [[position]]; float2 uv; };

    // Skin likelihood 0…1 from YCbCr chroma (Gaussian around the skin cluster), faded out in deep shadows / clipped whites.
    static float skin_k(float3 c) {
        float y = dot(c, float3(0.299, 0.587, 0.114));
        float cb = (c.b - y) * 0.564 + 0.5, cr = (c.r - y) * 0.713 + 0.5;
        float dcb = (cb - 0.42) / 0.075, dcr = (cr - 0.60) / 0.06;
        float k = exp(-0.5 * (dcb * dcb + dcr * dcr));
        return k * smoothstep(0.06, 0.18, y) * (1.0 - smoothstep(0.93, 1.0, y));
    }

    // CL-010: graded `b` pulled back towards the original `a` on skin tones.
    fragment float4 skin_protect_fs(QuadOut in [[stage_in]], texture2d<float> a [[texture(0)]], texture2d<float> b [[texture(1)]],
                                    constant float& strength [[buffer(0)]]) {
        constexpr sampler s(filter::nearest, address::clamp_to_edge);
        float4 o = a.sample(s, in.uv), g = b.sample(s, in.uv);
        float k = skin_k(o.rgb) * strength;
        return float4(mix(g.rgb, o.rgb, k), g.a);
    }

    // MK-005: running union of mask coverages (red channel); `inv` flips a rasterized (text / pen) coverage.
    fragment float4 mask_union_fs(QuadOut in [[stage_in]], texture2d<float> acc [[texture(0)]], texture2d<float> cov [[texture(1)]],
                                  constant float& inv [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float c = cov.sample(s, in.uv).r;
        if (inv > 0.5) c = 1.0 - c;
        float k = max(acc.sample(s, in.uv).r, c);
        return float4(k, k, k, 1.0);
    }

    // CK-008 matting blend: refines a cut-out edge on the matted layer (straight RGBA: rgb = source colour everywhere,
    // alpha = matte). In the edge band, the local foreground F (mean colour of nearby opaque pixels) and background B
    // (nearby transparent pixels) are estimated; alpha is re-estimated by projecting the pixel colour on the B→F line
    // (pixels that look like the background become transparent, like a closed-form matting step) and the colour is
    // decontaminated towards F (no background fringe).
    struct MattingU { float2 texel; float smooth; float decontaminate; };
    fragment float4 matting_blend_fs(QuadOut in [[stage_in]], texture2d<float> t [[texture(0)]], constant MattingU& u [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float4 c = t.sample(s, in.uv);
        float mn = 1.0, mx = 0.0;
        for (int j = -2; j <= 2; j += 2) for (int i = -2; i <= 2; i += 2) {
            float a2 = t.sample(s, in.uv + float2(i, j) * u.texel * 1.5).a; mn = min(mn, a2); mx = max(mx, a2);
        }
        if (mx - mn < 0.05) return c;            // not near an edge
        float3 fg = float3(0.0), bg = float3(0.0);
        float fw = 0.0, bw = 0.0;
        for (int j = -3; j <= 3; j++) for (int i = -3; i <= 3; i++) {
            float4 n = t.sample(s, in.uv + float2(i, j) * u.texel * 2.0);
            float g = exp(-float(i * i + j * j) / 8.0);
            float wf = n.a * n.a * n.a * n.a * g, wb = pow(1.0 - n.a, 4.0) * g;
            fg += n.rgb * wf; fw += wf;
            bg += n.rgb * wb; bw += wb;
        }
        if (fw < 1e-3 || bw < 1e-3) return c;
        float3 F = fg / fw, B = bg / bw, fb = F - B;
        float den = dot(fb, fb);
        float a = c.a;
        if (den > 0.004) a = mix(c.a, saturate(dot(c.rgb - B, fb) / den), u.smooth);
        float3 rgb = mix(c.rgb, F, u.decontaminate * (1.0 - a * a));
        return float4(rgb, a);
    }
    """
}

/// Pipelines for `FinishShaders` (created once on first use).
final class FinishPipelines: @unchecked Sendable {
    static let shared = FinishPipelines()
    let skinProtect: MTLRenderPipelineState
    let mattingBlend: MTLRenderPipelineState
    let maskUnion: MTLRenderPipelineState
    /// 1×1 black / white textures (coverage sources).
    let black: MTLTexture
    let white: MTLTexture

    private init() {
        let ctx = MetalContext.shared
        let lib: MTLLibrary
        do { lib = try ctx.device.makeLibrary(source: FinishShaders.source, options: ctx.caps.compileOptions) } catch {
            fatalError("finish shaders failed to compile: \(error)")
        }
        func pipe(_ fs: String) -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = ctx.fullscreenVS
            d.fragmentFunction = lib.makeFunction(name: fs)
            d.colorAttachments[0].pixelFormat = MetalContext.workingFormat
            do { return try ctx.device.makeRenderPipelineState(descriptor: d) } catch { fatalError("pipeline \(fs): \(error)") }
        }
        skinProtect = pipe("skin_protect_fs")
        mattingBlend = pipe("matting_blend_fs")
        maskUnion = pipe("mask_union_fs")
        func pixel(_ v: Float) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 1, height: 1, mipmapped: false)
            d.usage = .shaderRead
            let t = ctx.device.makeTexture(descriptor: d)!
            var px: [Float] = [v, v, v, 1]
            t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &px, bytesPerRow: 16)
            return t
        }
        black = pixel(0); white = pixel(1)
    }
}

/// Matches `MattingU`.
struct MattingUniforms {
    var texel: SIMD2<Float>
    var smooth: Float
    var decontaminate: Float
}
