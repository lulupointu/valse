import MontageCore

/// "Filters" tab: look presets. Every filter has an Intensity (0…1) as p[0].
public enum BuiltinFilters {
    static let intensity = ParamSpec.scalar("intensity", "fx.param.intensity", 0, 1, 1, display: 100)

    static func filter(_ name: String, group: String, _ body: String) -> EffectDescriptor {
        EffectDescriptor(id: "montage.filter.\(name)", category: .filter, nameKey: "filter.\(name)",
                         groupKey: "filter.group.\(group)", params: [intensity], symbol: "camera.filters", shader: """
        float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
            float4 c = src.sample(s, uv);
            float3 o = c.rgb;
            \(body)
            return float4(mix(c.rgb, saturate(o), p[0]), c.a);
        }
        """)
    }

    public static let all: [EffectDescriptor] = [
        filter("mono", group: "bw", "o = float3(fx_luma(c.rgb));"),
        filter("noir", group: "bw", "float l = fx_luma(c.rgb); l = smoothstep(0.08, 0.92, l); o = float3(l);"),
        filter("warm", group: "life", "o = c.rgb * float3(1.08, 1.0, 0.86) + float3(0.02, 0.01, 0.0);"),
        filter("cool", group: "life", "o = c.rgb * float3(0.88, 1.0, 1.1);"),
        filter("vivid", group: "life", "float l = fx_luma(c.rgb); o = mix(float3(l), c.rgb, 1.45); o = (o - 0.5) * 1.08 + 0.5;"),
        filter("fade", group: "retro", "o = mix(c.rgb, float3(0.55, 0.5, 0.45), 0.25); o = mix(float3(fx_luma(o)), o, 0.75);"),
        filter("sepia", group: "retro", """
            float3 x = c.rgb;
            o = float3(dot(x, float3(0.393, 0.769, 0.189)), dot(x, float3(0.349, 0.686, 0.168)), dot(x, float3(0.272, 0.534, 0.131)));
            """),
        filter("invert", group: "creative", "o = 1.0 - c.rgb;"),
    ]
}
