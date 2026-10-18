/// Core compositor passes (MSL, compiled at runtime — the offline Metal toolchain is an optional Xcode component).
/// Effects/transitions are compiled separately (EffectPipelines) so a broken effect can't break the compositor.
enum CoreShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct QuadOut { float4 pos [[position]]; float2 uv; };

    // Full-target quad; uv (0,0) top-left.
    vertex QuadOut fullscreen_vs(uint vid [[vertex_id]]) {
        float2 c = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? -1.0 : 1.0);
        QuadOut o; o.pos = float4(c, 0, 1); o.uv = float2((c.x + 1.0) * 0.5, (1.0 - c.y) * 0.5); return o;
    }

    // ---- Source conversion → straight RGBA (half float). uvXform maps target uv → source uv (crop/flip/rotate).
    struct ConvertU { float3x2 uvXform; float fullRange; float matrix709; float unpremultiply; float pad; };

    inline float2 xf(constant ConvertU& u, float2 uv) { return u.uvXform * float3(uv, 1.0); }

    fragment float4 convert_yuv_fs(QuadOut in [[stage_in]], texture2d<float> yT [[texture(0)]],
                                   texture2d<float> cT [[texture(1)]], constant ConvertU& u [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 suv = xf(u, in.uv);
        float y = yT.sample(s, suv).r;
        float2 c = cT.sample(s, suv).rg;
        if (u.fullRange > 0.5) { c -= 0.5; }
        else { y = (y - 16.0/255.0) * (255.0/219.0); c = (c - 128.0/255.0) * (255.0/224.0); }
        float3 rgb = u.matrix709 > 0.5
            ? float3(y + 1.5748 * c.y, y - 0.1873 * c.x - 0.4681 * c.y, y + 1.8556 * c.x)
            : float3(y + 1.402 * c.y, y - 0.344136 * c.x - 0.714136 * c.y, y + 1.772 * c.x);
        return float4(saturate(rgb), 1.0);
    }

    fragment float4 convert_rgba_fs(QuadOut in [[stage_in]], texture2d<float> t [[texture(0)]],
                                    constant ConvertU& u [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float4 c = t.sample(s, xf(u, in.uv));
        if (u.unpremultiply > 0.5 && c.a > 0.0) { c.rgb /= c.a; }
        return c;
    }

    fragment float4 solid_fs(QuadOut in [[stage_in]], constant float4& color [[buffer(0)]]) { return color; }

    // ---- Layer placement onto the premultiplied accumulation target, with blend modes (framebuffer fetch) + mask.
    struct PlaceU {
        float2 corners[4];   // NDC: TL, TR, BL, BR
        float opacity;
        int blend;
        int maskShape;       // -1 none, 0 linear, 1 mirror, 2 circle, 3 rectangle
        float maskInvert;
        float2 maskCenter;
        float2 maskSize;
        float maskRotation;
        float maskFeather;
        float maskRoundness;
        float layerAspect;
    };

    vertex QuadOut place_vs(uint vid [[vertex_id]], constant PlaceU& u [[buffer(0)]]) {
        QuadOut o;
        o.pos = float4(u.corners[vid], 0, 1);
        o.uv = float2((vid & 1) ? 1.0 : 0.0, (vid & 2) ? 1.0 : 0.0);
        return o;
    }

    inline float blendChannel(int m, float b, float s) {
        switch (m) {
            case 1: return min(b, s);                                         // darken
            case 2: return b * s;                                             // multiply
            case 3: return b >= 1.0 ? 1.0 : (s <= 0.0 ? 0.0 : 1.0 - min(1.0, (1.0 - b) / s)); // color burn
            case 4: return max(b, s);                                         // lighten
            case 5: return b + s - b * s;                                     // screen
            case 6: return b <= 0.0 ? 0.0 : (s >= 1.0 ? 1.0 : min(1.0, b / (1.0 - s)));     // color dodge
            case 7: return min(1.0, b + s);                                   // add
            case 8: return b <= 0.5 ? 2.0 * b * s : 1.0 - 2.0 * (1.0 - b) * (1.0 - s);      // overlay
            case 9: {                                                         // soft light
                float d = b <= 0.25 ? ((16.0 * b - 12.0) * b + 4.0) * b : sqrt(b);
                return s <= 0.5 ? b - (1.0 - 2.0 * s) * b * (1.0 - b) : b + (2.0 * s - 1.0) * (d - b);
            }
            case 10: return s <= 0.5 ? 2.0 * b * s : 1.0 - 2.0 * (1.0 - b) * (1.0 - s);     // hard light
            case 11: return abs(b - s);                                       // difference
            case 12: return b + s - 2.0 * b * s;                              // exclusion
            default: return s;                                                // normal
        }
    }

    inline float maskAlpha(constant PlaceU& u, float2 uv) {
        if (u.maskShape < 0) { return 1.0; }
        float2 q = (uv - 0.5 - u.maskCenter) * float2(u.layerAspect, 1.0);
        float cr = cos(-u.maskRotation), sr = sin(-u.maskRotation);
        q = float2(q.x * cr - q.y * sr, q.x * sr + q.y * cr);
        float f = max(u.maskFeather * 0.25, 0.002);
        float a = 1.0;
        if (u.maskShape == 0) {
            a = 1.0 - smoothstep(-f, f, q.y);
        } else if (u.maskShape == 1) {
            float h = u.maskSize.y * 0.5;
            a = 1.0 - smoothstep(h - f, h + f, abs(q.y));
        } else if (u.maskShape == 2) {
            float2 r = max(u.maskSize * float2(u.layerAspect, 1.0) * 0.5, float2(0.0001));
            float d = length(q / r);
            float ff = f / max(min(r.x, r.y), 0.0001);
            a = 1.0 - smoothstep(1.0 - ff, 1.0 + ff, d);
        } else {
            float2 h = u.maskSize * float2(u.layerAspect, 1.0) * 0.5;
            float rr = u.maskRoundness * min(h.x, h.y);
            float2 d2 = abs(q) - h + rr;
            float d = length(max(d2, 0.0)) + min(max(d2.x, d2.y), 0.0) - rr;
            a = 1.0 - smoothstep(-f, f, d);
        }
        return u.maskInvert > 0.5 ? 1.0 - a : a;
    }

    fragment float4 place_fs(QuadOut in [[stage_in]], float4 dst [[color(0)]], texture2d<float> t [[texture(0)]],
                             constant PlaceU& u [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float4 src = t.sample(s, in.uv);                    // straight alpha
        float as = src.a * u.opacity * maskAlpha(u, in.uv);
        if (as <= 0.0) { return dst; }
        float ab = dst.a;
        float3 cb = ab > 0.0 ? dst.rgb / ab : float3(0.0);
        float3 mixed = src.rgb;
        if (u.blend != 0) {
            float3 bl = float3(blendChannel(u.blend, cb.r, src.r), blendChannel(u.blend, cb.g, src.g), blendChannel(u.blend, cb.b, src.b));
            mixed = (1.0 - ab) * src.rgb + ab * bl;
        }
        return float4(as * mixed + (1.0 - as) * dst.rgb, as + ab * (1.0 - as));
    }

    // ---- Adjustment-layer mix: out = mix(original, processed, opacity), premultiplied accumulation.
    fragment float4 mix_fs(QuadOut in [[stage_in]], texture2d<float> a [[texture(0)]], texture2d<float> b [[texture(1)]],
                           constant float& k [[buffer(0)]]) {
        constexpr sampler s(filter::nearest, address::clamp_to_edge);
        return mix(a.sample(s, in.uv), b.sample(s, in.uv), k);
    }

    // Premultiplied → straight (so effects see straight colors).
    fragment float4 unpremultiply_fs(QuadOut in [[stage_in]], texture2d<float> a [[texture(0)]]) {
        constexpr sampler s(filter::nearest, address::clamp_to_edge);
        float4 c = a.sample(s, in.uv);
        return c.a > 0.0 ? float4(c.rgb / c.a, c.a) : float4(0.0);
    }
    fragment float4 premultiply_fs(QuadOut in [[stage_in]], texture2d<float> a [[texture(0)]]) {
        constexpr sampler s(filter::nearest, address::clamp_to_edge);
        float4 c = a.sample(s, in.uv);
        return float4(c.rgb * c.a, c.a);
    }

    // ---- Final output: premultiplied accumulation over opaque background → 8-bit target.
    fragment float4 output_fs(QuadOut in [[stage_in]], texture2d<float> a [[texture(0)]], constant float4& bg [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float4 c = a.sample(s, in.uv);
        return float4(saturate(c.rgb + bg.rgb * (1.0 - c.a)), 1.0);
    }

    // ---- Preview presentation: aspect-fit a BGRA frame into the drawable with a letterbox colour.
    // `offset` = content centre in NDC (player zoom / pan).
    struct PresentU { float2 scale; float2 offset; float4 letterbox; };
    vertex QuadOut present_vs(uint vid [[vertex_id]], constant PresentU& u [[buffer(0)]]) {
        float2 c = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? -1.0 : 1.0);
        QuadOut o; o.pos = float4(c * u.scale + u.offset, 0, 1); o.uv = float2((c.x + 1.0) * 0.5, (1.0 - c.y) * 0.5); return o;
    }
    fragment float4 present_fs(QuadOut in [[stage_in]], texture2d<float> t [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        return float4(t.sample(s, in.uv).rgb, 1.0);
    }
    """
}
