/// MSL included before every effect / transition source. Keep it small and stable: effects rely on it.
public enum ShaderPrelude {
    public static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct FXContext {
        float time;      // clip-local seconds
        float2 size;     // texture size in pixels
        int pass;        // pass index for multi-pass effects
        float aspect;    // size.x / size.y
    };

    inline float fx_luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }
    inline float fx_hash(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
    inline float3 fx_rgb2hsv(float3 c) {
        float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
        float4 p = mix(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
        float4 q = mix(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
        float d = q.x - min(q.w, q.y);
        float e = 1.0e-10;
        return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
    }
    inline float3 fx_hsv2rgb(float3 c) {
        float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
        float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
        return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
    }
    // Rec.709 / sRGB-style display gamma ↔ linear light (working values are display-encoded).
    inline float3 fx_to_linear(float3 c) { return pow(max(c, 0.0), 2.4); }
    inline float3 fx_to_display(float3 c) { return pow(max(c, 0.0), 1.0 / 2.4); }
    // 3D LUT lookup with texel-centre mapping (hardware trilinear).
    inline float3 fx_lut3d(texture3d<float> lut, sampler s3, float3 c) {
        float n = float(lut.get_width());
        return lut.sample(s3, saturate(c) * ((n - 1.0) / n) + 0.5 / n).rgb;
    }
    """
}
