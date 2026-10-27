import ValseCore

/// Video ▸ Basic ▸ ☐ Lens correction (CV-015, non-generative): radial (Brown–Conrady k1 + k2) distortion correction
/// for wide / action-camera footage. Distortion > 0 straightens barrel distortion (curved lines bow outwards),
/// < 0 straightens pincushion. "Zoom to fill" scales the result so no transparent edge appears.
/// An ordinary effect-stack entry (category `.key` = inspector-only, never listed in the asset panel), inserted first
/// in the stack so the other effects see corrected geometry; keyframeable like any effect parameter.
public enum BuiltinLensCorrection {
    public static let id = "valse.lens.correction"

    public static let descriptor = EffectDescriptor(
        id: id, category: .key, nameKey: "lens.correction", groupKey: "key.group.lens",
        params: [
            .scalar("distortion", "lens.distortion", -1, 1, 0.3, display: 100),
            ParamSpec("fill", nameKey: "lens.fill", .bool(defaultValue: true)),
        ],
        symbol: "camera.aperture",
        shader: """
        float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
            float k1 = -p[0] * 0.45, k2 = -p[0] * 0.12;   // + = straighten barrel (sample inwards)
            // normalised so the half-diagonal has radius 1 (aspect-correct)
            float2 h = float2(ctx.aspect, 1.0) * 0.5;
            float norm = length(h);
            float2 d = (uv - 0.5) * float2(ctx.aspect, 1.0) / norm;
            // zoom to fill (only barrel correction pushes the corners outside the source): z · f(z) = 1
            float zoom = 1.0;
            if (p[1] > 0.5 && k1 > 0.0) {
                for (int i = 0; i < 6; i++) { float z2 = zoom * zoom; zoom = 1.0 / (1.0 + k1 * z2 + k2 * z2 * z2); }
            }
            d *= zoom;
            float r2 = dot(d, d);
            float2 q = d * (1.0 + k1 * r2 + k2 * r2 * r2);
            float2 suv = q * norm / float2(ctx.aspect, 1.0) + 0.5;
            if (any(suv < 0.0) || any(suv > 1.0)) return float4(0.0);
            return src.sample(s, suv);
        }
        """)

    public static let all: [EffectDescriptor] = [descriptor]
}
