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
    // matrix709: 0 = BT.601, 1 = BT.709, 2 = BT.2020. inTF/outTF: 0 SDR, 1 HLG, 2 PQ. gamut: 0 none, 1 709→2020,
    // 2 2020→709. Colour math mirrors MontageCore.ColorMath (linear 1.0 = 203-nit reference white).
    struct ConvertU { float3x2 uvXform; float fullRange; float matrix709; float unpremultiply; float pad;
                      float inTF; float outTF; float gamut; float pad2; };

    inline float2 xf(constant ConvertU& u, float2 uv) { return u.uvXform * float3(uv, 1.0); }

    inline float3 tf_to_linear(float3 v, int tf) {
        v = max(v, 0.0);
        if (tf == 1) {
            const float a = 0.17883277, b = 0.28466892, c = 0.55991073;
            float3 e = select((exp((v - c) / a) + b) / 12.0, v * v / 3.0, v <= 0.5);
            return 1000.0 * pow(max(e, 0.0), 1.2) / 203.0;
        }
        if (tf == 2) {
            const float m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
            float3 p = pow(v, 1.0 / m2);
            return pow(max(p - c1, 0.0) / (c2 - c3 * p), 1.0 / m1) * (10000.0 / 203.0);
        }
        return pow(v, 2.4);
    }
    inline float3 tf_from_linear(float3 l, int tf) {
        l = max(l, 0.0);
        if (tf == 1) {
            const float a = 0.17883277, b = 0.28466892, c = 0.55991073;
            float3 e = pow(l * (203.0 / 1000.0), 1.0 / 1.2);
            return min(select(a * log(max(12.0 * e - b, 1e-6)) + c, sqrt(3.0 * e), e <= 1.0 / 12.0), 1.0);
        }
        if (tf == 2) {
            const float m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
            float3 p = pow(min(l * (203.0 / 10000.0), 1.0), m1);
            return pow((c1 + c2 * p) / (1.0 + c3 * p), m2);
        }
        return pow(min(l, 1.0), 1.0 / 2.4);
    }
    inline float3 color_convert(float3 rgb, constant ConvertU& u) {
        int inTF = int(u.inTF + 0.5), outTF = int(u.outTF + 0.5), gamut = int(u.gamut + 0.5);
        if (inTF == outTF && gamut == 0) { return rgb; }
        float3 l = tf_to_linear(rgb, inTF);
        if (gamut == 1) { l = float3x3(float3(0.6274, 0.0691, 0.0164), float3(0.3293, 0.9195, 0.0880), float3(0.0433, 0.0114, 0.8956)) * l; }
        if (gamut == 2) { l = float3x3(float3(1.6605, -0.1246, -0.0182), float3(-0.5876, 1.1329, -0.1006), float3(-0.0728, -0.0083, 1.1187)) * l; }
        l = max(l, 0.0);
        if (outTF == 0 && inTF != 0) {
            float m = max(l.r, max(l.g, l.b));
            if (m > 0.8) { float t = 0.8 + 0.2 * (1.0 - exp(-(m - 0.8) / 0.2)); l *= t / m; }
        }
        return tf_from_linear(l, outTF);
    }

    fragment float4 convert_yuv_fs(QuadOut in [[stage_in]], texture2d<float> yT [[texture(0)]],
                                   texture2d<float> cT [[texture(1)]], constant ConvertU& u [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 suv = xf(u, in.uv);
        float y = yT.sample(s, suv).r;
        float2 c = cT.sample(s, suv).rg;
        if (u.fullRange > 0.5) { c -= 0.5; }
        else { y = (y - 16.0/255.0) * (255.0/219.0); c = (c - 128.0/255.0) * (255.0/224.0); }
        float3 rgb = u.matrix709 > 1.5
            ? float3(y + 1.4746 * c.y, y - 0.16455 * c.x - 0.57135 * c.y, y + 1.8814 * c.x)
            : (u.matrix709 > 0.5
            ? float3(y + 1.5748 * c.y, y - 0.1873 * c.x - 0.4681 * c.y, y + 1.8556 * c.x)
            : float3(y + 1.402 * c.y, y - 0.344136 * c.x - 0.714136 * c.y, y + 1.772 * c.x));
        return float4(saturate(color_convert(saturate(rgb), u)), 1.0);
    }

    fragment float4 convert_rgba_fs(QuadOut in [[stage_in]], texture2d<float> t [[texture(0)]],
                                    constant ConvertU& u [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float4 c = t.sample(s, xf(u, in.uv));
        if (u.unpremultiply > 0.5 && c.a > 0.0) { c.rgb /= c.a; }
        c.rgb = color_convert(c.rgb, u);
        return c;
    }

    fragment float4 solid_fs(QuadOut in [[stage_in]], constant float4& color [[buffer(0)]]) { return color; }

    // ---- Layer placement onto the premultiplied accumulation target, with blend modes (framebuffer fetch) + mask.
    struct PlaceU {
        float2 corners[4];   // NDC: TL, TR, BL, BR
        float opacity;
        int blend;
        int maskShape;       // -1 none, 0 linear, 1 mirror, 2 circle, 3 rectangle, 4 heart, 5 star
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
            case 13: return max(0.0, b + s - 1.0);                            // linear burn
            case 14: return min(1.0, b + s);                                  // linear dodge
            case 15: return s <= 0.5                                          // vivid light
                ? (s <= 0.0 ? 0.0 : max(0.0, 1.0 - (1.0 - b) / (2.0 * s)))
                : (s >= 1.0 ? 1.0 : min(1.0, b / (2.0 * (1.0 - s))));
            case 16: return clamp(b + 2.0 * s - 1.0, 0.0, 1.0);               // linear light
            case 17: return s <= 0.5 ? min(b, 2.0 * s) : max(b, 2.0 * s - 1.0); // pin light
            case 18: return b + s >= 1.0 ? 1.0 : 0.0;                         // hard mix
            case 19: return max(0.0, b - s);                                  // subtract
            case 20: return s <= 0.0 ? 1.0 : min(1.0, b / s);                 // divide
            default: return s;                                                // normal
        }
    }

    // Non-separable modes (W3C compositing spec): hue, saturation, color, luminosity, darker/lighter colour.
    inline float lumW(float3 c) { return dot(c, float3(0.3, 0.59, 0.11)); }
    inline float3 clipColor(float3 c) {
        float l = lumW(c), n = min(c.r, min(c.g, c.b)), x = max(c.r, max(c.g, c.b));
        if (n < 0.0) { c = l + (c - l) * l / max(l - n, 1e-5); }
        if (x > 1.0) { c = l + (c - l) * (1.0 - l) / max(x - l, 1e-5); }
        return c;
    }
    inline float3 setLum(float3 c, float l) { return clipColor(c + (l - lumW(c))); }
    inline float satW(float3 c) { return max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b)); }
    inline float3 setSat(float3 c, float s) {
        float mn = min(c.r, min(c.g, c.b)), mx = max(c.r, max(c.g, c.b));
        return mx > mn ? (c - mn) * s / (mx - mn) : float3(0.0);
    }
    inline float3 blendRGB(int m, float3 b, float3 s) {
        switch (m) {
            case 21: return setLum(setSat(s, satW(b)), lumW(b));              // hue
            case 22: return setLum(setSat(b, satW(s)), lumW(b));              // saturation
            case 23: return setLum(s, lumW(b));                               // color
            case 24: return setLum(b, lumW(s));                               // luminosity
            case 25: return lumW(s) < lumW(b) ? s : b;                        // darker color
            case 26: return lumW(s) > lumW(b) ? s : b;                        // lighter color
            default: return float3(blendChannel(m, b.r, s.r), blendChannel(m, b.g, s.g), blendChannel(m, b.b, s.b));
        }
    }

    // Heart / star signed distances (Inigo Quilez), q in units where the shape spans [-1, 1].
    inline float sdHeart(float2 p) {
        p.x = abs(p.x);
        if (p.y + p.x > 1.0) { return sqrt(dot(p - float2(0.25, 0.75), p - float2(0.25, 0.75))) - sqrt(2.0) / 4.0; }
        float2 a = p - float2(0.0, 1.0);
        float2 b = p - 0.5 * max(p.x + p.y, 0.0);
        return sqrt(min(dot(a, a), dot(b, b))) * sign(p.x - p.y);
    }
    inline float sdStar5(float2 p, float r, float rf) {
        const float2 k1 = float2(0.809016994375, -0.587785252292);
        const float2 k2 = float2(-k1.x, k1.y);
        p.x = abs(p.x);
        p -= 2.0 * max(dot(k1, p), 0.0) * k1;
        p -= 2.0 * max(dot(k2, p), 0.0) * k2;
        p.x = abs(p.x);
        p.y -= r;
        float2 ba = rf * float2(-k1.y, k1.x) - float2(0, 1);
        float h = clamp(dot(p, ba) / dot(ba, ba), 0.0, r);
        return length(p - ba * h) * sign(p.y * ba.x - p.x * ba.y);
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
        } else if (u.maskShape == 4 || u.maskShape == 5) {
            // heart / star: fit the unit shape into the mask box, distance back in layer units
            float2 h = max(u.maskSize * float2(u.layerAspect, 1.0) * 0.5, float2(0.0001));
            float sc = min(h.x, h.y);
            float2 p = q / h * float2(1.0, -1.0);           // y up for the SDFs
            float d = u.maskShape == 4 ? sdHeart(p * 0.62 + float2(0.0, 0.5)) / 0.62 : sdStar5(p, 1.0, 0.45);
            a = 1.0 - smoothstep(-f, f, d * sc);
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
            float3 bl = saturate(blendRGB(u.blend, cb, src.rgb));
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

    // HDR output (rgba16Float compositor buffers): same as output_fs, encoded HLG/PQ code values in 0…1.
    fragment half4 output_half_fs(QuadOut in [[stage_in]], texture2d<float> a [[texture(0)]], constant float4& bg [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float4 c = a.sample(s, in.uv);
        return half4(half3(saturate(c.rgb + bg.rgb * (1.0 - c.a))), 1.0h);
    }

    // ---- Preview presentation: aspect-fit a BGRA frame into the drawable with a letterbox colour.
    struct PresentU { float2 scale; float4 letterbox; };
    vertex QuadOut present_vs(uint vid [[vertex_id]], constant PresentU& u [[buffer(0)]]) {
        float2 c = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? -1.0 : 1.0);
        QuadOut o; o.pos = float4(c * u.scale, 0, 1); o.uv = float2((c.x + 1.0) * 0.5, (1.0 - c.y) * 0.5); return o;
    }
    fragment float4 present_fs(QuadOut in [[stage_in]], texture2d<float> t [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        return float4(t.sample(s, in.uv).rgb, 1.0);
    }
    """
}
