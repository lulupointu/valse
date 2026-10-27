import ValseCore

/// "Transitions" tab: ~120 two-input GPU transitions in CapCut's categories (W5, FEATURES TR-001/TR-006).
///
/// Every shader body runs inside
/// `float4 transition(float2 uv, texture2d<float> from, texture2d<float> to, sampler s, float progress, constant float* p, FXContext ctx)`
/// with `t` = progress ∈ [0,1], `e` = eased progress, `aspect` = canvas width / height and the helpers of
/// `TransitionShaderLib` (`FA/FB` = sample A/B, `GA/GB` = sample or transparent outside [0,1]², `MA/MB` = mirrored
/// sampling, `tr_sweep`, `tr_bump`, blurs, noise, ray–quad hits for 3D). `from`/`to` are the two layers already placed
/// on canvas-size textures (premultiplied), so linear mixing is correct.
///
/// Contract (tested for every entry, `TransitionRenderTests`): progress 0 renders exactly A, progress 1 exactly B, and
/// the midpoint differs from both. Keep each shader single-pass with a bounded tap count (real time at 1080p).
/// Ids are persisted in projects: never rename one; append new entries.
public enum BuiltinTransitions {
    /// One transition. `params` are exposed in the inspector (direction/colour/softness…, TR-006) and packed into `p[]`.
    static func t(_ name: String, _ group: String, _ symbol: String, params: [ParamSpec] = [], duration: Double = 0.5,
                  _ body: String) -> TransitionDescriptor {
        TransitionDescriptor(id: "valse.transition.\(name)", nameKey: "transition.\(name)",
                             groupKey: "transition.group.\(group)", params: params, defaultDuration: Time(duration),
                             symbol: symbol, shader: TransitionShaderLib.wrap(body))
    }

    // MARK: Parameter specs

    static func softness(_ d: Double = 0.15) -> ParamSpec { .scalar("softness", "tr.param.softness", 0, 1, d, display: 100) }
    static func intensity(_ d: Double = 0.6) -> ParamSpec { .scalar("intensity", "tr.param.intensity", 0, 1, d, display: 100) }
    static func strength(_ d: Double = 0.5) -> ParamSpec { .scalar("strength", "tr.param.strength", 0, 1, d, display: 100) }
    static func count(_ d: Double, _ lo: Double = 2, _ hi: Double = 40) -> ParamSpec { .scalar("count", "tr.param.count", lo, hi, d) }
    static func color(_ c: RGBA) -> ParamSpec { ParamSpec("color", nameKey: "tr.param.color", .color(defaultValue: c)) }

    // MARK: Direction helpers

    /// (suffix, unit vector the content moves along, SF Symbol).
    static let directions: [(String, String, String)] = [
        ("Left", "float2(-1.0, 0.0)", "arrow.left"), ("Right", "float2(1.0, 0.0)", "arrow.right"),
        ("Up", "float2(0.0, -1.0)", "arrow.up"), ("Down", "float2(0.0, 1.0)", "arrow.down"),
    ]

    /// Frame mapping for the 3D transitions, which are written once for "content moves left":
    /// (suffix, screen uv → frame w, face uv h → texture uv).
    static let frames3D: [(String, String, String)] = [
        ("Left", "uv", "h"), ("Right", "float2(1.0 - uv.x, uv.y)", "float2(1.0 - h.x, h.y)"),
        ("Up", "uv.yx", "h.yx"), ("Down", "float2(1.0 - uv.y, uv.x)", "float2(h.y, 1.0 - h.x)"),
    ]

    // MARK: Basic

    static let basic: [TransitionDescriptor] = [
        t("dissolve", "basic", "circle.lefthalf.filled", "return mix(FA(uv), FB(uv), t);"),
        t("blackFade", "basic", "moon.fill", """
            float4 a = FA(uv), b = FB(uv);
            float4 k = float4(0.0, 0.0, 0.0, 1.0);
            return t < 0.5 ? mix(a, k, t * 2.0) : mix(k, b, (t - 0.5) * 2.0);
            """),
        t("whiteFade", "basic", "sun.max.fill", """
            float4 a = FA(uv), b = FB(uv);
            float4 k = float4(1.0);
            return t < 0.5 ? mix(a, k, t * 2.0) : mix(k, b, (t - 0.5) * 2.0);
            """),
        t("colorFade", "basic", "paintpalette.fill", params: [color(RGBA(0.95, 0.42, 0.55))], """
            float4 a = FA(uv), b = FB(uv);
            float4 k = float4(p[0], p[1], p[2], 1.0);
            return t < 0.5 ? mix(a, k, tr_smooth(t * 2.0)) : mix(k, b, tr_smooth((t - 0.5) * 2.0));
            """),
        t("additiveDissolve", "basic", "plus.circle", """
            float4 a = FA(uv), b = FB(uv);
            return min(a * saturate(2.0 - 2.0 * t) + b * saturate(2.0 * t), float4(1.0));
            """),
        t("lumaDissolve", "basic", "circle.bottomhalf.filled", params: [softness(0.3)], """
            float4 a = FA(uv), b = FB(uv);
            float w = 0.05 + p[0] * 0.4;
            float th = mix(1.0 + w, -w, t);
            return mix(a, b, smoothstep(th - w, th, fx_luma(b.rgb)));
            """),
        t("filmDissolve", "basic", "film", """
            float4 a = FA(uv), b = FB(uv);
            if (t <= 0.0) return a;
            if (t >= 1.0) return b;
            float3 c = fx_to_display(mix(fx_to_linear(a.rgb), fx_to_linear(b.rgb), t));
            return float4(c, mix(a.a, b.a, t));
            """),
        t("noiseDissolve", "basic", "circle.dotted", params: [count(3, 1, 24)], """
            float n = fx_hash(floor(uv * ctx.size / max(p[0], 1.0)));
            return n < t ? FB(uv) : FA(uv);
            """),
        t("flash", "basic", "bolt.fill", params: [color(RGBA(1, 1, 1))], """
            float4 c = t < 0.5 ? FA(uv) : FB(uv);
            float f = pow(tr_bump(t), 3.0);
            return mix(c, float4(p[0], p[1], p[2], 1.0), f);
            """),
        t("dimDissolve", "basic", SFSymbolCompat.compat("circle.lefthalf.striped.horizontal"), """
            float4 c = mix(FA(uv), FB(uv), tr_smooth(t));
            c.rgb *= 1.0 - 0.65 * tr_bump(t);
            return c;
            """),
    ]

    // MARK: Camera

