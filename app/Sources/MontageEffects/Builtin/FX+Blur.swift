import MontageCore

/// Effects library — blur, lens and camera-motion bases (FX-009).
enum FXBlur {
    /// Directional (motion) blur. p: amount, angle · c: length (canvas heights), wobble.
    static let directional = FXBase("directional", params: [FXKit.amount(0.6), FXKit.angle(0)], symbol: "wind", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 2;
        float a = p[1] * 0.0174533 + c[1] * sin(ctx.time * 2.7) * 0.35;
        float2 dir = float2(cos(a), sin(a)) * (p[0] * c[0]) / float2(ctx.aspect, 1.0);
        float j = kit_h21(uv * ctx.size) / 15.0;
        float4 acc = 0.0;
        for (int i = 0; i < 16; i++) { acc += src.sample(s, uv + dir * (float(i) / 15.0 + j - 0.5)); }
        return acc / 16.0;
    }
    """)

    /// Radial zoom blur around a point. p: amount, x, y · c: strength, pulse rate (0 = static).
    static let zoom = FXBase("zoomBlur", params: [FXKit.amount(0.5), FXKit.posX(), FXKit.posY()], symbol: "scope", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 3;
        float2 ctr = float2(p[1], p[2]);
        float pulse = c[1] > 0.0 ? pow(1.0 - fract(ctx.time * c[1]), 2.0) : 1.0;
        float k = p[0] * c[0] * pulse;
        float j = kit_h21(uv * ctx.size);
        float4 acc = 0.0;
        for (int i = 0; i < 20; i++) {
            float t = (float(i) + j) / 20.0;
            acc += src.sample(s, ctr + (uv - ctr) * (1.0 - k * t));
        }
        return acc / 20.0;
    }
    """)

    /// Rotational blur around the centre. p: amount · c: max angle (rad), spin speed.
    static let spin = FXBase("spinBlur", params: [FXKit.amount(0.5)], symbol: "arrow.clockwise.circle", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 1;
        float2 q = kit_centered(uv, ctx);
        float ang = p[0] * c[0] * (c[1] > 0.0 ? 0.55 + 0.45 * sin(ctx.time * c[1] * 3.0) : 1.0);
        float j = kit_h21(uv * ctx.size);
        float base = 0.0;
        float4 acc = 0.0;
        for (int i = 0; i < 20; i++) {
            float t = ((float(i) + j) / 20.0 - 0.5) * ang + base;
            acc += src.sample(s, kit_uncentered(kit_rot(t) * q, ctx));
        }
        return acc / 20.0;
    }
    """)

    /// Tilt-shift: sharp horizontal band, blur above/below. p: amount, y, range · c: saturation, contrast.
    static let tiltShift = FXBase("tiltShift", params: [FXKit.amount(0.7), FXKit.posY(0.55), FXKit.range(0.3)], symbol: "camera.aperture", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 3;
        float d = abs(uv.y - p[1]);
        float k = smoothstep(p[2] * 0.25, p[2] * 0.25 + 0.25, d);
        float rad = k * p[0] * 0.022;
        float4 acc = src.sample(s, uv);
        float wsum = 1.0;
        float j = kit_h21(uv * ctx.size) * 6.28318;
        for (int i = 1; i < 24; i++) {
            float fi = float(i);
            float a = fi * 2.39996 + j;
            float r = sqrt(fi / 23.0) * rad;
            acc += src.sample(s, uv + float2(cos(a), sin(a)) * r / float2(ctx.aspect, 1.0));
            wsum += 1.0;
        }
        float4 o = acc / wsum;
        o.rgb = kit_sat(o.rgb, c[0]);
        o.rgb = (o.rgb - 0.5) * c[1] + 0.5;
        return float4(saturate(o.rgb), o.a);
    }
    """)

    /// Lens defocus with bokeh highlights (golden-angle disc). p: amount · c: highlight boost, edge-only mode, max radius.
    static let defocus = FXBase("defocus", params: [FXKit.amount(0.6)], symbol: "circle.hexagongrid", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 1;
        float edge = c[1] > 0.5 ? smoothstep(0.12, 0.62, length(kit_centered(uv, ctx)) / max(ctx.aspect * 0.5, 0.5) * 0.9) : 1.0;
        float rad = p[0] * c[2] * edge;
        float j = kit_h21(uv * ctx.size) * 6.28318;
        float4 acc = 0.0; float wsum = 0.0;
        for (int i = 0; i < 32; i++) {
            float fi = float(i) + 0.5;
            float a = fi * 2.39996 + j;
            float r = sqrt(fi / 32.0) * rad;
            float4 t = src.sample(s, uv + float2(cos(a), sin(a)) * r / float2(ctx.aspect, 1.0));
            float l = fx_luma(t.rgb);
            float w = 1.0 + c[0] * 12.0 * pow(saturate(l), 6.0);
            acc += t * w; wsum += w;
        }
        return acc / wsum;
    }
    """)

    /// Unsharp mask. p: amount · c: radius (px at 1080p).
    static let sharpen = FXBase("sharpen", params: [FXKit.amount(0.5)], symbol: "triangle", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 1;
        float2 d = max(1.0, c[0] * ctx.size.y / 1080.0) / ctx.size;
        float4 o = src.sample(s, uv);
        float4 b = (src.sample(s, uv + float2(d.x, 0)) + src.sample(s, uv - float2(d.x, 0))
                  + src.sample(s, uv + float2(0, d.y)) + src.sample(s, uv - float2(0, d.y))) * 0.25;
        return float4(saturate(o.rgb + (o.rgb - b.rgb) * p[0] * 3.0), o.a);
    }
    """)

    // MARK: Lens

    /// Barrel / pincushion / fisheye. p: amount · c: direction (+1 barrel, −1 pincushion), round lens mask, zoom.
    static let lens = FXBase("lensWarp", params: [FXKit.amount(0.6)], symbol: "circle.circle", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 1;
        float2 q = kit_centered(uv, ctx);
        float norm = 0.5 * sqrt(ctx.aspect * ctx.aspect + 1.0);
        float r = length(q) / norm;
        float k = p[0] * c[0] * 0.7;
        float2 qs = q * (1.0 - k * (1.0 - r * r)) / c[2];
        float4 o = src.sample(s, kit_mirror(kit_uncentered(qs, ctx)));
        if (c[1] > 0.5) {
            float rr = length(q);
            float m = 1.0 - smoothstep(0.46, 0.48, rr);
            o.rgb *= m * (1.0 - 0.45 * smoothstep(0.25, 0.47, rr));
        }
        return o;
    }
    """)

    /// Vignette with colour, size and roundness. p: amount, size · c: rgb, roundness (1 = circle), feather.
    static let vignette = FXBase("vignettePlus", params: [FXKit.amount(0.7), FXKit.size(0.5)], symbol: "circle.dashed", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 2;
        float4 o = src.sample(s, uv);
        float2 q = uv - 0.5;
        q = mix(q * 1.41, q * float2(ctx.aspect, 1.0) * 1.2, c[3]);
        float r = length(q);
        float inner = mix(0.85, 0.15, p[1]);
        float v = smoothstep(inner, inner + c[4], r);
        o.rgb = mix(o.rgb, float3(c[0], c[1], c[2]), v * p[0]);
        return o;
    }
    """)

    // MARK: Motion

    /// Camera shake. p: intensity, speed · c: translate, rotate (rad), zoom, frequency (Hz), stepped (0/1).
    static let shake = FXBase("shake", params: [FXKit.intensity(0.6), FXKit.speed(0.5)], symbol: "iphone.radiowaves.left.and.right", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 2;
        float f = c[3] * (0.3 + p[1] * 1.4);
        float t = ctx.time * f;
        float2 off; float rot; float z;
        if (c[4] > 0.5) {
            float st = floor(ctx.time * (12.0 + 24.0 * p[1]));
            off = (kit_h22(float2(st, 3.1)) - 0.5) * 2.0;
            rot = (kit_h11(st * 1.7) - 0.5) * 2.0;
            z = kit_h11(st * 3.3);
        } else {
            off = float2(kit_noise(float2(t, 1.3)), kit_noise(float2(t, 7.9))) * 2.0 - 1.0;
            off += (float2(kit_noise(float2(t * 3.1, 4.4)), kit_noise(float2(t * 3.1, 9.2))) * 2.0 - 1.0) * 0.35;
            rot = kit_noise(float2(t * 0.8, 4.1)) * 2.0 - 1.0;
            z = kit_noise(float2(t * 0.6, 12.0));
        }
        float amp = c[0] * p[0];
        float zoom = 1.0 + amp * 2.2 + c[2] * p[0] * z + abs(c[1] * p[0]) * 0.5;
        float2 q = kit_centered(uv, ctx);
        q = kit_rot(rot * c[1] * p[0]) * q / zoom + off * amp;
        return src.sample(s, kit_mirror(kit_uncentered(q, ctx)));
    }
    """)

    /// Zoom pulse / Ken Burns. p: intensity, speed · c: mode (0 beat pulse, 1 slow zoom in, 2 slow zoom out, 3 punch), amplitude.
    static let zoomPulse = FXBase("zoomPulse", params: [FXKit.intensity(0.6), FXKit.speed(0.5)], symbol: "plus.magnifyingglass", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 2;
        float period = 1.0 / (0.5 + p[1] * 2.5);
        float ph = fract(ctx.time / period);
        float k;
        int mode = int(c[0] + 0.5);
        if (mode == 0) { k = pow(1.0 - ph, 3.0); }
        else if (mode == 1) { k = saturate(ctx.time / (8.0 - 6.0 * p[1])); k = k * k * (3.0 - 2.0 * k); }
        else if (mode == 2) { k = 1.0 - saturate(ctx.time / (8.0 - 6.0 * p[1])); k = k * k * (3.0 - 2.0 * k); }
        else { k = ph < 0.12 ? smoothstep(0.0, 0.12, ph) : exp(-(ph - 0.12) * 5.0); }
        float scale = 1.0 + c[1] * p[0] * k;
        float2 suv = 0.5 + (uv - 0.5) / scale;
        float4 o = src.sample(s, suv);
        if (mode == 3) {   // punch: a touch of radial blur at the peak
            float4 acc = o;
            for (int i = 1; i < 6; i++) { acc += src.sample(s, 0.5 + (suv - 0.5) * (1.0 - 0.012 * float(i) * k * p[0])); }
            o = acc / 6.0;
        }
        return o;
    }
    """)

    /// Swing / sway / bounce / spin. p: intensity, speed · c: amplitude, mode (0 rotate, 1 sway x, 2 bounce y, 3 spin).
    static let swing = FXBase("swing", params: [FXKit.intensity(0.6), FXKit.speed(0.5)], symbol: "metronome", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 2;
        float w = (0.4 + p[1] * 1.6) * 6.28318;
        float t = ctx.time * w;
        float2 q = kit_centered(uv, ctx);
        int mode = int(c[1] + 0.5);
        float a = c[0] * p[0];
        if (mode == 0) { q = kit_rot(sin(t) * a) * q / (1.0 + a * 0.9); }
        else if (mode == 1) { q.x += sin(t) * a * 0.25; q /= 1.0 + a * 0.5; }
        else if (mode == 2) { q.y += -abs(sin(t * 0.5)) * a * 0.18 + a * 0.09; q /= 1.0 + a * 0.4; }
        else { q = kit_rot(ctx.time * w * 0.25 * a) * q / (1.0 + 0.8 * min(a, 1.0)); }
        return src.sample(s, kit_mirror(kit_uncentered(q, ctx)));
    }
    """)

    /// Endless scroll. p: speed · c: direction x, y.
    static let scroll = FXBase("scroll", params: [FXKit.speed(0.5)], symbol: "arrow.up.and.down", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 1;
        float2 o = float2(c[0], c[1]) * ctx.time * (0.1 + p[0] * 0.9);
        float2 u = fract(uv + o);
        return src.sample(s, u);
    }
    """)

    /// Spatial echo: ghost copies. p: amount, speed · c: mode (0 offset ghosts, 1 zoom echo, 2 RGB echo), copies.
    static let echo = FXBase("echo", params: [FXKit.amount(0.6), FXKit.speed(0.5)], symbol: "square.stack.3d.down.right", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 2;
        float4 base = src.sample(s, uv);
        int mode = int(c[0] + 0.5);
        float t = ctx.time * (0.5 + p[1] * 2.5);
        float3 acc = base.rgb; float wsum = 1.0;
        int n = int(c[1]);
        for (int i = 1; i <= 4; i++) {
            if (i > n) break;
            float fi = float(i);
            float w = 0.55 / fi;
            if (mode == 0) {
                float2 off = float2(sin(t + fi), cos(t * 0.7 + fi * 1.3)) * 0.03 * p[0] * fi;
                acc += src.sample(s, uv + off).rgb * w; wsum += w;
            } else if (mode == 1) {
                float z = 1.0 + 0.06 * p[0] * fi * (0.6 + 0.4 * sin(t));
                acc += src.sample(s, 0.5 + (uv - 0.5) / z).rgb * w; wsum += w;
            } else {
                float2 off = float2(sin(t * 1.3), 0.0) * 0.025 * p[0] * fi;
                float3 tint = fi == 1.0 ? float3(1, 0.2, 0.3) : (fi == 2.0 ? float3(0.2, 1, 0.4) : float3(0.3, 0.4, 1));
                acc += src.sample(s, uv + off).rgb * tint * w; wsum += w * 0.45;
            }
        }
        return float4(saturate(acc / wsum), base.a);
    }
    """)

    static let all: [EffectDescriptor] = [
        directional.preset("motionBlur", group: "blur", [0.08, 0], tags: ["motion", "speed"]),
        directional.preset("verticalBlur", group: "blur", [0.08, 0], defaults: ["angle": 90]),
        directional.preset("swayBlur", group: "blur", [0.06, 1], defaults: ["angle": 20], tags: ["wobble"]),
        zoom.preset("zoomBlur", group: "blur", [0.25, 0], tags: ["radial", "speed"]),
        zoom.preset("radialBurst", group: "blur", [0.5, 0], defaults: ["amount": 0.7]),
        zoom.preset("zoomBeat", group: "motion", [0.35, 1.5], tags: ["beat", "pulse"]),
        spin.preset("spinBlur", group: "blur", [0.35, 0], tags: ["rotate", "radial"]),
        spin.preset("whirlBlur", group: "blur", [0.6, 0.8], defaults: ["amount": 0.6]),
        tiltShift.preset("tiltShift", group: "blur", [1.0, 1.0], tags: ["miniature", "focus"]),
        tiltShift.preset("miniature", group: "blur", [1.35, 1.12], defaults: ["amount": 0.9, "range": 0.2], tags: ["toy", "tilt"]),
        defocus.preset("defocus", group: "blur", [0.3, 0, 0.018], tags: ["lens", "out of focus"]),
        defocus.preset("bokehBlur", group: "blur", [1.0, 0, 0.026], defaults: ["amount": 0.8], tags: ["bokeh", "lens"]),
        defocus.preset("focusEdges", group: "blur", [0.4, 1, 0.03], tags: ["vignette", "dreamy"]),
        sharpen.preset("sharpen", group: "basic", [1.0], tags: ["detail", "crisp"]),
        sharpen.preset("detail", group: "basic", [2.5], defaults: ["amount": 0.4], tags: ["clarity", "crisp"]),

        lens.preset("fisheye", group: "lens", [1, 1, 0.92], defaults: ["amount": 0.8], tags: ["gopro", "round"]),
        lens.preset("barrel", group: "lens", [1, 0, 1], tags: ["bulge", "wide"]),
        lens.preset("pincushion", group: "lens", [-1, 0, 1.02], tags: ["pinch"]),
        vignette.preset("darkVignette", group: "lens", [0, 0, 0, 0, 0.55], defaults: ["amount": 0.85], tags: ["vignette", "dark"]),
        vignette.preset("whiteVignette", group: "lens", [1, 1, 1, 0, 0.5], defaults: ["amount": 0.75], tags: ["vignette", "bright", "dreamy"]),
        vignette.preset("spotlight", group: "lens", [0, 0, 0, 1, 0.18], defaults: ["amount": 0.92, "size": 0.62], tags: ["focus", "circle"]),
        vignette.preset("blueVignette", group: "lens", [0.05, 0.12, 0.45, 0, 0.6], defaults: ["amount": 0.7], tags: ["vignette", "colour"]),

        shake.preset("shake", group: "motion", [0.012, 0.02, 0.02, 4, 0], tags: ["camera", "handheld"]),
        shake.preset("earthquake", group: "motion", [0.03, 0.05, 0.05, 7, 0], defaults: ["intensity": 0.8], tags: ["shake", "strong"]),
        shake.preset("handheld", group: "motion", [0.006, 0.012, 0.02, 1.2, 0], tags: ["camera", "shake", "vlog"]),
        shake.preset("vibrate", group: "motion", [0.008, 0.0, 0.0, 1, 1], tags: ["shake", "buzz"]),
        shake.preset("impact", group: "motion", [0.02, 0.04, 0.08, 1, 1], defaults: ["speed": 0.3], tags: ["shake", "hit"]),
        zoomPulse.preset("pulse", group: "motion", [0, 0.12], tags: ["beat", "zoom"]),
        zoomPulse.preset("beatZoom", group: "motion", [0, 0.2], defaults: ["speed": 0.8], tags: ["beat", "pulse"]),
        zoomPulse.preset("slowZoomIn", group: "motion", [1, 0.35], tags: ["ken burns", "zoom"]),
        zoomPulse.preset("slowZoomOut", group: "motion", [2, 0.35], tags: ["ken burns", "zoom"]),
        zoomPulse.preset("punchZoom", group: "motion", [3, 0.18], defaults: ["speed": 0.35], tags: ["impact", "zoom", "beat"]),
        swing.preset("swing", group: "motion", [0.12, 0], tags: ["rotate", "rock"]),
        swing.preset("sway", group: "motion", [0.25, 1], tags: ["side"]),
        swing.preset("bounce", group: "motion", [0.6, 2], tags: ["jump"]),
        swing.preset("spin", group: "motion", [1.0, 3], defaults: ["speed": 0.3], tags: ["rotate"]),
        scroll.preset("scrollUp", group: "motion", [0, 1], tags: ["loop", "slide"]),
        scroll.preset("scrollLeft", group: "motion", [1, 0], tags: ["loop", "slide"]),
        echo.preset("doubleVision", group: "motion", [0, 1], tags: ["ghost", "drunk"]),
        echo.preset("ghost", group: "motion", [0, 3], defaults: ["amount": 0.8, "speed": 0.3], tags: ["echo", "trail"]),
        echo.preset("zoomEcho", group: "motion", [1, 3], tags: ["echo"]),
        echo.preset("rgbEcho", group: "glitch", [2, 3], tags: ["rgb", "ghost"]),
    ]
}
