import ValseCore

/// "Effects" tab → video effects.
public enum BuiltinEffects {
    public static let blur = EffectDescriptor(
        id: "valse.effect.blur", category: .effect, nameKey: "effect.blur", groupKey: "effect.group.basic",
        params: [.scalar("radius", "fx.param.radius", 0, 1, 0.3, display: 100)], passes: 2, symbol: "drop",
        shader: """
        float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
            // separable 13-tap gaussian; pass 0 horizontal, pass 1 vertical. radius 1 ≈ 3 % of height
            float r = p[0] * 0.03 * ctx.size.y;
            float2 dir = (ctx.pass == 0 ? float2(1, 0) : float2(0, 1)) / ctx.size * max(r / 6.0, 0.0001);
            float4 acc = src.sample(s, uv);
            float wsum = 1.0;
            for (int i = 1; i < 7; i++) {
                float wi = exp(-float(i * i) / 8.0);
                acc += (src.sample(s, uv + dir * float(i)) + src.sample(s, uv - dir * float(i))) * wi;
                wsum += 2.0 * wi;
            }
            return acc / wsum;
        }
        """)

    public static let vignette = EffectDescriptor(
        id: "valse.effect.vignette", category: .effect, nameKey: "effect.vignette", groupKey: "effect.group.basic",
        params: [.scalar("amount", "fx.param.amount", 0, 1, 0.6, display: 100)], symbol: "circle.dashed",
        shader: """
        float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
            float4 c = src.sample(s, uv);
            float2 d = (uv - 0.5) * float2(ctx.aspect, 1.0);
            float v = smoothstep(0.2, 0.9, length(d) / max(ctx.aspect * 0.5, 0.5) * 0.9);
            return float4(c.rgb * (1.0 - v * p[0]), c.a);
        }
        """)

    public static let glitch = EffectDescriptor(
        id: "valse.effect.glitch", category: .effect, nameKey: "effect.glitch", groupKey: "effect.group.party",
        params: [.scalar("amount", "fx.param.amount", 0, 1, 0.5, display: 100),
                 .scalar("speed", "fx.param.speed", 0, 1, 0.5, display: 100)],
        symbol: "waveform.path.ecg",
        shader: """
        float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
            float t = floor(ctx.time * (4.0 + p[1] * 20.0));
            float band = floor(uv.y * 24.0);
            float n = fx_hash(float2(band, t));
            float shift = (n > 0.85 ? (n - 0.85) * 0.6 : 0.0) * p[0];
            float off = 0.006 * p[0] + shift;
            float r = src.sample(s, uv + float2(off, 0)).r;
            float4 g = src.sample(s, uv + float2(shift, 0));
            float b = src.sample(s, uv - float2(off, 0)).b;
            return float4(r, g.g, b, g.a);
        }
        """)

    public static let pixelate = EffectDescriptor(
        id: "valse.effect.pixelate", category: .effect, nameKey: "effect.pixelate", groupKey: "effect.group.basic",
        params: [.scalar("size", "fx.param.size", 0, 1, 0.3, display: 100)], symbol: "square.grid.3x3",
        shader: """
        float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
            float cells = mix(160.0, 12.0, p[0]);
            float2 g = float2(cells * ctx.aspect, cells);
            float2 q = (floor(uv * g) + 0.5) / g;
            return src.sample(s, q);
        }
        """)

    public static let all: [EffectDescriptor] = [blur, vignette, glitch, pixelate] + library

    /// Curated "Trending" picks shown first in the Effects tab (ids).
    public static let trending: [String] = [
        "shake", "rgbSplit", "vhs", "lightLeak", "glow", "sparkle", "zoomBeat", "digitalGlitch", "cinemaBars", "snow",
        "filmGrain", "split4", "kaleidoscope", "flash", "dreamy", "neonOutline", "fireworks", "halftone", "fisheye", "hearts",
    ].map { "valse.effect.\($0)" }

    /// The procedural effects library (FXKit bases × presets), in asset-panel order.
    public static let library: [EffectDescriptor] = FXBlur.all + FXGlitch.all + FXArt.all + FXDistort.all + FXLight.all + FXParticles.all + FXMagic.all
}
