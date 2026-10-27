import ValseCore

/// Colour-grading descriptors (CapCut Adjust ▸ HSL / Curves / Color wheel, plus a physically-based white balance).
/// All parameters are scalars, so they get generated inspector sliders and keyframes for free.
/// CPU mirror of the Curves shader (editor drawing, tests): monotone cubic through sorted points.
public enum ColorCurveMath {
    public static let maxPoints = 8
    public typealias Point = (x: Double, y: Double)

    /// The points of `channel` from an instance's params (descriptor defaults for missing keys).
    public static func points(_ params: [String: ParamValue], channel: String) -> [Point] {
        let d = BuiltinColor.curves
        func v(_ k: String) -> Double {
            if let s = params[k]?.scalar { return s }
            if case .scalar(_, _, let def)? = d.params.first(where: { $0.key == k })?.kind { return def }
            return 0
        }
        let n = min(max(Int(v("\(channel).n").rounded()), 2), maxPoints)
        return (0..<n).map { (v("\(channel).x\($0)"), v("\(channel).y\($0)")) }
    }

    /// Params for `channel` holding `pts` (sorted by x, clamped to [0, 1], 2…8 points).
    public static func params(_ pts: [Point], channel: String) -> [String: ParamValue] {
        let sorted = pts.map { (x: min(max($0.x, 0), 1), y: min(max($0.y, 0), 1)) }.sorted { $0.x < $1.x }.prefix(maxPoints)
        var out: [String: ParamValue] = ["\(channel).n": .scalar(Double(sorted.count))]
        for k in 0..<maxPoints {
            let p = k < sorted.count ? sorted[sorted.startIndex + k] : (x: 1.0, y: 1.0)
            out["\(channel).x\(k)"] = .scalar(p.x); out["\(channel).y\(k)"] = .scalar(p.y)
        }
        return out
    }

    public static var identity: [Point] { BuiltinColor.curveKnots.map { ($0, $0) } }

    public static func evaluate(_ pts: [Point], _ x: Double) -> Double {
        let n = pts.count
        guard n >= 2 else { return x }
        let xc = min(max(x, 0), 1)
        if xc <= pts[0].x { return pts[0].y }
        if xc >= pts[n - 1].x { return pts[n - 1].y }
        var d = [Double](repeating: 0, count: n - 1), m = [Double](repeating: 0, count: n)
        for k in 0..<(n - 1) { d[k] = (pts[k + 1].y - pts[k].y) / max(pts[k + 1].x - pts[k].x, 1e-4) }
        m[0] = d[0]; m[n - 1] = d[n - 2]
        if n > 2 { for k in 1..<(n - 1) { m[k] = d[k - 1] * d[k] <= 0 ? 0 : (d[k - 1] + d[k]) * 0.5 } }
        for k in 0..<(n - 1) {
            if abs(d[k]) < 1e-6 { m[k] = 0; m[k + 1] = 0; continue }
            let a = m[k] / d[k], b = m[k + 1] / d[k], r = a * a + b * b
            if r > 9 { let t = 3 / r.squareRoot(); m[k] = t * a * d[k]; m[k + 1] = t * b * d[k] }
        }
        var i = 0
        for k in 0..<(n - 1) where xc >= pts[k].x { i = k }
        let h = max(pts[i + 1].x - pts[i].x, 1e-4), t = (xc - pts[i].x) / h, t2 = t * t, t3 = t2 * t
        return (2 * t3 - 3 * t2 + 1) * pts[i].y + (t3 - 2 * t2 + t) * h * m[i] + (-2 * t3 + 3 * t2) * pts[i + 1].y + (t3 - t2) * h * m[i + 1]
    }
}

public enum BuiltinColor {
    /// The 8 CapCut HSL colour ranges, with their centre hue in degrees.
    public static let hslRanges: [(key: String, hue: Double)] = [
        ("red", 0), ("orange", 30), ("yellow", 60), ("green", 120), ("cyan", 180), ("blue", 240), ("purple", 270), ("magenta", 300),
    ]

