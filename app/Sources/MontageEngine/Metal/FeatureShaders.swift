@preconcurrency import Metal
import Foundation
import simd

/// Per-layer feature passes (W6): AI matte, frame blending / motion-blur accumulation, pen-mask feather.
/// Compiled as a separate library (vertex stage = `fullscreen_vs` from the core library) so these features stay out
/// of the core compositor source. All passes take and return straight RGBA (rgba16Float working format).
enum FeatureShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct QuadOut { float4 pos [[position]]; float2 uv; };

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
        matte = pipe("matte_fs")
        blendFrames = pipe("blend_frames_fs")
        maskBlur = pipe("mask_blur_fs", .r16Float)
    }
}

/// Matches `MatteU`.
struct MatteUniforms {
    var uvXform: simd_float3x2
    var fullRange: Float, expand: Float, feather: Float, invert: Float, isVideo: Float, pad: Float = 0
}
