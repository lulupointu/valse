import ValseCore

/// "Adjustment" tab: the basic colour panel (CapCut Adjust → Basic). One descriptor holding all sliders so the
/// inspector shows them as one section and an adjustment clip carries one instance.
///
/// Params (p[] order — append only, saved projects store values by key): brightness, contrast, saturation, exposure,
/// temperature, tint, highlights, shadows, vignette (bipolar: + darkens, − whitens), hue, whites, blacks, sharpen,
/// clarity, grain ("Particles"), fade.
public enum BuiltinAdjustments {
    public static let basic = EffectDescriptor(
        id: "valse.adjust.basic", category: .adjustment, nameKey: "adjust.basic", groupKey: "adjust.group.basic",
        params: [
            .scalar("brightness", "adjust.brightness", -1, 1, 0, display: 50),
            .scalar("contrast", "adjust.contrast", -1, 1, 0, display: 50),
            .scalar("saturation", "adjust.saturation", -1, 1, 0, display: 50),
            .scalar("exposure", "adjust.exposure", -1, 1, 0, display: 50),
            .scalar("temperature", "adjust.temperature", -1, 1, 0, display: 50),
            .scalar("tint", "adjust.tint", -1, 1, 0, display: 50),
            .scalar("highlights", "adjust.highlights", -1, 1, 0, display: 50),
            .scalar("shadows", "adjust.shadows", -1, 1, 0, display: 50),
            .scalar("vignette", "adjust.vignette", -1, 1, 0, display: 50),
            .scalar("hue", "adjust.hue", -1, 1, 0, display: 50),
            .scalar("whites", "adjust.whites", -1, 1, 0, display: 50),
            .scalar("blacks", "adjust.blacks", -1, 1, 0, display: 50),
            .scalar("sharpen", "adjust.sharpen", 0, 1, 0, display: 100),
            .scalar("clarity", "adjust.clarity", 0, 1, 0, display: 100),
            .scalar("grain", "adjust.grain", 0, 1, 0, display: 100),
            .scalar("fade", "adjust.fade", 0, 1, 0, display: 100),
        ],
        symbol: "slider.horizontal.3",
        shader: """
        float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
            float4 c = src.sample(s, uv);
            float3 o = c.rgb;
            // sharpen (unsharp, 1 px at 1080p) and clarity (midtone local contrast, ~12 px) on the source
            if (p[12] > 0.0 || p[13] > 0.0) {
                float2 d = max(1.0, ctx.size.y / 1080.0) / ctx.size;
                float3 b = (src.sample(s, uv + float2(d.x, 0)).rgb + src.sample(s, uv - float2(d.x, 0)).rgb
                          + src.sample(s, uv + float2(0, d.y)).rgb + src.sample(s, uv - float2(0, d.y)).rgb) * 0.25;
                o += (o - b) * p[12] * 2.5;
                float2 D = d * 12.0;
                float lb = 0.0;
                for (int i = 0; i < 8; i++) {
                    float a = float(i) * 0.785398;
                    lb += fx_luma(src.sample(s, uv + float2(cos(a), sin(a)) * D).rgb);
                }
                lb /= 8.0;
                float l0 = fx_luma(c.rgb);
                float mid = 1.0 - abs(l0 - 0.5) * 2.0;
                o += (l0 - lb) * p[13] * 1.6 * (0.35 + 0.65 * mid);
            }
            o *= exp2(p[3] * 2.0);                                   // exposure (±2 stops)
            o += p[0] * 0.3;                                         // brightness
            o = (o - 0.5) * (1.0 + p[1]) + 0.5;                      // contrast
            float l = fx_luma(o);
            o = mix(float3(l), o, 1.0 + p[2]);                       // saturation
            if (abs(p[9]) > 1e-4) {                                  // hue (±60°)
                float3 hsv = fx_rgb2hsv(saturate(o)); hsv.x = fract(hsv.x + p[9] / 6.0 + 1.0); o = fx_hsv2rgb(hsv);
            }
            o += float3(p[4], 0.0, -p[4]) * 0.1;                     // temperature
            o += float3(0.0, -p[5], 0.0) * 0.08 + float3(p[5], 0.0, p[5]) * 0.04; // tint
            float hl = smoothstep(0.5, 1.0, l), sh = 1.0 - smoothstep(0.0, 0.5, l);
            o += p[6] * 0.25 * hl + p[7] * 0.25 * sh;                // highlights / shadows
            o += p[10] * 0.2 * smoothstep(0.7, 1.0, l);              // whites
            o += p[11] * 0.15 * (1.0 - smoothstep(0.0, 0.3, l));     // blacks
            o = o * (1.0 - p[15] * 0.25) + p[15] * 0.25 * float3(0.52, 0.5, 0.48);   // fade
            float2 d = uv - 0.5;
            float v = smoothstep(0.25, 0.75, length(d * float2(ctx.aspect, 1.0)) / max(ctx.aspect, 1.0) * 1.4);
            o = p[8] >= 0.0 ? o * (1.0 - p[8] * v) : mix(o, float3(1.0), -p[8] * v * 0.85);   // vignette
            if (p[14] > 0.0) {                                       // grain ("Particles")
                float gs = max(1.0, 1.4 * ctx.size.y / 1080.0);
                float2 gp = floor(uv * ctx.size / gs);
                float n = fract(sin(dot(gp + floor(ctx.time * 24.0) * 1.37, float2(12.9898, 78.233))) * 43758.5453) - 0.5;
                o += n * p[14] * 0.18;
            }
            return float4(saturate(o), c.a);
        }
        """)

    public static let all: [EffectDescriptor] = [basic, AutoColor.descriptor]
}
