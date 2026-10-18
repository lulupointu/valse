import MontageCore

/// Building blocks of the procedural effects library (`BuiltinEffects.library`).
///
/// An effect library entry = a **base shader** (one MSL source, compiled once) × **preset constants**. Each base
/// declares its user parameters (sliders, keyframes) and reads its preset constants at `c = p + <param count>`.
/// Presets of one base share the same source, so `EffectPipelines` compiles it once.
public enum FXKit {
    /// MSL helpers shared by the library shaders (prepended to each base; `kit_` prefix avoids prelude clashes).
    public static let msl = """
    inline float kit_h11(float x) { return fract(sin(x * 127.1) * 43758.5453); }
    inline float kit_h21(float2 q) { q = fract(q * float2(123.34, 456.21)); q += dot(q, q + 45.32); return fract(q.x * q.y); }
    inline float2 kit_h22(float2 q) { float n = kit_h21(q); return float2(n, kit_h21(q + n + 17.17)); }
    inline float3 kit_h23(float2 q) { float n = kit_h21(q); return float3(n, kit_h21(q + n + 3.1), kit_h21(q + n * 7.3 + 11.7)); }
    inline float kit_noise(float2 x) {
        float2 i = floor(x), f = fract(x);
        float2 u = f * f * (3.0 - 2.0 * f);
        return mix(mix(kit_h21(i), kit_h21(i + float2(1, 0)), u.x), mix(kit_h21(i + float2(0, 1)), kit_h21(i + float2(1, 1)), u.x), u.y);
    }
    inline float kit_fbm(float2 x) {
        float v = 0.0, a = 0.5;
        for (int i = 0; i < 4; i++) { v += a * kit_noise(x); x = x * 2.03 + float2(17.0, 9.0); a *= 0.5; }
        return v;
    }
    inline float2x2 kit_rot(float a) { float c = cos(a), s = sin(a); return float2x2(float2(c, s), float2(-s, c)); }
    /// Centred, aspect-correct coordinates: x ∈ [-aspect/2, aspect/2], y ∈ [-0.5, 0.5] (y down).
    inline float2 kit_centered(float2 uv, FXContext ctx) { return (uv - 0.5) * float2(ctx.aspect, 1.0); }
    inline float2 kit_uncentered(float2 q, FXContext ctx) { return q / float2(ctx.aspect, 1.0) + 0.5; }
    /// Mirrored repeat of uv into [0,1].
    inline float2 kit_mirror(float2 uv) { float2 m = fmod(abs(uv), 2.0); return select(m, 2.0 - m, m > 1.0); }
    inline float3 kit_screen(float3 a, float3 b) { return 1.0 - (1.0 - a) * (1.0 - b); }
    inline float3 kit_overlay(float3 a, float3 b) { return select(1.0 - 2.0 * (1.0 - a) * (1.0 - b), 2.0 * a * b, a < 0.5); }
    inline float3 kit_softlight(float3 a, float3 b) { return (1.0 - 2.0 * b) * a * a + 2.0 * b * a; }
    inline float3 kit_sat(float3 c, float s) { return mix(float3(fx_luma(c)), c, s); }
    inline float3 kit_hue(float h) { return saturate(abs(fract(h + float3(0.0, 2.0, 1.0) / 3.0) * 6.0 - 3.0) - 1.0); }
    /// Signed distances (q centred, r = size).
    inline float kit_sdCircle(float2 q, float r) { return length(q) - r; }
    inline float kit_sdBox(float2 q, float2 b) { float2 d = abs(q) - b; return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0); }
    inline float kit_sdHeart(float2 q, float r) {
        q /= r; q.y = -q.y + 0.35; q.x = abs(q.x);
        if (q.y + q.x > 1.0) return (sqrt(dot(q - float2(0.25, 0.75), q - float2(0.25, 0.75))) - sqrt(2.0) / 4.0) * r;
        float2 a = q - float2(0.0, 1.0), b = q - 0.5 * max(q.x + q.y, 0.0);
        return sqrt(min(dot(a, a), dot(b, b))) * sign(q.x - q.y) * r;
    }
    inline float kit_sdStar(float2 q, float r, float inner) {
        float a = atan2(q.x, -q.y), n = 5.0;
        float seg = 6.2831853 / n;
        float k = fmod(a + seg * 10.0, seg) - seg * 0.5;
        float2 pp = length(q) * float2(cos(k), abs(sin(k)));
        float2 tip = float2(r, 0.0), in2 = float2(cos(seg * 0.5), sin(seg * 0.5)) * r * inner;
        float2 e = in2 - tip, w = pp - tip;
        float h = saturate(dot(w, e) / dot(e, e));
        float d = length(w - e * h);
        return (e.x * w.y - e.y * w.x) > 0.0 ? -d : d;
    }
    /// 4-point star glint (sparkle), intensity at q (glint centred at 0, size r).
    inline float kit_glint(float2 q, float r) {
        float2 a = abs(q) / r;
        float cross = max(0.0, 1.0 - a.x * 8.0 - a.y) + max(0.0, 1.0 - a.y * 8.0 - a.x);
        float2 d = abs(kit_rot(0.785398) * q) / r;
        float diag = 0.5 * (max(0.0, 1.0 - d.x * 10.0 - d.y * 1.6) + max(0.0, 1.0 - d.y * 10.0 - d.x * 1.6));
        float core = exp(-dot(q, q) / (r * r * 0.012));
        return saturate(cross * cross + diag * diag + core);
    }
    /// Separable 9-tap gaussian along `dir` (in uv units per tap).
    inline float4 kit_blur9(texture2d<float> t, sampler s, float2 uv, float2 dir) {
        float4 a = t.sample(s, uv) * 0.2270270270;
        a += (t.sample(s, uv + dir * 1.3846153846) + t.sample(s, uv - dir * 1.3846153846)) * 0.3162162162;
        a += (t.sample(s, uv + dir * 3.2307692308) + t.sample(s, uv - dir * 3.2307692308)) * 0.0702702703;
        return a;
    }
    /// Wider separable blur (17 effective taps via linear sampling).
    inline float4 kit_blur17(texture2d<float> t, sampler s, float2 uv, float2 dir) {
        const float o[5] = { 0.0, 1.4588, 3.4048, 5.3518, 7.3010 };
        const float w[5] = { 0.1597, 0.2611, 0.1262, 0.0331, 0.0045 };
        float4 a = t.sample(s, uv) * w[0];
        for (int i = 1; i < 5; i++) { a += (t.sample(s, uv + dir * o[i]) + t.sample(s, uv - dir * o[i])) * w[i]; }
        return a / (w[0] + 2.0 * (w[1] + w[2] + w[3] + w[4]));
    }
    """