    /// HSL: per range Hue (±30° shift), Saturation and Lightness (−1…1). Hue weights form a partition of unity between
    /// neighbouring range centres (smoothstep falloff), scaled by pixel saturation so greys are never touched.
    /// Params: `<range>.hue`, `<range>.sat`, `<range>.light` for each range in `hslRanges` order (24 floats).
    public static let hsl = EffectDescriptor(
        id: "valse.color.hsl", category: .adjustment, nameKey: "adjust.hsl", groupKey: "adjust.group.color",
        params: hslRanges.flatMap { r in
            [ParamSpec.scalar("\(r.key).hue", "hsl.\(r.key).hue", -1, 1, 0, display: 100),
             .scalar("\(r.key).sat", "hsl.\(r.key).sat", -1, 1, 0, display: 100),
             .scalar("\(r.key).light", "hsl.\(r.key).light", -1, 1, 0, display: 100)]
        },
        symbol: "paintpalette",
        shader: """
        constant float HSL_CENTERS[9] = { 0.0, 30.0, 60.0, 120.0, 180.0, 240.0, 270.0, 300.0, 360.0 };
        float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
            float4 c = src.sample(s, uv);
            float3 hsv = fx_rgb2hsv(saturate(c.rgb));
            float h = hsv.x * 360.0;
            int i = 0;
            for (int k = 0; k < 8; k++) { if (h >= HSL_CENTERS[k]) { i = k; } }
            float t = smoothstep(0.0, 1.0, (h - HSL_CENTERS[i]) / (HSL_CENTERS[i + 1] - HSL_CENTERS[i]));
            int j = (i + 1) % 8;
            float wi = 1.0 - t, wj = t;
            float k = smoothstep(0.02, 0.2, hsv.y);           // greys stay untouched
            float dh = (p[i * 3] * wi + p[j * 3] * wj) * k;
            float ds = (p[i * 3 + 1] * wi + p[j * 3 + 1] * wj) * k;
            float dl = (p[i * 3 + 2] * wi + p[j * 3 + 2] * wj) * k;
            hsv.x = fract(hsv.x + dh * (30.0 / 360.0) + 1.0);
            hsv.y = saturate(hsv.y * (1.0 + ds));
            float3 o = fx_hsv2rgb(hsv);
            o = dl >= 0.0 ? mix(o, float3(1.0), dl * 0.5) : o * (1.0 + dl * 0.5);
            return float4(saturate(o), c.a);
        }
        """)

    /// Default curve knots (identity diagonal) — the first 5 point slots of every channel.
    public static let curveKnots: [Double] = [0, 0.25, 0.5, 0.75, 1]
    public static let curveChannels = ["luma", "red", "green", "blue"]

