import MontageCore

/// Video ▸ Cutout ▸ Chroma key. An ordinary effect-stack entry (category `.key`, hidden from the asset panel), so it
/// renders in preview and export through the normal effect path and every parameter is keyframeable.
///
/// The key colour's alpha doubles as "picked": until the user samples a colour (alpha 0) the shader passes pixels
/// through and the inspector greys out the sliders, like CapCut ("First pick the color of the screen…").
public enum BuiltinKeying {
    public static let chromaKeyID = "montage.key.chroma"

    public static let chromaKey = EffectDescriptor(
        id: chromaKeyID, category: .key, nameKey: "key.chroma", groupKey: "key.group.cutout",
        params: [
            ParamSpec("color", nameKey: "key.chroma.color", .color(defaultValue: RGBA(0, 0, 0, 0))),
            .scalar("intensity", "key.chroma.intensity", 0, 1, 0.2, display: 100),
            .scalar("shadow", "key.chroma.shadow", 0, 1, 0, display: 100),
            .scalar("feather", "key.chroma.feather", 0, 1, 0, display: 100),
            .scalar("cleanup", "key.chroma.cleanup", 0, 1, 0, display: 100),
        ],
        symbol: "eyedropper",
        shader: """
        // W6 keyer: chroma relative to luma (hue + saturation, independent of how evenly the screen is lit),
        // normalised by the key's own chroma; shadow keeps darkened screen as semi-transparent black; clean-up
        // chokes the fringe and removes the key colour cast (despill) from what remains.
        inline float3 kc_ycc(float3 c) {
            float y = dot(c, float3(0.2126, 0.7152, 0.0722));
            return float3(y, (c.b - y) / 1.8556, (c.r - y) / 1.5748);
        }
        float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
            float4 c = src.sample(s, uv);
            if (p[3] < 0.5) return c;                                   // no colour picked yet
            float intensity = p[4], shadow = p[5], feather = p[6], cleanup = p[7];
            float3 k = kc_ycc(float3(p[0], p[1], p[2])), q = kc_ycc(c.rgb);
            float2 kc = k.yz / max(k.x, 0.1), pc = q.yz / max(q.x, 0.1);
            float d = length(pc - kc) / max(length(kc), 0.08);
            float thr = mix(0.05, 0.9, intensity);
            float soft = max(feather * 0.6, 0.01);
            float a = smoothstep(thr, thr + soft, d);
            a = saturate((a - cleanup * 0.3) / max(1.0 - cleanup * 0.3, 0.001));
            float darker = saturate((k.x - q.x) / max(k.x, 0.05));
            float sh = shadow * darker * (1.0 - a);
            // despill along the key's chroma direction
            float2 kd = normalize(k.yz + float2(1e-5));
            float along = dot(q.yz, kd);
            if (along > 0.0) { q.yz -= kd * along * saturate(0.5 + cleanup); }
            float3 rgb = float3(q.x + 1.5748 * q.z, q.x - 0.1873 * q.y - 0.4681 * q.z, q.x + 1.8556 * q.y);
            rgb = mix(rgb, float3(0.0), sh / max(a + sh, 1e-4) * step(a, 0.999));
            return float4(saturate(rgb), c.a * saturate(a + sh));
        }
        """)

    public static let all: [EffectDescriptor] = [chromaKey]
}

/// Video ▸ Basic ▸ Canvas ▸ Style: procedural backgrounds (CapCut ships image patterns; ours are shaders so they are
/// resolution-independent). Category `.canvas`, hidden from the asset panel; drawn on a full-canvas `.solid` layer
/// by `FrameEvaluator.canvasItems`. The shader ignores `src`.
public enum BuiltinCanvasStyles {
    static func style(_ name: String, _ body: String) -> EffectDescriptor {
        EffectDescriptor(id: "montage.canvas.\(name)", category: .canvas, nameKey: "canvas.style.\(name)",
                         groupKey: "canvas.group.style", symbol: "square.grid.2x2", shader: """
        float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
            float2 q = float2(uv.x * ctx.aspect, uv.y);
            float3 o = float3(0.0);
            \(body)
            return float4(saturate(o), 1.0);
        }
        """)
    }

    public static let all: [EffectDescriptor] = [
        style("sunset", "o = mix(float3(0.98, 0.62, 0.36), float3(0.55, 0.22, 0.52), uv.y);"),
        style("ocean", "o = mix(float3(0.20, 0.75, 0.80), float3(0.07, 0.17, 0.42), uv.y);"),
        style("mint", "o = mix(float3(0.80, 0.96, 0.86), float3(0.42, 0.78, 0.66), length(uv - 0.5) * 1.3);"),
        style("stripes", "float k = step(0.5, fract((q.x + q.y) * 9.0)); o = mix(float3(0.96, 0.85, 0.40), float3(0.98, 0.93, 0.70), k);"),
        style("dots", """
            float2 g = fract(q * 14.0) - 0.5;
            float k = 1.0 - smoothstep(0.17, 0.2, length(g));
            o = mix(float3(0.98, 0.80, 0.84), float3(1.0), k);
            """),
        style("grid", """
            float2 g = abs(fract(q * 12.0) - 0.5);
            float k = 1.0 - smoothstep(0.44, 0.47, max(g.x, g.y));
            o = mix(float3(0.85, 0.89, 0.97), float3(0.16, 0.20, 0.32), 1.0 - k);
            """),
        style("checker", """
            float2 g = floor(q * 10.0);
            float k = fmod(g.x + g.y, 2.0);
            o = mix(float3(0.93), float3(0.80), k);
            """),
        style("waves", """
            float w = sin(q.x * 14.0 + sin(q.y * 6.0) * 2.0) * 0.5 + 0.5;
            o = mix(float3(0.42, 0.36, 0.84), float3(0.70, 0.52, 0.95), smoothstep(0.35, 0.65, fract(q.y * 6.0 + w * 0.5)));
            """),
    ]
}