    static let camera: [TransitionDescriptor] = [
        t("zoomIn", "camera", "plus.magnifyingglass", """
            float2 za = (uv - 0.5) / (1.0 + e * 0.6) + 0.5;
            float2 zb = (uv - 0.5) / (1.6 - e * 0.6) + 0.5;
            return mix(FA(za), FB(zb), smoothstep(0.35, 0.65, t));
            """),
        t("zoomOut", "camera", "minus.magnifyingglass", """
            float2 za = (uv - 0.5) * (1.0 + e * 0.6) + 0.5;
            float2 zb = (uv - 0.5) * (1.0 - (1.0 - e) * 0.4) + 0.5;
            return mix(MA(za), MB(zb), smoothstep(0.35, 0.65, t));
            """),
        t("pullIn", "camera", "arrow.down.right.and.arrow.up.left", params: [strength(0.6)], """
            float k = p[0];
            float blur = 0.35 * k * tr_bump(t);
            float za = 1.0 + 2.5 * k * tr_ease(min(t * 2.0, 1.0));
            float zb = mix(0.55, 1.0, tr_ease(max(t * 2.0 - 1.0, 0.0)));
            float4 a = tr_zoomBlur(from, s, (uv - 0.5) / za + 0.5, blur, true);
            float4 b = tr_zoomBlur(to, s, (uv - 0.5) / zb + 0.5, blur, true);
            return mix(a, b, smoothstep(0.42, 0.58, t));
            """),
        t("pullOut", "camera", "arrow.up.left.and.arrow.down.right", params: [strength(0.6)], """
            float k = p[0];
            float blur = 0.35 * k * tr_bump(t);
            float za = mix(1.0, 0.55, tr_ease(min(t * 2.0, 1.0)));
            float zb = mix(1.0 + 2.5 * k, 1.0, tr_ease(max(t * 2.0 - 1.0, 0.0)));
            float4 a = tr_zoomBlur(from, s, (uv - 0.5) / za + 0.5, blur, true);
            float4 b = tr_zoomBlur(to, s, (uv - 0.5) / zb + 0.5, blur, true);
            return mix(a, b, smoothstep(0.42, 0.58, t));
            """),
        t("zoomSpin", "camera", "arrow.triangle.2.circlepath", """
            float2 q = tr_asp(uv, aspect);
            float za = 1.0 + 1.5 * tr_ease(min(t * 2.0, 1.0)), zb = mix(2.5, 1.0, tr_ease(max(t * 2.0 - 1.0, 0.0)));
            float2 qa = tr_rot(q, e * TR_PI) / za, qb = tr_rot(q, (e - 1.0) * TR_PI) / zb;
            return mix(MA(tr_unasp(qa, aspect)), MB(tr_unasp(qb, aspect)), smoothstep(0.4, 0.6, t));
            """),
        t("crossZoom", "camera", "scope", params: [strength(0.5)], """
            float k = p[0] * 0.8 * tr_bump(t);
            return mix(tr_zoomBlur(from, s, uv, k, false), tr_zoomBlur(to, s, uv, k, false), tr_ease(t));
            """),
        t("cameraShake", "camera", "camera.metering.unknown", params: [intensity(0.6)], """
            float amp = p[0] * 0.06 * tr_bump(t);
            float f = floor(t * 24.0);
            float2 off = float2(fx_hash(float2(f, 1.3)) - 0.5, fx_hash(float2(f, 7.1)) - 0.5) * amp * 2.0;
            float2 q = (uv - 0.5) / (1.0 + amp * 2.0) + 0.5 + off;
            return mix(MA(q), MB(q), smoothstep(0.45, 0.55, t));
            """),
        t("rotateCW", "camera", "rotate.right", """
            float2 q = tr_asp(uv, aspect);
            float z = 1.0 + 0.9 * tr_bump(t);
            float2 qa = tr_rot(q, -e * TR_PI * 0.5) / z, qb = tr_rot(q, (1.0 - e) * TR_PI * 0.5) / z;
            return mix(MA(tr_unasp(qa, aspect)), MB(tr_unasp(qb, aspect)), smoothstep(0.42, 0.58, t));
            """),
        t("rotateCCW", "camera", "rotate.left", """
            float2 q = tr_asp(uv, aspect);
            float z = 1.0 + 0.9 * tr_bump(t);
            float2 qa = tr_rot(q, e * TR_PI * 0.5) / z, qb = tr_rot(q, (e - 1.0) * TR_PI * 0.5) / z;
            return mix(MA(tr_unasp(qa, aspect)), MB(tr_unasp(qb, aspect)), smoothstep(0.42, 0.58, t));
            """),
        t("popIn", "camera", "bubble.left.and.bubble.right.fill", """
            float k = tr_backOut(t);
            float4 a = FA(uv) * (1.0 - smoothstep(0.5, 1.0, t));
            a.rgb *= 1.0 - 0.4 * saturate(t * 3.0);
            if (k < 1e-3) return t <= 0.0 ? FA(uv) : a;
            float4 b = GB((uv - 0.5) / k + 0.5);
            return b + a * (1.0 - b.a);
            """),
    ] + directions.map { name, d, sym in
        t("whip\(name)", "camera", sym, params: [strength(0.5)], """
            float2 d = \(d);
            float blur = (0.12 + 0.3 * p[0]) * tr_bump(t);
            float4 acc = float4(0.0);
            for (int i = 0; i < 9; i++) {
                float2 q = uv + d * blur * (float(i) / 8.0 - 0.5);
                float2 ua = q - d * e, ub = q - d * (e - 1.0);
                acc += tr_inside(ua) ? FA(ua) : FB(ub);
            }
            return acc / 9.0;
            """)
    }

    // MARK: Blur

    static let blur: [TransitionDescriptor] = [
        t("blurDissolve", "blur", "drop.fill", params: [strength(0.5)], """
            float r = p[0] * 0.07 * tr_bump(t);
            return mix(tr_blur(from, s, uv, r, aspect), tr_blur(to, s, uv, r, aspect), tr_smooth(t));
            """),
        t("blurHorizontal", "blur", "arrow.left.and.right", params: [strength(0.5)], """
            float2 d = float2(p[0] * 0.12 * tr_bump(t), 0.0);
            return mix(tr_blurDir(from, s, uv, d), tr_blurDir(to, s, uv, d), smoothstep(0.3, 0.7, t));
            """),
        t("blurVertical", "blur", "arrow.up.and.down", params: [strength(0.5)], """
            float2 d = float2(0.0, p[0] * 0.12 * tr_bump(t));
            return mix(tr_blurDir(from, s, uv, d), tr_blurDir(to, s, uv, d), smoothstep(0.3, 0.7, t));
            """),
        t("spinBlur", "blur", "hurricane", params: [strength(0.5)], """
            float amt = p[0] * 0.8 * tr_bump(t);
            float2 q = tr_asp(uv, aspect);
            float4 a = float4(0.0), b = float4(0.0);
            for (int i = 0; i < 9; i++) {
                float2 r = tr_unasp(tr_rot(q, amt * (float(i) / 8.0 - 0.5)), aspect);
                a += MA(r); b += MB(r);
            }
            return mix(a / 9.0, b / 9.0, smoothstep(0.3, 0.7, t));
            """),
        t("zoomBlur", "blur", "circle.circle", params: [strength(0.5)], """
            float k = p[0] * 0.5 * tr_bump(t);
            return mix(tr_zoomBlur(from, s, uv, k, true), tr_zoomBlur(to, s, uv, k, true), smoothstep(0.3, 0.7, t));
            """),
        t("defocus", "blur", "camera.aperture", params: [strength(0.5)], """
            float r = p[0] * 0.09 * tr_bump(t);
            return mix(tr_blur(from, s, uv, r, aspect), tr_blur(to, s, uv, r, aspect), smoothstep(0.42, 0.58, t));
            """),
        t("frostedGlass", "blur", "snowflake", params: [strength(0.5)], """
            float amp = p[0] * 0.05 * tr_bump(t);
            float2 cell = floor(uv * ctx.size / 2.0);
            float2 off = (float2(fx_hash(cell), fx_hash(cell + 17.0)) - 0.5) * amp;
            return mix(FA(uv + off), FB(uv + off), smoothstep(0.3, 0.7, t));
            """),
        t("dreamBlur", "blur", "cloud.fill", params: [strength(0.5)], """
            float k = tr_bump(t);
            float r = p[0] * 0.06 * k;
            float4 c = mix(tr_blur(from, s, uv, r, aspect), tr_blur(to, s, uv, r, aspect), tr_smooth(t));
            c.rgb = min(c.rgb + max(c.rgb - 0.55, 0.0) * 2.0 * k + 0.08 * k, 1.0);
            return c;
            """),
    ]

    // MARK: Light

