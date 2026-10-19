import Foundation
import MontageCore

/// FX-008 "Magic cutout" body effects: the person is cut out (person matte, automatic on plain video — FX-002) and
/// animated over a restyled background. `src` = the cut-out person, `backdrop` = the whole un-cut frame,
/// `orig` = the cut-out person again for the second pass (the first pass blurs the backdrop horizontally).
/// p: intensity, speed · c: mode (0 pop: darkened blurred background + pulsing person with a white stroke;
/// 1 spotlight: black & white background, the person in colour with a warm glow; 2 colour pop: hue-cycling background,
/// sticker-like white outline + drop shadow).
public enum FXMagic {
    static let magic = FXBase("magicCutout", params: [FXKit.intensity(0.7), FXKit.speed(0.5)], passes: 2,
                              inputs: [.backdrop, .original], symbol: "person.crop.rectangle.badge.plus", """
    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx,
                  texture2d<float> bd, texture2d<float> orig) {
        constant float* c = p + 2;
        float px = (2.0 + 6.0 * p[0]) * ctx.size.y / 1080.0;
        if (ctx.pass == 0) { return kit_blur17(bd, s, uv, float2(px / ctx.size.x, 0.0)); }
        float4 bg = kit_blur17(src, s, uv, float2(0.0, px / ctx.size.y));
        int mode = int(c[0] + 0.5);
        float t = ctx.time * (0.5 + p[1] * 3.0);
        float lum = dot(bg.rgb, float3(0.2126, 0.7152, 0.0722));
        float3 back;
        if (mode == 0) back = bg.rgb * (1.0 - 0.65 * p[0]);
        else if (mode == 1) back = float3(lum) * (1.0 - 0.5 * p[0]);
        else back = mix(bg.rgb, kit_hue(fract(t * 0.08)) * (0.35 + 0.65 * lum), 0.75 * p[0]);
        // the person: a gentle pulse (pop), still otherwise
        float z = mode == 0 ? 1.0 + 0.05 * p[0] * (0.5 + 0.5 * sin(t * 2.5)) : 1.0;
        float2 puv = (uv - 0.5) / z + 0.5;
        float4 o = orig.sample(s, puv);
        float rad = (3.0 + 9.0 * p[0]) * ctx.size.y / 1080.0;
        float dil = 0.0, wide = 0.0;
        for (int i = 0; i < 16; i++) {
            float ang = float(i) / 16.0 * 6.28318;
            float2 d = float2(cos(ang), sin(ang)) / ctx.size;
            dil = max(dil, orig.sample(s, puv + d * rad).a);
            wide = max(wide, orig.sample(s, puv + d * rad * 3.0).a);
        }
        float stroke = saturate(dil - o.a);
        float3 rgb = back;
        float outA = max(bg.a, 0.0);
        if (mode == 1) {
            float glow = saturate(wide - o.a) * 0.55 * p[0];
            rgb = mix(rgb, float3(1.0, 0.86, 0.55), glow);
            outA = max(outA, glow);
        } else {
            if (mode == 2) {
                float sh = orig.sample(s, puv - float2(0.012, -0.018) * p[0]).a * 0.6;
                rgb = mix(rgb, float3(0.0), sh * (1.0 - o.a));
                outA = max(outA, sh);
            }
            rgb = mix(rgb, float3(1.0), stroke);
            outA = max(outA, stroke);
        }
        rgb = mix(rgb, o.rgb, o.a);
        outA = max(outA, o.a);
        return float4(saturate(rgb), outA);
    }
    """)

    public static let all: [EffectDescriptor] = [
        magic.preset("magicCutout", group: "body", [0], tags: ["magic", "cutout", "pop", "person", "subject"]),
        magic.preset("magicSpotlight", group: "body", [1], tags: ["magic", "cutout", "spotlight", "black and white", "colour"]),
        magic.preset("magicColorPop", group: "body", [2], tags: ["magic", "cutout", "sticker", "outline", "colour"]),
    ]
}
