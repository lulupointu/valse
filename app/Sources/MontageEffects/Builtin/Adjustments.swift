import MontageCore

/// "Adjustment" tab: the basic colour panel (CapCut Adjust → Basic). One descriptor holding all sliders so the
/// inspector shows them as one section and an adjustment clip carries one instance.
public enum BuiltinAdjustments {
    public static let basic = EffectDescriptor(
        id: "montage.adjust.basic", category: .adjustment, nameKey: "adjust.basic", groupKey: "adjust.group.basic",
        params: [
            .scalar("brightness", "adjust.brightness", -1, 1, 0, display: 50),
            .scalar("contrast", "adjust.contrast", -1, 1, 0, display: 50),
            .scalar("saturation", "adjust.saturation", -1, 1, 0, display: 50),
            .scalar("exposure", "adjust.exposure", -1, 1, 0, display: 50),
            .scalar("temperature", "adjust.temperature", -1, 1, 0, display: 50),
            .scalar("tint", "adjust.tint", -1, 1, 0, display: 50),
            .scalar("highlights", "adjust.highlights", -1, 1, 0, display: 50),
            .scalar("shadows", "adjust.shadows", -1, 1, 0, display: 50),
            .scalar("vignette", "adjust.vignette", 0, 1, 0, display: 100),
        ],
        symbol: "slider.horizontal.3",
        shader: """
        float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
            float4 c = src.sample(s, uv);
            float3 o = c.rgb;
            o *= exp2(p[3] * 2.0);                                   // exposure (±2 stops)
            o += p[0] * 0.3;                                         // brightness
            o = (o - 0.5) * (1.0 + p[1]) + 0.5;                      // contrast
            float l = fx_luma(o);
            o = mix(float3(l), o, 1.0 + p[2]);                       // saturation
            o += float3(p[4], 0.0, -p[4]) * 0.1;                     // temperature
            o += float3(0.0, -p[5], 0.0) * 0.08 + float3(p[5], 0.0, p[5]) * 0.04; // tint
            float hl = smoothstep(0.5, 1.0, l), sh = 1.0 - smoothstep(0.0, 0.5, l);
            o += p[6] * 0.25 * hl + p[7] * 0.25 * sh;                // highlights / shadows
            float2 d = uv - 0.5;
            o *= 1.0 - p[8] * smoothstep(0.25, 0.75, length(d * float2(ctx.aspect, 1.0)) / max(ctx.aspect, 1.0) * 1.4);
            return float4(saturate(o), c.a);
        }
        """)

    public static let all: [EffectDescriptor] = [basic]
}
