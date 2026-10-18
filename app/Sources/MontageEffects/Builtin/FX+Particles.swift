import MontageCore

/// Effects library — particles / weather (FX-013), bling, frames (FX-014) and alpha-based body effects (FX-002).
/// Particles are deterministic functions of (uv, clip time): preview and export render identical frames.
enum FXParticles {
    /// Falling / rising particle field (3 depth layers). p: density, size, speed · c: shape (0 snow, 1 rain,
    /// 2 confetti, 3 heart, 4 petal, 5 bubble, 6 star, 7 ember, 8 leaf), dir x, dir y, sway, colour rgb,
    /// colour mode (0 fixed, 1 random hue, 2 pinks, 3 autumn, 4 warm fire), base size, glow.
    static let particles = FXBase("particles", params: [FXKit.density(0.5), FXKit.size(0.5), FXKit.speed(0.5)], symbol: "snowflake", """
    inline float3 pcolor(constant float* c, float2 r) {
        int m = int(c[7] + 0.5);
        float3 base = float3(c[4], c[5], c[6]);
        if (m == 1) return kit_hue(r.x) * 0.85 + 0.15;
        if (m == 2) return mix(float3(1.0, 0.35, 0.55), float3(1.0, 0.75, 0.85), r.x);
        if (m == 3) return mix(float3(0.85, 0.3, 0.05), float3(0.95, 0.75, 0.15), r.x);
        if (m == 4) return mix(float3(1.0, 0.45, 0.1), float3(1.0, 0.85, 0.4), r.x);
        return base;
    }
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 3;
        float4 o = src.sample(s, uv);
        float3 col = o.rgb;
        float alphaOut = o.a;
        int shape = int(c[0] + 0.5);
        float2 q = uv * float2(ctx.aspect, 1.0);
        float t = ctx.time * (0.3 + p[2] * 1.4);
        float px = 1.5 / ctx.size.y;
        for (int L = 0; L < 3; L++) {
            float fl = float(L);
            float depth = 1.0 - fl * 0.3;
            float cell = mix(0.22, 0.09, fl * 0.5);
            float2 dir = float2(c[1], c[2]) * depth;
            float2 g = (q - dir * t) / cell + fl * 17.31;
            float2 id = floor(g);
            float2 f = fract(g) - 0.5;
            float2 r = kit_h22(id + fl * 31.7);
            float exist = step(1.0 - p[0] * 0.85 - 0.05, kit_h21(id * 1.31 + fl));
            if (exist < 0.5) continue;
            float2 ctr = (r - 0.5) * 0.3 + float2(sin(t * (1.0 + r.x) + r.y * 6.28) * c[3] * 0.08, 0.0);
            float2 d = f - ctr;
            float R = c[8] * (0.5 + p[1]) * (0.7 + 0.5 * r.y);
            R = min(R, 0.32);
            float ang = (r.x - 0.5) * 6.28 + t * (r.y - 0.5) * 4.0;
            float2 dr = kit_rot(ang) * d;
            float pxc = px / cell;
            float cov = 0.0; float3 pc = pcolor(c, r); float glow = 0.0;
            if (shape == 0) { cov = 1.0 - smoothstep(R * 0.25, R, length(d)); glow = cov * 0.3; }
            else if (shape == 1) {
                float2 fall = normalize(float2(c[1], c[2]) + 1e-4);
                float2 rr = float2(dot(d, float2(fall.y, -fall.x)), dot(d, fall));
                cov = (1.0 - smoothstep(R * 0.06, R * 0.06 + pxc, abs(rr.x))) * (1.0 - smoothstep(R * 1.2, R * 1.6, abs(rr.y)));
                cov *= 0.55;
            } else if (shape == 2) {
                float flip = abs(cos(t * 3.0 + r.x * 6.28));
                float2 bq = dr * float2(1.0 / max(flip, 0.15), 1.0);
                cov = 1.0 - smoothstep(-pxc, pxc, kit_sdBox(bq, float2(R * 0.55, R * 0.3)));
                pc *= 0.75 + 0.25 * flip;
            } else if (shape == 3) {
                float2 hq = kit_rot((r.x - 0.5) * 0.8 + sin(t * 2.0 + r.y * 6.0) * 0.3) * d;
                cov = 1.0 - smoothstep(-pxc, pxc, kit_sdHeart(hq, R));
                pc *= 0.85 + 0.25 * saturate(-hq.y / R);
            } else if (shape == 4 || shape == 8) {
                float2 eq = dr / float2(R, R * (shape == 4 ? 0.55 : 0.42));
                float e = length(eq);
                cov = 1.0 - smoothstep(1.0 - pxc / R * 2.0, 1.0, e);
                pc *= 0.8 + 0.3 * (1.0 - e);
                if (shape == 8) pc *= 0.85 + 0.25 * step(abs(eq.y), 0.08);
            } else if (shape == 5) {
                float l = length(d);
                cov = (1.0 - smoothstep(R * 0.08, R * 0.08 + pxc * 2.0, abs(l - R))) * 0.7 + (1.0 - smoothstep(R * 0.7, R, l)) * 0.12;
                cov += (1.0 - smoothstep(R * 0.05, R * 0.18, length(d - float2(-R * 0.4, -R * 0.4)))) * 0.8;
                pc = mix(float3(0.85, 0.95, 1.0), kit_hue(fract(atan2(d.y, d.x) * 0.16 + t * 0.1)), 0.35);
            } else if (shape == 6) {
                cov = 1.0 - smoothstep(-pxc, pxc, kit_sdStar(dr, R, 0.45));
                glow = exp(-length(d) / (R * 0.5)) * 0.4;
            } else {
                float fk = 0.6 + 0.4 * sin(t * 9.0 + r.x * 30.0);
                cov = (1.0 - smoothstep(R * 0.1, R * 0.45, length(d))) * fk;
                glow = exp(-length(d) / (R * 0.6)) * 0.7 * fk;
            }
            float fade = mix(1.0, 0.65, fl * 0.5);
            col = mix(col, pc, saturate(cov) * fade);
            col += pc * glow * c[9] * fade;
            alphaOut = max(alphaOut, saturate(cov));
        }
        return float4(saturate(col), alphaOut);
    }
    """)