    // MARK: Common parameter specs

    public static func intensity(_ def: Double = 1) -> ParamSpec { .scalar("intensity", "fx.param.intensity", 0, 1, def, display: 100) }
    public static func speed(_ def: Double = 0.5) -> ParamSpec { .scalar("speed", "fx.param.speed", 0, 1, def, display: 100) }
    public static func amount(_ def: Double = 0.5) -> ParamSpec { .scalar("amount", "fx.param.amount", 0, 1, def, display: 100) }
    public static func size(_ def: Double = 0.5) -> ParamSpec { .scalar("size", "fx.param.size", 0, 1, def, display: 100) }
    public static func range(_ def: Double = 0.5) -> ParamSpec { .scalar("range", "fx.param.range", 0, 1, def, display: 100) }
    public static func density(_ def: Double = 0.5) -> ParamSpec { .scalar("density", "fx.param.density", 0, 1, def, display: 100) }
    public static func angle(_ def: Double = 0) -> ParamSpec { .scalar("angle", "fx.param.angle", -180, 180, def) }
    public static func glow(_ def: Double = 0.5) -> ParamSpec { .scalar("glow", "fx.param.glow", 0, 1, def, display: 100) }
    public static func color(_ def: RGBA) -> ParamSpec { ParamSpec("color", nameKey: "fx.param.color", .color(defaultValue: def)) }
    public static func posX(_ def: Double = 0.5) -> ParamSpec { .scalar("x", "fx.param.horizontal", 0, 1, def, display: 100) }
    public static func posY(_ def: Double = 0.5) -> ParamSpec { .scalar("y", "fx.param.vertical", 0, 1, def, display: 100) }
}

/// A base shader of the effects library. `body` is MSL defining `float4 effect(...)`; constants are at
/// `p + paramFloatCount` (the body may write `constant float* c = p + N;`).
public struct FXBase: Sendable {
    public let name: String
    public let params: [ParamSpec]
    public let passes: Int
    public let inputs: [EffectInput]
    public let symbol: String
    public let source: String

    public init(_ name: String, params: [ParamSpec], passes: Int = 1, inputs: [EffectInput] = [], symbol: String = "sparkles",
                _ body: String) {
        self.name = name; self.params = params; self.passes = passes; self.inputs = inputs; self.symbol = symbol
        self.source = FXKit.msl + "\n" + body
    }

    /// Number of floats taken by `params` = index of the first constant.
    public var constantsOffset: Int { params.reduce(0) { $0 + $1.floatCount } }

    /// A named preset: `montage.effect.<name>`, constants appended after the params, optional default overrides.
    public func preset(_ name: String, group: String, _ constants: [Float] = [], defaults: [String: Double] = [:],
                       tags: [String] = []) -> EffectDescriptor {
        let specs = params.map { spec -> ParamSpec in
            guard let v = defaults[spec.key], case .scalar(let lo, let hi, _) = spec.kind else { return spec }
            return ParamSpec(spec.key, nameKey: spec.nameKey, .scalar(min: lo, max: hi, defaultValue: v), displayScale: spec.displayScale)
        }
        return EffectDescriptor(id: "montage.effect.\(name)", category: .effect, nameKey: "effect.\(name)",
                                groupKey: "effect.group.\(group)", params: specs, passes: passes, symbol: symbol,
                                inputs: inputs, constants: constants, tags: tags + [self.name], shader: source)
    }
}
