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
        inline float2 kc_chroma(float3 c) {
            return float2(dot(c, float3(-0.1146, -0.3854, 0.5)), dot(c, float3(0.5, -0.4542, -0.0458)));
        }
        float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
            float4 c = src.sample(s, uv);
            float3 key = float3(p[0], p[1], p[2]);
            if (p[3] < 0.5) return c;                                   // no colour picked yet
            float intensity = p[4], shadow = p[5], feather = p[6], cleanup = p[7];
            float d = distance(kc_chroma(c.rgb), kc_chroma(key));
            float thr = intensity * 0.32;
            float soft = 0.004 + feather * 0.16;
            float a = smoothstep(thr, thr + soft, d);
            // Shadow: keep darkened areas of the screen (cast shadows) as semi-transparent black.
            float dl = saturate((fx_luma(key) - fx_luma(c.rgb)) * 2.5);
            float sh = shadow * dl * (1.0 - a);
            // Edge clean-up: remove key-colour spill from what remains.
            float3 rgb = c.rgb;
            float spill = (1.0 - smoothstep(thr, thr + soft + 0.12, d)) * cleanup;
            float3 kn = normalize(key + 1e-4);
            float amount = max(dot(rgb, kn) - fx_luma(rgb), 0.0);
            rgb = mix(rgb, rgb - kn * amount, saturate(spill * 1.5));
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