    /// Fireworks bursts. p: density, size, speed · c: colour mode (0 multicolour, 1 gold).
    static let fireworks = FXBase("fireworks", params: [FXKit.density(0.5), FXKit.size(0.5), FXKit.speed(0.5)], symbol: "fireworks", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 3;
        float4 o = src.sample(s, uv);
        float2 q = uv * float2(ctx.aspect, 1.0);
        float t = ctx.time * (0.5 + p[2]);
        float3 acc = 0.0;
        int nb = 2 + int(p[0] * 3.0);
        for (int b = 0; b < 5; b++) {
            if (b >= nb) break;
            float T = 2.2;
            float tt = t + float(b) * 0.73;
            float id = floor(tt / T) + float(b) * 13.0;
            float lt = fract(tt / T);
            float2 ctr = (kit_h22(float2(id, 2.0)) * float2(0.7, 0.45) + float2(0.15, 0.08)) * float2(ctx.aspect, 1.0);
            float rad = (0.25 + 0.2 * p[1]) * (1.0 - exp(-lt * 5.0));
            float fade = pow(1.0 - lt, 1.6);
            float3 bc = c[0] > 0.5 ? mix(float3(1.0, 0.75, 0.3), float3(1.0, 0.95, 0.7), kit_h11(id)) : kit_hue(kit_h11(id * 1.7)) * 0.8 + 0.25;
            float2 d = q - ctr;
            d.y -= lt * lt * 0.08;
            float a = atan2(d.y, d.x);
            float n = 36.0;
            float k0 = floor(a / 6.28318 * n);
            for (int j = 0; j <= 1; j++) {
                float k = k0 + float(j);
                float ak = (k + 0.5) / n * 6.28318;
                float rk = rad * (0.75 + 0.25 * kit_h11(k + id));
                float2 pp = float2(cos(ak), sin(ak)) * rk;
                float dd = length(d - pp);
                float2 dirk = float2(cos(ak), sin(ak));
                float along = dot(d, dirk);
                float perp = length(d - dirk * along);
                float trail = exp(-perp * perp * 40000.0) * smoothstep(rk - 0.08, rk, along) * step(along, rk);
                acc += bc * (exp(-dd * dd * 30000.0) * 1.5 + trail * 0.5) * fade;
            }
            acc += bc * exp(-length(d) * 30.0) * smoothstep(0.15, 0.0, lt) * 2.0;
        }
        return float4(saturate(o.rgb * 0.9 + acc), o.a);
    }
    """)

    /// Starry sky overlay with twinkling stars and shooting stars. p: density, speed · c: night darkening, shooting stars.
    static let stars = FXBase("starrySky", params: [FXKit.density(0.5), FXKit.speed(0.5)], symbol: "moon.stars", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 2;
        float4 o = src.sample(s, uv);
        float3 col = o.rgb * mix(float3(1.0), float3(0.35, 0.4, 0.65), c[0] * smoothstep(1.0, 0.0, uv.y * 0.9));
        float2 q = uv * float2(ctx.aspect, 1.0);
        float t = ctx.time * (0.5 + p[1] * 2.0);
        for (int L = 0; L < 2; L++) {
            float cell = L == 0 ? 0.035 : 0.06;
            float2 g = q / cell + float(L) * 9.1;
            float2 id = floor(g); float2 f = fract(g) - 0.5;
            float2 r = kit_h22(id);
            if (kit_h21(id + 4.0) > p[0] * 0.6 + 0.15) continue;
            float tw = 0.4 + 0.6 * pow(0.5 + 0.5 * sin(t * (1.0 + r.x * 3.0) + r.y * 6.28), 3.0);
            float d = length(f - (r - 0.5) * 0.6);
            float sz = L == 0 ? 0.06 : 0.1;
            col += float3(0.9, 0.95, 1.0) * (exp(-d * d / (sz * sz * 0.08)) + kit_glint(f - (r - 0.5) * 0.6, sz * 3.0) * 0.5 * float(L)) * tw * smoothstep(0.85, 0.2, uv.y);
        }
        if (c[1] > 0.5) {
            for (int k = 0; k < 2; k++) {
                float T = 2.5;
                float tt = t * 0.7 + float(k) * 1.3;
                float id = floor(tt / T) + float(k) * 5.0;
                float lt = fract(tt / T);
                float2 st = float2(kit_h11(id) * ctx.aspect * 0.8 + 0.1, kit_h11(id + 1.0) * 0.35);
                float2 dir = normalize(float2(-1.0, 0.45));
                float2 head = st + dir * lt * 0.9;
                float2 d = q - head;
                float along = dot(d, -dir);
                float perp = abs(d.x * dir.y - d.y * dir.x);
                float tail = exp(-perp * perp * 60000.0) * smoothstep(0.25, 0.0, along) * step(0.0, along);
                col += float3(1.0, 0.95, 0.85) * (tail + exp(-length(d) * 120.0)) * smoothstep(0.0, 0.1, lt) * smoothstep(1.0, 0.6, lt);
            }
        }
        return float4(saturate(col), o.a);
    }
    """)

    /// Fog / mist / smoke. p: amount, speed · c: colour rgb, ground (0 even … 1 low-lying), scale.
    static let fog = FXBase("fog", params: [FXKit.amount(0.6), FXKit.speed(0.4)], symbol: "cloud.fog", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 2;
        float4 o = src.sample(s, uv);
        float t = ctx.time * (0.05 + p[1] * 0.3);
        float2 q = uv * float2(ctx.aspect, 1.0) * c[4];
        float n = kit_fbm(q + float2(t, t * 0.3));
        n = kit_fbm(q * 1.7 + n * 1.5 + float2(-t * 0.7, 0.0));
        float h = mix(1.0, smoothstep(0.2, 1.0, uv.y), c[3]);
        float a = saturate(smoothstep(0.25, 0.8, n) * h * p[0] * 1.2);
        return float4(mix(o.rgb, float3(c[0], c[1], c[2]), a), o.a);
    }
    """)

    /// Sparkles / glitter. p: intensity, size, density · c: colour mode (0 white, 1 gold, 2 rainbow, 3 pink),
    /// placement (0 anywhere, 1 highlights only), shape (0 glint, 1 star, 2 glitter dot).
    static let sparkle = FXBase("sparkle", params: [FXKit.intensity(0.8), FXKit.size(0.5), FXKit.density(0.5)], symbol: "sparkles", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 3;
        float4 o = src.sample(s, uv);
        float3 col = o.rgb;
        float2 q = uv * float2(ctx.aspect, 1.0);
        int shape = int(c[2] + 0.5);
        for (int L = 0; L < 2; L++) {
            float cell = (shape == 2 ? 0.04 : 0.13) * (L == 0 ? 1.0 : 0.6);
            float2 g = q / cell + float(L) * 3.3;
            float2 id = floor(g); float2 f = fract(g) - 0.5;
            float2 r = kit_h22(id + float(L) * 5.0);
            if (kit_h21(id * 0.71 + 2.0) > p[2] * 0.7 + 0.08) continue;
            float2 ctr = (r - 0.5) * 0.5;
            float2 su = (id + 0.5 + ctr - float(L) * 3.3) * cell / float2(ctx.aspect, 1.0);
            float w = 1.0;
            if (c[1] > 0.5) w = smoothstep(0.55, 0.85, fx_luma(src.sample(s, su).rgb));
            float rate = 2.0 + r.x * 3.0;
            float tw = 0.15 + 0.85 * pow(max(0.0, sin(ctx.time * rate + r.y * 6.28)), 3.0);
            float3 sc = c[0] < 0.5 ? float3(1.0) : (c[0] < 1.5 ? float3(1.0, 0.82, 0.45) : (c[0] < 2.5 ? kit_hue(r.x) * 0.7 + 0.35 : float3(1.0, 0.6, 0.85)));
            float2 d = f - ctr;
            float R = (0.25 + 0.35 * p[1]) * (0.6 + 0.6 * r.y);
            float v;
            if (shape == 0) v = kit_glint(d, R);
            else if (shape == 1) v = (1.0 - smoothstep(-0.02, 0.02, kit_sdStar(kit_rot(ctx.time * (r.x - 0.5)) * d, R * 0.35, 0.45))) + exp(-length(d) / (R * 0.25)) * 0.4;
            else v = exp(-dot(d, d) / (R * R * 0.04)) * (0.5 + 0.5 * step(0.5, r.x));
            col += sc * v * tw * w * p[0] * 1.4;
        }
        return float4(saturate(col), o.a);
    }
    """)

    /// Floating bokeh lights. p: intensity, speed, size · c: colour mode (0 warm gold, 1 multicolour, 2 fairy (small),
    /// 3 cool), darken.
    static let bokeh = FXBase("bokehLights", params: [FXKit.intensity(0.7), FXKit.speed(0.3), FXKit.size(0.5)], symbol: "circle.hexagonpath", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 3;
        float4 o = src.sample(s, uv);
        float3 col = o.rgb * (1.0 - c[1]);
        float2 q = uv * float2(ctx.aspect, 1.0);
        float t = ctx.time * (0.05 + p[1] * 0.3);
        int mode = int(c[0] + 0.5);
        for (int L = 0; L < 2; L++) {
            float cell = (mode == 2 ? 0.08 : 0.22) * (L == 0 ? 1.0 : 0.65);
            float2 g = (q + float2(t * (0.5 + float(L)), -t * 0.6)) / cell + float(L) * 7.7;
            float2 id = floor(g); float2 f = fract(g) - 0.5;
            float2 r = kit_h22(id);
            if (kit_h21(id + 9.0) > 0.55) continue;
            float2 ctr = (r - 0.5) * 0.35 + float2(sin(ctx.time * 0.5 + r.x * 6.0), cos(ctx.time * 0.4 + r.y * 6.0)) * 0.05;
            float R = (mode == 2 ? 0.12 : 0.22) * (0.5 + p[2]) * (0.6 + 0.5 * r.y);
            float d = length(f - ctr);
            float disc = 1.0 - smoothstep(R * 0.85, R, d);
            float rim = exp(-pow((d - R * 0.9) / (R * 0.1), 2.0)) * 0.4;
            float3 bc = mode == 0 ? mix(float3(1.0, 0.7, 0.3), float3(1.0, 0.9, 0.6), r.x)
                      : (mode == 1 ? kit_hue(r.x) * 0.7 + 0.3 : (mode == 2 ? float3(1.0, 0.92, 0.7) : mix(float3(0.4, 0.7, 1.0), float3(0.75, 0.9, 1.0), r.x)));
            float pulse = 0.7 + 0.3 * sin(ctx.time * (1.0 + r.x) + r.y * 6.0);
            col = kit_screen(col, bc * (disc * 0.35 + rim) * pulse * p[0] * (L == 0 ? 1.0 : 0.7));
        }
        return float4(saturate(col), o.a);
    }
    """)

    /// Frames and borders. p: size · c: mode (0 letterbox, 1 white border, 2 polaroid, 3 film strip, 4 rounded
    /// corners, 5 camera viewfinder, 6 binoculars, 7 vintage projector), target ratio (letterbox), colour rgb.
    static let frame = FXBase("frame", params: [FXKit.size(0.5)], symbol: "rectangle.inset.filled", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 1;
        int mode = int(c[0] + 0.5);
        float3 fc = float3(c[2], c[3], c[4]);
        float2 asp = float2(ctx.aspect, 1.0);
        float px = 1.5 / ctx.size.y;
        if (mode == 0) {
            float bar = max(0.0, (1.0 - ctx.aspect / c[1]) * 0.5) * (0.6 + 0.8 * p[0]);
            bar *= smoothstep(0.0, 0.6, ctx.time);
            float4 o = src.sample(s, uv);
            float m = step(uv.y, bar) + step(1.0 - bar, uv.y);
            return float4(mix(o.rgb, fc, saturate(m)), o.a);
        }
        if (mode == 1 || mode == 2) {
            float b = 0.02 + p[0] * 0.06;
            float bottom = mode == 2 ? b * 3.2 : b;
            float2 lo = float2(b / ctx.aspect, b), hi = float2(1.0 - b / ctx.aspect, 1.0 - bottom);
            float2 u = (uv - lo) / (hi - lo);
            float2 cq = (uv - (lo + hi) * 0.5) * asp;
            float2 half_ = (hi - lo) * 0.5 * asp;
            float rr = mode == 1 ? 0.03 : 0.004;
            float inside = 1.0 - smoothstep(-px, px, kit_sdBox(cq, half_ - rr) - rr);
            float4 o = src.sample(s, u);
            float3 paper = fc * (0.97 + 0.03 * kit_noise(uv * ctx.size / 4.0));
            float shadow = (1.0 - smoothstep(0.0, 0.015, kit_sdBox(cq, half_))) * 0.15;
            return float4(mix(paper * (1.0 - shadow * (1.0 - inside)), o.rgb, inside), 1.0);
        }
        if (mode == 3) {
            float band = 0.07 + p[0] * 0.06;
            float4 o = src.sample(s, float2(uv.x, (uv.y - band) / (1.0 - 2.0 * band)));
            float inBand = step(uv.y, band) + step(1.0 - band, uv.y);
            float hole = 0.0;
            float yy = uv.y < 0.5 ? uv.y : 1.0 - uv.y;
            float2 h = float2(fract(uv.x * ctx.aspect * 9.0 + ctx.time * 0.8) - 0.5, (yy - band * 0.5) * 9.0);
            hole = 1.0 - smoothstep(-0.02, 0.02, kit_sdBox(h, float2(0.22, band * 1.6)) - 0.06);
            float3 film = mix(float3(0.05, 0.04, 0.03), float3(0.93, 0.9, 0.85), hole);
            float3 col = mix(o.rgb, film, saturate(inBand));
            return float4(col, 1.0);
        }
        if (mode == 4) {
            float r = 0.04 + p[0] * 0.12;
            float2 cq = (uv - 0.5) * asp;
            float d = kit_sdBox(cq, float2(ctx.aspect * 0.5, 0.5) - r) - r;
            float4 o = src.sample(s, uv);
            float m = 1.0 - smoothstep(-px, px, d);
            return float4(o.rgb, o.a * m);
        }
        if (mode == 5) {
            float4 o = src.sample(s, uv);
            float3 col = o.rgb;
            float2 cq = (uv - 0.5) * asp;
            float2 b = float2(ctx.aspect * 0.5, 0.5) - 0.06;
            float2 a = abs(cq);
            float th = 0.004 + 0.003 * p[0];
            float corner = (step(abs(a.x - b.x), th) * step(b.y - 0.08, a.y) * step(a.y, b.y + th))
                         + (step(abs(a.y - b.y), th) * step(b.x - 0.08, a.x) * step(a.x, b.x + th));
            float cross_ = (step(abs(cq.x), th * 0.6) * step(abs(cq.y), 0.035)) + (step(abs(cq.y), th * 0.6) * step(abs(cq.x), 0.035));
            col = mix(col, float3(1.0), saturate(corner + cross_ * 0.8));
            float2 dotC = float2(-b.x + 0.06, -b.y + 0.06);
            float blink = step(0.5, fract(ctx.time * 0.8));
            col = mix(col, float3(1.0, 0.15, 0.1), (1.0 - smoothstep(0.016, 0.02, length(cq - dotC))) * blink);
            float2 bat = cq - float2(b.x - 0.1, -b.y + 0.06);
            float batO = step(kit_sdBox(bat, float2(0.04, 0.016)), 0.0) - step(kit_sdBox(bat, float2(0.034, 0.011)), 0.0);
            float batF = step(kit_sdBox(bat - float2(0.008, 0.0), float2(0.02, 0.008)), 0.0);
            col = mix(col, float3(1.0), saturate(batO + batF));
            col *= 1.0 - 0.25 * smoothstep(0.45, 0.9, length(cq) / max(ctx.aspect * 0.5, 0.5));
            return float4(col, o.a);
        }
        if (mode == 6) {
            float2 cq = (uv - 0.5) * asp;
            float r = 0.36 + 0.1 * p[0];
            float d = min(length(cq - float2(-r * 0.62, 0.0)), length(cq - float2(r * 0.62, 0.0))) - r;
            float4 o = src.sample(s, 0.5 + (uv - 0.5) / 1.15);
            float m = 1.0 - smoothstep(-0.01, 0.01, d);
            float vig = 1.0 - smoothstep(-0.12, 0.0, d) * 0.5;
            return float4(o.rgb * m * vig, o.a);
        }
        float2 cq = (uv - 0.5) * asp;
        float rr = 0.12 + 0.1 * p[0];
        float d = kit_sdBox(cq, float2(ctx.aspect * 0.5, 0.5) - rr - 0.03) - rr;
        float4 o = src.sample(s, uv);
        float m = 1.0 - smoothstep(-0.06, 0.03, d);
        float flick = 0.95 + 0.05 * kit_h11(floor(ctx.time * 18.0));
        float3 col = o.rgb * m * flick * float3(1.02, 1.0, 0.94);
        return float4(col, o.a);
    }
    """)

    /// Outline / neon stroke around the layer's alpha (cut-outs, stickers, text). p: size · c: mode (0 solid,
    /// 1 neon glow, 2 rainbow, 3 double), colour rgb.
    static let outline = FXBase("outline", params: [FXKit.size(0.4)], symbol: "person.crop.square", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 1;
        float4 o = src.sample(s, uv);
        int mode = int(c[0] + 0.5);
        float rad = (3.0 + p[0] * 14.0) * ctx.size.y / 1080.0;
        float a1 = 0.0, a2 = 0.0, a3 = 0.0;
        for (int i = 0; i < 16; i++) {
            float ang = float(i) / 16.0 * 6.28318;
            float2 d = float2(cos(ang), sin(ang)) / ctx.size;
            a1 = max(a1, src.sample(s, uv + d * rad).a);
            a2 = max(a2, src.sample(s, uv + d * rad * 0.5).a);
            a3 = max(a3, src.sample(s, uv + d * rad * 2.0).a);
        }
        float dil = max(a1, a2);
        float3 sc = float3(c[1], c[2], c[3]);
        if (mode == 2) sc = kit_hue(fract(atan2(uv.y - 0.5, uv.x - 0.5) * 0.159 + ctx.time * 0.4));
        float stroke = saturate(dil - o.a);
        float3 col = sc; float sa = stroke;
        if (mode == 1) { sa = saturate(stroke + (a3 - dil) * 0.5); col = sc * (1.0 + stroke * 0.6); }
        if (mode == 3) {
            float inner = saturate(a2 - o.a);
            float outer = saturate(a3 - a1) * 0.9;
            col = mix(float3(1.0), sc, step(inner, 0.01));
            sa = saturate(inner + outer + saturate(a1 - a2) * 0.0);
        }
        float outA = max(o.a, sa);
        float3 rgb = (o.rgb * o.a + col * sa * (1.0 - o.a)) / max(outA, 1e-4);
        return float4(saturate(rgb), outA);
    }
    """)

    /// Aura glow behind the subject (two passes, uses the original). p: intensity, size · c: colour rgb, fire flicker.
    static let aura = FXBase("aura", params: [FXKit.intensity(0.8), FXKit.size(0.5)], passes: 2, inputs: [.original], symbol: "person.and.background.dotted", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx, texture2d<float> orig) {
        constant float* c = p + 2;
        float stepPx = (2.0 + p[1] * 7.0) * ctx.size.y / 1080.0;
        if (ctx.pass == 0) {
            float a = kit_blur17(src, s, uv, float2(stepPx / ctx.size.x, 0.0)).a;
            return float4(a, a, a, 1.0);
        }
        float g = kit_blur17(src, s, uv, float2(0.0, stepPx / ctx.size.y)).r;
        float4 o = orig.sample(s, uv);
        float3 ac = float3(c[0], c[1], c[2]);
        if (c[3] > 0.5) {
            float n = kit_fbm(uv * float2(ctx.aspect, 1.0) * 6.0 + float2(0.0, ctx.time * 1.5));
            g *= 0.6 + 0.8 * n;
            ac = mix(ac, float3(1.0, 0.9, 0.4), n * 0.6);
        }
        float ga = saturate(g * 2.8 * p[0]) * (1.0 - o.a);
        float outA = max(o.a, ga);
        float3 rgb = (o.rgb * o.a + ac * ga) / max(outA, 1e-4);
        return float4(saturate(rgb), outA);
    }
    """)

    /// Shadow / clones / afterimage of the subject. p: amount, speed · c: mode (0 drop shadow, 1 colour clones,
    /// 2 afterimage).
    static let clones = FXBase("clones", params: [FXKit.amount(0.6), FXKit.speed(0.5)], symbol: "person.2", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 2;
        float4 o = src.sample(s, uv);
        int mode = int(c[0] + 0.5);
        float t = ctx.time * (0.5 + p[1] * 3.0);
        float3 acc = 0.0; float aacc = 0.0;
        if (mode == 0) {
            float2 off = float2(0.025, 0.03) * p[0];
            float sa = 0.0;
            for (int i = 0; i < 5; i++) { sa += src.sample(s, uv - off + float2(float(i) - 2.0, 0.0) * 0.003).a; }
            aacc = sa / 5.0 * 0.6; acc = float3(0.0);
        } else {
            for (int i = 1; i <= 3; i++) {
                float fi = float(i);
                float2 off = mode == 1 ? float2(fi * 0.09 * p[0] * (fmod(fi, 2.0) > 0.5 ? 1.0 : -1.0), 0.0)
                                       : float2(sin(t - fi * 0.6), cos(t * 0.8 - fi * 0.6)) * 0.03 * p[0] * fi;
                float4 cs = src.sample(s, uv - off);
                float3 tint = mode == 1 ? kit_hue(fi * 0.3 + 0.55) : (fi == 1.0 ? float3(1, 0.3, 0.5) : (fi == 2.0 ? float3(0.3, 0.8, 1) : float3(0.6, 0.4, 1)));
                float w = cs.a * (mode == 1 ? 0.85 : 0.55 / fi);
                acc = acc * (1.0 - w) + mix(cs.rgb, tint, mode == 1 ? 0.55 : 0.75) * w;
                aacc = aacc + w * (1.0 - aacc);
            }
        }
        float outA = max(o.a, aacc);
        float3 rgb = (o.rgb * o.a + acc * aacc * (1.0 - o.a)) / max(outA, 1e-4);
        return float4(saturate(rgb), outA);
    }
    """)

    static let all: [EffectDescriptor] = [
        particles.preset("snow", group: "nature", [0, 0.05, 0.35, 1.0, 1, 1, 1, 0, 0.18, 0.3], tags: ["winter", "christmas", "flakes"]),
        particles.preset("blizzard", group: "nature", [0, 0.5, 0.8, 1.5, 1, 1, 1, 0, 0.12, 0.2], defaults: ["density": 0.9, "speed": 0.8], tags: ["snow", "storm", "winter"]),
        particles.preset("lightSnow", group: "nature", [0, 0.02, 0.18, 1.0, 1, 1, 1, 0, 0.135, 0.4], defaults: ["density": 0.3], tags: ["snow", "gentle"]),
        particles.preset("rain", group: "nature", [1, 0.08, 1.6, 0, 0.75, 0.82, 0.92, 0, 0.27, 0], defaults: ["density": 0.7], tags: ["weather", "drops", "storm"]),
        particles.preset("heavyRain", group: "nature", [1, 0.15, 2.4, 0, 0.7, 0.78, 0.9, 0, 0.33, 0], defaults: ["density": 1.0, "speed": 0.8], tags: ["storm", "weather"]),
        particles.preset("confetti", group: "party", [2, 0.0, 0.35, 1.5, 1, 1, 1, 1, 0.21, 0], defaults: ["density": 0.7], tags: ["celebration", "birthday", "party"]),
        particles.preset("hearts", group: "bling", [3, 0.0, -0.18, 1.2, 1.0, 0.25, 0.4, 2, 0.24, 0], defaults: ["density": 0.4], tags: ["love", "valentine", "romance"]),
        particles.preset("loveRain", group: "bling", [3, 0.0, 0.3, 0.8, 1.0, 0.2, 0.3, 0, 0.18, 0], defaults: ["density": 0.7], tags: ["love", "hearts", "valentine"]),
        particles.preset("petals", group: "nature", [4, 0.25, 0.3, 1.5, 1, 0.7, 0.8, 2, 0.21, 0], defaults: ["density": 0.5], tags: ["sakura", "flowers", "spring"]),
        particles.preset("bubbles", group: "nature", [5, 0.0, -0.22, 1.0, 1, 1, 1, 0, 0.3, 0], defaults: ["density": 0.4], tags: ["soap", "float"]),
        particles.preset("fallingStars", group: "bling", [6, 0.05, 0.25, 0.8, 1.0, 0.88, 0.45, 0, 0.195, 1.0], defaults: ["density": 0.45], tags: ["stars", "magic"]),
        particles.preset("embers", group: "nature", [7, 0.05, -0.25, 1.5, 1, 0.5, 0.1, 4, 0.18, 1.0], defaults: ["density": 0.6], tags: ["fire", "sparks", "campfire"]),
        particles.preset("autumnLeaves", group: "nature", [8, 0.3, 0.35, 2.0, 1, 0.5, 0.1, 3, 0.27, 0], defaults: ["density": 0.45], tags: ["fall", "leaves"]),
        fireworks.preset("fireworks", group: "party", [0], tags: ["celebration", "new year", "4th of july"]),
        fireworks.preset("goldFireworks", group: "party", [1], tags: ["celebration", "gold"]),
        stars.preset("starrySky", group: "nature", [0.6, 0], tags: ["night", "stars"]),
        stars.preset("shootingStars", group: "nature", [0.5, 1], tags: ["meteor", "night", "wish"]),
        fog.preset("fog", group: "nature", [0.86, 0.88, 0.9, 0.3, 1.5], tags: ["mist", "haze", "weather"]),
        fog.preset("groundMist", group: "nature", [0.9, 0.92, 0.95, 1.0, 2.0], tags: ["mist", "low fog"]),
        fog.preset("smoke", group: "nature", [0.25, 0.25, 0.27, 0.6, 2.5], defaults: ["amount": 0.7], tags: ["dark", "fire"]),
        sparkle.preset("sparkle", group: "bling", [0, 0, 0], tags: ["shine", "twinkle", "glint"]),
        sparkle.preset("glitter", group: "bling", [2, 0, 2], defaults: ["density": 0.8], tags: ["shine", "dots"]),
        sparkle.preset("starTwinkle", group: "bling", [1, 0, 1], defaults: ["density": 0.4], tags: ["stars", "twinkle"]),
        sparkle.preset("diamond", group: "bling", [0, 1, 0], defaults: ["density": 0.9, "size": 0.6], tags: ["highlights", "bling", "jewel"]),
        sparkle.preset("goldDust", group: "bling", [1, 0, 2], defaults: ["density": 0.9], tags: ["gold", "glitter"]),
        sparkle.preset("rainbowSparkle", group: "bling", [2, 0, 0], tags: ["rainbow", "shine"]),
        sparkle.preset("pinkSparkle", group: "bling", [3, 0, 0], tags: ["pink", "cute"]),
        bokeh.preset("bokehLights", group: "bling", [0, 0.0], tags: ["bokeh", "lights", "christmas"]),
        bokeh.preset("fairyLights", group: "bling", [2, 0.0], defaults: ["intensity": 0.8], tags: ["string lights", "warm"]),
        bokeh.preset("colorBokeh", group: "bling", [1, 0.15], tags: ["bokeh", "party", "colour"]),
        bokeh.preset("coolBokeh", group: "bling", [3, 0.1], tags: ["bokeh", "blue", "winter"]),
        frame.preset("cinemaBars", group: "frame", [0, 2.39, 0, 0, 0], tags: ["letterbox", "movie", "widescreen", "cinematic"]),
        frame.preset("widescreen", group: "frame", [0, 2.0, 0, 0, 0], defaults: ["size": 0.6], tags: ["letterbox", "bars"]),
        frame.preset("whiteBorder", group: "frame", [1, 0, 0.98, 0.98, 0.97], tags: ["border", "frame"]),
        frame.preset("instantFrame", group: "frame", [2, 0, 0.97, 0.96, 0.93], tags: ["instant", "photo", "polaroid", "frame"]),
        frame.preset("filmStrip", group: "frame", [3, 0, 0, 0, 0], tags: ["film", "sprockets", "negative"]),
        frame.preset("roundedCorners", group: "frame", [4, 0, 0, 0, 0], tags: ["corners", "rounded"]),
        frame.preset("viewfinder", group: "frame", [5, 0, 1, 1, 1], tags: ["rec", "camera", "camcorder", "recording"]),
        frame.preset("binoculars", group: "frame", [6, 0, 0, 0, 0], tags: ["spy", "look"]),
        frame.preset("projector", group: "frame", [7, 0, 0, 0, 0], tags: ["vintage", "cinema", "film"]),
        outline.preset("outline", group: "body", [0, 1, 1, 1], tags: ["stroke", "sticker", "cutout"]),
        outline.preset("neonOutline", group: "body", [1, 1.0, 0.25, 0.8], defaults: ["size": 0.5], tags: ["neon", "glow", "stroke"]),
        outline.preset("rainbowOutline", group: "body", [2, 1, 1, 1], tags: ["rainbow", "stroke"]),
        outline.preset("doubleOutline", group: "body", [3, 0.2, 0.6, 1.0], tags: ["stroke", "sticker"]),
        aura.preset("aura", group: "body", [1.0, 0.85, 0.4, 0], tags: ["glow", "halo", "gold"]),
        aura.preset("fireAura", group: "body", [1.0, 0.35, 0.05, 1], defaults: ["size": 0.7], tags: ["flames", "fire", "hero"]),
        aura.preset("iceAura", group: "body", [0.4, 0.75, 1.0, 0], tags: ["glow", "blue", "frozen"]),
        clones.preset("dropShadow", group: "body", [0], tags: ["shadow", "sticker"]),
        clones.preset("clones", group: "body", [1], tags: ["copies", "multiply"]),
        clones.preset("afterimage", group: "body", [2], tags: ["trail", "ghost", "echo"]),
    ]
}
