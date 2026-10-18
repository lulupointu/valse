@preconcurrency import Metal
import Foundation
import MontageCore
import MontageEffects

/// Lazily compiles one Metal library per effect / transition (prelude + descriptor source + wrapper).
/// Failures are cached and logged; the renderer then skips that effect instead of failing the frame.
public final class EffectPipelines: @unchecked Sendable {
    public static let shared = EffectPipelines()

    private let lock = NSLock()
    private var effects: [String: MTLRenderPipelineState?] = [:]
    private var transitions: [String: MTLRenderPipelineState?] = [:]
    private var bySource: [String: MTLRenderPipelineState] = [:]
    public private(set) var errors: [String: String] = [:]

    /// Fragment wrapper for an effect: `texture(0)` = src, then one texture per `EffectInput` in order
    /// (`.lut3D` → texture3d + sampler `s3`, `.original` → texture2d `orig`).
    static func effectWrapper(inputs: [EffectInput]) -> String {
        var decl = "", args = ""
        for (i, input) in inputs.enumerated() {
            switch input {
            case .lut3D:
                decl += "texture3d<float> in\(i) [[texture(\(i + 1))]], "
                args += ", in\(i), s3"
            case .original:
                decl += "texture2d<float> in\(i) [[texture(\(i + 1))]], "
                args += ", in\(i)"
            }
        }
        return """

        struct FXQuadOut { float4 pos [[position]]; float2 uv; };
        fragment float4 fx_main(FXQuadOut in [[stage_in]], texture2d<float> src [[texture(0)]], \(decl)
                                constant float* p [[buffer(0)]], constant FXContext& ctx [[buffer(1)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            constexpr sampler s3(filter::linear, address::clamp_to_edge);
            return effect(in.uv, src, s, p, ctx\(args));
        }
        """
    }

    static let transitionWrapper = """

    struct FXQuadOut { float4 pos [[position]]; float2 uv; };
    fragment float4 tr_main(FXQuadOut in [[stage_in]], texture2d<float> a [[texture(0)]], texture2d<float> b [[texture(1)]],
                            constant float* p [[buffer(0)]], constant FXContext& ctx [[buffer(1)]],
                            constant float& progress [[buffer(2)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        return transition(in.uv, a, b, s, progress, p, ctx);
    }
    """

    public func effect(_ d: EffectDescriptor) -> MTLRenderPipelineState? {
        if let cached = lock.withLock({ effects[d.id] }) { return cached }
        let source = ShaderPrelude.source + "\n" + d.shader + EffectPipelines.effectWrapper(inputs: d.inputs)
        // Presets of one base shader (same source, different `constants`) share one compiled pipeline.
        if let shared = lock.withLock({ bySource[source] }) {
            lock.withLock { effects[d.id] = .some(shared) }
            return shared
        }
        let p = compile(id: d.id, source: source, fn: "fx_main")
        lock.withLock {
            effects[d.id] = .some(p)
            if let p { bySource[source] = p }
        }
        return p
    }

    public func transition(_ d: TransitionDescriptor) -> MTLRenderPipelineState? {
        if let cached = lock.withLock({ transitions[d.id] }) { return cached }
        let p = compile(id: d.id, source: ShaderPrelude.source + "\n" + d.shader + EffectPipelines.transitionWrapper, fn: "tr_main")
        lock.withLock { transitions[d.id] = .some(p) }
        return p
    }

    /// Compiles every registered effect/transition; returns id → error for failures (used by tests).
    public func validateAll() -> [String: String] {
        for d in Registries.effects.all { _ = effect(d) }
        for d in Registries.transitions.all { _ = transition(d) }
        return lock.withLock { errors }
    }

    private func compile(id: String, source: String, fn: String) -> MTLRenderPipelineState? {
        let ctx = MetalContext.shared
        do {
            let lib = try ctx.device.makeLibrary(source: source, options: nil)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = ctx.fullscreenVS
            d.fragmentFunction = lib.makeFunction(name: fn)
            d.colorAttachments[0].pixelFormat = MetalContext.workingFormat
            return try ctx.device.makeRenderPipelineState(descriptor: d)
        } catch {
            lock.withLock { errors[id] = String(describing: error) }
            EngineLog.error("shader \(id) failed: \(error)")
            return nil
        }
    }
}

/// Matches `FXContext` in ShaderPrelude.
struct FXContextU {
    var time: Float
    var size: SIMD2<Float>
    var pass: Int32
    var aspect: Float
}