    /// Curves: Brightness (luma) + R + G + B, each 2…8 free points (CapCut: click to add, drag, double-click to
    /// remove), monotone cubic (Fritsch–Carlson) so the curve never overshoots. Luma is applied to all channels first,
    /// then the per-channel curves. `ColorCurveMath` mirrors the shader on the CPU (editor drawing, tests).
    /// Params per channel (p[] order): `<ch>.n` (point count), `<ch>.x0…x7`, `<ch>.y0…y7` — points sorted by x.
    /// Defaults: 5 points on the diagonal, so projects saved with the older fixed-knot version (`<ch>.y0…y4` only)
    /// decode unchanged.
    public static let curves = EffectDescriptor(
        id: "valse.color.curves", category: .adjustment, nameKey: "adjust.curves", groupKey: "adjust.group.color",
        params: curveChannels.flatMap { ch -> [ParamSpec] in
            [ParamSpec.scalar("\(ch).n", "curves.\(ch)", 2, Double(ColorCurveMath.maxPoints), 5)]
            + (0..<ColorCurveMath.maxPoints).map { k in ParamSpec.scalar("\(ch).x\(k)", "curves.\(ch)", 0, 1, k < 5 ? curveKnots[k] : 1, display: 100) }
            + (0..<ColorCurveMath.maxPoints).map { k in ParamSpec.scalar("\(ch).y\(k)", "curves.\(ch)", 0, 1, k < 5 ? curveKnots[k] : 1, display: 100) }
        },
        symbol: "point.topleft.down.curvedto.point.bottomright.up",
        shader: """
        // Perf (1080p budget, EffectsPerfTests): tangents depend only on the params, so they are built once per channel
        // (not once per evaluation) and identity channels (every point on the diagonal, the default) are skipped.
        inline bool curveIsIdentity(constant float* c) {
            int n = clamp(int(c[0] + 0.5), 2, 8);
            for (int k = 0; k < n; k++) { if (abs(c[1 + k] - c[9 + k]) > 1e-5) return false; }
            return c[1] <= 1e-5 && c[n] >= 1.0 - 1e-5;
        }
        inline void curveTangents(constant float* c, thread float* m) {
            int n = clamp(int(c[0] + 0.5), 2, 8);
            constant float* xs = c + 1;
            constant float* ys = c + 9;
            float d[7];
            for (int k = 0; k < n - 1; k++) { d[k] = (ys[k + 1] - ys[k]) / max(xs[k + 1] - xs[k], 1e-4); }
            m[0] = d[0]; m[n - 1] = d[n - 2];
            for (int k = 1; k < n - 1; k++) { m[k] = d[k - 1] * d[k] <= 0.0 ? 0.0 : (d[k - 1] + d[k]) * 0.5; }
            for (int k = 0; k < n - 1; k++) {
                if (abs(d[k]) < 1e-6) { m[k] = 0.0; m[k + 1] = 0.0; continue; }
                float a = m[k] / d[k], b = m[k + 1] / d[k];
                float r = a * a + b * b;
                if (r > 9.0) { float tt = 3.0 / sqrt(r); m[k] = tt * a * d[k]; m[k + 1] = tt * b * d[k]; }
            }
        }
        inline float curveEval(constant float* c, thread const float* m, float x) {
            int n = clamp(int(c[0] + 0.5), 2, 8);
            constant float* xs = c + 1;
            constant float* ys = c + 9;
            float xc = saturate(x);
            if (xc <= xs[0]) return ys[0];
            if (xc >= xs[n - 1]) return ys[n - 1];
            int i = 0;
            for (int k = 0; k < n - 1; k++) { if (xc >= xs[k]) { i = k; } }
            float h = max(xs[i + 1] - xs[i], 1e-4);
            float t = (xc - xs[i]) / h;
            float t2 = t * t, t3 = t2 * t;
            return (2.0 * t3 - 3.0 * t2 + 1.0) * ys[i] + (t3 - 2.0 * t2 + t) * h * m[i]
                 + (-2.0 * t3 + 3.0 * t2) * ys[i + 1] + (t3 - t2) * h * m[i + 1];
        }
        inline float curveN(constant float* c, float x) {
            float m[8]; curveTangents(c, m); return curveEval(c, m, x);
        }
        float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
            float4 c = src.sample(s, uv);
            float3 o = saturate(c.rgb);
            if (!curveIsIdentity(p)) {
                float m[8]; curveTangents(p, m);
                o = float3(curveEval(p, m, o.r), curveEval(p, m, o.g), curveEval(p, m, o.b));
            }
            if (!curveIsIdentity(p + 17)) o.r = curveN(p + 17, o.r);
            if (!curveIsIdentity(p + 34)) o.g = curveN(p + 34, o.g);
            if (!curveIsIdentity(p + 51)) o.b = curveN(p + 51, o.b);
            return float4(saturate(o), c.a);
        }
        """)

    public static let wheelNames = ["lift", "gamma", "gain", "offset"]

