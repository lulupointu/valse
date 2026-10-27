@preconcurrency import Metal
import Foundation
import ValseCore
import ValseEffects

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
            case .original, .backdrop:
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

    /// Full MSL library source of an effect / transition (prelude + descriptor shader + fragment wrapper).
    static func source(_ d: EffectDescriptor) -> String {
        ShaderPrelude.source + "\n" + d.shader + EffectPipelines.effectWrapper(inputs: d.inputs)
    }
    static func source(_ d: TransitionDescriptor) -> String {
        ShaderPrelude.source + "\n" + d.shader + EffectPipelines.transitionWrapper
    }

    public func effect(_ d: EffectDescriptor) -> MTLRenderPipelineState? {
        if let cached = lock.withLock({ effects[d.id] }) { return cached }
        let source = Self.source(d)
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

    /// FX-018: forget a (custom) effect's compiled pipeline and error so an edited shader is compiled again.
    public func invalidate(effect id: String) {
        lock.withLock { effects[id] = nil; errors[id] = nil }
    }

    /// Compiles `d` now; returns the Metal compiler message when it fails (custom effect import / reload).
    public func compileError(_ d: EffectDescriptor) -> String? {
        invalidate(effect: d.id)
        if effect(d) != nil { return nil }
        let message = lock.withLock { errors[d.id] } ?? "compile failed"
        invalidate(effect: d.id)   // a rejected package isn't registered: keep `validateAll` about registered effects
        return message
    }

    public func transition(_ d: TransitionDescriptor) -> MTLRenderPipelineState? {
        if let cached = lock.withLock({ transitions[d.id] }) { return cached }
        let p = compile(id: d.id, source: Self.source(d), fn: "tr_main")
        lock.withLock { transitions[d.id] = .some(p) }
        return p
    }

    /// Compiles every registered effect/transition; returns id → error for failures (used by tests).
    public func validateAll() -> [String: String] {
        let effects = Registries.effects.all, transitions = Registries.transitions.all
        // Runtime MSL compiles are independent and thread-safe: spread them over half the cores (leave room for
        // playback / other work running meanwhile).
        let n = effects.count + transitions.count
        let workers = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
        DispatchQueue.concurrentPerform(iterations: workers) { w in
            for i in stride(from: w, to: n, by: workers) {
                if i < effects.count { _ = effect(effects[i]) } else { _ = transition(transitions[i - effects.count]) }
            }
        }
        return lock.withLock { errors }
    }

    /// Compiles the pipelines a project uses in the background, so the first frame of a transition/effect does not
    /// stall the compositor (a runtime compile takes ~0.1–0.2 s). Cheap when everything is cached.
    /// Effect / transition ids used per track (recomputed only for tracks that changed).
    private let usedIDs = TrackMemo<(t: Set<String>, e: Set<String>)> { clips in
        var t = Set<String>(), e = Set<String>()
        for c in clips {
            if let x = c.transitionOut { t.insert(x.typeID) }
            for x in c.effects { e.insert(x.typeID) }
        }
        return (t, e)
    }

    public func prewarm(_ project: Project) {
        var tIDs = Set<String>(), eIDs = Set<String>()
        for u in usedIDs.values(project.timeline.tracks) { tIDs.formUnion(u.t); eIDs.formUnion(u.e) }
        let missing: [() -> Void] = lock.withLock {
            tIDs.filter { transitions[$0] == nil }.compactMap { id in Registries.transitions[id].map { d in { _ = self.transition(d) } } }
            + eIDs.filter { effects[$0] == nil }.compactMap { id in Registries.effects[id].map { d in { _ = self.effect(d) } } }
        }
        guard !missing.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { DispatchQueue.concurrentPerform(iterations: missing.count) { missing[$0]() } }
    }

    private func compile(id: String, source: String, fn: String) -> MTLRenderPipelineState? {
        let ctx = MetalContext.shared
        do {
            let lib = try ctx.device.makeLibrary(source: source, options: ctx.caps.compileOptions)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = ctx.fullscreenVS
            d.fragmentFunction = lib.makeFunction(name: fn)
            d.colorAttachments[0].pixelFormat = MetalContext.workingFormat
            return try ctx.device.makeRenderPipelineState(descriptor: d)
        } catch {
            lock.withLock { errors[id] = String(describing: error) }
            // one line, no raw "error:" tokens (user shaders fail by design; scripts/test.sh greps the log for "error:")
            let msg = (error as NSError).localizedDescription.replacingOccurrences(of: "error:", with: "error -")
                .replacingOccurrences(of: "\n", with: " | ")
            EngineLog.error("shader \(id) failed - \(msg)")
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
