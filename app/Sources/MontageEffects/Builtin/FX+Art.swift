import MontageCore

/// Effects library — comic, painterly and stylized bases (FX-016 procedural NPR shaders).
enum FXArt {
    /// Halftone. p: size · c: mode (0 mono dots, 1 CMYK dots, 2 line screen), angle (deg), paper r, g, b.
    static let halftone = FXBase("halftone", params: [FXKit.size(0.4)], symbol: "circle.grid.3x3.fill", """
    inline float dots(float2 px, float cell, float ang, float v) {
        float2 r = kit_rot(ang) * px / cell;
        float2 f = fract(r) - 0.5;
        float rad = sqrt(saturate(v)) * 0.62;
        return 1.0 - smoothstep(rad - 0.08, rad + 0.08, length(f));
    }
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 1;
        float4 o = src.sample(s, uv);
        float cell = (4.0 + p[0] * 22.0) * ctx.size.y / 1080.0;
        float2 px = uv * ctx.size;
        float ang = c[1] * 0.0174533;
        float3 paper = float3(c[2], c[3], c[4]);
        float3 col;
        int mode = int(c[0] + 0.5);
        if (mode == 1) {
            float3 rgb = saturate(o.rgb);
            float k = 1.0 - max(rgb.r, max(rgb.g, rgb.b));
            float3 cmy = (1.0 - rgb - k) / max(1.0 - k, 1e-3);
            float cc = dots(px, cell, ang + 0.26, cmy.x), mm = dots(px, cell, ang + 1.31, cmy.y);
            float yy = dots(px, cell, ang, cmy.z), kk = dots(px, cell, ang + 0.79, k);
            col = paper * (1.0 - cc * float3(1.0, 0.0, 0.0)) * (1.0 - mm * float3(0.0, 1.0, 0.0)) * (1.0 - yy * float3(0.0, 0.0, 1.0));
            col *= 1.0 - kk * 0.9;
        } else if (mode == 2) {
            float2 r = kit_rot(ang) * px / cell;
            float v = 1.0 - fx_luma(o.rgb);
            float w = abs(fract(r.y) - 0.5);
            col = mix(paper, float3(0.08), 1.0 - smoothstep(v * 0.5 - 0.06, v * 0.5 + 0.06, w));
        } else {
            float d = dots(px, cell, ang, 1.0 - fx_luma(o.rgb));
            col = mix(paper, float3(0.06), d);
        }
        return float4(col, o.a);
    }
    """)