    /// Colour wheels (CapCut Primary / Log). Primary = Lift / Gamma / Gain / Offset, ASC-CDL style; Log = the same four
    /// wheels acting as Shadows / Midtones / Highlights / Offset on smooth luminance ranges (`mode` param). Each wheel has a puck (hue 0…360° +
    /// amount 0…1, a chroma-only tint) and a luma slider (−1…1). `strength` mixes the grade with the source.
    /// lift: c + v·(1−c) · gamma: c^(1/(1+v)) · gain: c·(1+v) · offset: c + v/2.
    public static let colorWheels = EffectDescriptor(
        id: "valse.color.wheels", category: .adjustment, nameKey: "adjust.wheels", groupKey: "adjust.group.color",
        params: [ParamSpec.scalar("strength", "fx.param.strength", 0, 1, 1, display: 100)] + wheelNames.flatMap { w in
            [ParamSpec.scalar("\(w).hue", "wheels.\(w).hue", 0, 360, 0),
             .scalar("\(w).amount", "wheels.\(w).amount", 0, 1, 0, display: 100),
             .scalar("\(w).luma", "wheels.\(w).luma", -1, 1, 0, display: 100)]
        } + [ParamSpec("mode", nameKey: "wheels.mode", .choice(optionKeys: ["wheels.mode.primary", "wheels.mode.log"], defaultValue: 0))],
        symbol: "circle.circle",
        shader: """
        inline float3 wheel(constant float* w) {
            float3 hue = fx_hsv2rgb(float3(fract(w[0] / 360.0), 1.0, 1.0));
            float3 chroma = (hue - fx_luma(hue)) * w[1] * 0.5;   // tint without luminance change
            return chroma + w[2] * 0.5;
        }
        float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
            float4 c = src.sample(s, uv);
            float3 o = saturate(c.rgb);
            float3 lift = wheel(p + 1), gam = wheel(p + 4), gain = wheel(p + 7), off = wheel(p + 10);
            if (p[13] < 0.5) {
                o = o + lift * (1.0 - o);
                o = o * (1.0 + gain);
                o = pow(max(o, 0.0), 1.0 / max(1.0 + gam, 0.05));
                o = o + off * 0.5;
            } else {
                // Log wheels: Shadows / Midtones / Highlights act on luminance ranges (smooth, overlapping)
                float l = fx_luma(o);
                float ws = 1.0 - smoothstep(0.0, 0.42, l), wh = smoothstep(0.58, 1.0, l);
                float wm = saturate(1.0 - ws - wh);
                o = o + lift * ws * 0.8 + gam * wm * 0.8 + gain * wh * 0.8 + off * 0.5;
            }
            return float4(mix(c.rgb, saturate(o), saturate(p[0])), c.a);
        }
        """)

    /// White balance in linear light: temperature (blue ↔ amber) and tint (green ↔ magenta) as per-channel gains,
    /// normalized to keep luminance constant (no brightness shift, unlike the quick "Temp" slider of Adjust ▸ Basic).
    public static let whiteBalance = EffectDescriptor(
        id: "valse.color.whiteBalance", category: .adjustment, nameKey: "adjust.whiteBalance", groupKey: "adjust.group.color",
        params: [.scalar("temperature", "adjust.temperature", -1, 1, 0, display: 50),
                 .scalar("tint", "adjust.tint", -1, 1, 0, display: 50)],
        symbol: "thermometer.sun",
        shader: """
        float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
            float4 c = src.sample(s, uv);
            float3 lin = fx_to_linear(saturate(c.rgb));
            float3 g = float3(1.0 + 0.35 * p[0], 1.0 - 0.3 * p[1], 1.0 - 0.35 * p[0]);
            g /= dot(g, float3(0.2126, 0.7152, 0.0722));         // luminance-preserving
            return float4(saturate(fx_to_display(lin * g)), c.a);
        }
        """)

    public static let all: [EffectDescriptor] = [hsl, curves, colorWheels, whiteBalance]
}