    static let light: [TransitionDescriptor] = [
        t("lightLeak", "light", "sun.haze.fill", params: [intensity(0.8)], """
            float k = tr_bump(t) * p[0];
            float4 c = mix(FA(uv), FB(uv), smoothstep(0.3, 0.7, t));
            float2 q = tr_asp(uv, aspect);
            float2 c1 = float2(mix(-0.9, 0.9, t) * aspect * 0.5, -0.25), c2 = float2(mix(0.6, -0.6, t) * aspect * 0.5, 0.35);
            float n = 0.6 + 0.4 * tr_fbm(uv * 3.0 + t * 2.0);
            float3 leak = float3(1.0, 0.55, 0.2) * (1.0 - smoothstep(0.0, 0.9, length(q - c1))) + float3(1.0, 0.3, 0.45) * (1.0 - smoothstep(0.0, 0.8, length(q - c2)));
            c.rgb = min(c.rgb + leak * k * n * 1.4, 1.0);
            return c;
            """),
        t("filmBurn", "light", "flame.fill", duration: 0.8, """
            float n = tr_fbm(uv * float2(3.0 * aspect, 3.0) + 1.7);
            float edge = mix(-0.25, 1.25, t);
            float burnt = 1.0 - smoothstep(edge - 0.2, edge - 0.1, n);
            float glow = smoothstep(edge - 0.2, edge - 0.1, n) * (1.0 - smoothstep(edge - 0.05, edge + 0.05, n));
            float4 c = mix(FA(uv), FB(uv), burnt);
            c.rgb = min(c.rgb + float3(1.0, 0.45, 0.1) * glow * 1.6, 1.0);
            return c;
            """),
        t("glow", "light", "light.max", params: [intensity(0.6)], """
            float k = tr_bump(t) * p[0];
            float4 c = mix(FA(uv), FB(uv), tr_smooth(t));
            float4 g = mix(tr_blur(from, s, uv, 0.035, aspect), tr_blur(to, s, uv, 0.035, aspect), tr_smooth(t));
            c.rgb = min(c.rgb + g.rgb * 1.5 * k, 1.0);
            return c;
            """),
        t("shine", "light", "sparkle", """
            float x = (uv.x * aspect + uv.y) / (aspect + 1.0);
            float m = tr_sweep(x, t, 0.02);
            float edge = mix(-0.02, 1.02, t);
            float band = (1.0 - smoothstep(0.0, 0.12, abs(x - edge))) * tr_bump(t);
            float4 c = mix(FA(uv), FB(uv), m);
            c.rgb = min(c.rgb + float3(1.0, 0.97, 0.9) * band * 0.9, 1.0);
            return c;
            """),
        t("overexposure", "light", "sun.max", params: [intensity(0.8)], """
            float k = pow(tr_bump(t), 2.0) * p[0];
            float4 c = mix(FA(uv), FB(uv), smoothstep(0.4, 0.6, t));
            c.rgb = mix(c.rgb * (1.0 + 2.0 * k), float3(1.0), k * 0.85);
            c.rgb = min(c.rgb, 1.0);
            return c;
            """),
        t("lightRays", "light", "rays", params: [intensity(0.7)], """
            float k = tr_bump(t) * p[0];
            float4 c = mix(FA(uv), FB(uv), smoothstep(0.35, 0.65, t));
            float2 q = (uv - float2(-0.1, -0.15)) * float2(aspect, 1.0);
            float ang = atan2(q.y, q.x);
            float rays = pow(0.5 + 0.5 * sin(ang * 36.0 + t * 4.0), 6.0) * (1.0 - smoothstep(0.0, 1.8, length(q)));
            c.rgb = min(c.rgb + float3(1.0, 0.94, 0.78) * (rays + 0.25) * k, 1.0);
            return c;
            """),
        t("strobe", "light", "light.beacon.max.fill", """
            float m = t < 0.12 ? 0.0 : (t > 0.88 ? 1.0 : fmod(floor(t * 10.0), 2.0));
            float4 c = mix(FA(uv), FB(uv), m);
            float f = (t > 0.12 && t < 0.88) ? 0.35 * (1.0 - fract(t * 10.0)) : 0.0;
            c.rgb = min(c.rgb + f, 1.0);
            return c;
            """),
        t("rainbowLeak", "light", SFSymbolCompat.compat("rainbow"), params: [intensity(0.7)], """
            float k = tr_bump(t) * p[0];
            float4 c = mix(FA(uv), FB(uv), smoothstep(0.3, 0.7, t));
            float3 h = fx_hsv2rgb(float3(fract(uv.x * 0.6 + uv.y * 0.3 + t * 0.8), 0.65, 1.0));
            c.rgb = min(c.rgb + h * k * 0.75, 1.0);
            return c;
            """),
    ]

    // MARK: Slide (push = both move; cover = B over A; uncover = A slides off B)

    static let slide: [TransitionDescriptor] = directions.map { name, d, sym in
        t("slide\(name)", "slide", sym, """
            float2 d = \(d);
            float2 ua = uv - d * e, ub = uv - d * (e - 1.0);
            return tr_inside(ua) ? FA(ua) : FB(ub);
            """)
    } + directions.map { name, d, sym in
        t("cover\(name)", "slide", "\(sym).square", """
            float2 d = \(d);
            float2 ub = uv - d * (e - 1.0);
            return tr_inside(ub) ? FB(ub) : FA(uv);
            """)
    } + directions.map { name, d, sym in
        t("uncover\(name)", "slide", "\(sym).square.fill", """
            float2 d = \(d);
            float2 ua = uv - d * e;
            return tr_inside(ua) ? FA(ua) : FB(uv);
            """)
    }

    // MARK: Wipe

    static let wipe: [TransitionDescriptor] = [
        // B revealed from left to right (persisted id; same direction as before).
        t("wipeRight", "wipe", "rectangle.righthalf.filled", params: [softness(0.1)],
          "return mix(FA(uv), FB(uv), tr_sweep(uv.x, t, 0.005 + p[0] * 0.2));"),
        t("wipeLeft", "wipe", "rectangle.lefthalf.filled", params: [softness(0.1)],
          "return mix(FA(uv), FB(uv), tr_sweep(1.0 - uv.x, t, 0.005 + p[0] * 0.2));"),
        t("wipeDown", "wipe", "rectangle.bottomhalf.filled", params: [softness(0.1)],
          "return mix(FA(uv), FB(uv), tr_sweep(uv.y, t, 0.005 + p[0] * 0.2));"),
        t("wipeUp", "wipe", "rectangle.tophalf.filled", params: [softness(0.1)],
          "return mix(FA(uv), FB(uv), tr_sweep(1.0 - uv.y, t, 0.005 + p[0] * 0.2));"),
        t("wipeDiagonal", "wipe", "arrow.down.right", params: [softness(0.1)],
          "return mix(FA(uv), FB(uv), tr_sweep((uv.x + uv.y) * 0.5, t, 0.005 + p[0] * 0.2));"),
        t("wipeDiagonalUp", "wipe", "arrow.up.right", params: [softness(0.1)],
          "return mix(FA(uv), FB(uv), tr_sweep((uv.x + 1.0 - uv.y) * 0.5, t, 0.005 + p[0] * 0.2));"),
        t("clockWipe", "wipe", "clock", params: [softness(0.02)], """
            float2 q = tr_asp(uv, aspect);
            float a = fract(atan2(q.x, -q.y) / (2.0 * TR_PI) + 1.0);
            return mix(FA(uv), FB(uv), tr_sweep(a, t, 0.002 + p[0] * 0.1));
            """),
        t("fanWipe", "wipe", "fanblades", params: [softness(0.02)], """
            float2 q = tr_asp(uv, aspect);
            float a = abs(atan2(q.x, -q.y)) / TR_PI;
            return mix(FA(uv), FB(uv), tr_sweep(a, t, 0.002 + p[0] * 0.1));
            """),
        t("zigzagWipe", "wipe", "bolt.horizontal", params: [count(10, 2, 30)], """
            float tri = abs(fract(uv.y * p[0]) - 0.5) * 2.0;
            float x = (uv.x * 0.85 + tri * 0.15);
            return mix(FA(uv), FB(uv), tr_sweep(x, t, 0.01));
            """),
        t("waveWipe", "wipe", "water.waves", params: [count(3, 1, 12)], """
            float x = uv.x * 0.85 + (0.5 + 0.5 * sin(uv.y * TR_PI * 2.0 * p[0] + t * 6.0)) * 0.15;
            return mix(FA(uv), FB(uv), tr_sweep(x, t, 0.02));
            """),
        t("inkWipe", "wipe", "drop.triangle", """
            float x = uv.x * 0.7 + tr_fbm(uv * float2(4.0 * aspect, 4.0)) * 0.3;
            return mix(FA(uv), FB(uv), tr_sweep(x, t, 0.03));
            """),
        t("softWipe", "wipe", "square.lefthalf.filled", "return mix(FA(uv), FB(uv), tr_sweep(uv.x, t, 0.35));"),
    ]

