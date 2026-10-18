import MontageCore

/// Colour-grading descriptors (CapCut Adjust ▸ HSL / Curves / Color wheel, plus a physically-based white balance).
/// All parameters are scalars, so they get generated inspector sliders and keyframes for free.
public enum BuiltinColor {
    /// The 8 CapCut HSL colour ranges, with their centre hue in degrees.
    public static let hslRanges: [(key: String, hue: Double)] = [
        ("red", 0), ("orange", 30), ("yellow", 60), ("green", 120), ("cyan", 180), ("blue", 240), ("purple", 270), ("magenta", 300),
    ]

    /// HSL: per range Hue (±30° shift), Saturation and Lightness (−1…1). Hue weights form a partition of unity between
    /// neighbouring range centres (smoothstep falloff), scaled by pixel saturation so greys are never touched.
    /// Params: `<range>.hue`, `<range>.sat`, `<range>.light` for each range in `hslRanges` order (24 floats).
    public static let hsl = EffectDescriptor(
        id: "montage.color.hsl", category: .adjustment, nameKey: "adjust.hsl", groupKey: "adjust.group.color",
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

    /// Curve control points: fixed x positions, adjustable y (CapCut lets you drag points; we expose 5 knots).
    public static let curveKnots: [Double] = [0, 0.25, 0.5, 0.75, 1]
    public static let curveChannels = ["luma", "red", "green", "blue"]

    /// Curves: Brightness (luma) + R + G + B, 5 knots each, monotone cubic (Fritsch–Carlson) interpolation so the
    /// curve never overshoots. Luma is applied to all channels first, then the per-channel curves.
    /// Params: `<channel>.y<k>` (k = 0…4), defaults on the identity diagonal.
    public static let curves = EffectDescriptor(
        id: "montage.color.curves", category: .adjustment, nameKey: "adjust.curves", groupKey: "adjust.group.color",
        params: curveChannels.flatMap { ch in
            curveKnots.enumerated().map { k, x in ParamSpec.scalar("\(ch).y\(k)", "curves.\(ch)", 0, 1, x, display: 100) }
        },
        symbol: "point.topleft.down.to.point.bottomright.curvepath",
        shader: """
        inline float curve5(constant float* y, float x) {
            const float h = 0.25;
            float d[4]; float m[5];
            for (int k = 0; k < 4; k++) { d[k] = (y[k + 1] - y[k]) / h; }
            m[0] = d[0]; m[4] = d[3];
            for (int k = 1; k < 4; k++) { m[k] = d[k - 1] * d[k] <= 0.0 ? 0.0 : (d[k - 1] + d[k]) * 0.5; }
            for (int k = 0; k < 4; k++) {
                if (abs(d[k]) < 1e-6) { m[k] = 0.0; m[k + 1] = 0.0; continue; }
                float a = m[k] / d[k], b = m[k + 1] / d[k];
                float r = a * a + b * b;
                if (r > 9.0) { float tt = 3.0 / sqrt(r); m[k] = tt * a * d[k]; m[k + 1] = tt * b * d[k]; }
            }
            float xc = saturate(x);
            int i = min(int(xc / h), 3);
            float t = (xc - float(i) * h) / h;
            float t2 = t * t, t3 = t2 * t;
            return (2.0 * t3 - 3.0 * t2 + 1.0) * y[i] + (t3 - 2.0 * t2 + t) * h * m[i]
                 + (-2.0 * t3 + 3.0 * t2) * y[i + 1] + (t3 - t2) * h * m[i + 1];
        }
        float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
            float4 c = src.sample(s, uv);
            float3 o = saturate(c.rgb);
            o = float3(curve5(p, o.r), curve5(p, o.g), curve5(p, o.b));
            o = float3(curve5(p + 5, o.r), curve5(p + 10, o.g), curve5(p + 15, o.b));
            return float4(saturate(o), c.a);
        }
        """)

    public static let wheelNames = ["lift", "gamma", "gain", "offset"]

    /// Primary colour wheels (Lift / Gamma / Gain / Offset, ASC-CDL style). Each wheel has a puck (hue 0…360° +
    /// amount 0…1, a chroma-only tint) and a luma slider (−1…1). `strength` mixes the grade with the source.
    /// lift: c + v·(1−c) · gamma: c^(1/(1+v)) · gain: c·(1+v) · offset: c + v/2.
    public static let colorWheels = EffectDescriptor(
        id: "montage.color.wheels", category: .adjustment, nameKey: "adjust.wheels", groupKey: "adjust.group.color",
        params: [ParamSpec.scalar("strength", "fx.param.strength", 0, 1, 1, display: 100)] + wheelNames.flatMap { w in
            [ParamSpec.scalar("\(w).hue", "wheels.\(w).hue", 0, 360, 0),
             .scalar("\(w).amount", "wheels.\(w).amount", 0, 1, 0, display: 100),
             .scalar("\(w).luma", "wheels.\(w).luma", -1, 1, 0, display: 100)]
        },
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
            o = o + lift * (1.0 - o);
            o = o * (1.0 + gain);
            o = pow(max(o, 0.0), 1.0 / max(1.0 + gam, 0.05));
            o = o + off * 0.5;
            return float4(mix(c.rgb, saturate(o), saturate(p[0])), c.a);
        }
        """)

    /// White balance in linear light: temperature (blue ↔ amber) and tint (green ↔ magenta) as per-channel gains,
    /// normalized to keep luminance constant (no brightness shift, unlike the quick "Temp" slider of Adjust ▸ Basic).
    public static let whiteBalance = EffectDescriptor(
        id: "montage.color.whiteBalance", category: .adjustment, nameKey: "adjust.whiteBalance", groupKey: "adjust.group.color",
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
