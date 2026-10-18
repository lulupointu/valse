import MontageCore

/// Effects library — glitch, VHS / CRT and film bases (FX-010).
enum FXGlitch {
    /// RGB split. p: amount, speed · c: mode (0 horizontal, 1 radial lens, 2 random jitter, 3 wobble), base offset.
    static let rgbSplit = FXBase("rgbSplit", params: [FXKit.amount(0.5), FXKit.speed(0.5)], symbol: "square.3.layers.3d", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 2;
        int mode = int(c[0] + 0.5);
        float k = p[0] * c[1];
        float2 off;
        if (mode == 1) { off = (uv - 0.5) * k * 1.6; }
        else if (mode == 2) {
            float st = floor(ctx.time * (6.0 + 20.0 * p[1]));
            float2 r = kit_h22(float2(st, 5.0)) - 0.5;
            off = r * k * 2.0 * step(0.35, kit_h11(st * 2.3));
        } else if (mode == 3) {
            float t = ctx.time * (1.0 + p[1] * 5.0);
            off = float2(sin(t * 2.1), cos(t * 1.7)) * k;
        } else { off = float2(k, 0.0) * (0.75 + 0.25 * sin(ctx.time * (1.0 + 6.0 * p[1]))); }
        float4 g = src.sample(s, uv);
        float r = src.sample(s, uv + off).r;
        float b = src.sample(s, uv - off).b;
        return float4(r, g.g, b, g.a);
    }
    """)

    /// Digital glitch: displaced bands / blocks, colour channel tears, noise. p: amount, speed ·
    /// c: band count, probability, block mode (0/1), colour noise, scanline noise, quantize.
    static let digital = FXBase("digitalGlitch", params: [FXKit.amount(0.6), FXKit.speed(0.5)], symbol: "waveform.path.ecg", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 2;
        float st = floor(ctx.time * (4.0 + p[1] * 22.0));
        float burst = step(0.45, kit_noise(float2(ctx.time * (1.0 + p[1] * 3.0), 3.0)));
        float amt = p[0] * (0.35 + 0.65 * burst);
        float2 cell = c[2] > 0.5 ? floor(uv * float2(c[0] * 0.5, c[0])) : float2(0.0, floor(uv.y * c[0]));
        float n = kit_h21(cell + st * 1.37);
        float hit = step(1.0 - c[1] * amt, n);
        float shift = (kit_h21(cell * 1.7 + st) - 0.5) * 0.25 * amt * hit;
        float2 u = uv + float2(shift, 0.0);
        float split = (0.004 + 0.02 * hit) * amt;
        float4 g = src.sample(s, u);
        float3 col = float3(src.sample(s, u + float2(split, 0)).r, g.g, src.sample(s, u - float2(split, 0)).b);
        if (c[5] > 0.5 && hit > 0.5) { col = floor(col * 4.0 + 0.5) / 4.0; }
        float cn = kit_h21(floor(uv * ctx.size / 3.0) + st);
        col = mix(col, float3(cn), c[3] * amt * hit * 0.6);
        float line = step(0.985 - c[4] * 0.04 * amt, kit_h21(float2(floor(uv.y * ctx.size.y * 0.5), st)));
        col = mix(col, float3(1.0), line * c[4] * 0.7);
        if (hit > 0.5 && kit_h21(cell + st + 9.0) > 0.8) { col = col.gbr; }
        return float4(saturate(col), g.a);
    }
    """)

    /// VHS tape: chroma bleed, tracking band, noise, jitter, faded colour. p: amount · c: tracking, noise, bleed,
    /// saturation, wear, warmth.
    static let vhs = FXBase("vhs", params: [FXKit.amount(0.7)], symbol: "videoprojector", """
    inline float3 rgb2yiq(float3 c) { return float3(dot(c, float3(0.299, 0.587, 0.114)), dot(c, float3(0.596, -0.274, -0.322)), dot(c, float3(0.211, -0.523, 0.312))); }
    inline float3 yiq2rgb(float3 c) { return float3(c.x + 0.956 * c.y + 0.621 * c.z, c.x - 0.272 * c.y - 0.647 * c.z, c.x - 1.106 * c.y + 1.703 * c.z); }
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 1;
        float a = p[0];
        float t = ctx.time;
        float line = floor(uv.y * 240.0);
        float jitter = (kit_h21(float2(line, floor(t * 30.0))) - 0.5) * 0.0025 * a;
        float band = fract(t * 0.13);
        float inBand = exp(-pow((uv.y - band) * 18.0, 2.0)) * c[0] * a;
        float2 u = uv + float2(jitter + inBand * 0.04 * (kit_h11(line + floor(t * 30.0)) - 0.3), 0.0);
        float3 y = rgb2yiq(src.sample(s, u).rgb);
        float3 ch = 0.0;
        float bl = c[2] * 0.012 * a;
        for (int i = 0; i < 6; i++) { ch += rgb2yiq(src.sample(s, u + float2(bl * (float(i) / 5.0 - 0.2), 0.0)).rgb); }
        ch /= 6.0;
        float3 col = yiq2rgb(float3(y.x, ch.y, ch.z) * float3(1.0, c[3], c[3]));
        float4 base = src.sample(s, uv);
        float nz = kit_h21(uv * ctx.size * 0.5 + floor(t * 30.0) * 13.1) - 0.5;
        col += nz * c[1] * 0.18 * a;
        col += inBand * 0.35 * (kit_h21(float2(uv.x * 400.0, floor(t * 30.0))) - 0.2);
        float drop = step(0.9975 - c[4] * 0.004, kit_h21(float2(floor(uv.x * 60.0), line + floor(t * 15.0) * 7.0)));
        col = mix(col, float3(0.95), drop * c[4] * a);
        col *= float3(1.0 + 0.06 * c[5], 1.0, 1.0 - 0.08 * c[5]);
        col *= 0.92 + 0.08 * sin(uv.y * ctx.size.y * 1.5);
        col = mix(base.rgb, col, saturate(a * 1.4));
        return float4(saturate(col), base.a);
    }
    """)

    /// Vertical roll / horizontal tear (bad TV signal). p: amount, speed · c: mode (0 roll, 1 tear).
    static let tvSignal = FXBase("tvSignal", params: [FXKit.amount(0.6), FXKit.speed(0.5)], symbol: "tv", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 2;
        float t = ctx.time * (0.3 + p[1] * 1.5);
        float2 u = uv;
        float bar = 0.0;
        if (c[0] < 0.5) {
            float roll = fract(t * 0.5) * p[0];
            u.y = fract(uv.y + roll + 0.02 * sin(t * 7.0) * p[0]);
            bar = smoothstep(0.03, 0.0, abs(fract(uv.y + roll) - 0.002)) + smoothstep(0.012, 0.0, abs(u.y - 0.0));
        } else {
            float y = floor(uv.y * 90.0);
            float n = kit_noise(float2(y * 0.15, t * 6.0));
            u.x += (n - 0.5) * 0.12 * p[0] * step(0.55, n);
            u.x += sin(uv.y * 40.0 + t * 20.0) * 0.004 * p[0];
        }
        float4 o = src.sample(s, fract(u));
        o.rgb = mix(o.rgb, float3(0.0), saturate(bar) * 0.85);
        o.rgb += (kit_h21(uv * ctx.size + t * 100.0) - 0.5) * 0.08 * p[0];
        return float4(saturate(o.rgb), o.a);
    }
    """)

    /// Pixel sorting / melt: bright pixels streak along a direction. p: amount · c: direction (0 right, 1 down), threshold.
    static let pixelSort = FXBase("pixelSort", params: [FXKit.amount(0.6)], symbol: "line.3.horizontal.decrease", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 1;
        float2 dir = c[0] < 0.5 ? float2(-1.0, 0.0) : float2(0.0, -1.0);
        float len = p[0] * 0.18;
        float4 o = src.sample(s, uv);
        float best = fx_luma(o.rgb);
        float4 res = o;
        float wob = c[0] < 0.5 ? kit_h11(floor(uv.y * ctx.size.y / 2.0)) : kit_h11(floor(uv.x * ctx.size.x / 3.0));
        float l2 = len * (0.4 + 0.6 * wob);
        for (int i = 1; i < 20; i++) {
            float2 q = uv + dir * l2 * float(i) / 19.0;
            float4 t = src.sample(s, q);
            float l = fx_luma(t.rgb);
            if (l > c[1] && l > best) { best = l; res = mix(t, res, float(i) / 22.0); }
        }
        return float4(res.rgb, o.a);
    }
    """)

    /// Random inverts / channel swaps on beats. p: speed · c: mode (0 invert, 1 channel swap, 2 posterized flash).
    static let invertFlicker = FXBase("invertFlicker", params: [FXKit.speed(0.5)], symbol: "circle.lefthalf.filled", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 1;
        float st = floor(ctx.time * (2.0 + p[0] * 12.0));
        float on = step(0.5, kit_h11(st * 1.31 + 0.5));
        float4 o = src.sample(s, uv);
        float3 col = o.rgb;
        if (on > 0.5) {
            if (c[0] < 0.5) col = 1.0 - col;
            else if (c[0] < 1.5) col = kit_h11(st) > 0.5 ? col.brg : col.gbr;
            else col = step(0.5, col) * kit_hue(kit_h11(st)) + (1.0 - step(0.5, col)) * 0.08;
        }
        return float4(col, o.a);
    }
    """)

    /// Datamosh look: blocks dragged along a noise flow field. p: amount, speed · c: block size (px at 1080p).
    static let datamosh = FXBase("datamosh", params: [FXKit.amount(0.6), FXKit.speed(0.5)], symbol: "square.grid.3x3.square", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 2;
        float bs = c[0] * ctx.size.y / 1080.0;
        float2 blk = floor(uv * ctx.size / bs);
        float t = ctx.time * (0.5 + p[1] * 2.0);
        float2 flow = float2(kit_noise(blk * 0.11 + t), kit_noise(blk * 0.11 - t + 9.0)) - 0.5;
        float hit = step(0.5, kit_noise(blk * 0.05 + floor(t * 2.0) * 3.7));
        float2 u = uv + flow * 0.12 * p[0] * hit;
        float4 o = src.sample(s, u);
        float4 b = src.sample(s, (blk + 0.5) * bs / ctx.size + flow * 0.05 * p[0]);
        o.rgb = mix(o.rgb, b.rgb, hit * 0.45 * p[0]);
        return float4(o.rgb, src.sample(s, uv).a);
    }
    """)

    // MARK: Film / retro

    /// Film: grain, flicker, dust, scratches, gate weave, tone. p: amount, size · c: grain colour (0 mono … 1),
    /// flicker, dust, scratches, desaturate, vignette, weave, sepia, warm.
    static let film = FXBase("film", params: [FXKit.amount(0.6), FXKit.size(0.4)], symbol: "film", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 2;
        float a = p[0];
        float fr = floor(ctx.time * 18.0);
        float2 weave = float2(kit_noise(float2(ctx.time * 3.0, 1.0)) - 0.5, kit_noise(float2(ctx.time * 2.3, 5.0)) - 0.5) * 0.006 * c[6];
        float4 o = src.sample(s, uv + weave);
        float3 col = o.rgb;
        float l = fx_luma(col);
        col = mix(col, float3(l), c[4]);
        float3 sep = float3(l) * float3(1.07, 0.95, 0.78) + float3(0.03, 0.01, -0.02);
        col = mix(col, sep, c[7]);
        col *= float3(1.0 + 0.05 * c[8], 1.0, 1.0 - 0.07 * c[8]);
        // grain (resolution independent cell size)
        float gs = max(1.0, (0.6 + p[1] * 2.4) * ctx.size.y / 1080.0);
        float2 gp = floor(uv * ctx.size / gs);
        float3 g = float3(kit_h21(gp + fr * 1.71), kit_h21(gp + fr * 2.37 + 7.0), kit_h21(gp + fr * 3.13 + 3.0));
        g = mix(float3(g.x), g, c[0]);
        float gk = (g.x + g.y + g.z) / 3.0;
        col += (g - 0.5) * 0.22 * a * (1.0 - 0.5 * l);
        (void)gk;
        // flicker
        col *= 1.0 + (kit_h11(fr * 0.71) - 0.5) * 0.12 * c[1] * a;
        // dust specks
        float2 dc = floor(uv * float2(36.0 * ctx.aspect, 36.0));
        float dn = kit_h21(dc + fr * 4.1);
        float2 dq = fract(uv * float2(36.0 * ctx.aspect, 36.0)) - kit_h22(dc + fr) ;
        float speck = step(0.992, dn) * (1.0 - smoothstep(0.02, 0.12, length(dq)));
        col = mix(col, kit_h11(dn * 9.0) > 0.4 ? float3(0.05) : float3(0.95), speck * c[2] * a);
        // scratches
        for (int k = 0; k < 2; k++) {
            float seed = floor(ctx.time * 3.0) + float(k) * 17.0;
            float sx = kit_h11(seed) + sin(ctx.time * 1.7 + float(k)) * 0.01;
            float on = step(0.4, kit_h11(seed * 2.1));
            float d = abs(uv.x - sx) * ctx.size.x / (ctx.size.y / 1080.0);
            col = mix(col, float3(0.85), on * c[3] * a * exp(-d * d * 0.5) * (0.6 + 0.4 * kit_noise(float2(uv.y * 40.0, seed))));
        }
        // vignette
        float2 vq = (uv - 0.5) * float2(ctx.aspect, 1.0);
        col *= 1.0 - c[5] * a * smoothstep(0.3, 0.95, length(vq) / max(ctx.aspect * 0.5, 0.5));
        return float4(saturate(col), o.a);
    }
    """)

    /// CRT monitor: curvature, scanlines, RGB mask, rolling bar, glow. p: amount · c: curvature, scanlines, mask,
    /// rolling bar, desaturate, green phosphor.
    static let crt = FXBase("crt", params: [FXKit.amount(0.7)], symbol: "tv.inset.filled", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 1;
        float a = p[0];
        float2 q = uv * 2.0 - 1.0;
        q *= 1.0 + c[0] * a * 0.25 * (q.yx * q.yx);
        float2 u = q * 0.5 + 0.5;
        float inside = step(0.0, u.x) * step(u.x, 1.0) * step(0.0, u.y) * step(u.y, 1.0);
        float4 o = src.sample(s, u);
        float3 col = o.rgb;
        float lines = ctx.size.y / max(2.0, 3.0 * ctx.size.y / 1080.0);
        float sl = 0.5 + 0.5 * cos(u.y * lines * 6.28318);
        col *= 1.0 - c[1] * a * 0.45 * sl;
        float mx = fmod(floor(uv.x * ctx.size.x / max(1.0, ctx.size.y / 540.0)), 3.0);
        float3 mask = mx < 0.5 ? float3(1.0, 0.7, 0.7) : (mx < 1.5 ? float3(0.7, 1.0, 0.7) : float3(0.7, 0.7, 1.0));
        col *= mix(float3(1.0), mask, c[2] * a);
        float bar = smoothstep(0.08, 0.0, abs(fract(u.y - ctx.time * 0.15) - 0.5));
        col *= 1.0 + bar * 0.12 * c[3] * a;
        col = mix(col, float3(fx_luma(col)), c[4]);
        col = mix(col, float3(0.25, 1.0, 0.45) * fx_luma(col) * 1.3, c[5]);
        col *= 1.0 + 0.25 * a;
        float2 vq = q;
        col *= 1.0 - 0.35 * a * smoothstep(0.6, 1.4, length(vq));
        return float4(saturate(col) * inside, mix(o.a, 1.0, 1.0 - inside));
    }
    """)

    /// Posterize / retro palettes. p: amount · c: mode (0 posterize, 1 Game Boy, 2 8-bit, 3 CGA), pixel size.
    static let palette = FXBase("palette", params: [FXKit.amount(1.0)], symbol: "square.grid.2x2", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 1;
        int mode = int(c[0] + 0.5);
        float2 u = uv;
        if (c[1] > 0.0) { float2 g = ctx.size / max(1.0, c[1] * ctx.size.y / 1080.0); u = (floor(uv * g) + 0.5) / g; }
        float4 o = src.sample(s, u);
        float3 col = o.rgb;
        float l = fx_luma(col);
        float bay[16] = { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 };
        float2 pc = floor(uv * ctx.size / max(1.0, c[1] * ctx.size.y / 1080.0));
        float d = (bay[int(fmod(pc.x, 4.0)) + int(fmod(pc.y, 4.0)) * 4] / 16.0 - 0.5);
        float3 res;
        if (mode == 0) { res = floor(col * 4.0 + 0.5) / 4.0; }
        else if (mode == 1) {
            float k = floor(saturate(l + d * 0.25) * 3.999);
            res = k < 1.0 ? float3(0.06, 0.22, 0.06) : (k < 2.0 ? float3(0.19, 0.38, 0.19) : (k < 3.0 ? float3(0.55, 0.67, 0.06) : float3(0.61, 0.74, 0.06)));
        } else if (mode == 2) { res = floor(saturate(col + d * 0.2) * 3.0 + 0.5) / 3.0; }
        else {
            float3 pal[4] = { float3(0.0), float3(0.33, 1.0, 1.0), float3(1.0, 0.33, 1.0), float3(1.0) };
            float best = 1e9; res = pal[0];
            for (int i = 0; i < 4; i++) { float dd = distance(col + d * 0.25, pal[i]); if (dd < best) { best = dd; res = pal[i]; } }
        }
        return float4(mix(src.sample(s, uv).rgb, res, p[0]), o.a);
    }
    """)

    /// Old photo: tone, fade, paper texture, burnt edges. p: amount · c: tone r, g, b (multiplier on luma), edge burn.
    static let oldPhoto = FXBase("oldPhoto", params: [FXKit.amount(0.85)], symbol: "photo", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 1;
        float4 o = src.sample(s, uv);
        float l = fx_luma(o.rgb);
        l = smoothstep(-0.05, 1.05, l);
        float3 col = l * float3(c[0], c[1], c[2]) + float3(0.06, 0.05, 0.04);
        float paper = kit_fbm(uv * float2(ctx.aspect, 1.0) * 18.0);
        col *= 0.88 + 0.16 * paper;
        float2 q = (uv - 0.5) * float2(ctx.aspect, 1.0);
        float e = smoothstep(0.35, 0.75, length(q) / max(ctx.aspect * 0.5, 0.5) + (paper - 0.5) * 0.25);
        col = mix(col, col * float3(0.55, 0.38, 0.22), e * c[3]);
        col = mix(col, float3(0.92, 0.88, 0.8), 0.08);
        return float4(mix(o.rgb, saturate(col), p[0]), o.a);
    }
    """)

    static let all: [EffectDescriptor] = [
        rgbSplit.preset("rgbSplit", group: "glitch", [0, 0.02], tags: ["chromatic", "aberration", "rgb"]),
        rgbSplit.preset("chromatic", group: "lens", [1, 0.02], tags: ["aberration", "rgb", "lens"]),
        rgbSplit.preset("rgbJitter", group: "glitch", [2, 0.03], tags: ["rgb", "shake"]),
        rgbSplit.preset("rgbWobble", group: "glitch", [3, 0.018], tags: ["rgb", "wave"]),
        digital.preset("digitalGlitch", group: "glitch", [24, 0.35, 0, 0.0, 0.3, 0], tags: ["error", "bug"]),
        digital.preset("signalLost", group: "glitch", [40, 0.6, 0, 0.8, 1.0, 0], defaults: ["amount": 0.8], tags: ["noise", "static"]),
        digital.preset("blockGlitch", group: "glitch", [18, 0.4, 1, 0.2, 0.2, 0], tags: ["blocks", "pixel"]),
        digital.preset("corrupt", group: "glitch", [12, 0.55, 1, 0.4, 0.5, 1], defaults: ["amount": 0.75], tags: ["broken", "data"]),
        digital.preset("glitchLines", group: "glitch", [90, 0.3, 0, 0.0, 0.8, 0], tags: ["lines", "scan"]),
        tvSignal.preset("verticalRoll", group: "retro", [0], tags: ["tv", "hold", "vintage"]),
        tvSignal.preset("tvTear", group: "glitch", [1], tags: ["tv", "signal", "tear"]),
        pixelSort.preset("pixelSort", group: "glitch", [0, 0.55], tags: ["sort", "streak"]),
        pixelSort.preset("melt", group: "glitch", [1, 0.45], defaults: ["amount": 0.7], tags: ["drip", "liquid"]),
        invertFlicker.preset("invertFlicker", group: "glitch", [0], tags: ["invert", "negative", "flash"]),
        invertFlicker.preset("channelSwap", group: "glitch", [1], tags: ["rgb", "colour"]),
        invertFlicker.preset("posterFlash", group: "party", [2], tags: ["pop", "beat"]),
        datamosh.preset("datamosh", group: "glitch", [24], tags: ["mosh", "compression"]),

        vhs.preset("vhs", group: "retro", [0.6, 0.6, 1.0, 0.85, 0.4, 0.3], tags: ["tape", "80s", "90s", "vintage"]),
        vhs.preset("vhsWorn", group: "retro", [1.0, 1.0, 1.5, 0.7, 1.0, 0.5], defaults: ["amount": 0.9], tags: ["tape", "old"]),
        vhs.preset("camcorder", group: "retro", [0.2, 0.4, 0.7, 0.95, 0.1, 0.6], tags: ["home video", "90s"]),
        vhs.preset("tapeRewind", group: "retro", [2.0, 1.2, 2.0, 0.6, 1.0, 0.0], defaults: ["amount": 1.0], tags: ["rewind", "tracking"]),
        film.preset("filmGrain", group: "retro", [0.2, 0, 0, 0, 0, 0, 0, 0, 0], defaults: ["amount": 0.5], tags: ["grain", "noise", "film"]),
        film.preset("oldFilm", group: "retro", [0, 1, 1, 1, 0.6, 0.8, 1, 0.5, 0.3], defaults: ["amount": 0.8], tags: ["vintage", "cinema", "dust"]),
        film.preset("super8", group: "retro", [0.6, 0.8, 0.6, 0.3, 0.15, 1.0, 1.5, 0, 1.0], defaults: ["amount": 0.7, "size": 0.7], tags: ["8mm", "home movie", "warm"]),
        film.preset("silentMovie", group: "retro", [0, 1.5, 1, 1, 1.0, 1.0, 1.2, 0, 0], defaults: ["amount": 0.85], tags: ["black and white", "chaplin"]),
        film.preset("dust", group: "retro", [0, 0, 1.6, 0.6, 0, 0, 0, 0, 0], defaults: ["amount": 0.9, "size": 0.2], tags: ["specks", "scratches"]),
        crt.preset("crt", group: "retro", [0.6, 0.8, 0.5, 0.6, 0, 0], tags: ["monitor", "tv", "scanlines"]),
        crt.preset("arcade", group: "retro", [0.4, 1.0, 1.0, 0.0, 0, 0], tags: ["game", "scanlines", "pixel"]),
        crt.preset("oldTV", group: "retro", [1.0, 0.7, 0.2, 1.0, 0.8, 0], defaults: ["amount": 0.85], tags: ["tv", "black and white"]),
        crt.preset("terminal", group: "retro", [0.5, 1.0, 0.0, 0.5, 0, 1], tags: ["green", "hacker", "monitor"]),
        palette.preset("posterize", group: "comic", [0, 0], tags: ["levels", "pop"]),
        palette.preset("gameBoy", group: "retro", [1, 3], tags: ["green", "pixel", "game"]),
        palette.preset("eightBit", group: "retro", [2, 6], tags: ["8-bit", "pixel", "game"]),
        palette.preset("cga", group: "retro", [3, 4], tags: ["cyan", "magenta", "pc"]),
        oldPhoto.preset("oldPhoto", group: "retro", [1.0, 0.86, 0.66, 1.0], tags: ["sepia", "vintage", "paper"]),
        oldPhoto.preset("cyanotype", group: "retro", [0.45, 0.68, 0.98, 0.5], tags: ["blue", "print"]),
        oldPhoto.preset("silverPrint", group: "retro", [0.93, 0.93, 0.95, 0.7], tags: ["black and white", "daguerreotype"]),
    ]
}