    // MARK: Shape (mask) reveals

    /// B grows inside `shape` (see `tr_gauge` in the shader lib) from the centre until it covers the canvas.
    static func shape(_ name: String, _ shapeIndex: Int, _ symbol: String, inverse: Bool = false) -> TransitionDescriptor {
        t(name, "shape", symbol, params: [softness(0.05)], """
            float f = 0.002 + p[0] * 0.2;
            float2 q = tr_asp(uv, aspect);
            float g = tr_gauge(q, \(shapeIndex), aspect);
            float rmax = tr_gaugeMax(\(shapeIndex), aspect);
            float m = tr_sweep(g / rmax, \(inverse ? "1.0 - t" : "t"), f);
            return \(inverse ? "mix(FB(uv), FA(uv), m)" : "mix(FA(uv), FB(uv), m)");
            """)
    }

    static let shapes: [TransitionDescriptor] = [
        shape("circle", 0, "circle"),
        shape("circleClose", 0, "circle.dashed", inverse: true),
        shape("oval", 7, "oval"),
        shape("rectangle", 2, "rectangle"),
        shape("diamond", 1, "diamond"),
        shape("heart", 3, "heart"),
        shape("star", 4, "star"),
        shape("cross", 5, "cross"),
        shape("hexagon", 6, "hexagon"),
        shape("triangle", 8, "triangle"),
        t("dots", "shape", "circle.grid.3x3.fill", params: [count(16, 4, 40)], """
            float n = p[0];
            float2 g = uv * float2(n * aspect, n);
            float2 l = fract(g) - 0.5;
            float lt = saturate(t * 1.5 - (uv.x * 0.35 + uv.y * 0.15));
            float r = mix(-0.03, 0.74, lt);
            float m = 1.0 - smoothstep(r - 0.03, r + 0.03, length(l));
            return mix(FA(uv), FB(uv), lt >= 1.0 ? 1.0 : m);
            """),
        t("rings", "shape", "target", params: [count(6, 2, 20)], """
            float2 q = tr_asp(uv, aspect);
            float f = fract(length(q) * p[0]);
            return mix(FA(uv), FB(uv), tr_sweep(f, t, 0.02));
            """),
    ]

    // MARK: Split

    static let split: [TransitionDescriptor] = [
        t("barnDoorH", "split", "rectangle.split.2x1", """
            float h = 0.5 * e;
            if (uv.x < 0.5 - h) return FA(float2(uv.x + h, uv.y));
            if (uv.x > 0.5 + h) return FA(float2(uv.x - h, uv.y));
            return FB(uv);
            """),
        t("barnDoorV", "split", "rectangle.split.1x2", """
            float h = 0.5 * e;
            if (uv.y < 0.5 - h) return FA(float2(uv.x, uv.y + h));
            if (uv.y > 0.5 + h) return FA(float2(uv.x, uv.y - h));
            return FB(uv);
            """),
        t("splitFour", "split", "square.split.2x2", """
            float h = 0.5 * e;
            float2 sg = float2(uv.x < 0.5 ? -1.0 : 1.0, uv.y < 0.5 ? -1.0 : 1.0);
            float2 ua = uv - sg * h;
            bool same = (ua.x < 0.5) == (sg.x < 0.0) && (ua.y < 0.5) == (sg.y < 0.0);
            return (same && tr_inside(ua)) ? FA(ua) : FB(uv);
            """),
        t("blindsH", "split", "line.3.horizontal", params: [count(10, 2, 40)], """
            float f = fract(uv.y * p[0]);
            return f < e ? FB(uv) : FA(uv);
            """),
        t("blindsV", "split", "line.3.horizontal.decrease", params: [count(12, 2, 40)], """
            float f = fract(uv.x * p[0]);
            return f < e ? FB(uv) : FA(uv);
            """),
        t("stripes", "split", "line.horizontal.3", params: [count(8, 2, 30)], """
            float row = floor(uv.y * p[0]);
            float dir = fmod(row, 2.0) < 1.0 ? 1.0 : -1.0;
            float2 ub = float2(uv.x - dir * (e - 1.0), uv.y);
            return tr_inside(ub) ? FB(ub) : FA(uv);
            """),
        t("checkerboard", "split", "checkerboard.rectangle", params: [count(8, 2, 30)], """
            float2 cell = floor(uv * float2(p[0] * aspect, p[0]));
            float d = fmod(cell.x + cell.y, 2.0) < 1.0 ? 0.0 : 0.5;
            return t >= d + 0.5 || (t > d && fract(uv.x * p[0] * aspect) < (t - d) * 2.0) ? FB(uv) : FA(uv);
            """),
        t("mosaicTiles", "split", "square.grid.3x3.fill", params: [count(10, 2, 40)], """
            float2 cell = floor(uv * float2(p[0] * aspect, p[0]));
            float d = fx_hash(cell + 3.7) * 0.8;
            float lt = saturate((t - d) / 0.2);
            float2 l = fract(uv * float2(p[0] * aspect, p[0]));
            float w = abs(cos(lt * TR_PI));
            bool inside = abs(l.x - 0.5) <= w * 0.5 + 1e-4;
            if (!inside) return float4(0.0);
            return lt < 0.5 ? FA(uv) : FB(uv);
            """),
        t("splitDiagonal", "split", "square.split.diagonal", """
            float side = uv.x + uv.y < 1.0 ? -1.0 : 1.0;
            float2 ua = uv - side * float2(0.7071, 0.7071) * e * 0.75;
            bool same = (ua.x + ua.y < 1.0) == (side < 0.0);
            return (same && tr_inside(ua)) ? FA(ua) : FB(uv);
            """),
    ]

    // MARK: Glitch

