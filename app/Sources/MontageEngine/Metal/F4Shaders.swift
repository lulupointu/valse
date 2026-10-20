@preconcurrency import Metal
import Foundation

/// F4-FX passes: straight-alpha "over" used to put body effects rendered on a person matte back over the
/// un-cut layer (FX-002 / FX-008). Own library like `FinishShaders` (vertex stage = core `fullscreen_vs`).
enum F4Shaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct QuadOut { float4 pos [[position]]; float2 uv; };

    // Straight RGBA `fg` over straight RGBA `bg` → straight RGBA.
    fragment float4 straight_over_fs(QuadOut in [[stage_in]], texture2d<float> fg [[texture(0)]], texture2d<float> bg [[texture(1)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float4 f = fg.sample(s, in.uv), b = bg.sample(s, in.uv);
        float a = f.a + b.a * (1.0 - f.a);
        if (a < 1e-5) return float4(0.0);
        return float4((f.rgb * f.a + b.rgb * b.a * (1.0 - f.a)) / a, a);
    }
    """
}

final class F4Pipelines: @unchecked Sendable {
    static let shared = F4Pipelines()
    let straightOver: MTLRenderPipelineState

    private init() {
        let ctx = MetalContext.shared
        let lib: MTLLibrary
        do { lib = try ctx.device.makeLibrary(source: F4Shaders.source, options: ctx.caps.compileOptions) } catch {
            fatalError("F4 shaders failed to compile: \(error)")
        }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = ctx.fullscreenVS
        d.fragmentFunction = lib.makeFunction(name: "straight_over_fs")
        d.colorAttachments[0].pixelFormat = MetalContext.workingFormat
        do { straightOver = try ctx.device.makeRenderPipelineState(descriptor: d) } catch { fatalError("straight_over: \(error)") }
    }
}
