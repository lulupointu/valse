import MontageCore

/// "Transitions" tab.
public enum BuiltinTransitions {
    static func t(_ name: String, group: String, symbol: String, _ body: String) -> TransitionDescriptor {
        TransitionDescriptor(id: "montage.transition.\(name)", nameKey: "transition.\(name)",
                             groupKey: "transition.group.\(group)", symbol: symbol, shader: """
        float4 transition(float2 uv, texture2d<float> from, texture2d<float> to, sampler s, float progress,
                          constant float* p, FXContext ctx) {
            float t = progress;
            \(body)
        }
        """)
    }

    public static let all: [TransitionDescriptor] = [
        t("dissolve", group: "basic", symbol: "circle.lefthalf.filled",
          "return mix(from.sample(s, uv), to.sample(s, uv), t);"),
        t("blackFade", group: "basic", symbol: "moon.fill", """
            float4 a = from.sample(s, uv), b = to.sample(s, uv);
            float4 black = float4(0, 0, 0, 1);
            return t < 0.5 ? mix(a, black, t * 2.0) : mix(black, b, (t - 0.5) * 2.0);
            """),
        t("slideLeft", group: "slide", symbol: "arrow.left.square", """
            float e = t * t * (3.0 - 2.0 * t);
            float2 ua = uv + float2(e, 0), ub = uv + float2(e - 1.0, 0);
            return ua.x <= 1.0 ? from.sample(s, ua) : to.sample(s, ub);
            """),
        t("wipeRight", group: "slide", symbol: "rectangle.righthalf.filled", """
            float edge = smoothstep(t - 0.02, t + 0.02, uv.x * 1.04 - 0.02);
            return mix(to.sample(s, uv), from.sample(s, uv), edge);
            """),
        t("zoomIn", group: "camera", symbol: "plus.magnifyingglass", """
            float e = t * t * (3.0 - 2.0 * t);
            float2 za = (uv - 0.5) / (1.0 + e * 0.6) + 0.5;
            float2 zb = (uv - 0.5) / (1.6 - e * 0.6) + 0.5;
            return mix(from.sample(s, za), to.sample(s, zb), smoothstep(0.35, 0.65, t));
            """),
        t("circle", group: "shape", symbol: "circle", """
            float2 d = (uv - 0.5) * float2(ctx.aspect, 1.0);
            float r = t * length(float2(ctx.aspect, 1.0)) * 0.5;
            float m = 1.0 - smoothstep(r - 0.01, r + 0.01, length(d));
            return mix(from.sample(s, uv), to.sample(s, uv), m);
            """),
    ]
}