    static let glitch: [TransitionDescriptor] = [
        t("glitch", "glitch", "waveform.path.ecg", params: [intensity(0.6)], """
            float amp = tr_bump(t) * p[0];
            float seed = floor(t * 18.0);
            float row = floor(uv.y * 24.0);
            float r = fx_hash(float2(row, seed));
            float shift = (r > 0.6 ? (fx_hash(float2(row + 3.1, seed)) - 0.5) * 0.25 : 0.0) * amp;
            float2 q = float2(uv.x + shift, uv.y);
            float off = 0.025 * amp;
            bool useB = fx_hash(float2(floor(uv.y * 9.0), seed + 0.5)) * 0.6 + 0.2 < t;
            float4 c = AB(q);
            return float4(AB(q + float2(off, 0.0)).r, c.g, AB(q - float2(off, 0.0)).b, c.a);
            """),
        t("rgbSplit", "glitch", "circle.hexagongrid.fill", params: [intensity(0.6)], """
            float amp = tr_bump(t) * p[0] * 0.05;
            float2 dir = (uv - 0.5);
            float m = smoothstep(0.4, 0.6, t);
            float4 c = mix(FA(uv), FB(uv), m);
            float rr = mix(FA(uv + dir * amp).r, FB(uv + dir * amp).r, m);
            float bb = mix(FA(uv - dir * amp).b, FB(uv - dir * amp).b, m);
            return float4(rr, c.g, bb, c.a);
            """),
        t("digitalNoise", "glitch", "square.grid.4x3.fill", """
            float2 block = floor(uv * float2(32.0, 18.0));
            float n = fx_hash(block + floor(t * 20.0) * 0.37);
            float4 c = n < t ? FB(uv) : FA(uv);
            float g = fx_hash(uv * ctx.size + t * 13.0);
            c.rgb = mix(c.rgb, float3(g), 0.35 * tr_bump(t));
            return c;
            """),
        t("scanlines", "glitch", "tv", params: [intensity(0.6)], """
            float amp = tr_bump(t) * p[0];
            float line = floor(uv.y * ctx.size.y / 3.0);
            float shift = (fx_hash(float2(line, floor(t * 30.0))) - 0.5) * 0.08 * amp;
            float2 q = float2(uv.x + shift, uv.y);
            float4 c = t < 0.5 ? FA(q) : FB(q);
            c.rgb *= 1.0 - 0.45 * amp * step(0.5, fract(uv.y * ctx.size.y / 4.0));
            return c;
            """),
        t("vhs", "glitch", "videoprojector", params: [intensity(0.7)], """
            float amp = tr_bump(t) * p[0];
            float wob = sin(uv.y * 30.0 + t * 50.0) * 0.006 + (fx_hash(float2(floor(uv.y * 90.0), floor(t * 24.0))) - 0.5) * 0.02;
            float2 q = float2(uv.x + wob * amp, uv.y);
            float m = smoothstep(0.4, 0.6, t);
            float4 c = mix(FA(q), FB(q), m);
            float rr = mix(FA(q + float2(0.012 * amp, 0.0)).r, FB(q + float2(0.012 * amp, 0.0)).r, m);
            float3 v = float3(rr, c.g, c.b);
            v = mix(v, float3(fx_luma(v)), 0.3 * amp) + (fx_hash(uv * ctx.size + t) - 0.5) * 0.2 * amp;
            return float4(saturate(v), c.a);
            """),
        t("mosaic", "glitch", "square.grid.3x3", params: [count(48, 4, 120)], """
            float amp = tr_bump(t);
            float cs = 1.0 + amp * p[0];
            float2 q = amp < 1e-3 ? uv : (floor(uv * ctx.size / cs) + 0.5) * cs / ctx.size;
            return mix(FA(q), FB(q), smoothstep(0.4, 0.6, t));
            """),
        t("datamosh", "glitch", "square.stack.3d.down.forward", params: [intensity(0.6)], """
            float amp = tr_bump(t) * p[0];
            float2 block = floor(uv * float2(24.0, 14.0));
            float2 off = (FB((block + 0.5) / float2(24.0, 14.0)).rg - 0.5) * 0.2 * amp;
            return mix(FA(uv + off), FB(uv - off * 0.5), smoothstep(0.3, 0.8, t));
            """),
        t("signalLoss", "glitch", "antenna.radiowaves.left.and.right.slash", """
            float k = pow(tr_bump(t), 1.5);
            float4 c = t < 0.5 ? FA(uv) : FB(uv);
            float n = fx_hash(floor(uv * ctx.size / 2.0) + floor(t * 30.0) * 0.71);
            c.rgb = mix(c.rgb, float3(n), k * 0.9);
            return c;
            """),
        t("chromaticZoom", "glitch", "camera.filters", params: [intensity(0.6)], """
            float amp = tr_bump(t) * p[0] * 0.25;
            float m = smoothstep(0.4, 0.6, t);
            float2 c0 = uv - 0.5;
            float4 g = mix(FA(c0 / (1.0 + amp) + 0.5), FB(c0 / (1.0 + amp) + 0.5), m);
            float rr = mix(FA(c0 / (1.0 + amp * 1.3) + 0.5).r, FB(c0 / (1.0 + amp * 1.3) + 0.5).r, m);
            float bb = mix(FA(c0 / (1.0 + amp * 0.7) + 0.5).b, FB(c0 / (1.0 + amp * 0.7) + 0.5).b, m);
            return float4(rr, g.g, bb, g.a);
            """),
        t("tvOff", "glitch", SFSymbolCompat.compat("tv.slash"), duration: 0.6, """
            float sy = t < 0.5 ? mix(1.0, 0.004, tr_ease(t * 2.0)) : mix(0.004, 1.0, tr_ease(t * 2.0 - 1.0));
            float2 q = float2(uv.x, (uv.y - 0.5) / sy + 0.5);
            if (!tr_inside(q)) return float4(0.0, 0.0, 0.0, 1.0);
            float4 c = t < 0.5 ? FA(q) : FB(q);
            c.rgb = min(c.rgb * (1.0 + 2.0 * pow(tr_bump(t), 4.0)), 1.0);
            return c;
            """),
    ]

    // MARK: Distortion

