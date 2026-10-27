import ValseCore

/// Effects library — light (FX-011), dreamy and party bases.
enum FXLight {
    /// Two-pass glow / bloom (pass 0: horizontal blur of the bright pass, pass 1: vertical blur + add onto the
    /// original). p: intensity, size · c: threshold, tint r, g, b, saturation, mode (0 add, 1 screen + soften).
    static let glow = FXBase("glow", params: [FXKit.intensity(0.6), FXKit.size(0.5)], passes: 2, inputs: [.original],
                             symbol: "sun.max", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx, texture2d<float> orig) {
        constant float* c = p + 2;
        float stepPx = (1.0 + p[1] * 7.0) * ctx.size.y / 1080.0;
        if (ctx.pass == 0) {
            float2 dir = float2(stepPx / ctx.size.x, 0.0);
            const float o[5] = { 0.0, 1.4588, 3.4048, 5.3518, 7.3010 };
            const float w[5] = { 0.1597, 0.2611, 0.1262, 0.0331, 0.0045 };
            float3 acc = 0.0; float ws = 0.0;
            for (int i = -4; i <= 4; i++) {
                float wi = w[abs(i)];
                float3 t = src.sample(s, uv + dir * o[abs(i)] * sign(float(i))).rgb;
                float l = fx_luma(t);
                float k = smoothstep(c[0], min(c[0] + 0.25, 1.0), l);
                acc += t * k * wi; ws += wi;
            }
            return float4(acc / ws, 1.0);
        }
        float3 g = kit_blur17(src, s, uv, float2(0.0, stepPx / ctx.size.y)).rgb;
        g = mix(float3(fx_luma(g)), g, c[4]) * float3(c[1], c[2], c[3]);
        float4 base = orig.sample(s, uv);
        float3 col = c[5] > 0.5 ? kit_screen(mix(base.rgb, base.rgb * 0.92 + g * 0.3, 0.5), g * p[0] * 1.6) : base.rgb + g * p[0] * 2.2;
        return float4(saturate(col), base.a);
    }
    """)

    /// Dreamy soft focus (two passes): blurred highlights, haze tint, lifted blacks, soft white vignette.
    /// p: intensity · c: tint r, g, b, glow mix, saturation, white vignette, fade.
    static let dreamy = FXBase("dreamy", params: [FXKit.intensity(0.7)], passes: 2, inputs: [.original], symbol: "cloud.sun", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx, texture2d<float> orig) {
        constant float* c = p + 1;
        float stepPx = 5.0 * ctx.size.y / 1080.0;
        if (ctx.pass == 0) { return kit_blur17(src, s, uv, float2(stepPx / ctx.size.x, 0.0)); }
        float3 b = kit_blur17(src, s, uv, float2(0.0, stepPx / ctx.size.y)).rgb;
        float4 base = orig.sample(s, uv);
        float a = p[0];
        float3 col = kit_screen(base.rgb, b * c[3] * a);
        col = mix(col, max(col, b), 0.35 * a);
        col = kit_sat(col, mix(1.0, c[4], a));
        col = mix(col, col * float3(c[0], c[1], c[2]), a);
        col = col * (1.0 - c[6] * a * 0.25) + c[6] * a * 0.25 * float3(c[0], c[1], c[2]) * 0.9;
        float2 q = (uv - 0.5) * float2(ctx.aspect, 1.0);
        float v = smoothstep(0.35, 0.95, length(q) / max(ctx.aspect * 0.5, 0.5));
        col = mix(col, float3(1.0), v * c[5] * a);
        return float4(saturate(col), base.a);
    }
    """)

    /// Light leaks. p: intensity, speed · c: colour A rgb, colour B rgb, mode (0 left edge, 1 right/top corner,
    /// 2 sweeping band, 3 both edges), rainbow (0/1).
    static let leak = FXBase("lightLeak", params: [FXKit.intensity(0.7), FXKit.speed(0.4)], symbol: "rays", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 2;
        float4 o = src.sample(s, uv);
        float t = ctx.time * (0.15 + p[1] * 0.9);
        float2 q = uv * float2(ctx.aspect, 1.0);
        int mode = int(c[6] + 0.5);
        float3 acc = 0.0;
        for (int i = 0; i < 3; i++) {
            float fi = float(i);
            float2 ctr;
            float n1 = kit_noise(float2(t + fi * 3.7, fi)), n2 = kit_noise(float2(t * 0.8 + fi * 1.9, 4.0 + fi));
            if (mode == 0) ctr = float2(-0.05 + 0.2 * n1, 0.1 + 0.8 * n2);
            else if (mode == 1) ctr = float2(ctx.aspect * (0.85 + 0.25 * n1), -0.05 + 0.4 * n2);
            else if (mode == 2) ctr = float2(ctx.aspect * (fract(t * 0.25 + fi * 0.08) * 1.6 - 0.3), 0.2 + 0.6 * n2);
            else ctr = float2(fi == 1.0 ? ctx.aspect * (0.95 + 0.1 * n1) : -0.05 + 0.15 * n1, 0.15 + 0.7 * n2);
            float2 d = q - ctr;
            if (mode == 2) d.x *= 2.2;
            float r = 0.25 + 0.25 * kit_noise(float2(t * 1.3, fi * 5.0));
            float w = exp(-dot(d, d) / (r * r));
            float3 col = mix(float3(c[0], c[1], c[2]), float3(c[3], c[4], c[5]), fi * 0.5);
            if (c[7] > 0.5) col = kit_hue(fract(fi * 0.33 + t * 0.15 + q.y * 0.3)) * 0.9 + 0.1;
            acc += col * w;
        }
        float flick = 0.8 + 0.2 * kit_noise(float2(t * 4.0, 2.0));
        float3 leakC = saturate(acc * p[0] * flick * 1.2);
        return float4(kit_screen(o.rgb, leakC), o.a);
    }
    """)

    /// Lens flare at a light position. p: intensity, x, y · c: mode (0 classic ghosts, 1 anamorphic streak,
    /// 2 starburst sun), drift speed, tint r, g, b.
    static let flare = FXBase("lensFlare", params: [FXKit.intensity(0.7), FXKit.posX(0.75), FXKit.posY(0.25)], symbol: "sun.min", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 3;
        float4 o = src.sample(s, uv);
        float2 lp = float2(p[1], p[2]) + float2(sin(ctx.time * c[1]), cos(ctx.time * c[1] * 0.7)) * 0.04 * step(0.001, c[1]);
        float2 asp = float2(ctx.aspect, 1.0);
        float2 q = (uv - lp) * asp;
        float d = length(q);
        float3 tint = float3(c[2], c[3], c[4]);
        int mode = int(c[0] + 0.5);
        float3 f = 0.0;
        f += tint * (exp(-d * 9.0) * 0.9 + exp(-d * 2.5) * 0.25);
        if (mode == 0) {
            float2 axis = (float2(0.5) - lp) * asp;
            const float ks[5] = { 0.45, 0.75, 1.1, 1.45, 1.9 };
            const float rs[5] = { 0.035, 0.06, 0.025, 0.09, 0.05 };
            for (int i = 0; i < 5; i++) {
                float2 g = (uv - lp) * asp - axis * ks[i] * 2.0;
                float gd = length(g);
                float3 gc = kit_hue(0.55 + float(i) * 0.12) * 0.5 + 0.2;
                f += gc * (1.0 - smoothstep(rs[i] * 0.7, rs[i], gd)) * 0.3;
                f += gc * exp(-gd * gd / (rs[i] * rs[i] * 4.0)) * 0.08;
            }
            float ring = exp(-pow((length((uv - 0.5) * asp) - 0.42) * 30.0, 2.0)) * 0.12;
            f += kit_hue(fract(atan2(q.y, q.x) * 0.16)) * ring * smoothstep(0.8, 0.0, d);
        } else if (mode == 1) {
            f += float3(0.35, 0.6, 1.0) * exp(-abs(q.y) * 90.0) * exp(-abs(q.x) * 1.6) * 1.3;
            f += float3(0.2, 0.4, 1.0) * exp(-abs(q.y) * 30.0) * exp(-abs(q.x) * 4.0) * 0.4;
        } else {
            float a = atan2(q.y, q.x);
            float rays = pow(abs(sin(a * 6.0 + ctx.time * 0.3)), 18.0) + pow(abs(sin(a * 9.0 - ctx.time * 0.2)), 30.0) * 0.6;
            f += tint * rays * exp(-d * 4.0) * 0.8;
            f += tint * (1.0 - smoothstep(0.02, 0.05, d));
        }
        return float4(saturate(o.rgb + f * p[0]), o.a);
    }
    """)

    /// God rays from a light position (radial accumulation of the bright pass). p: intensity, x, y · c: length, tint rgb.
    static let rays = FXBase("godRays", params: [FXKit.intensity(0.7), FXKit.posX(0.75), FXKit.posY(0.2)], symbol: "light.beacon.max", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 3;
        float4 o = src.sample(s, uv);
        float2 lp = float2(p[1], p[2]);
        float2 delta = (lp - uv) * c[0] / 24.0;
        float2 u = uv + delta * kit_h21(uv * ctx.size);
        float decay = 1.0; float3 acc = 0.0;
        for (int i = 0; i < 24; i++) {
            u += delta;
            float3 t = src.sample(s, u).rgb;
            acc += max(t - 0.62, 0.0) * decay;
            decay *= 0.94;
        }
        acc = acc / 6.0 * float3(c[1], c[2], c[3]);
        return float4(saturate(o.rgb + acc * p[0] * 2.5), o.a);
    }
    """)

    /// Flash / strobe. p: intensity, speed · c: colour rgb, mode (0 beat flash, 1 strobe, 2 random camera flashes,
    /// 3 colour-cycling flash).
    static let flash = FXBase("flash", params: [FXKit.intensity(0.8), FXKit.speed(0.5)], symbol: "bolt", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 2;
        float4 o = src.sample(s, uv);
        float rate = 0.6 + p[1] * 4.0;
        float t = ctx.time * rate;
        int mode = int(c[3] + 0.5);
        float f; float3 col = float3(c[0], c[1], c[2]);
        if (mode == 0) { f = exp(-fract(t) * 7.0); }
        else if (mode == 1) { f = step(0.5, fract(t * 2.0)) * 0.85; }
        else if (mode == 2) {
            float slot = floor(t * 2.0);
            float on = step(0.35, kit_h11(slot * 3.1));
            f = on * exp(-fract(t * 2.0) * 4.0);
            float2 cp = kit_h22(float2(slot, 1.0));
            f *= 0.6 + 0.4 * exp(-length((uv - cp) * float2(ctx.aspect, 1.0)) * 2.0);
        } else { f = exp(-fract(t) * 5.0) * 0.8; col = kit_hue(fract(floor(t) * 0.37)); }
        return float4(mix(o.rgb, col, saturate(f * p[0])), o.a);
    }
    """)

    /// Prism / rainbow / hologram. p: intensity, speed · c: mode (0 prism dispersion, 1 rainbow band, 2 hologram).
    static let prism = FXBase("prism", params: [FXKit.intensity(0.7), FXKit.speed(0.4)], symbol: "triangle.lefthalf.filled", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 2;
        float t = ctx.time * (0.1 + p[1]);
        int mode = int(c[0] + 0.5);
        float4 o = src.sample(s, uv);
        float3 col = o.rgb;
        if (mode == 0) {
            float2 dir = float2(0.012, 0.004) * p[0];
            col = float3(src.sample(s, uv + dir).r, src.sample(s, uv).g, src.sample(s, uv - dir).b);
            float band = fract(uv.x * 0.8 + uv.y * 0.4 - t * 0.3);
            col = kit_screen(col, kit_hue(band) * 0.22 * p[0]);
        } else if (mode == 1) {
            float2 q = (uv - float2(0.5, 1.25)) * float2(ctx.aspect, 1.0);
            float r = length(q);
            float k = (r - 0.95) / 0.22;
            float a = exp(-k * k * 2.0) * smoothstep(0.0, 0.3, uv.y + 0.1);
            col = kit_screen(col, kit_hue(saturate(k * 0.5 + 0.5) * 0.8) * a * 0.55 * p[0] * (0.85 + 0.15 * sin(t * 3.0)));
        } else {
            float l = fx_luma(col);
            float scan = 0.5 + 0.5 * sin((uv.y - t * 0.5) * ctx.size.y * 0.5 / (ctx.size.y / 1080.0) * 0.1);
            float flick = 0.85 + 0.15 * kit_noise(float2(t * 12.0, 3.0));
            float3 holo = float3(0.25, 0.85, 1.0) * (l * 1.3 + 0.1) * flick * (0.75 + 0.25 * scan);
            holo += float3(src.sample(s, uv + float2(0.004, 0)).r * 0.2, 0.0, 0.0);
            col = mix(col, holo, p[0]);
        }
        return float4(saturate(col), o.a);
    }
    """)

    /// Film burn from the edges. p: intensity, speed · c: colour r, g, b.
    static let burn = FXBase("filmBurn", params: [FXKit.intensity(0.8), FXKit.speed(0.4)], symbol: "flame", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 2;
        float4 o = src.sample(s, uv);
        float t = ctx.time * (0.2 + p[1] * 1.2);
        float2 q = uv * float2(ctx.aspect, 1.0);
        float n = kit_fbm(q * 2.5 + float2(t * 0.6, -t * 0.4));
        float edge = max(abs(uv.x - 0.5), abs(uv.y - 0.5)) * 2.0;
        float cyc = 0.5 + 0.5 * sin(t * 1.3);
        float v = n * 0.9 + edge * 0.7 - 0.55 - cyc * 0.35;
        float burnA = smoothstep(0.0, 0.25, v) * p[0];
        float3 hot = mix(float3(c[0], c[1], c[2]), float3(1.0, 0.95, 0.8), smoothstep(0.15, 0.4, v));
        float3 col = kit_screen(o.rgb, hot * burnA * 1.3);
        col = mix(col, float3(1.0, 0.97, 0.9), smoothstep(0.35, 0.6, v) * p[0]);
        return float4(saturate(col), o.a);
    }
    """)

    /// Disco / spotlights / lasers. p: intensity, speed · c: mode (0 disco spots, 1 sweeping spotlights, 2 lasers,
    /// 3 club colour wash).
    static let disco = FXBase("disco", params: [FXKit.intensity(0.7), FXKit.speed(0.5)], symbol: "light.recessed.3", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 2;
        float4 o = src.sample(s, uv);
        float t = ctx.time * (0.3 + p[1] * 1.5);
        float2 q = kit_centered(uv, ctx);
        int mode = int(c[0] + 0.5);
        float3 light = 0.0;
        if (mode == 0) {
            float2 r = kit_rot(t * 0.6) * q;
            float2 g = r * 7.0;
            float2 id = floor(g); float2 f = fract(g) - 0.5;
            float on = step(0.4, kit_h21(id + floor(t * 2.0)));
            light = kit_hue(kit_h21(id)) * (1.0 - smoothstep(0.15, 0.35, length(f))) * on;
            o.rgb *= 0.55;
        } else if (mode == 1) {
            for (int i = 0; i < 3; i++) {
                float fi = float(i);
                float2 src0 = float2((fi - 1.0) * 0.6, -0.65);
                float ang = sin(t * (0.8 + fi * 0.3) + fi * 2.0) * 0.6;
                float2 d = q - src0;
                float a = atan2(d.x, d.y) - ang;
                float cone = smoothstep(0.16, 0.08, abs(a)) * smoothstep(1.6, 0.2, length(d));
                light += kit_hue(fi * 0.33 + t * 0.05) * cone * 0.9;
            }
            o.rgb *= 0.5;
        } else if (mode == 2) {
            for (int i = 0; i < 6; i++) {
                float fi = float(i);
                float2 org = float2(0.0, -0.6);
                float ang = sin(t * 1.4 + fi * 1.1) * 0.9;
                float2 d = q - org;
                float2 dir = float2(sin(ang), cos(ang));
                float dist = abs(d.x * dir.y - d.y * dir.x);
                float beam = exp(-dist * dist * 6000.0) * step(0.0, dot(d, dir));
                light += kit_hue(fi / 6.0 + t * 0.1) * beam * 1.2;
            }
            o.rgb *= 0.6;
        } else {
            float h = fract(t * 0.25 + q.x * 0.3);
            light = kit_hue(h) * (0.5 + 0.5 * sin(t * 6.28318)) * 0.6;
            o.rgb *= 0.75;
        }
        float3 col = o.rgb + light * p[0] * (0.6 + 0.4 * fx_luma(o.rgb) * 2.0);
        return float4(saturate(col), o.a);
    }
    """)

    /// Colour cycling. p: speed, intensity · c: mode (0 hue rotate, 1 rainbow gradient sweep, 2 RGB channel cycle).
    static let colorCycle = FXBase("colorCycle", params: [FXKit.speed(0.4), FXKit.intensity(1.0)], symbol: "paintpalette", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 2;
        float4 o = src.sample(s, uv);
        float t = ctx.time * (0.1 + p[0] * 1.2);
        float3 col;
        int mode = int(c[0] + 0.5);
        if (mode == 0) { float3 hsv = fx_rgb2hsv(saturate(o.rgb)); hsv.x = fract(hsv.x + t); col = fx_hsv2rgb(hsv); }
        else if (mode == 1) { col = kit_softlight(o.rgb, kit_hue(fract(uv.x * 0.7 - uv.y * 0.3 - t))); col = kit_sat(col, 1.3); }
        else { float k = fmod(floor(t * 4.0), 3.0); col = k < 0.5 ? o.rgb : (k < 1.5 ? o.gbr : o.brg); }
        return float4(mix(o.rgb, saturate(col), p[1]), o.a);
    }
    """)

    static let all: [EffectDescriptor] = [
        glow.preset("glow", group: "light", [0.55, 1, 1, 1, 1, 0], tags: ["bloom", "shine"]),
        glow.preset("softGlow", group: "dreamy", [0.35, 1, 0.97, 0.94, 0.8, 1], defaults: ["intensity": 0.5], tags: ["soft", "bloom"]),
        glow.preset("bloom", group: "light", [0.7, 1, 1, 1, 1.2, 0], defaults: ["intensity": 0.8, "size": 0.8], tags: ["glow", "highlights"]),
        glow.preset("neonGlow", group: "light", [0.45, 1.0, 0.4, 1.0, 2.0, 0], defaults: ["intensity": 0.8], tags: ["neon", "pink"]),
        glow.preset("halation", group: "retro", [0.6, 1.0, 0.35, 0.2, 1.0, 0], defaults: ["intensity": 0.6, "size": 0.35], tags: ["film", "red", "cinestill"]),
        glow.preset("goldenGlow", group: "light", [0.45, 1.0, 0.78, 0.4, 1.0, 1], defaults: ["intensity": 0.7], tags: ["gold", "warm", "sun"]),
        dreamy.preset("dreamy", group: "dreamy", [1.04, 0.98, 1.04, 0.6, 0.9, 0.25, 0.3], tags: ["soft", "fantasy"]),
        dreamy.preset("haze", group: "dreamy", [1.0, 0.98, 0.95, 0.4, 0.8, 0.0, 0.8], tags: ["fog", "matte"]),
        dreamy.preset("softFocus", group: "dreamy", [1, 1, 1, 0.7, 1.0, 0.0, 0.0], tags: ["soft", "portrait"]),
        dreamy.preset("fairyTale", group: "dreamy", [1.08, 0.92, 1.06, 0.7, 1.1, 0.35, 0.3], tags: ["pink", "fantasy", "magic"]),
        dreamy.preset("memory", group: "dreamy", [1.06, 1.0, 0.86, 0.5, 0.75, 0.45, 0.5], tags: ["nostalgia", "flashback", "warm"]),
        dreamy.preset("heavenly", group: "dreamy", [1.02, 1.02, 1.06, 1.0, 0.85, 0.6, 0.4], tags: ["white", "angel", "glow"]),
        leak.preset("lightLeak", group: "light", [1.0, 0.45, 0.1, 1.0, 0.75, 0.3, 0, 0], tags: ["leak", "film", "warm"]),
        leak.preset("warmLeak", group: "light", [1.0, 0.25, 0.05, 1.0, 0.55, 0.1, 1, 0], tags: ["leak", "orange"]),
        leak.preset("rainbowLeak", group: "light", [1, 1, 1, 1, 1, 1, 3, 1], tags: ["leak", "rainbow"]),
        leak.preset("sunsetLeak", group: "light", [1.0, 0.25, 0.55, 1.0, 0.6, 0.2, 3, 0], tags: ["leak", "pink", "sunset"]),
        leak.preset("coolLeak", group: "light", [0.2, 0.5, 1.0, 0.4, 0.95, 0.9, 1, 0], tags: ["leak", "blue"]),
        leak.preset("lightSweep", group: "light", [1.0, 0.9, 0.7, 1.0, 1.0, 0.95, 2, 0], tags: ["sweep", "shine", "pass"]),
        flare.preset("lensFlare", group: "light", [0, 0, 1.0, 0.9, 0.75], tags: ["flare", "sun", "lens"]),
        flare.preset("anamorphicFlare", group: "light", [1, 0, 0.6, 0.75, 1.0], defaults: ["y": 0.4], tags: ["flare", "streak", "cinema", "blue"]),
        flare.preset("sunBurst", group: "light", [2, 0, 1.0, 0.85, 0.6], tags: ["sun", "rays", "star"]),
        flare.preset("driftingFlare", group: "light", [0, 0.6, 1.0, 0.8, 0.6], tags: ["flare", "moving"]),
        rays.preset("godRays", group: "light", [0.6, 1.0, 0.9, 0.7], tags: ["rays", "sun", "beams"]),
        rays.preset("lightRays", group: "light", [0.9, 1.0, 1.0, 1.0], defaults: ["intensity": 0.45, "x": 0.5, "y": 0.0], tags: ["rays", "beams", "heaven"]),
        flash.preset("flash", group: "party", [1, 1, 1, 0], tags: ["white", "beat", "blink"]),
        flash.preset("strobe", group: "party", [1, 1, 1, 1], defaults: ["intensity": 0.6], tags: ["club", "blink"]),
        flash.preset("cameraFlash", group: "party", [1, 1, 1, 2], tags: ["paparazzi", "photo"]),
        flash.preset("colorFlash", group: "party", [1, 1, 1, 3], tags: ["colour", "beat"]),
        flash.preset("blackFlash", group: "party", [0, 0, 0, 0], defaults: ["intensity": 0.9], tags: ["blackout", "blink"]),
        prism.preset("prism", group: "light", [0], tags: ["rainbow", "dispersion"]),
        prism.preset("rainbow", group: "light", [1], tags: ["arc", "sky"]),
        prism.preset("hologram", group: "light", [2], defaults: ["intensity": 0.8], tags: ["sci-fi", "blue", "projection"]),
        burn.preset("filmBurn", group: "light", [1.0, 0.35, 0.05], tags: ["burn", "film", "fire"]),
        burn.preset("pinkBurn", group: "light", [1.0, 0.2, 0.5], tags: ["burn", "pink"]),
        disco.preset("disco", group: "party", [0], tags: ["disco ball", "dance"]),
        disco.preset("spotlights", group: "party", [1], tags: ["stage", "concert"]),
        disco.preset("lasers", group: "party", [2], tags: ["laser", "club", "rave"]),
        disco.preset("clubLights", group: "party", [3], tags: ["club", "colour", "dance"]),
        colorCycle.preset("colorCycle", group: "party", [0], tags: ["hue", "rainbow"]),
        colorCycle.preset("rainbowShift", group: "party", [1], tags: ["rainbow", "gradient"]),
        colorCycle.preset("rgbCycle", group: "party", [2], tags: ["rgb", "channels"]),
    ]
}
