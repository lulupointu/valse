import Foundation
import MontageCore
import MontageEffects

/// Metal generators behind Media ▸ Library (MI-023 local substitute): animated backgrounds, gradients, countdown rings
/// and green-screen elements. Each one is an `EffectDescriptor` whose shader ignores `src` (like `BuiltinCanvasStyles`)
/// and is placed on a full-canvas `.solid` clip by a `StockLibrary` recipe, which is then rendered once to a file.
///
/// Category `.canvas` + group `library.group.generator`: hidden from the asset panel and excluded from the Canvas ▸ Style
/// picker. Shared params (shader `p[]` order): colours `a`, `b`, `c` (4 floats each), `speed`, `style`.
nonisolated enum LibraryGenerators {
    static let groupKey = "library.group.generator"
    static func id(_ name: String) -> String { "montage.library.\(name)" }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var registered = false

    /// Registers every generator (idempotent; call before rendering a library recipe).
    static func register() {
        lock.withLock {
            guard !registered else { return }
            registered = true
            for d in all { Registries.effects.register(d) }
        }
    }

    /// Instance of generator `name` with colours / style / speed set.
    static func instance(_ name: String, _ a: RGBA, _ b: RGBA, _ c: RGBA, style: Double = 0, speed: Double = 1) -> EffectInstance {
        register()
        var e = Registries.effects[id(name)]!.makeInstance()
        e.params["a"] = .color(a); e.params["b"] = .color(b); e.params["c"] = .color(c)
        e.params["style"] = .scalar(style); e.params["speed"] = .scalar(speed)
        return e
    }

    static let params: [ParamSpec] = [
        ParamSpec("a", nameKey: "library.param.a", .color(defaultValue: RGBA(hex: 0x57BECB))),
        ParamSpec("b", nameKey: "library.param.b", .color(defaultValue: RGBA(hex: 0x8E4EC6))),
        ParamSpec("c", nameKey: "library.param.c", .color(defaultValue: RGBA(hex: 0x101828))),
        .scalar("speed", "library.param.speed", 0, 3, 1),
        .scalar("style", "library.param.style", 0, 8, 0),
    ]

    static let helpers = """
    inline float lib_noise(float2 p) {
        float2 i = floor(p), f = fract(p); float2 u = f * f * (3.0 - 2.0 * f);
        return mix(mix(fx_hash(i), fx_hash(i + float2(1, 0)), u.x), mix(fx_hash(i + float2(0, 1)), fx_hash(i + float2(1, 1)), u.x), u.y);
    }
    inline float lib_fbm(float2 p) {
        float v = 0.0, a = 0.5;
        for (int i = 0; i < 5; i++) { v += a * lib_noise(p); p = p * 2.03 + float2(17.1, 9.2); a *= 0.5; }
        return v;
    }
    // cyclic palette a → b → c → a
    inline float3 lib_pal(float3 a, float3 b, float3 c, float x) {
        x = fract(x) * 3.0;
        if (x < 1.0) return mix(a, b, smoothstep(0.0, 1.0, x));
        if (x < 2.0) return mix(b, c, smoothstep(0.0, 1.0, x - 1.0));
        return mix(c, a, smoothstep(0.0, 1.0, x - 2.0));
    }
    inline float3 lib_ramp(float3 a, float3 b, float3 c, float x) {
        x = saturate(x);
        return x < 0.5 ? mix(a, b, x * 2.0) : mix(b, c, x * 2.0 - 1.0);
    }
    inline float lib_box(float2 p, float2 b, float r) {
        float2 d = abs(p) - b + r;
        return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - r;
    }
    inline float2 lib_rot(float2 p, float a) { float c = cos(a), s = sin(a); return float2(c * p.x - s * p.y, s * p.x + c * p.y); }
    inline float lib_dot2(float2 v) { return dot(v, v); }
    // heart, y up, tip at origin, top ≈ 1
    inline float lib_heart(float2 p) {
        p.x = abs(p.x);
        if (p.y + p.x > 1.0) return sqrt(lib_dot2(p - float2(0.25, 0.75))) - sqrt(2.0) / 4.0;
        return sqrt(min(lib_dot2(p - float2(0.0, 1.0)), lib_dot2(p - 0.5 * max(p.x + p.y, 0.0)))) * sign(p.x - p.y);
    }
    // 4-point sparkle star
    inline float lib_sparkle(float2 p, float r) {
        p = abs(p);
        float d = pow(p.x, 0.5) + pow(p.y, 0.5);
        return smoothstep(sqrt(r), sqrt(r) * 0.8, d);
    }
    // ease-out-back pop 0 → 1
    inline float lib_pop(float t) { t = saturate(t); float c1 = 1.70158, c3 = c1 + 1.0; return 1.0 + c3 * pow(t - 1.0, 3.0) + c1 * pow(t - 1.0, 2.0); }
    """

    /// Background generator: `body` writes `o` (rgb). Available: uv (0…1, y down), q (centred, aspect-corrected, y down),
    /// A/B/C colours, t (seconds × speed), ph (loop phase 2π per 8 s), ctx, st (style index).
    static func generator(_ name: String, _ body: String) -> EffectDescriptor {
        EffectDescriptor(id: id(name), category: .canvas, nameKey: "library.gen.\(name)", groupKey: groupKey, params: params,
                         symbol: "sparkles.rectangle.stack", shader: """
        \(helpers)
        float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
            float3 A = float3(p[0], p[1], p[2]);
            float3 B = float3(p[4], p[5], p[6]);
            float3 C = float3(p[8], p[9], p[10]);
            float t = ctx.time * p[12];
            int st = int(p[13] + 0.5);
            float ph = 6.2831853 * t / 8.0;
            float2 q = float2((uv.x - 0.5) * ctx.aspect, uv.y - 0.5);
            float3 o = float3(0.0);
            \(body)
            o += (fx_hash(uv * ctx.size + fract(ctx.time * 7.13) * 31.0) - 0.5) / 255.0;   // dither (no banding)
            return float4(saturate(o), 1.0);
        }
        """)
    }

    /// Green-screen element over pure #00FF00: `body` writes `col` and coverage `k` (0…1).
    static func element(_ name: String, _ body: String) -> EffectDescriptor {
        EffectDescriptor(id: id(name), category: .canvas, nameKey: "library.gen.\(name)", groupKey: groupKey, params: params,
                         symbol: "person.crop.rectangle", shader: """
        \(helpers)
        float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
            float3 A = float3(p[0], p[1], p[2]);
            float3 B = float3(p[4], p[5], p[6]);
            float3 C = float3(p[8], p[9], p[10]);
            float t = ctx.time * p[12];
            int st = int(p[13] + 0.5);
            float2 q = float2((uv.x - 0.5) * ctx.aspect, uv.y - 0.5);
            float3 col = float3(1.0);
            float k = 0.0;
            \(body)
            return float4(mix(float3(0.0, 1.0, 0.0), col, saturate(k)), 1.0);
        }
        """)
    }

    static let all: [EffectDescriptor] = backgrounds + elements

    // MARK: Backgrounds

    static let backgrounds: [EffectDescriptor] = [
        generator("gradient", """
            float x;
            if (st == 0) x = dot(uv - 0.5, normalize(float2(1.0, 0.6))) * 1.1 + 0.5;
            else if (st == 1) x = uv.y;
            else if (st == 2) x = length(q) * 1.35;
            else if (st == 3) x = fract(atan2(q.y, q.x) / 6.2831853 + 0.25);
            else x = 0.0;
            if (st == 4) {
                // mesh-like: three soft colour fields
                float3 m = A * exp(-lib_dot2(q - float2(-0.5, -0.35)) * 3.0) + B * exp(-lib_dot2(q - float2(0.55, -0.1)) * 2.5)
                         + C * exp(-lib_dot2(q - float2(-0.1, 0.45)) * 2.8);
                float w = exp(-lib_dot2(q - float2(-0.5, -0.35)) * 3.0) + exp(-lib_dot2(q - float2(0.55, -0.1)) * 2.5)
                        + exp(-lib_dot2(q - float2(-0.1, 0.45)) * 2.8);
                o = m / max(w, 1e-3);
            } else if (st == 3) {
                o = lib_pal(A, B, C, x);
            } else {
                o = lib_ramp(A, B, C, x);
            }
            """),
        generator("aurora", """
            float3 sky = mix(C * 1.4, C * 0.35, uv.y);
            float n1 = lib_fbm(float2(q.x * 1.7 + 0.6 * cos(ph), q.y * 0.5 + 0.6 * sin(ph)));
            float n2 = lib_fbm(float2(q.x * 2.3 - 0.5 * sin(ph), q.y * 0.7 + 0.5 * cos(ph)) + 4.0);
            float b1 = exp(-pow((uv.y - 0.42 - (n1 - 0.5) * 0.7) * 5.5, 2.0));
            float b2 = exp(-pow((uv.y - 0.30 - (n2 - 0.5) * 0.6) * 8.0, 2.0));
            float curtain = 0.6 + 0.4 * sin(q.x * 18.0 + n1 * 9.0 + ph);
            o = sky + A * b1 * curtain * 0.95 + B * b2 * 0.75;
            float2 cell = floor(uv * ctx.size / 3.0);
            float h = fx_hash(cell);
            o += step(0.996, h) * (0.55 + 0.45 * sin(ph * 3.0 + h * 60.0)) * (1.0 - b1) * smoothstep(0.8, 0.2, uv.y);
            """),
        generator("plasma", """
            float v = sin(q.x * 5.0 + ph) + sin(q.y * 6.0 - ph * 2.0) + sin((q.x + q.y) * 4.0 + ph)
                    + sin(length(q * 7.0 + float2(cos(ph), sin(ph))) - ph * 2.0);
            o = lib_pal(A, B, C, v * 0.11 + ph / 6.2831853);
            o *= 1.0 - 0.35 * length(q);
            """),
        generator("bokeh", """
            o = mix(C * 1.3, C * 0.5, uv.y);
            for (int i = 0; i < 26; i++) {
                float fi = float(i);
                float2 c0 = float2(fx_hash(float2(fi, 1.7)), fx_hash(float2(fi, 2.9)));
                float r = mix(0.035, 0.12, fx_hash(float2(fi, 3.3)));
                float2 c = float2((c0.x - 0.5) * ctx.aspect + 0.07 * cos(ph + fi), c0.y - 0.5 + 0.05 * sin(ph + fi * 1.7));
                float d = length(q - c);
                float disc = smoothstep(r, r * 0.88, d) * (0.6 + 0.4 * smoothstep(r * 0.6, r, d));
                float a = disc * (0.16 + 0.10 * sin(ph * 2.0 + fi));
                float3 col = fmod(fi, 3.0) < 1.0 ? A : (fmod(fi, 3.0) < 2.0 ? B : mix(A, B, 0.5));
                o += col * a;
            }
            """),
        generator("lightleak", """
            o = C * 0.6;
            for (int i = 0; i < 5; i++) {
                float fi = float(i);
                float2 c = float2(cos(ph + fi * 1.3) * 0.62 * ctx.aspect * 0.6, sin(ph * 1.0 + fi * 2.1) * 0.42);
                float d = length((q - c) * float2(0.9, 1.4));
                o += mix(A, B, fi / 4.0) * exp(-d * d * 11.0) * 0.55;
            }
            o += A * 0.22 * exp(-pow((uv.x - 0.5 - 0.4 * sin(ph)) * 5.0, 2.0)) * (1.0 - uv.y * 0.6);
            o = 1.0 - exp(-o * 1.4);
            """),
        generator("starfield", """
            o = mix(C * 0.4, C * 1.2, length(q));
            for (int l = 0; l < 4; l++) {
                float depth = fract(float(l) / 4.0 + t / 8.0);
                float scale = mix(28.0, 3.0, depth);
                float fade = smoothstep(0.0, 0.3, depth) * smoothstep(1.0, 0.85, depth);
                float2 g = q * scale + float(l) * 31.7;
                float2 id = floor(g); float2 f = fract(g) - 0.5;
                float h = fx_hash(id + float(l) * 7.0);
                float2 off = float2(fx_hash(id + 3.1), fx_hash(id + 7.7)) - 0.5;
                float d = length(f - off * 0.6);
                float star = (0.012 / (d * d + 0.012) - 0.08) * step(0.55, h);
                o += mix(A, B, h) * max(star, 0.0) * fade * 0.6;
            }
            """),
        generator("liquid", """
            float2 w = q * 1.8;
            float2 off = float2(cos(ph), sin(ph)) * 0.7;
            float n1 = lib_fbm(w + off);
            float n2 = lib_fbm(w + float2(n1 * 2.2, n1 * 1.4) - off);
            o = lib_pal(A, B, C, n2 * 1.3 + 0.15);
            o *= 0.85 + 0.3 * n1;
            """),
        generator("waves", """
            o = mix(A, B, uv.y);
            for (int i = 0; i < 6; i++) {
                float fi = float(i);
                float y = 0.30 + fi * 0.12 + 0.045 * sin(q.x * (2.5 + fi * 0.8) + ph * (1.0 + fmod(fi, 2.0)) + fi * 1.9);
                float m = smoothstep(y, y + 0.004, uv.y);
                float3 layer = mix(B, C, fi / 5.0);
                o = mix(o, layer, m * 0.7);
            }
            """),
        generator("synthwave", """
            float hz = 0.58;
            o = mix(C * 0.6, A * 0.9, smoothstep(0.0, hz, uv.y));
            float2 sp = q - float2(0.0, 0.0);
            float sd = length(sp);
            float sun = smoothstep(0.23, 0.225, sd) * step(uv.y, hz);
            float cut = uv.y > 0.46 ? step(0.38 + (uv.y - 0.46) * 3.0, fract((uv.y - 0.46) * 28.0)) : 1.0;
            o = mix(o, mix(B * 1.15, A * 1.1, smoothstep(-0.22, 0.12, sp.y)), sun * cut);
            o += B * 0.3 * exp(-sd * 5.0) * step(uv.y, hz);
            if (uv.y > hz) {
                float yy = uv.y - hz;
                float z = 0.09 / yy;
                float x = q.x * z;
                float gz = fract(z * 3.0 - t * 1.5);
                float gx = fract(x * 16.0 + 0.5);
                float ex = 0.5 - abs(gx - 0.5), ez = 0.5 - abs(gz - 0.5);    // distance to the nearest grid line (cell units)
                float line = max(smoothstep(0.05, 0.0, ex), smoothstep(0.06, 0.0, ez));
                line = mix(line, 0.14, saturate(z / 3.0));                  // average out near the horizon (no moiré)
                o = mix(C * 0.35, B * 1.2, saturate(line));
                o += B * 0.5 * exp(-yy * 22.0);
            }
            """),
        generator("dust", """
            o = mix(A, B, saturate(uv.y + 0.15 * sin(ph + uv.x * 2.0)));
            for (int l = 0; l < 3; l++) {
                float sc = 7.0 + 6.0 * float(l);
                float2 g = q * sc + float2(0.4 * sin(ph + float(l)), -t * (0.25 + 0.15 * float(l)));
                float2 id = floor(g); float2 f = fract(g) - 0.5;
                float h = fx_hash(id + float(l) * 11.0);
                float2 off = float2(fx_hash(id + 1.3), fx_hash(id + 5.1)) - 0.5;
                float d = length(f - off * 0.7);
                float tw = 0.5 + 0.5 * sin(t * 2.0 + h * 40.0);
                float sz = mix(0.05, 0.16, fx_hash(id + 9.9)) / (1.0 + 0.4 * float(l));
                o += C * (smoothstep(sz, 0.0, d) + 0.25 * smoothstep(sz * 3.0, 0.0, d)) * step(0.55, h) * tw * (0.9 - 0.2 * float(l));
            }
            """),
        generator("confetti", """
            o = mix(A, A * 0.75, uv.y);
            for (int l = 0; l < 3; l++) {
                float sc = 7.0 + 4.0 * float(l);
                float2 g = float2(q.x * sc, q.y * sc - t * (1.2 + 0.4 * float(l)));
                float2 id = floor(g); float2 f = fract(g) - 0.5;
                float h = fx_hash(id + float(l) * 13.0);
                if (h > 0.4) {
                    float2 r = lib_rot(f - (float2(fx_hash(id + 2.0), fx_hash(id + 4.0)) - 0.5) * 0.4, t * (h - 0.5) * 8.0 + h * 6.0);
                    r.x *= 0.5 + 0.5 * abs(cos(t * 3.0 + h * 9.0));
                    float d = lib_box(r, float2(0.16, 0.07) * (0.7 + h * 0.5), 0.02);
                    float3 cc = fx_hsv2rgb(float3(fract(h * 7.31), 0.65, 1.0));
                    cc = mix(cc, fmod(floor(h * 10.0), 2.0) < 1.0 ? B : C, 0.35);
                    o = mix(o, cc, smoothstep(0.02, 0.0, d));
                }
            }
            """),
        generator("rays", """
            float a = atan2(q.y, q.x);
            float r = length(q);
            float k = smoothstep(0.25, 0.75, 0.5 + 0.5 * sin(a * 12.0 + ph));
            o = mix(A, B, k);
            o = mix(o, C, smoothstep(0.18, 0.0, r));
            o *= 1.0 - 0.45 * r;
            """),
        generator("grain", """
            float2 c = float2(cos(ph), sin(ph)) * 0.3;
            o = mix(A, B, smoothstep(-0.7, 0.7, dot(q - c * 0.5, normalize(float2(1.0, 0.6)))));
            o = mix(o, C, 0.55 * exp(-length(q + c) * 2.5));
            float g = fx_hash(floor(uv * ctx.size / 2.0) + floor(t * 24.0) * 3.7) - 0.5;
            o += g * 0.10;
            o *= 1.0 - 0.3 * lib_dot2(q);
            """),
        generator("blobs", """
            float f = 0.0;
            for (int i = 0; i < 6; i++) {
                float fi = float(i);
                float2 c = float2(cos(ph * (1.0 + fmod(fi, 2.0)) + fi * 2.1) * 0.55, sin(ph + fi * 1.3) * 0.3);
                f += 0.022 / max(lib_dot2(q - c), 1e-4);
            }
            o = mix(C, A, smoothstep(0.7, 1.1, f));
            o = mix(o, B, smoothstep(2.0, 3.5, f) * 0.85);
            """),
        generator("pattern", """
            float2 g = q * 6.0 + float2(t / 8.0 * 2.0, t / 8.0 * 2.0);
            float2 id = floor(g); float2 f = fract(g) - 0.5;
            float alt = fmod(abs(id.x + id.y), 2.0);
            float2 rf = lib_rot(f, ph + alt * 1.5708);
            float d = abs(rf.x) + abs(rf.y);
            float k = smoothstep(0.33, 0.31, d);
            float ring = smoothstep(0.03, 0.0, abs(d - 0.40));
            o = mix(C, mix(A, B, alt), k);
            o = mix(o, mix(B, A, alt), ring * 0.6);
            """),
        // countdown ring background; style 0 modern, 1 film leader, 2 neon
        generator("countdown", """
            float sec = fract(ctx.time);
            float ang = fract(atan2(q.x, -q.y) / 6.2831853 + 1.0);
            float r = length(q);
            if (st == 1) {
                float flick = 0.94 + 0.06 * fx_hash(float2(floor(ctx.time * 24.0), 3.0));
                o = A * flick;
                o = mix(o, A * 0.55, step(ang, sec) * step(r, 0.62));              // sweeping sector
                float lines = max(smoothstep(0.004, 0.0, abs(q.x)), smoothstep(0.004, 0.0, abs(q.y)));
                float circ = max(smoothstep(0.005, 0.0, abs(r - 0.36)), smoothstep(0.005, 0.0, abs(r - 0.42)));
                o = mix(o, float3(0.05), max(lines, circ) * 0.85);
                o += (fx_hash(floor(uv * ctx.size / 2.0) + floor(ctx.time * 24.0)) - 0.5) * 0.08;
                o *= 1.0 - 0.5 * lib_dot2(q * 1.2);
            } else {
                o = mix(B * 0.35, C, saturate(r * 1.4));
                float track = smoothstep(0.012, 0.0, abs(r - 0.33));
                // distance to the remaining arc [0, 1 - sec] of the ring (round caps → no hard radial edge on the glow)
                float endA = 1.0 - sec, R = 0.33;
                float2 e1 = R * float2(sin(endA * 6.2831853), -cos(endA * 6.2831853));
                float dArc = ang <= endA ? abs(r - R) : min(length(q - float2(0.0, -R)), length(q - e1));
                float arc = smoothstep(0.022, 0.0, dArc);
                float glow = exp(-dArc * (st == 2 ? 22.0 : 60.0));
                o = mix(o, float3(1.0), track * 0.12);
                o = mix(o, A, arc);
                o += A * glow * (st == 2 ? 0.9 : 0.35);
                o += A * 0.25 * exp(-r * 6.0) * (1.0 - sec) * (st == 2 ? 1.0 : 0.4);
            }
            """),
    ]

    // MARK: Green-screen elements

    static let elements: [EffectDescriptor] = [
        element("gs.arrow", """
            float b = abs(sin(t * 3.14159 * 1.5)) * 0.07;
            float2 a = q - float2(0.0, 0.02 - b);
            float pz = lib_pop(t * 2.5);
            a /= max(pz * 1.6, 0.01);
            float shaft = lib_box(a - float2(0.0, -0.08), float2(0.045, 0.12), 0.015);
            float2 h = a - float2(0.0, 0.10);
            float head = max(-0.07 - h.y, abs(h.x) * 1.1 + h.y * 0.9 - 0.09);
            float d = min(shaft, head);
            col = d < -0.012 ? A : float3(1.0);
            k = smoothstep(0.003, 0.0, d);
            """),
        element("gs.ring", """
            for (int i = 0; i < 3; i++) {
                float ph2 = fract(t * 0.6 + float(i) / 3.0);
                float r = ph2 * 0.48;
                float w = 0.006 + 0.012 * (1.0 - ph2);
                float ring = smoothstep(w, 0.0, abs(length(q) - r)) * (1.0 - ph2);
                if (ring > k) { k = ring; col = mix(A, B, ph2); }
            }
            float dot0 = smoothstep(0.05, 0.045, length(q)) ;
            if (dot0 > k) { k = dot0; col = A; }
            """),
        element("gs.sparkle", """
            for (int i = 0; i < 14; i++) {
                float fi = float(i);
                float2 c = (float2(fx_hash(float2(fi, 1.0)), fx_hash(float2(fi, 2.0))) - 0.5) * float2(ctx.aspect * 0.8, 0.8);
                float life = fract(t * 0.7 + fx_hash(float2(fi, 5.0)));
                float sz = sin(life * 3.14159) * mix(0.05, 0.12, fx_hash(float2(fi, 3.0)));
                float2 r = lib_rot(q - c, life * 2.0);
                float sp = sz > 0.001 ? max(lib_sparkle(r / sz, 1.0), 0.6 * smoothstep(0.35, 0.0, length(r / sz))) : 0.0;
                if (sp > k) { k = sp; col = mix(float3(1.0), fmod(fi, 2.0) < 1.0 ? A : B, 0.45); }
            }
            """),
        element("gs.confetti", """
            for (int l = 0; l < 3; l++) {
                float sc = 6.0 + 3.0 * float(l);
                float2 g = float2(q.x * sc, q.y * sc - t * (1.6 + 0.5 * float(l)) + 4.0);
                float2 id = floor(g); float2 f = fract(g) - 0.5;
                float h = fx_hash(id + float(l) * 13.0);
                if (h > 0.45) {
                    float2 r = lib_rot(f - (float2(fx_hash(id + 2.0), fx_hash(id + 4.0)) - 0.5) * 0.4, t * (h - 0.5) * 8.0 + h * 6.0);
                    r.x *= 0.4 + 0.6 * abs(cos(t * 3.0 + h * 9.0));
                    float d = lib_box(r, float2(0.16, 0.07) * (0.7 + h * 0.5), 0.02);
                    float cov = smoothstep(0.02, 0.0, d);
                    float3 cc = fx_hsv2rgb(float3(fract(h * 7.31 + 0.45), 0.8, 1.0));
                    if (abs(cc.g - 1.0) < 0.2 && cc.r < 0.4 && cc.b < 0.4) cc = A;      // never green on green
                    if (cov > k) { k = cov; col = cc; }
                }
            }
            """),
        element("gs.sweep", """
            float x = -1.2 + fract(t / 2.0) * 2.4;
            float d = dot(q, normalize(float2(1.0, -0.35))) - x;
            k = exp(-d * d * 60.0) + 0.6 * exp(-pow(d + 0.12, 2.0) * 400.0);
            col = mix(float3(1.0), A, 0.15);
            """),
        element("gs.like", """
            float pz = lib_pop(t * 2.2) * (1.0 - 0.12 * exp(-pow((t - 1.6) * 9.0, 2.0)));
            float2 b = q / max(pz * 1.5, 0.01);
            float liked = smoothstep(1.55, 1.7, t);
            float d = length(b) - 0.17;
            col = mix(A, B, liked);
            k = smoothstep(0.004, 0.0, d);
            // thumbs-up glyph (white)
            float2 g = b - float2(0.012, 0.012);
            float palm = lib_box(g - float2(0.02, 0.02), float2(0.048, 0.045), 0.016);
            float thumb = lib_box(lib_rot(g - float2(0.0, -0.055), -0.45), float2(0.02, 0.05), 0.018);
            float cuff = lib_box(g - float2(-0.062, 0.025), float2(0.017, 0.045), 0.006);
            float icon = min(min(palm, thumb), cuff);
            if (icon < 0.0) col = float3(1.0);
            col = mix(col, float3(1.0), smoothstep(0.003, 0.0, icon) * k);
            // click ripple
            float rp = saturate((t - 1.6) * 1.8);
            float ripple = smoothstep(0.012, 0.0, abs(length(q) - (0.26 + rp * 0.22))) * (1.0 - rp) * step(1.6, t);
            if (ripple > k) { k = ripple; col = B; }
            """),
        element("gs.glitch", """
            float fr = floor(t * 12.0);
            for (int i = 0; i < 10; i++) {
                float fi = float(i);
                float h = fx_hash(float2(fi, fr));
                if (h > 0.45) {
                    float y = fx_hash(float2(fi * 3.1, fr + 1.0)) - 0.5;
                    float hh = mix(0.01, 0.06, fx_hash(float2(fi, fr + 2.0)));
                    float x0 = (fx_hash(float2(fi, fr + 3.0)) - 0.5) * ctx.aspect;
                    float w = mix(0.2, 0.9, fx_hash(float2(fi, fr + 4.0)));
                    float inBar = step(abs(q.y - y), hh) * step(abs(q.x - x0), w);
                    if (inBar > 0.5) { k = 1.0; int ci = int(fmod(fi + fr, 3.0)); col = ci == 0 ? A : (ci == 1 ? B : C); }
                }
            }
            """),
        element("gs.heart", """
            float pz = lib_pop(t * 2.0) * (1.0 + 0.08 * sin(t * 9.0) * step(0.5, t));
            float2 hp = float2(q.x, -q.y) / max(0.36 * pz, 0.01) + float2(0.0, 0.5);
            float d = lib_heart(hp);
            k = smoothstep(0.02, 0.0, d);
            col = mix(A, A * 1.25, saturate(-hp.y * 0.5 + 0.8));
            float hl = smoothstep(0.08, 0.0, length(hp - float2(-0.28, 0.72)) - 0.06);
            col = mix(col, float3(1.0), hl * 0.7);
            for (int i = 0; i < 7; i++) {
                float fi = float(i);
                float life = fract(t * 0.5 + fi / 7.0);
                float2 c = float2((fx_hash(float2(fi, 9.0)) - 0.5) * 1.1, 0.35 - life * 0.9);
                float2 sp = float2(q.x - c.x - 0.03 * sin(life * 12.0 + fi), -(q.y - c.y)) / 0.05 + float2(0.0, 0.5);
                float dd = lib_heart(sp);
                float cov = smoothstep(0.05, 0.0, dd) * smoothstep(1.0, 0.6, life) * step(0.3, t);
                if (cov > k) { k = cov; col = B; }
            }
            """),
    ]
}