    static let distortion: [TransitionDescriptor] = [
        t("ripple", "distortion", "dot.radiowaves.left.and.right", params: [intensity(0.6)], """
            float amp = tr_bump(t) * p[0];
            float2 q = tr_asp(uv, aspect);
            float d = length(q);
            float2 off = (d > 1e-4 ? q / d : float2(0.0)) * sin(d * 40.0 - t * 30.0) * 0.025 * amp;
            float2 r = tr_unasp(q + off, aspect);
            return mix(MA(r), MB(r), smoothstep(0.3, 0.7, t));
            """),
        t("swirl", "distortion", "tornado", params: [strength(0.6)], """
            float amp = tr_bump(t) * p[0];
            float2 q = tr_asp(uv, aspect);
            float a = amp * 6.0 * pow(1.0 - smoothstep(0.0, 0.9, length(q)), 2.0);
            float2 r = tr_unasp(tr_rot(q, a), aspect);
            return mix(MA(r), MB(r), smoothstep(0.35, 0.65, t));
            """),
        t("wave", "distortion", "water.waves", params: [intensity(0.6)], """
            float amp = tr_bump(t) * p[0];
            float2 r = uv + float2(sin(uv.y * 12.0 + t * 8.0) * 0.05, sin(uv.x * 8.0 + t * 5.0) * 0.025) * amp;
            return mix(MA(r), MB(r), smoothstep(0.3, 0.7, t));
            """),
        t("liquid", "distortion", SFSymbolCompat.compat("drop.halffull"), params: [intensity(0.6)], """
            float amp = tr_bump(t) * p[0];
            float2 off = float2(tr_fbm(uv * 4.0 + t * 2.0), tr_fbm(uv * 4.0 + 9.3 - t * 2.0)) - 0.45;
            float2 r = uv + off * 0.12 * amp;
            float n = tr_fbm(uv * float2(3.0 * aspect, 3.0) + 4.1);
            return mix(MA(r), MB(r), tr_sweep(n, t, 0.08));
            """),
        t("squeezeH", "distortion", "arrow.right.and.line.vertical.and.arrow.left", """
            float w = 1.0 - e;
            if (uv.x < w) return FA(float2(uv.x / max(w, 1e-5), uv.y));
            return FB(float2((uv.x - w) / max(e, 1e-5), uv.y));
            """),
        t("squeezeV", "distortion", "arrow.down.and.line.horizontal.and.arrow.up", """
            float h = 1.0 - e;
            if (uv.y < h) return FA(float2(uv.x, uv.y / max(h, 1e-5)));
            return FB(float2(uv.x, (uv.y - h) / max(e, 1e-5)));
            """),
        t("bulge", "distortion", "circle.circle.fill", params: [strength(0.6)], """
            float amp = tr_bump(t) * p[0];
            float2 q = tr_asp(uv, aspect);
            float k = 1.0 - amp * 0.6 * (1.0 - smoothstep(0.0, 0.8, length(q)));
            float2 r = tr_unasp(q * k, aspect);
            return mix(MA(r), MB(r), smoothstep(0.35, 0.65, t));
            """),
        t("pinch", "distortion", "smallcircle.filled.circle", params: [strength(0.6)], """
            float amp = tr_bump(t) * p[0];
            float2 q = tr_asp(uv, aspect);
            float k = 1.0 + amp * 1.2 * (1.0 - smoothstep(0.0, 0.8, length(q)));
            float2 r = tr_unasp(q * k, aspect);
            return mix(MA(r), MB(r), smoothstep(0.35, 0.65, t));
            """),
        t("kaleidoscope", "distortion", "seal", params: [count(6, 3, 12)], """
            float amp = tr_bump(t);
            float2 q = tr_asp(uv, aspect);
            float seg = 2.0 * TR_PI / floor(p[0]);
            float a = atan2(q.y, q.x);
            a = abs(fmod(a + 10.0 * seg, seg) - seg * 0.5);
            float2 k = tr_unasp(float2(cos(a), sin(a)) * length(q), aspect);
            float2 r = mix(uv, k, amp);
            return mix(MA(r), MB(r), smoothstep(0.4, 0.6, t));
            """),
        t("morph", "distortion", "aqi.medium", params: [strength(0.5)], """
            float4 ca = FA(uv), cb = FB(uv);
            float2 oa = float2((ca.r + ca.b) * 0.5, (ca.g + ca.b) * 0.5) * 2.0 - 1.0;
            float2 ob = float2((cb.r + cb.b) * 0.5, (cb.g + cb.b) * 0.5) * 2.0 - 1.0;
            float2 oc = mix(oa, ob, 0.5) * p[0] * 0.3;
            return mix(FA(uv + oc * t), FB(uv - oc * (1.0 - t)), t);
            """),
        t("stretch", "distortion", "arrow.left.and.right.square", """
            float sx = t < 0.5 ? 1.0 + 6.0 * tr_ease(t * 2.0) : 7.0 - 6.0 * tr_ease(t * 2.0 - 1.0);
            float2 q = float2((uv.x - 0.5) / sx + 0.5, uv.y);
            return mix(FA(q), FB(q), smoothstep(0.45, 0.55, t));
            """),
    ]

    // MARK: 3D

    static let threeD: [TransitionDescriptor] = frames3D.map { name, w, map in
        t("cube\(name)", "3d", "cube", duration: 0.7, """
            float2 w = \(w);
            float a = e * TR_PI * 0.5;
            float3 c = float3(0.0, 0.0, 0.5 + 0.35 * tr_bump(t));
            float3 V = float3(0.0, 1.0, 0.0);
            float3 OA = tr_ry(float3(-0.5, -0.5, -0.5), a) + c, UA = tr_ry(float3(1.0, 0.0, 0.0), a);
            float3 OB = tr_ry(float3(0.5, -0.5, -0.5), a) + c, UB = tr_ry(float3(0.0, 0.0, 1.0), a);
            float3 ha = tr_quad(w, OA, UA, V, tr_ry(float3(0.0, 0.0, -1.0), a), 2.0);
            float3 hb = tr_quad(w, OB, UB, V, tr_ry(float3(1.0, 0.0, 0.0), a), 2.0);
            float da = ha.z > 0.0 ? ha.z : 1e9, db = hb.z > 0.0 ? hb.z : 1e9;
            if (da >= 1e9 && db >= 1e9) return float4(0.0);
            float3 h3 = da <= db ? ha : hb;
            float2 h = h3.xy;
            float4 col = da <= db ? FA(\(map)) : FB(\(map));
            col.rgb *= da <= db ? (1.0 - 0.45 * sin(a)) : (0.55 + 0.45 * sin(a));
            return col;
            """)
    } + [("H", "uv", "h"), ("V", "uv.yx", "h.yx")].map { name, w, map in
        t("flip\(name)", "3d", name == "H" ? "arrow.left.and.right.righttriangle.left.righttriangle.right" : "arrow.up.and.down.righttriangle.up.righttriangle.down", duration: 0.6, """
            float2 w = \(w);
            float a = e * TR_PI;
            float3 c = float3(0.0, 0.0, 0.6 * tr_bump(t));
            float3 O = tr_ry(float3(-0.5, -0.5, 0.0), a) + c, U = tr_ry(float3(1.0, 0.0, 0.0), a);
            float3 h3 = tr_quad(w, O, U, float3(0.0, 1.0, 0.0), float3(0.0), 2.0);
            if (h3.z <= 0.0) return float4(0.0);
            float2 h = a < TR_PI * 0.5 ? h3.xy : float2(1.0 - h3.x, h3.y);
            float shade = 1.0 - 0.4 * abs(sin(a));
            float4 col = a < TR_PI * 0.5 ? FA(\(map)) : FB(\(map));
            col.rgb *= shade;
            return col;
            """)
    } + [
        t("pageCurl", "3d", SFSymbolCompat.compat("book.pages"), duration: 0.9, """
            float2 n = float2(0.9, 0.25);
            float nn = dot(n, n), ns = n.x + n.y;
            float x = dot(uv, n) / ns;
            float R = 0.12;
            float f = mix(1.02, -R - 0.02, e);
            if (x < f) return FA(uv);
            if (x < f + R) {
                float ph = asin(saturate((x - f) / R));
                float xb = f + (TR_PI - ph) * R;
                float2 ub = uv + n * ((xb - x) * ns / nn);
                if (tr_inside(ub)) { float4 c = FA(ub); c.rgb = mix(c.rgb, float3(0.92), 0.55) * (0.78 + 0.22 * cos(ph)); return c; }
                float xf = f + ph * R;
                float2 uf = uv + n * ((xf - x) * ns / nn);
                if (tr_inside(uf)) { float4 c = FA(uf); c.rgb *= 0.6 + 0.4 * cos(ph); return c; }
            }
            float4 c = FB(uv);
            c.rgb *= 1.0 - 0.45 * exp(-max(x - f - R, 0.0) * 18.0) * max(tr_bump(t), 0.0);
            return c;
            """),
        t("doorway", "3d", "door.left.hand.open", duration: 0.7, """
            float a = e * (TR_PI * 0.5 + 0.35);
            float3 V = float3(0.0, 1.0, 0.0);
            float3 UL = float3(cos(a), 0.0, sin(a)), UR = float3(-cos(a), 0.0, sin(a));
            float3 hl = tr_quad(uv, float3(-0.5, -0.5, 0.0), UL, V, float3(sin(a), 0.0, -cos(a)), 2.0);
            float3 hr = tr_quad(uv, float3(0.5, -0.5, 0.0), UR, V, float3(-sin(a), 0.0, -cos(a)), 2.0);
            float shade = 1.0 - 0.5 * sin(min(a, TR_PI * 0.5));
            if (hl.z > 0.0 && hl.x <= 0.5) { float4 c = FA(hl.xy); c.rgb *= shade; return c; }
            if (hr.z > 0.0 && hr.x <= 0.5) { float4 c = FA(float2(1.0 - hr.x, hr.y)); c.rgb *= shade; return c; }
            float z = mix(0.8, 1.0, e);
            return GB((uv - 0.5) / z + 0.5);
            """),
        t("revolve", "3d", "door.right.hand.open", duration: 0.7, """
            float a = e * (TR_PI * 0.5 + 0.35);
            float3 h = tr_quad(uv, float3(-0.5, -0.5, 0.0), float3(cos(a), 0.0, sin(a)), float3(0.0, 1.0, 0.0),
                               float3(sin(a), 0.0, -cos(a)), 2.0);
            if (h.z > 0.0) { float4 c = FA(h.xy); c.rgb *= 1.0 - 0.5 * sin(min(a, TR_PI * 0.5)); return c; }
            float z = mix(0.85, 1.0, e);
            return GB((uv - 0.5) / z + 0.5);
            """),
    ]

