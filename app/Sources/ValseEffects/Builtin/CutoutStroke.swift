import ValseCore

/// Video ▸ Cutout ▸ ☐ Stroke (CK-005): an outline around the cut-out subject (sticker look), from the layer alpha
/// (AI matte, custom cutout or chroma key — it must run after the key, so it is appended at the end of the stack).
/// Dilation of the alpha over 4 rings × 24 directions (≈ distance field) gives the stroke; Glow adds a soft halo.
public enum BuiltinCutoutStroke {
    public static let id = "valse.cutout.stroke"

    public static let stroke = EffectDescriptor(
        id: id, category: .key, nameKey: "cutout.stroke", groupKey: "key.group.cutout",
        params: [
            ParamSpec("color", nameKey: "cutout.stroke.color", .color(defaultValue: RGBA(1, 1, 1, 1))),
            .scalar("size", "cutout.stroke.size", 0, 1, 0.3, display: 100),
            .scalar("opacity", "cutout.stroke.opacity", 0, 1, 1, display: 100),
            .scalar("glow", "cutout.stroke.glow", 0, 1, 0, display: 100),
        ],
        symbol: "circle.dashed",
        shader: """
        float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
            float4 o = src.sample(s, uv);
            // an opaque pixel is returned unchanged by the formula below (outA = 1, rgb = o.rgb): skip the 96-192 taps
            if (o.a >= 1.0) return float4(saturate(o.rgb), 1.0);
            float3 sc = float3(p[0], p[1], p[2]);
            float px = ctx.size.y / 1080.0;
            float rad = (1.0 + p[4] * 40.0) * px;
            float glow = p[6];
            float dil = 0.0, halo = 0.0;
            for (int k = 1; k <= 4; k++) {
                float rr = rad * float(k) / 4.0;
                for (int i = 0; i < 24; i++) {
                    float ang = (float(i) + 0.5 * float(k & 1)) / 24.0 * 6.28318;
                    float2 d = float2(cos(ang), sin(ang)) / ctx.size;
                    dil = max(dil, src.sample(s, uv + d * rr).a);
                    if (glow > 0.0) halo = max(halo, src.sample(s, uv + d * (rad + rr * 1.5)).a * (1.0 - float(k) / 5.0));
                }
                // without glow the result only needs dil, and alpha never exceeds 1: done once it is reached
                if (glow <= 0.0 && dil >= 1.0) break;
            }
            float stroke = saturate(dil - o.a) * p[5];
            float g = saturate(halo - dil) * glow * p[5];
            float sa = saturate(stroke + g * (1.0 - stroke));
            float outA = o.a + sa * (1.0 - o.a);
            float3 rgb = (o.rgb * o.a + sc * sa * (1.0 - o.a)) / max(outA, 1e-4);
            return float4(saturate(rgb), outA);
        }
        """)

    public static let all: [EffectDescriptor] = [stroke]
}
