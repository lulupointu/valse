// Metal shader source, compiled at runtime (the Metal offline toolchain is an optional Xcode 26
// component and is not installed on this machine; a production build would ship a precompiled
// .metallib produced by `xcrun metal` in an Xcode build phase).
let montageShaderSource = """
#include <metal_stdlib>
using namespace metal;

// ---------- Compositor: one textured quad per layer, YUV (biplanar 4:2:0) sampled zero-copy ----------
struct LayerU { float2 center; float2 halfSize; float opacity; float saturation; float brightness; float fullRange; };
struct LOut { float4 pos [[position]]; float2 uv; };

vertex LOut layer_vs(uint vid [[vertex_id]], constant LayerU& u [[buffer(0)]]) {
    float2 c = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? -1.0 : 1.0);
    LOut o;
    o.pos = float4(u.center + c * u.halfSize, 0.0, 1.0);
    o.uv = float2((c.x + 1.0) * 0.5, (1.0 - c.y) * 0.5);
    return o;
}

fragment float4 layer_fs(LOut in [[stage_in]],
                         texture2d<float> yTex [[texture(0)]],
                         texture2d<float> cTex [[texture(1)]],
                         constant LayerU& u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, mip_filter::none, address::clamp_to_edge);
    float y = yTex.sample(s, in.uv).r;
    float2 c = cTex.sample(s, in.uv).rg;
    if (u.fullRange > 0.5) { c -= 0.5; }
    else { y = (y - 16.0/255.0) * (255.0/219.0); c = (c - 128.0/255.0) * (255.0/224.0); }
    float3 rgb = float3(y + 1.5748 * c.y, y - 0.1873 * c.x - 0.4681 * c.y, y + 1.8556 * c.x); // BT.709
    float l = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    rgb = mix(float3(l), rgb, u.saturation) + u.brightness;
    return float4(saturate(rgb), u.opacity);
}

// ---------- Present: draw a BGRA frame to the drawable ----------
struct POut { float4 pos [[position]]; float2 uv; };
vertex POut present_vs(uint vid [[vertex_id]]) {
    float2 c = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? -1.0 : 1.0);
    POut o; o.pos = float4(c, 0, 1); o.uv = float2((c.x + 1.0) * 0.5, (1.0 - c.y) * 0.5); return o;
}
fragment float4 present_fs(POut in [[stage_in]], texture2d<float> t [[texture(0)]]) {
    constexpr sampler s(filter::linear);
    return float4(t.sample(s, in.uv).rgb, 1.0);
}

// ---------- Timeline: instanced rects (clips, thumbnails, labels from a glyph atlas) ----------
struct TLInst { float4 rect; float4 color; float4 uv; float4 misc; }; // misc.x = kind, misc.y = corner radius
struct TLOut { float4 pos [[position]]; float4 color; float2 uv; float2 local; float2 size; float kind [[flat]]; float radius [[flat]]; };

vertex TLOut tl_vs(uint vid [[vertex_id]], uint iid [[instance_id]],
                   const device TLInst* inst [[buffer(0)]], constant float2& vp [[buffer(1)]]) {
    TLInst i = inst[iid];
    float2 c = float2(vid & 1, (vid >> 1) & 1);
    float2 p = i.rect.xy + c * i.rect.zw;
    TLOut o;
    o.pos = float4(p.x / vp.x * 2.0 - 1.0, 1.0 - p.y / vp.y * 2.0, 0.0, 1.0);
    o.color = i.color; o.uv = mix(i.uv.xy, i.uv.zw, c); o.local = c * i.rect.zw; o.size = i.rect.zw;
    o.kind = i.misc.x; o.radius = i.misc.y;
    return o;
}

fragment float4 tl_fs(TLOut in [[stage_in]], texture2d<float> atlas [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    if (in.kind > 1.5) { // label
        float a = atlas.sample(s, in.uv).r;
        return float4(in.color.rgb, in.color.a * a);
    }
    float4 col = in.color;
    if (in.kind > 0.5) { // thumbnail placeholder: vertical gradient with diagonal stripes
        float stripe = step(0.5, fract((in.local.x + in.local.y) / 12.0));
        col.rgb = mix(col.rgb * 0.45, col.rgb * 0.9, in.local.y / max(in.size.y, 1.0)) + stripe * 0.05;
    }
    // rounded corners (SDF)
    float r = in.radius;
    if (r > 0.0) {
        float2 q = abs(in.local - in.size * 0.5) - (in.size * 0.5 - r);
        float d = length(max(q, 0.0)) - r;
        col.a *= saturate(0.5 - d);
    }
    return col;
}
"""