    // MARK: Overlay / motion graphics

    static let overlay: [TransitionDescriptor] = [
        t("colorBars", "overlay", "chart.bar.fill", params: [count(5, 2, 12)], duration: 0.8, """
            float n = floor(p[0]);
            float i = floor(uv.y * n);
            float d = (i / max(n - 1.0, 1.0)) * 0.3;
            float3 pal[5] = { float3(0.98, 0.36, 0.42), float3(1.0, 0.78, 0.25), float3(0.34, 0.75, 0.80),
                              float3(0.45, 0.42, 0.95), float3(0.98, 0.98, 0.98) };
            float3 col = pal[int(fmod(i, 5.0))];
            if (t < 0.5) {
                float cover = tr_ease(saturate((t * 2.0 - d) / 0.7));
                return uv.x < cover ? float4(col, 1.0) : FA(uv);
            }
            float start = tr_ease(saturate((t * 2.0 - 1.0 - d) / 0.7));
            return (uv.x >= start && start < 1.0) ? float4(col, 1.0) : FB(uv);
            """),
        t("halftone", "overlay", "circle.grid.cross.fill", params: [count(24, 6, 60)], """
            float n = p[0];
            float2 l = fract(uv * float2(n * aspect, n)) - 0.5;
            float lt = saturate(t * 1.4 - uv.x * 0.4);
            float r = mix(-0.05, 0.76, lt);
            float m = lt >= 1.0 ? 1.0 : 1.0 - smoothstep(r - 0.05, r, length(l));
            return mix(FA(uv), FB(uv), m);
            """),
        t("filmRoll", "overlay", "film.stack", duration: 0.6, """
            float g = 0.12;
            float o = e * (1.0 + g);
            float ys = uv.y + o;
            if (ys < 1.0) return FA(float2(uv.x, ys));
            if (ys < 1.0 + g) {
                float yy = (ys - 1.0) / g;
                float edge = min(uv.x, 1.0 - uv.x) * aspect;
                float hole = (edge > 0.02 && edge < 0.07 && abs(fract(uv.x * 14.0) - 0.5) < 0.25 && abs(yy - 0.5) < 0.25) ? 1.0 : 0.0;
                return float4(float3(0.06 + 0.85 * hole), 1.0);
            }
            return FB(float2(uv.x, ys - 1.0 - g));
            """),
        t("mirrorSplit", "overlay", "rectangle.split.2x1.fill", """
            float amp = tr_bump(t);
            float2 m = float2(uv.x < 0.5 ? uv.x : 1.0 - uv.x, uv.y);
            float2 r = mix(uv, m, amp);
            return mix(FA(r), FB(r), smoothstep(0.42, 0.58, t));
            """),
        t("colorBlocks", "overlay", "square.grid.2x2.fill", params: [count(6, 2, 20)], """
            float2 cell = floor(uv * float2(p[0] * aspect, p[0]));
            float d = 0.02 + fx_hash(cell + 1.3) * 0.43;
            bool shown = t > d && t < 0.55 + d;
            float3 col = fx_hsv2rgb(float3(fx_hash(cell + 7.7), 0.55, 1.0));
            if (shown) return float4(col, 1.0);
            return t < 0.5 ? FA(uv) : FB(uv);
            """),
        t("colorStripes", "overlay", "line.diagonal", params: [count(7, 2, 20)], """
            float x = (uv.x * aspect + uv.y) / (aspect + 1.0);
            float i = floor(x * p[0]);
            float lt = saturate(t * 1.6 - i / p[0] * 0.6);
            float3 col = fx_hsv2rgb(float3(fract(i * 0.17 + 0.55), 0.5, 1.0));
            if (lt > 0.0 && lt < 1.0 && abs(fract(x * p[0]) - 0.5) < 0.5 * tr_bump(lt)) return float4(col, 1.0);
            return lt >= 0.5 ? FB(uv) : FA(uv);
            """),
    ]

    public static let all: [TransitionDescriptor] =
        basic + camera + blur + light + slide + wipe + shapes + split + glitch + distortion + threeD + overlay
}