    /// Cartoon / comic / sketch. p: amount · c: levels, edge thickness (px at 1080p), mode (0 cartoon, 1 comic ink,
    /// 2 pencil, 3 charcoal), saturation.
    static let toon = FXBase("toon", params: [FXKit.amount(1.0)], symbol: "pencil.and.outline", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 1;
        float2 d = c[1] * (ctx.size.y / 1080.0) / ctx.size;
        float tl = fx_luma(src.sample(s, uv + float2(-d.x, -d.y)).rgb), t = fx_luma(src.sample(s, uv + float2(0, -d.y)).rgb);
        float tr = fx_luma(src.sample(s, uv + float2(d.x, -d.y)).rgb), l = fx_luma(src.sample(s, uv + float2(-d.x, 0)).rgb);
        float r = fx_luma(src.sample(s, uv + float2(d.x, 0)).rgb), bl = fx_luma(src.sample(s, uv + float2(-d.x, d.y)).rgb);
        float b = fx_luma(src.sample(s, uv + float2(0, d.y)).rgb), br = fx_luma(src.sample(s, uv + float2(d.x, d.y)).rgb);
        float gx = -tl - 2.0 * l - bl + tr + 2.0 * r + br, gy = -tl - 2.0 * t - tr + bl + 2.0 * b + br;
        float e = length(float2(gx, gy));
        float4 o = src.sample(s, uv);
        int mode = int(c[2] + 0.5);
        float3 col;
        if (mode == 0) {
            float3 hsv = fx_rgb2hsv(saturate(o.rgb));
            hsv.z = floor(hsv.z * c[0] + 0.5) / c[0];
            hsv.y = saturate(hsv.y * c[3]);
            col = fx_hsv2rgb(hsv) * (1.0 - smoothstep(0.25, 0.6, e));
        } else if (mode == 1) {
            float lum = fx_luma(o.rgb);
            float ink = smoothstep(0.2, 0.45, e);
            float tone = lum > 0.62 ? 1.0 : (lum > 0.32 ? 0.72 : 0.18);
            float hatch = lum < 0.45 ? step(0.5, fract((uv.x + uv.y) * ctx.size.y / (6.0 * ctx.size.y / 1080.0))) : 1.0;
            col = float3(tone * mix(1.0, hatch, 0.35)) * (1.0 - ink);
            col = mix(col, col * float3(1.0, 0.97, 0.9), 0.5);
        } else if (mode == 2) {
            float lum = fx_luma(o.rgb);
            float pencil = 1.0 - smoothstep(0.05, 0.5, e);
            float paper = 0.94 + 0.06 * kit_noise(uv * ctx.size / (2.0 * ctx.size.y / 1080.0));
            float shade = mix(0.75, 1.0, smoothstep(0.15, 0.7, lum));
            col = float3(pencil * paper * shade);
        } else {
            float lum = fx_luma(o.rgb);
            float grain = kit_noise(uv * ctx.size / (3.0 * ctx.size.y / 1080.0));
            float v = smoothstep(0.1, 0.9, lum) * (1.0 - smoothstep(0.1, 0.7, e) * 0.85);
            v = v * (0.85 + 0.3 * grain);
            col = float3(v) * float3(1.0, 0.98, 0.95);
        }
        return float4(mix(o.rgb, saturate(col), p[0]), o.a);
    }
    """)

    /// Kuwahara oil paint / watercolour. p: size · c: mode (0 oil, 1 watercolour), saturation.
    static let paint = FXBase("paint", params: [FXKit.size(0.5)], symbol: "paintbrush.pointed", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 1;
        float rad = (2.0 + p[0] * 6.0) * ctx.size.y / 1080.0;
        float2 st = rad / 2.0 / ctx.size;
        float3 m[4]; float3 s2[4];
        for (int k = 0; k < 4; k++) { m[k] = 0.0; s2[k] = 0.0; }
        for (int j = 0; j <= 2; j++) {
            for (int i = 0; i <= 2; i++) {
                float2 o = float2(float(i), float(j)) * st;
                float3 a = src.sample(s, uv + float2(-o.x, -o.y)).rgb; m[0] += a; s2[0] += a * a;
                float3 b = src.sample(s, uv + float2(o.x, -o.y)).rgb; m[1] += b; s2[1] += b * b;
                float3 cc = src.sample(s, uv + float2(-o.x, o.y)).rgb; m[2] += cc; s2[2] += cc * cc;
                float3 d = src.sample(s, uv + float2(o.x, o.y)).rgb; m[3] += d; s2[3] += d * d;
            }
        }
        float best = 1e9; float3 col = 0.0;
        for (int k = 0; k < 4; k++) {
            float3 mu = m[k] / 9.0;
            float3 var = abs(s2[k] / 9.0 - mu * mu);
            float v = var.r + var.g + var.b;
            if (v < best) { best = v; col = mu; }
        }
        col = kit_sat(col, c[1]);
        float4 o = src.sample(s, uv);
        if (c[0] > 0.5) {
            float paper = kit_fbm(uv * float2(ctx.aspect, 1.0) * 40.0);
            col = mix(col, float3(1.0), 0.12);
            col *= 0.9 + 0.12 * paper;
            float e = length(o.rgb - col);
            col *= 1.0 - smoothstep(0.08, 0.3, e) * 0.25;
        } else {
            float2 dd = st;
            float rl = fx_luma(src.sample(s, uv + dd).rgb) - fx_luma(src.sample(s, uv - dd).rgb);
            col *= 1.0 + rl * 0.6;
        }
        return float4(saturate(col), o.a);
    }
    """)

    /// Emboss / metal relief. p: amount · c: keep colour (0…1), metallic tint.
    static let emboss = FXBase("emboss", params: [FXKit.amount(0.7)], symbol: "square.on.square.dashed", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 1;
        float2 d = 2.0 * (ctx.size.y / 1080.0) / ctx.size;
        float4 o = src.sample(s, uv);
        float a = fx_luma(src.sample(s, uv - d).rgb), b = fx_luma(src.sample(s, uv + d).rgb);
        float rel = 0.5 + (b - a) * 3.0 * p[0];
        float3 col = mix(float3(rel), o.rgb * (rel + 0.5), c[0]);
        col = mix(col, rel * float3(0.85, 0.88, 0.95) + pow(saturate(rel), 6.0) * 0.4, c[1]);
        return float4(saturate(col), o.a);
    }
    """)

    /// Neon edges. p: glow, speed · c: background keep (0 black … 1 image), rainbow (0/1), line r, g, b, mode
    /// (0 additive, 1 blueprint).
    static let edges = FXBase("edges", params: [FXKit.glow(0.6), FXKit.speed(0.4)], symbol: "scribble.variable", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 2;
        float e = 0.0;
        for (int k = 1; k <= 2; k++) {
            float2 d = float(k) * 1.5 * (ctx.size.y / 1080.0) / ctx.size;
            float3 gx = src.sample(s, uv + float2(d.x, 0)).rgb - src.sample(s, uv - float2(d.x, 0)).rgb;
            float3 gy = src.sample(s, uv + float2(0, d.y)).rgb - src.sample(s, uv - float2(0, d.y)).rgb;
            e += (length(gx) + length(gy)) / float(k);
        }
        e = smoothstep(0.08, 0.5, e * (0.6 + p[0]));
        float4 o = src.sample(s, uv);
        float3 lineC = float3(c[2], c[3], c[4]);
        if (c[1] > 0.5) { lineC = kit_hue(fract(uv.x * 0.6 + uv.y * 0.3 - ctx.time * (0.1 + p[1] * 0.6))); }
        float3 col;
        if (c[5] > 0.5) {
            float3 bg = float3(0.08, 0.27, 0.55);
            float grid = step(0.96, fract(uv.x * ctx.aspect * 24.0)) + step(0.96, fract(uv.y * 24.0));
            bg += grid * 0.06;
            col = mix(bg, float3(0.92, 0.96, 1.0), e);
        } else {
            float3 base = o.rgb * c[0];
            col = base + lineC * e * (1.2 + p[0]);
        }
        return float4(saturate(col), o.a);
    }
    """)

    /// False colour: thermal, night vision, X-ray, infrared. p: amount · c: mode.
    static let falseColor = FXBase("falseColor", params: [FXKit.amount(1.0)], symbol: "thermometer.medium", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 1;
        float4 o = src.sample(s, uv);
        float l = fx_luma(o.rgb);
        int mode = int(c[0] + 0.5);
        float3 col;
        if (mode == 0) {
            float t = saturate(l);
            col = t < 0.25 ? mix(float3(0.0, 0.0, 0.25), float3(0.35, 0.0, 0.7), t * 4.0)
                : (t < 0.5 ? mix(float3(0.35, 0.0, 0.7), float3(0.95, 0.1, 0.25), (t - 0.25) * 4.0)
                : (t < 0.75 ? mix(float3(0.95, 0.1, 0.25), float3(1.0, 0.75, 0.0), (t - 0.5) * 4.0)
                : mix(float3(1.0, 0.75, 0.0), float3(1.0, 1.0, 0.85), (t - 0.75) * 4.0)));
        } else if (mode == 1) {
            float n = kit_h21(uv * ctx.size * 0.5 + floor(ctx.time * 24.0) * 3.3) - 0.5;
            float v = saturate(l * 1.6 + 0.08 + n * 0.12);
            col = float3(0.1, 1.0, 0.25) * v;
            float2 q = (uv - 0.5) * float2(ctx.aspect, 1.0);
            col *= 1.0 - smoothstep(0.3, 0.55, length(q));
            col *= 0.9 + 0.1 * sin(uv.y * ctx.size.y * 1.2);
        } else if (mode == 2) {
            float v = 1.0 - l;
            col = pow(saturate(v), 1.4) * float3(0.75, 0.9, 1.05) + float3(0.0, 0.02, 0.06);
        } else {
            float3 rgb = o.rgb;
            float veg = saturate((rgb.g - max(rgb.r, rgb.b)) * 4.0);
            col = float3(l * 1.1 + veg * 0.7, l * 0.9 - veg * 0.2, l * 0.95 + veg * 0.25);
            col = mix(col, col * float3(1.05, 0.8, 0.95), 0.4);
        }
        return float4(mix(o.rgb, saturate(col), p[0]), o.a);
    }
    """)

    /// Ordered dither. p: size · c: palette (0 1-bit, 1 8 colours, 2 sepia 2-tone).
    static let dither = FXBase("dither", params: [FXKit.size(0.3)], symbol: "circle.dotted", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 1;
        float ps = max(1.0, (1.0 + p[0] * 5.0) * ctx.size.y / 1080.0 * 1.5);
        float2 pc = floor(uv * ctx.size / ps);
        float4 o = src.sample(s, (pc + 0.5) * ps / ctx.size);
        float bay[16] = { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 };
        float d = (bay[int(fmod(pc.x, 4.0)) + int(fmod(pc.y, 4.0)) * 4] + 0.5) / 16.0;
        float3 col;
        if (c[0] < 0.5) { col = float3(step(d, fx_luma(o.rgb))); }
        else if (c[0] < 1.5) { col = step(float3(d), o.rgb); }
        else { col = mix(float3(0.17, 0.1, 0.07), float3(0.98, 0.9, 0.74), step(d, fx_luma(o.rgb))); }
        return float4(col, o.a);
    }
    """)

    /// Mosaics. p: size · c: shape (0 hexagons, 1 triangles, 2 crystals (Voronoi), 3 LED dots, 4 bricks).
    static let mosaic = FXBase("mosaic", params: [FXKit.size(0.55)], symbol: "hexagon", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 1;
        int mode = int(c[0] + 0.5);
        float cells = mix(70.0, 8.0, p[0]);
        float2 q = uv * float2(ctx.aspect, 1.0) * cells;
        float2 center; float edge = 1.0;
        if (mode == 0) {
            float2 r = float2(1.0, 1.7320508);
            float2 a = fmod(q, r) - r * 0.5, b = fmod(q - r * 0.5, r) - r * 0.5;
            float2 g = dot(a, a) < dot(b, b) ? a : b;
            center = q - g;
        } else if (mode == 1) {
            float2 g = floor(q); float2 f = fract(q);
            bool up = f.x + f.y < 1.0;
            center = g + (up ? float2(0.333, 0.333) : float2(0.667, 0.667));
        } else if (mode == 2) {
            float2 g = floor(q); float best = 9.0; float second = 9.0; center = g;
            for (int j = -1; j <= 1; j++) for (int i = -1; i <= 1; i++) {
                float2 nb = g + float2(i, j);
                float2 pt = nb + 0.5 + 0.45 * (kit_h22(nb) - 0.5) * 2.0;
                float d = distance(q, pt);
                if (d < best) { second = best; best = d; center = pt; } else if (d < second) { second = d; }
            }
            edge = smoothstep(0.0, 0.06, second - best);
        } else if (mode == 3) {
            center = floor(q) + 0.5;
            float d = length(fract(q) - 0.5);
            edge = 1.0 - smoothstep(0.32, 0.42, d);
        } else {
            float row = floor(q.y);
            float2 qq = float2(q.x * 0.5 + fmod(row, 2.0) * 0.5, q.y);
            float2 cc = floor(qq) + 0.5;
            center = float2(cc.x - fmod(row, 2.0) * 0.5, cc.y) * float2(2.0, 1.0);
            float2 f = fract(qq);
            edge = smoothstep(0.0, 0.06, min(min(f.x, 1.0 - f.x) * 2.0, min(f.y, 1.0 - f.y)));
            float2 dq = f - float2(0.5, 0.5);
            edge *= 0.85 + 0.25 * saturate(1.0 - length(dq * float2(1.0, 1.6)) * 2.5) * step(length(dq * float2(1.0, 2.0)), 0.3);
        }
        float2 su = center / cells / float2(ctx.aspect, 1.0);
        float4 o = src.sample(s, su);
        float3 col = o.rgb * edge;
        if (mode == 3) col = col * 1.15 + edge * 0.04;
        return float4(saturate(col), src.sample(s, uv).a);
    }
    """)

    /// ASCII art (5×5 bitmap glyphs chosen by brightness). p: size · c: mode (0 white on black, 1 green matrix, 2 colour).
    static let ascii = FXBase("ascii", params: [FXKit.size(0.35)], symbol: "textformat.abc", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 1;
        float cs = (6.0 + p[0] * 14.0) * ctx.size.y / 1080.0;
        float2 cell = floor(uv * ctx.size / cs);
        float2 f = fract(uv * ctx.size / cs);
        float4 o = src.sample(s, (cell + 0.5) * cs / ctx.size);
        float l = fx_luma(o.rgb);
        // glyphs: space . : - = + * # % @ as 5x5 bitmaps (row-major, top row = high bits)
        int glyphs[10] = { 0, 4, 131200, 14336, 459200, 145536, 332096, 11512810, 27070835, 15261391 };
        int gi = int(saturate(l) * 9.99);
        int2 b = int2(f * 5.0);
        int bit = (glyphs[gi] >> ((4 - b.y) * 5 + (4 - b.x))) & 1;
        float on = float(bit);
        float3 col;
        if (c[0] < 0.5) col = float3(on);
        else if (c[0] < 1.5) {
            float fade = 0.4 + 0.6 * kit_h11(cell.x * 7.1 + floor(ctx.time * 6.0 + kit_h11(cell.x) * 10.0 - cell.y * 0.3));
            col = float3(0.15, 1.0, 0.35) * on * fade;
        } else col = o.rgb * on * 1.3;
        return float4(saturate(col), o.a);
    }
    """)

    /// Duotone: maps luminance between two colours. p: amount · c: dark rgb, light rgb.
    static let duotone = FXBase("duotone", params: [FXKit.amount(1.0)], symbol: "circle.lefthalf.filled.righthalf.striped.horizontal", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 1;
        float4 o = src.sample(s, uv);
        float l = smoothstep(0.02, 0.98, fx_luma(o.rgb));
        float3 col = mix(float3(c[0], c[1], c[2]), float3(c[3], c[4], c[5]), l);
        return float4(mix(o.rgb, col, p[0]), o.a);
    }
    """)

    static let all: [EffectDescriptor] = [
        halftone.preset("halftone", group: "comic", [0, 45, 0.96, 0.95, 0.9], tags: ["dots", "print"]),
        halftone.preset("popArtDots", group: "comic", [1, 15, 1.0, 0.98, 0.94], defaults: ["size": 0.5], tags: ["cmyk", "pop art", "lichtenstein"]),
        halftone.preset("newsprint", group: "comic", [0, 45, 0.88, 0.85, 0.76], defaults: ["size": 0.15], tags: ["newspaper", "print"]),
        halftone.preset("lineScreen", group: "comic", [2, 30, 0.97, 0.96, 0.92], tags: ["engraving", "lines"]),
        toon.preset("cartoon", group: "comic", [5, 1.5, 0, 1.35], tags: ["toon", "anime"]),
        toon.preset("comic", group: "comic", [4, 1.5, 1, 1], tags: ["ink", "manga", "black and white"]),
        toon.preset("pencilSketch", group: "comic", [4, 1.2, 2, 1], tags: ["drawing", "sketch"]),
        toon.preset("charcoal", group: "comic", [4, 2.0, 3, 1], tags: ["drawing", "sketch", "dark"]),
        toon.preset("manga", group: "comic", [3, 1.0, 1, 1], defaults: ["amount": 1.0], tags: ["anime", "ink"]),
        paint.preset("oilPainting", group: "comic", [0, 1.25], tags: ["paint", "art", "kuwahara"]),
        paint.preset("watercolor", group: "comic", [1, 1.1], defaults: ["size": 0.4], tags: ["paint", "art"]),
        emboss.preset("emboss", group: "comic", [0.0, 0.0], tags: ["relief", "stone"]),
        emboss.preset("metal", group: "comic", [0.0, 1.0], tags: ["silver", "chrome", "relief"]),
        edges.preset("neonEdges", group: "light", [0.15, 1, 1, 0.2, 0.9, 0], tags: ["neon", "outline", "glow"]),
        edges.preset("edgeGlow", group: "light", [0.85, 0, 0.3, 0.9, 1.0, 0], tags: ["outline", "glow"]),
        edges.preset("rainbowEdges", group: "party", [0.0, 1, 1, 1, 1, 0], defaults: ["glow": 0.8], tags: ["rainbow", "neon"]),
        edges.preset("blueprint", group: "comic", [0, 0, 1, 1, 1, 1], tags: ["sketch", "plan", "technical"]),
        falseColor.preset("thermal", group: "comic", [0], tags: ["heat", "infrared", "predator"]),
        falseColor.preset("nightVision", group: "comic", [1], tags: ["green", "military", "spy"]),
        falseColor.preset("xRay", group: "comic", [2], tags: ["negative", "skeleton"]),
        falseColor.preset("infrared", group: "comic", [3], tags: ["ir", "pink", "foliage"]),
        dither.preset("dither", group: "retro", [0], tags: ["1-bit", "mac", "pixel"]),
        dither.preset("colorDither", group: "retro", [1], tags: ["8 colours", "pixel"]),
        dither.preset("sepiaDither", group: "retro", [2], defaults: ["size": 0.2], tags: ["vintage", "pixel"]),
        mosaic.preset("hexMosaic", group: "comic", [0], tags: ["hexagon", "pixelate"]),
        mosaic.preset("triangles", group: "comic", [1], tags: ["low poly", "pixelate"]),
        mosaic.preset("crystal", group: "comic", [2], tags: ["voronoi", "stained glass"]),
        mosaic.preset("ledDots", group: "comic", [3], defaults: ["size": 0.3], tags: ["led", "screen", "dots"]),
        mosaic.preset("bricks", group: "comic", [4], defaults: ["size": 0.35], tags: ["lego", "blocks"]),
        ascii.preset("ascii", group: "comic", [0], tags: ["text", "terminal", "characters"]),
        ascii.preset("matrix", group: "comic", [1], tags: ["code", "green", "hacker"]),
        ascii.preset("colorAscii", group: "comic", [2], tags: ["text", "characters"]),
        duotone.preset("duotonePink", group: "dreamy", [0.18, 0.05, 0.35, 1.0, 0.55, 0.75], tags: ["two tone", "pink", "pop"]),
        duotone.preset("duotoneBlue", group: "dreamy", [0.03, 0.08, 0.28, 0.55, 0.9, 1.0], tags: ["two tone", "blue"]),
        duotone.preset("duotoneSunset", group: "dreamy", [0.25, 0.03, 0.3, 1.0, 0.72, 0.3], tags: ["two tone", "orange", "purple"]),
        duotone.preset("duotoneMint", group: "dreamy", [0.05, 0.2, 0.22, 0.75, 1.0, 0.82], tags: ["two tone", "green"]),
    ]
}
