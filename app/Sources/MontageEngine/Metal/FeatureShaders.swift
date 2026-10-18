@preconcurrency import Metal
import Foundation
import simd

/// Per-layer feature passes (W6): chroma key, AI matte, frame blending / motion-blur accumulation, pen-mask feather.
/// Compiled as a separate library (vertex stage = `fullscreen_vs` from the core library) so these features stay out
/// of the core compositor source. All passes take and return straight RGBA (rgba16Float working format).
enum FeatureShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct QuadOut { float4 pos [[position]]; float2 uv; };

    // ---- Chroma key: soft matte from the CbCr distance to the key colour, shadow retention, choke, despill.
    struct ChromaU { float4 key; float intensity; float shadow; float feather; float cleanup; float spill; float3 pad; };

    inline float3 rgb2ycc(float3 c) {
        float y = dot(c, float3(0.2126, 0.7152, 0.0722));
        return float3(y, (c.b - y) / 1.8556, (c.r - y) / 1.5748);
    }

    fragment float4 chroma_fs(QuadOut in [[stage_in]], texture2d<float> t [[texture(0)]], constant ChromaU& u [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float4 c = t.sample(s, in.uv);
        float3 k = rgb2ycc(u.key.rgb), p = rgb2ycc(c.rgb);
        // chroma distance, normalised by the key's own saturation so dull keys still work
        float d = length(p.yz - k.yz) / max(length(k.yz), 0.08);
        float thr = mix(0.05, 0.9, u.intensity);
        float soft = max(u.feather * 0.6, 0.01);
        float a = smoothstep(thr, thr + soft, d);
        // shadow: keyed pixels darker than the key keep some opacity (the shadow cast on the screen)
        float darker = saturate((k.x - p.x) / max(k.x, 0.05));
        a = max(a, (1.0 - a) * u.shadow * darker);
        // edge clean-up: choke the fringe
        a = saturate((a - u.cleanup * 0.5) / max(1.0 - u.cleanup * 0.5, 0.001));
        // despill: pull the colour away from the key direction in CbCr
        float2 kd = normalize(k.yz + float2(1e-5));
        float along = dot(p.yz, kd);
        if (along > 0.0) { p.yz -= kd * along * u.spill * (1.0 - smoothstep(thr, thr + soft + 0.5, d) * 0.5); }
        float3 rgb = float3(p.x + 1.5748 * p.z, p.x - 0.1873 * p.y - 0.4681 * p.z, p.x + 1.8556 * p.y);
        return float4(saturate(rgb), c.a * a);
    }

    // ---- AI matte: alpha *= matte (Y plane of a matte video, or an r8 still), with expand/feather/invert.
    struct MatteU { float3x2 uvXform; float fullRange; float expand; float feather; float invert; float isVideo; float pad; };

    fragment float4 matte_fs(QuadOut in [[stage_in]], texture2d<float> t [[texture(0)]], texture2d<float> m [[texture(1)]],
                             constant MatteU& u [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float4 c = t.sample(s, in.uv);
        float2 muv = u.uvXform * float3(in.uv, 1.0);
        float v = m.sample(s, muv).r;
        if (u.isVideo > 0.5 && u.fullRange < 0.5) { v = saturate((v - 16.0/255.0) * (255.0/219.0)); }
        float centre = 0.5 - u.expand * 0.45;
        float f = max(u.feather * 0.5, 0.02);
        float a = smoothstep(centre - f, centre + f, v);
        if (u.invert > 0.5) { a = 1.0 - a; }
        return float4(c.rgb, c.a * a);
    }

    // ---- Weighted accumulation: out = mix(a, b, k) on straight RGBA (frame blending, motion blur).
    fragment float4 blend_frames_fs(QuadOut in [[stage_in]], texture2d<float> a [[texture(0)]], texture2d<float> b [[texture(1)]],
                                    constant float& k [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        return mix(a.sample(s, in.uv), b.sample(s, in.uv), k);
    }

    // ---- Separable box/gaussian blur of an r8/r16 mask (pen-mask feather). dir = texel step.
    fragment float4 mask_blur_fs(QuadOut in [[stage_in]], texture2d<float> t [[texture(0)]], constant float2& dir [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float acc = t.sample(s, in.uv).r, w = 1.0;
        for (int i = 1; i <= 8; i++) {
            float wi = exp(-float(i * i) / 18.0);
            acc += (t.sample(s, in.uv + dir * float(i)).r + t.sample(s, in.uv - dir * float(i)).r) * wi;
            w += 2.0 * wi;
        }
        return float4(acc / w);
    }
    """
}

/// Pipelines for `FeatureShaders` (lazily created once, thread-safe after init).
final class FeaturePipelines: @unchecked Sendable {
    static let shared = FeaturePipelines()

    let chroma: MTLRenderPipelineState
    let matte: MTLRenderPipelineState
    let blendFrames: MTLRenderPipelineState
    let maskBlur: MTLRenderPipelineState

    private init() {
        let ctx = MetalContext.shared
        let lib: MTLLibrary
        do { lib = try ctx.device.makeLibrary(source: FeatureShaders.source, options: nil) } catch {
            fatalError("feature shaders failed to compile: \(error)")
        }
        func pipe(_ fs: String, _ fmt: MTLPixelFormat = MetalContext.workingFormat) -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = ctx.fullscreenVS
            d.fragmentFunction = lib.makeFunction(name: fs)
            d.colorAttachments[0].pixelFormat = fmt
            do { return try ctx.device.makeRenderPipelineState(descriptor: d) } catch { fatalError("pipeline \(fs): \(error)") }
        }
        chroma = pipe("chroma_fs")
        matte = pipe("matte_fs")
        blendFrames = pipe("blend_frames_fs")
        maskBlur = pipe("mask_blur_fs", .r16Float)
    }
}

/// Matches `ChromaU`.
struct ChromaUniforms {
    var key: SIMD4<Float>
    var intensity: Float, shadow: Float, feather: Float, cleanup: Float, spill: Float
    var pad: SIMD3<Float> = .zero
}

/// Matches `MatteU`.
struct MatteUniforms {
    var uvXform: simd_float3x2
    var fullRange: Float, expand: Float, feather: Float, invert: Float, isVideo: Float, pad: Float = 0
}