/// MSL shared by every transition shader (prepended to each one's own library).
public enum TransitionShaderLib {
    public static let helpers = """
    constant float TR_PI = 3.14159265358979;
    #define FA(u) from.sample(s, (u))
    #define FB(u) to.sample(s, (u))
    #define GA(u) tr_get(from, s, (u))
    #define GB(u) tr_get(to, s, (u))
    #define MA(u) from.sample(s, tr_mirror(u))
    #define MB(u) to.sample(s, tr_mirror(u))
    #define AB(u) (useB ? to.sample(s, (u)) : from.sample(s, (u)))

    inline float tr_smooth(float t) { t = saturate(t); return t * t * (3.0 - 2.0 * t); }
    inline float tr_ease(float t) { t = saturate(t); return t < 0.5 ? 4.0 * t * t * t : 1.0 - pow(-2.0 * t + 2.0, 3.0) * 0.5; }
    /// 0 → 1 → 0 over the transition (amplitude of mid-transition effects; exactly 0 at both ends).
    inline float tr_bump(float t) { return t <= 0.0 || t >= 1.0 ? 0.0 : sin(TR_PI * t); }
    /// Back-out ease with overshoot (0 → 1.1 → 1).
    inline float tr_backOut(float t) { t = saturate(t); float c1 = 1.70158, c3 = c1 + 1.0, u = t - 1.0; return 1.0 + c3 * u * u * u + c1 * u * u; }
    inline bool tr_inside(float2 uv) { return uv.x >= 0.0 && uv.x <= 1.0 && uv.y >= 0.0 && uv.y <= 1.0; }
    inline float4 tr_get(texture2d<float> tex, sampler s, float2 uv) { return tr_inside(uv) ? tex.sample(s, uv) : float4(0.0); }
    inline float2 tr_mirror(float2 uv) { return 1.0 - abs(fmod(abs(uv), 2.0) - 1.0); }
    inline float2 tr_rot(float2 v, float a) { float c = cos(a), n = sin(a); return float2(c * v.x - n * v.y, n * v.x + c * v.y); }
    /// Canvas uv ↔ aspect-corrected offsets from the centre (canvas-height units).
    inline float2 tr_asp(float2 uv, float aspect) { return (uv - 0.5) * float2(aspect, 1.0); }
    inline float2 tr_unasp(float2 q, float aspect) { return q / float2(aspect, 1.0) + 0.5; }
    inline float tr_noise(float2 q) {
        float2 i = floor(q), f = fract(q);
        float a = fx_hash(i), b = fx_hash(i + float2(1.0, 0.0)), c = fx_hash(i + float2(0.0, 1.0)), d = fx_hash(i + float2(1.0, 1.0));
        float2 u = f * f * (3.0 - 2.0 * f);
        return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
    }
    inline float tr_fbm(float2 q) { float v = 0.0, a = 0.5; for (int i = 0; i < 4; i++) { v += a * tr_noise(q); q *= 2.03; a *= 0.5; } return v; }
    /// Reveal mask sweeping x ∈ [0,1]: 1 where already revealed, soft edge; exactly 0 at t = 0 and 1 at t = 1.
    inline float tr_sweep(float x, float t, float soft) {
        soft = max(soft, 1e-4);
        float e = mix(-soft, 1.0 + soft, saturate(t));
        return 1.0 - smoothstep(e - soft, e + soft, x);
    }
    /// 9-tap gaussian along d (uv units, total half-extent).
    inline float4 tr_blurDir(texture2d<float> tex, sampler s, float2 uv, float2 d) {
        float4 acc = float4(0.0); float w = 0.0;
        for (int i = -4; i <= 4; i++) { float k = exp(-float(i * i) / 10.0); acc += tex.sample(s, uv + d * (float(i) / 4.0)) * k; w += k; }
        return acc / w;
    }
    /// 16-tap golden-angle disc blur; r in canvas heights (0 = exact sample).
    inline float4 tr_blur(texture2d<float> tex, sampler s, float2 uv, float r, float aspect) {
        if (r < 1e-5) return tex.sample(s, uv);
        float4 acc = tex.sample(s, uv); float w = 1.0;
        for (int i = 1; i < 16; i++) {
            float a = float(i) * 2.39996;
            float rr = sqrt(float(i) / 15.0) * r;
            acc += tex.sample(s, uv + float2(cos(a) / aspect, sin(a)) * rr); w += 1.0;
        }
        return acc / w;
    }
    /// Radial (zoom) blur toward the centre; amt 0 = exact sample.
    inline float4 tr_zoomBlur(texture2d<float> tex, sampler s, float2 uv, float amt, bool mirror) {
        if (amt < 1e-5) return tex.sample(s, mirror ? tr_mirror(uv) : uv);
        float4 acc = float4(0.0);
        for (int i = 0; i < 10; i++) {
            float2 q = (uv - 0.5) * (1.0 - amt * float(i) / 9.0) + 0.5;
            acc += tex.sample(s, mirror ? tr_mirror(q) : q);
        }
        return acc / 10.0;
    }

    // Unit shapes (y down, aspect-corrected units) — signed distance, negative inside.
    inline float tr_sdHeart(float2 q) {
        float2 p = float2(abs(q.x), -q.y + 0.55);
        if (p.y + p.x > 1.0) return length(p - float2(0.25, 0.75)) - 0.35355;
        float2 d1 = p - float2(0.0, 1.0);
        float2 d2 = p - 0.5 * max(p.x + p.y, 0.0);
        return sqrt(min(dot(d1, d1), dot(d2, d2))) * sign(p.x - p.y);
    }
    inline float tr_sdStar(float2 q) {
        float2 p = float2(q.x, -q.y);
        const float2 k1 = float2(0.809016994375, -0.587785252292);
        const float2 k2 = float2(-k1.x, k1.y);
        p.x = abs(p.x);
        p -= 2.0 * max(dot(k1, p), 0.0) * k1;
        p -= 2.0 * max(dot(k2, p), 0.0) * k2;
        p.x = abs(p.x);
        p.y -= 0.5;
        float2 ba = 0.42 * float2(-k1.y, k1.x) - float2(0.0, 1.0);
        float h = clamp(dot(p, ba) / dot(ba, ba), 0.0, 0.5);
        return length(p - ba * h) * sign(p.y * ba.x - p.x * ba.y);
    }
    inline float tr_sdCross(float2 q) {
        float2 p = abs(q);
        p = (p.y > p.x) ? p.yx : p;
        float2 b = float2(0.5, 0.17);
        float2 r = p - b;
        float k = max(r.y, r.x);
        float2 w = (k > 0.0) ? r : float2(b.y - p.x, -k);
        return sign(k) * length(max(w, 0.0));
    }
    inline float tr_sdf(float2 q, int shape) {
        if (shape == 3) return tr_sdHeart(q);
        if (shape == 4) return tr_sdStar(q);
        return tr_sdCross(q);
    }
    /// Gauge (scale at which the point enters the shape) of shape `shape` at q: circle 0, diamond 1, canvas-rectangle 2,
    /// heart 3, star 4, cross 5, hexagon 6, canvas-oval 7, triangle 8.
    inline float tr_gauge(float2 q, int shape, float aspect) {
        switch (shape) {
        case 0: return length(q);
        case 1: return abs(q.x) + abs(q.y);
        case 2: return max(abs(q.x) / aspect, abs(q.y));
        case 6: { float2 a = abs(q); return max(a.x * 0.866025 + a.y * 0.5, a.y); }
        case 7: return length(float2(q.x / aspect, q.y));
        case 8: return max(max(-q.y, q.y * 0.5 + q.x * 0.866025), q.y * 0.5 - q.x * 0.866025);
        default: {
            // star-shaped SDF shapes: bisection on the scale
            float lo = 0.0, hi = 8.0;
            for (int i = 0; i < 14; i++) { float m = 0.5 * (lo + hi); if (tr_sdf(q / max(m, 1e-4), shape) < 0.0) hi = m; else lo = m; }
            return hi;
        }
        }
    }
    /// Gauge that covers the whole canvas (max over corners / edge midpoints).
    inline float tr_gaugeMax(int shape, float aspect) {
        float h = 0.5, w = 0.5 * aspect;
        float g = max(max(tr_gauge(float2(w, h), shape, aspect), tr_gauge(float2(w, -h), shape, aspect)),
                      max(tr_gauge(float2(-w, h), shape, aspect), tr_gauge(float2(-w, -h), shape, aspect)));
        if (shape == 3 || shape == 4 || shape == 5) {
            g = max(g, max(max(tr_gauge(float2(0.0, h), shape, aspect), tr_gauge(float2(0.0, -h), shape, aspect)),
                           max(tr_gauge(float2(w, 0.0), shape, aspect), tr_gauge(float2(-w, 0.0), shape, aspect))));
        }
        return g * 1.02;
    }

    // 3D: camera at (0,0,-D) looking +z; the screen (z = 0) spans [-0.5,0.5]² in face units.
    inline float3 tr_ry(float3 q, float a) { float c = cos(a), n = sin(a); return float3(q.x * c + q.z * n, q.y, -q.x * n + q.z * c); }
    /// Hit of the view ray through screen point uv with the unit quad O + u·U + v·V (u, v ∈ [0,1]). Nf = front normal
    /// (zero = two-sided). Returns (u, v, ray distance), distance ≤ 0 = miss / back-facing.
    inline float3 tr_quad(float2 uv, float3 O, float3 U, float3 V, float3 Nf, float D) {
        float3 C = float3(0.0, 0.0, -D);
        float3 dir = float3(uv.x - 0.5, uv.y - 0.5, D);
        if (dot(Nf, Nf) > 0.0 && dot(dir, Nf) >= 0.0) return float3(0.0, 0.0, -1.0);
        float3 N = cross(U, V);
        float den = dot(dir, N);
        if (abs(den) < 1e-6) return float3(0.0, 0.0, -1.0);
        float k = dot(O - C, N) / den;
        if (k <= 0.0) return float3(0.0, 0.0, -1.0);
        float3 H = C + dir * k - O;
        float u = dot(H, U), v = dot(H, V);
        if (u < 0.0 || u > 1.0 || v < 0.0 || v > 1.0) return float3(0.0, 0.0, -1.0);
        return float3(u, v, k);
    }
    """

    /// Full transition source for a body (see `BuiltinTransitions`).
    public static func wrap(_ body: String) -> String {
        helpers + """

        float4 transition(float2 uv, texture2d<float> from, texture2d<float> to, sampler s, float progress,
                          constant float* p, FXContext ctx) {
            float t = saturate(progress);
            float e = tr_ease(t);
            float aspect = ctx.aspect;
            \(body)
        }
        """
    }
}
