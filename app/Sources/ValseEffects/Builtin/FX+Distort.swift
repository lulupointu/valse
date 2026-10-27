import ValseCore

/// Effects library — distortion (FX-015) and split screen / mirror / kaleidoscope (FX-012) bases.
enum FXDistort {
    /// Waves. p: amount, speed · c: frequency, mode (0 horizontal, 1 vertical, 2 underwater), tint.
    static let wave = FXBase("wave", params: [FXKit.amount(0.5), FXKit.speed(0.5)], symbol: "water.waves", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 2;
        float t = ctx.time * (0.5 + p[1] * 4.0);
        int mode = int(c[1] + 0.5);
        float a = p[0] * 0.025;
        float2 u = uv;
        if (mode == 0) { u.x += sin(uv.y * c[0] + t) * a; }
        else if (mode == 1) { u.y += sin(uv.x * c[0] + t) * a; }
        else {
            u += float2(sin(uv.y * c[0] + t), cos(uv.x * c[0] * 0.8 + t * 1.3)) * a * 0.6;
            u += (float2(kit_noise(uv * 6.0 + t * 0.3), kit_noise(uv * 6.0 - t * 0.3 + 5.0)) - 0.5) * a;
        }
        float4 o = src.sample(s, kit_mirror(u));
        if (mode == 2) {
            float caust = pow(saturate(kit_noise(uv * float2(ctx.aspect, 1.0) * 9.0 + t * 0.4) * kit_noise(uv * 13.0 - t * 0.5) * 2.2), 3.0);
            o.rgb = mix(o.rgb, o.rgb * float3(0.55, 0.85, 1.0) + float3(0.0, 0.04, 0.08), c[2] * 0.8);
            o.rgb += caust * 0.14 * c[2];
        }
        return float4(saturate(o.rgb), o.a);
    }
    """)

    /// Ripples from a point. p: amount, speed, x, y · c: frequency, mode (0 continuous, 1 expanding drop rings).
    static let ripple = FXBase("ripple", params: [FXKit.amount(0.5), FXKit.speed(0.5), FXKit.posX(), FXKit.posY()], symbol: "drop.circle", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 4;
        float2 q = (uv - float2(p[2], p[3])) * float2(ctx.aspect, 1.0);
        float r = length(q);
        float t = ctx.time * (0.5 + p[1] * 3.0);
        float w;
        if (c[1] < 0.5) { w = sin(r * c[0] - t * 6.0) * exp(-r * 2.0); }
        else {
            float ph = fract(t * 0.35);
            float front = ph * 1.2;
            w = sin((r - front) * c[0]) * exp(-pow((r - front) * 8.0, 2.0)) * (1.0 - ph);
        }
        float2 dir = r > 1e-4 ? q / r : float2(0.0);
        float2 u = uv + dir * w * p[0] * 0.03 / float2(ctx.aspect, 1.0);
        float4 o = src.sample(s, kit_mirror(u));
        o.rgb *= 1.0 + w * p[0] * 0.15;
        return float4(saturate(o.rgb), o.a);
    }
    """)

    /// Twirl / vortex. p: amount, speed · c: radius, spin (0 static twist, 1 animated).
    static let twirl = FXBase("twirl", params: [FXKit.amount(0.6), FXKit.speed(0.4)], symbol: "tornado", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 2;
        float2 q = kit_centered(uv, ctx);
        float r = length(q);
        float k = saturate(1.0 - r / c[0]);
        float ang = p[0] * 4.0 * k * k;
        if (c[1] > 0.5) { ang *= sin(ctx.time * (0.5 + p[1] * 3.0)); ang += ctx.time * p[1] * 2.0 * k * k; }
        q = kit_rot(ang) * q;
        return src.sample(s, kit_mirror(kit_uncentered(q, ctx)));
    }
    """)

    /// Bulge / pinch. p: amount, x, y · c: sign (+1 bulge, −1 pinch), pulse speed (0 = static), radius.
    static let bulge = FXBase("bulge", params: [FXKit.amount(0.6), FXKit.posX(), FXKit.posY()], symbol: "circle.circle.fill", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 3;
        float2 ctr = float2(p[1], p[2]);
        float2 q = (uv - ctr) * float2(ctx.aspect, 1.0);
        float r = length(q) / c[2];
        float amt = p[0] * c[0];
        if (c[1] > 0.0) amt *= 0.5 + 0.5 * sin(ctx.time * c[1] * 6.28318);
        float f = r < 1.0 ? mix(1.0, pow(r, amt * 1.6 + 1.0) / max(r, 1e-4), smoothstep(1.0, 0.0, r)) : 1.0;
        if (amt < 0.0) { f = r < 1.0 ? mix(1.0, pow(max(r, 1e-4), 1.0 / (1.0 - amt * 1.2)) / max(r, 1e-4), smoothstep(1.0, 0.0, r)) : 1.0; }
        float2 u = ctr + q * f / float2(ctx.aspect, 1.0);
        return src.sample(s, u);
    }
    """)

    /// Heat haze: rising shimmer. p: amount, speed · c: scale, warm tint.
    static let heat = FXBase("heatHaze", params: [FXKit.amount(0.5), FXKit.speed(0.5)], symbol: "sun.haze", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 2;
        float t = ctx.time * (0.4 + p[1] * 2.0);
        float2 q = uv * float2(ctx.aspect, 1.0) * c[0];
        float2 d = float2(kit_fbm(q + float2(0.0, t * 1.5)), kit_fbm(q * 1.3 + float2(4.0, t * 2.0))) - 0.5;
        float4 o = src.sample(s, uv + d * p[0] * 0.02 * (0.4 + uv.y));
        o.rgb *= float3(1.0 + 0.06 * c[1], 1.0, 1.0 - 0.08 * c[1]);
        return float4(saturate(o.rgb), o.a);
    }
    """)

    /// Liquid warp, optionally psychedelic colours. p: amount, speed · c: scale, colour cycling.
    static let liquid = FXBase("liquid", params: [FXKit.amount(0.5), FXKit.speed(0.5)], symbol: SFSymbolCompat.compat("drop.halffull"), """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 2;
        float t = ctx.time * (0.2 + p[1] * 1.2);
        float2 q = uv * float2(ctx.aspect, 1.0) * c[0];
        float2 w = float2(kit_fbm(q + t), kit_fbm(q + float2(5.2, 1.3) - t));
        float2 w2 = float2(kit_fbm(q + w * 2.0 + float2(1.7, 9.2) + t * 0.5), kit_fbm(q + w * 2.0 + float2(8.3, 2.8)));
        float2 u = uv + (w2 - 0.5) * p[0] * 0.16;
        float4 o = src.sample(s, kit_mirror(u));
        if (c[1] > 0.0) {
            float3 hsv = fx_rgb2hsv(saturate(o.rgb));
            hsv.x = fract(hsv.x + (w2.x - 0.5) * 2.0 * c[1] + t * 0.2 * c[1]);
            hsv.y = saturate(hsv.y * (1.0 + 0.6 * c[1]));
            o.rgb = fx_hsv2rgb(hsv);
        }
        return o;
    }
    """)

    /// Glass: frosted, tiles, rainy window, fluted. p: amount · c: mode, scale.
    static let glass = FXBase("glass", params: [FXKit.amount(0.6)], symbol: "rectangle.split.3x3", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 1;
        int mode = int(c[0] + 0.5);
        float a = p[0];
        float2 u = uv; float3 add = 0.0;
        if (mode == 0) {
            float2 n = kit_h22(floor(uv * ctx.size / max(1.0, ctx.size.y / 540.0))) - 0.5;
            u += n * 0.02 * a;
            add = 0.06 * a;
        } else if (mode == 1) {
            float2 g = uv * float2(ctx.aspect, 1.0) * c[1];
            float2 f = fract(g) - 0.5;
            u += f * 0.06 * a / float2(ctx.aspect, 1.0);
            float edge = smoothstep(0.42, 0.5, max(abs(f.x), abs(f.y)));
            add = edge * 0.12 * a - 0.02;
        } else if (mode == 2) {
            float2 g = uv * float2(ctx.aspect, 1.0) * c[1];
            float t = ctx.time;
            float2 off = 0.0; float shade = 0.0;
            for (int L = 0; L < 2; L++) {
                float2 gg = g * (1.0 + float(L) * 0.7) + float2(0.0, t * (0.08 + 0.05 * float(L)));
                float2 id = floor(gg); float2 f = fract(gg) - 0.5;
                float2 r = kit_h22(id + float(L) * 7.0);
                float2 dp = f - (r - 0.5) * 0.6;
                float rad = 0.12 + 0.12 * r.x;
                float drop = 1.0 - smoothstep(rad * 0.8, rad, length(dp * float2(1.0, 0.85)));
                drop *= step(0.45, r.y);
                off += dp * drop * 1.5;
                shade += drop;
            }
            float2 fr = kit_h22(floor(uv * ctx.size / max(1.0, ctx.size.y / 360.0))) - 0.5;
            u += (off * 0.06 + fr * 0.008 * (1.0 - saturate(shade))) * a;
            add = (shade * 0.08 - 0.03) * a;
        } else {
            float g = uv.x * ctx.aspect * c[1];
            float f = fract(g) - 0.5;
            u.x += f * 0.05 * a;
            add = (0.5 - abs(f)) * 0.1 * a - 0.03;
        }
        float4 o = src.sample(s, u);
        return float4(saturate(o.rgb + add), o.a);
    }
    """)

    /// Jelly wobble: squash and stretch. p: amount, speed.
    static let jelly = FXBase("jelly", params: [FXKit.amount(0.6), FXKit.speed(0.5)], symbol: "oval.portrait", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        float t = ctx.time * (1.0 + p[1] * 5.0);
        float2 q = uv - 0.5;
        float sq = sin(t * 3.0) * 0.06 * p[0];
        q.x *= 1.0 + sq * (1.0 - 2.0 * abs(q.y));
        q.y *= 1.0 - sq * (1.0 - 2.0 * abs(q.x));
        q.x += sin(q.y * 6.0 + t * 2.0) * 0.012 * p[0];
        return src.sample(s, kit_mirror(q + 0.5));
    }
    """)

    // MARK: Split / mirror

    /// Multi-screen grid. p: none (gap) · c: columns, rows, gap, mode (0 copies, 1 mirrored, 2 pop-art colours, 3 RGB bands).
    static let grid = FXBase("grid", params: [.scalar("gap", "fx.param.border", 0, 1, 0, display: 100)], symbol: "rectangle.split.2x2", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 1;
        float2 n = float2(c[0], c[1]);
        float2 g = uv * n;
        float2 id = floor(g);
        float2 f = fract(g);
        int mode = int(c[3] + 0.5);
        if (mode == 1) { f = select(f, 1.0 - f, fmod(id, 2.0) > 0.5); }
        // keep each cell's aspect = the frame's: crop the centre of the source
        float cellAspect = ctx.aspect * n.y / n.x;
        float2 su = f;
        if (cellAspect < ctx.aspect) su.x = 0.5 + (f.x - 0.5) * cellAspect / ctx.aspect;
        else su.y = 0.5 + (f.y - 0.5) * ctx.aspect / cellAspect;
        float4 o = src.sample(s, su);
        if (mode == 2) {
            float k = id.x + id.y * n.x;
            float3 tint = kit_hue(fract(k * 0.29 + 0.05));
            float l = fx_luma(o.rgb);
            o.rgb = mix(tint * 0.25, tint * 0.5 + 0.55, smoothstep(0.25, 0.7, l));
        } else if (mode == 3) {
            float3 m = id.x < 0.5 ? float3(1.0, 0.25, 0.3) : (id.x < 1.5 ? float3(0.3, 1.0, 0.4) : float3(0.3, 0.45, 1.0));
            o.rgb = fx_luma(o.rgb) * m * 1.3;
        }
        float gap = (p[0] * 0.03 + c[2]) * 0.5;
        float2 e = min(f, 1.0 - f) / n * float2(ctx.aspect, 1.0);
        float border = step(min(e.x, e.y), gap);
        o.rgb = mix(o.rgb, float3(1.0), border);
        return float4(saturate(o.rgb), o.a);
    }
    """)

    /// Mirror. c: mode (0 left half → right, 1 right → left, 2 top → bottom, 3 bottom → top, 4 quad).
    static let mirror = FXBase("mirror", params: [], symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        int mode = int(p[0] + 0.5);
        float2 u = uv;
        if (mode == 0) u.x = u.x > 0.5 ? 1.0 - u.x : u.x;
        else if (mode == 1) u.x = u.x < 0.5 ? 1.0 - u.x : u.x;
        else if (mode == 2) u.y = u.y > 0.5 ? 1.0 - u.y : u.y;
        else if (mode == 3) u.y = u.y < 0.5 ? 1.0 - u.y : u.y;
        else { u = abs(uv - 0.5) * 2.0; u = 1.0 - u; u = u * 0.5 + 0.25; }
        return src.sample(s, u);
    }
    """)

    /// Kaleidoscope. p: segments, speed · c: zoom.
    static let kaleido = FXBase("kaleidoscope", params: [.scalar("segments", "fx.param.segments", 2, 16, 6), FXKit.speed(0.0)], symbol: "seal", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 2;
        float n = max(2.0, floor(p[0] + 0.5));
        float2 q = kit_centered(uv, ctx);
        float r = length(q) / c[0];
        float a = atan2(q.y, q.x) + ctx.time * p[1] * 1.5;
        float seg = 6.28318 / n;
        a = fmod(a + 62.8318, seg);
        a = abs(a - seg * 0.5);
        float2 m = float2(cos(a), sin(a)) * r;
        float2 u = kit_uncentered(m + float2(c[1], c[2]), ctx);
        return src.sample(s, kit_mirror(u));
    }
    """)

    static let all: [EffectDescriptor] = [
        wave.preset("wave", group: "distortion", [18, 0, 0], tags: ["wavy", "flag"]),
        wave.preset("wavy", group: "distortion", [10, 1, 0], defaults: ["amount": 0.7], tags: ["wave"]),
        wave.preset("underwater", group: "distortion", [14, 2, 1], tags: ["water", "sea", "pool", "caustics"]),
        ripple.preset("ripple", group: "distortion", [60, 0], tags: ["water", "rings"]),
        ripple.preset("waterDrop", group: "distortion", [45, 1], defaults: ["amount": 0.8], tags: ["drop", "rings"]),
        twirl.preset("twirl", group: "distortion", [0.55, 0], tags: ["swirl", "twist"]),
        twirl.preset("vortex", group: "distortion", [0.7, 1], tags: ["swirl", "spin", "portal"]),
        bulge.preset("bulge", group: "distortion", [1, 0, 0.45], tags: ["fat", "magnify"]),
        bulge.preset("pinch", group: "distortion", [-1, 0, 0.45], tags: ["thin", "squeeze"]),
        bulge.preset("breathe", group: "distortion", [1, 0.8, 0.5], defaults: ["amount": 0.45], tags: ["pulse", "beat"]),
        heat.preset("heatHaze", group: "distortion", [3.0, 1.0], tags: ["mirage", "hot", "desert"]),
        heat.preset("shimmer", group: "distortion", [6.0, 0.0], defaults: ["amount": 0.35], tags: ["haze"]),
        liquid.preset("liquid", group: "distortion", [2.0, 0.0], tags: ["warp", "fluid"]),
        liquid.preset("psychedelic", group: "party", [1.5, 0.6], defaults: ["amount": 0.7], tags: ["trippy", "acid", "colour"]),
        glass.preset("frostedGlass", group: "distortion", [0, 0], tags: ["frosted", "privacy"]),
        glass.preset("glassTiles", group: "distortion", [1, 9], tags: ["tiles", "refraction"]),
        glass.preset("rainyWindow", group: "nature", [2, 7], tags: ["rain", "drops", "window"]),
        glass.preset("flutedGlass", group: "distortion", [3, 22], tags: ["ribbed", "stripes"]),
        jelly.preset("jelly", group: "distortion", [], tags: ["wobble", "bouncy"]),

        grid.preset("split2", group: "split", [2, 1, 0, 0], tags: ["two", "multi screen", "duo"]),
        grid.preset("split3", group: "split", [3, 1, 0, 0], tags: ["three", "multi screen"]),
        grid.preset("split4", group: "split", [2, 2, 0, 0], tags: ["four", "multi screen", "quad"]),
        grid.preset("split6", group: "split", [3, 2, 0, 0], tags: ["six", "multi screen"]),
        grid.preset("split9", group: "split", [3, 3, 0, 0], tags: ["nine", "multi screen"]),
        grid.preset("split16", group: "split", [4, 4, 0, 0], tags: ["sixteen", "multi screen"]),
        grid.preset("splitVertical3", group: "split", [1, 3, 0, 0], tags: ["three", "stack"]),
        grid.preset("mirrorGrid", group: "split", [2, 2, 0, 1], tags: ["mirror", "four"]),
        grid.preset("popArtGrid", group: "split", [2, 2, 0.004, 2], tags: ["warhol", "pop art", "colour"]),
        grid.preset("rgbBands", group: "split", [3, 1, 0, 3], tags: ["rgb", "three", "colour"]),
        mirror.preset("mirrorLeft", group: "split", [0], tags: ["symmetry", "reflect"]),
        mirror.preset("mirrorRight", group: "split", [1], tags: ["symmetry", "reflect"]),
        mirror.preset("mirrorTop", group: "split", [2], tags: ["symmetry", "reflect", "lake"]),
        mirror.preset("mirrorBottom", group: "split", [3], tags: ["symmetry", "reflect"]),
        mirror.preset("quadMirror", group: "split", [4], tags: ["symmetry", "four"]),
        kaleido.preset("kaleidoscope", group: "split", [0.8, -0.35, -0.2], tags: ["mandala", "symmetry"]),
        kaleido.preset("kaleido8", group: "split", [0.7, 0.3, -0.15], defaults: ["segments": 8], tags: ["mandala"]),
        kaleido.preset("kaleidoSpin", group: "split", [0.8, -0.2, 0.1], defaults: ["segments": 5, "speed": 0.4], tags: ["mandala", "rotate"]),
    ]
}
