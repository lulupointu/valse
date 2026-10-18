import MontageCore

/// "Filters" tab: look presets. Every filter has an Intensity (0…1) as p[0] (CapCut "Strength", default 100).
///
/// The library is a **parametric grade graph** (`Grade`, one shared shader): each preset is just a set of constants
/// (exposure, white balance, contrast/filmic curve, highlights/shadows, saturation/vibrance, hue, split toning,
/// cross-process, bleach bypass, channel-mixer B&W, fade/matte, grain, vignette, skin protection), so 100+ looks
/// compile into one pipeline. A few legacy filters keep their own exact shaders (`invert`, `mono`, `sepia`…).
public enum BuiltinFilters {
    static let intensity = ParamSpec.scalar("intensity", "fx.param.intensity", 0, 1, 1, display: 100)

    static func filter(_ name: String, group: String, _ body: String) -> EffectDescriptor {
        EffectDescriptor(id: "montage.filter.\(name)", category: .filter, nameKey: "filter.\(name)",
                         groupKey: "filter.group.\(group)", params: [intensity], symbol: "camera.filters", shader: """
        float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
            float4 c = src.sample(s, uv);
            float3 o = c.rgb;
            \(body)
            return float4(mix(c.rgb, saturate(o), p[0]), c.a);
        }
        """)
    }

    /// Parameters of one look. All neutral by default; display-referred values, ranges are soft (−1…1 unless noted).
    public struct Grade: Sendable {
        public var exposure = 0.0, contrast = 0.0, saturation = 0.0, vibrance = 0.0
        public var temperature = 0.0, tint = 0.0, fade = 0.0, hue = 0.0
        public var shadowTint = SIMD3<Double>(0, 0, 0), highlightTint = SIMD3<Double>(0, 0, 0)
        public var highlights = 0.0, shadows = 0.0
        public var bw = 0.0, bwMix = SIMD3<Double>(0.2126, 0.7152, 0.0722)
        public var grain = 0.0, vignette = 0.0, whitePoint = 1.0, filmic = 0.0
        public var crossProcess = 0.0, bleach = 0.0, gamma = 0.0, skinProtect = 0.0
        public init() {}

        var constants: [Float] {
            let v: [Double] = [exposure, contrast, saturation, vibrance, temperature, tint, fade, hue,
                               shadowTint.x, shadowTint.y, shadowTint.z, highlightTint.x, highlightTint.y, highlightTint.z,
                               highlights, shadows, bw, bwMix.x, bwMix.y, bwMix.z, grain, vignette, whitePoint, filmic,
                               crossProcess, bleach, gamma, skinProtect]
            return v.map { Float($0) }
        }
    }

    static let gradeShader = FXKit.msl + """

    float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx) {
        constant float* c = p + 1;
        float4 src0 = src.sample(s, uv);
        float3 x = saturate(src0.rgb);
        // exposure + white balance in linear light (luminance-preserving gains)
        float3 lin = fx_to_linear(x) * exp2(c[0]);
        float3 g = float3(1.0 + 0.3 * c[4] + 0.05 * c[5], 1.0 - 0.25 * c[5], 1.0 - 0.3 * c[4] + 0.05 * c[5]);
        g /= dot(g, float3(0.2126, 0.7152, 0.0722));
        x = fx_to_display(lin * g);
        x = pow(max(x, 0.0), 1.0 / (1.0 + c[26] * 0.5));
        // filmic S-curve, then linear contrast around mid grey
        float3 sc = x * x * (3.0 - 2.0 * x);
        x = mix(x, sc, saturate(c[23]));
        x = (x - 0.5) * (1.0 + c[1]) + 0.5;
        float l = fx_luma(saturate(x));
        x += c[14] * 0.22 * smoothstep(0.45, 1.0, l) + c[15] * 0.22 * (1.0 - smoothstep(0.0, 0.55, l));
        // hue rotation, saturation, vibrance
        if (abs(c[7]) > 1e-4) { float3 hsv = fx_rgb2hsv(saturate(x)); hsv.x = fract(hsv.x + c[7]); x = fx_hsv2rgb(hsv); }
        l = fx_luma(x);
        float sat = max(x.r, max(x.g, x.b)) - min(x.r, min(x.g, x.b));
        x = mix(float3(l), x, 1.0 + c[2]);
        x = mix(float3(l), x, 1.0 + c[3] * (1.0 - saturate(sat * 1.6)));
        // split toning
        l = saturate(fx_luma(x));
        x += float3(c[8], c[9], c[10]) * (1.0 - l) * (1.0 - l) + float3(c[11], c[12], c[13]) * l * l;
        // cross process
        if (c[24] > 0.0) {
            float3 cp = float3(smoothstep(0.05, 0.95, x.r), x.g * 1.05 - 0.02, x.b * 0.75 + 0.12);
            x = mix(x, cp, c[24]);
        }
        // bleach bypass (luminance overlay, partial desaturation)
        if (c[25] > 0.0) {
            float lb = fx_luma(saturate(x));
            float3 ov = kit_overlay(saturate(x), float3(lb));
            x = mix(x, mix(ov, float3(fx_luma(ov)), 0.45), c[25]);
        }
        // channel-mixer black & white
        float3 w = float3(c[17], c[18], c[19]);
        float bwv = dot(x, w / max(w.r + w.g + w.b, 1e-3));
        x = mix(x, float3(bwv), c[16]);
        // fade (lifted blacks) and matte white point
        x = x * (1.0 - c[6] * 0.22) + c[6] * 0.22 * float3(0.52, 0.5, 0.48);
        x = saturate(x) * c[22];
        // skin protection: keep skin tones close to the source
        if (c[27] > 0.0) {
            float3 hsv = fx_rgb2hsv(saturate(src0.rgb));
            float hd = abs(fract(hsv.x - 0.07 + 0.5) - 0.5);
            float skin = (1.0 - smoothstep(0.03, 0.09, hd)) * smoothstep(0.12, 0.25, hsv.y) * (1.0 - smoothstep(0.65, 0.85, hsv.y));
            x = mix(x, mix(src0.rgb, x, 0.45), skin * c[27]);
        }
        // vignette + grain
        float2 vq = (uv - 0.5) * float2(ctx.aspect, 1.0);
        x *= 1.0 - c[21] * smoothstep(0.3, 0.95, length(vq) / max(ctx.aspect * 0.5, 0.5));
        if (c[20] > 0.0) {
            float gs = max(1.0, 1.4 * ctx.size.y / 1080.0);
            float n = kit_h21(floor(uv * ctx.size / gs) + floor(ctx.time * 24.0) * 1.37) - 0.5;
            x += n * c[20] * 0.14;
        }
        return float4(mix(src0.rgb, saturate(x), p[0]), src0.a);
    }
    """

    static func look(_ name: String, _ group: String, _ tags: [String] = [], _ edit: (inout Grade) -> Void) -> EffectDescriptor {
        var g = Grade(); edit(&g)
        return EffectDescriptor(id: "montage.filter.\(name)", category: .filter, nameKey: "filter.\(name)",
                                groupKey: "filter.group.\(group)", params: [intensity], symbol: "camera.filters",
                                constants: g.constants, tags: tags + ["filter"], shader: gradeShader)
    }

    static let legacy: [EffectDescriptor] = [
        filter("mono", group: "bw", "o = float3(fx_luma(c.rgb));"),
        filter("noir", group: "bw", "float l = fx_luma(c.rgb); l = smoothstep(0.08, 0.92, l); o = float3(l);"),
        filter("warm", group: "life", "o = c.rgb * float3(1.08, 1.0, 0.86) + float3(0.02, 0.01, 0.0);"),
        filter("cool", group: "life", "o = c.rgb * float3(0.88, 1.0, 1.1);"),
        filter("vivid", group: "life", "float l = fx_luma(c.rgb); o = mix(float3(l), c.rgb, 1.45); o = (o - 0.5) * 1.08 + 0.5;"),
        filter("fade", group: "retro", "o = mix(c.rgb, float3(0.55, 0.5, 0.45), 0.25); o = mix(float3(fx_luma(o)), o, 0.75);"),
        filter("sepia", group: "retro", """
            float3 x = c.rgb;
            o = float3(dot(x, float3(0.393, 0.769, 0.189)), dot(x, float3(0.349, 0.686, 0.168)), dot(x, float3(0.272, 0.534, 0.131)));
            """),
        filter("invert", group: "style", "o = 1.0 - c.rgb;"),
    ]

    typealias V = SIMD3<Double>

    static let portrait: [EffectDescriptor] = [
        look("natural", "portrait", ["skin", "soft"]) { $0.exposure = 0.08; $0.vibrance = 0.15; $0.temperature = 0.05; $0.shadows = 0.15; $0.skinProtect = 0.6 },
        look("fair", "portrait", ["bright", "white", "skin"]) { $0.exposure = 0.3; $0.contrast = -0.12; $0.saturation = -0.1; $0.tint = 0.08; $0.highlights = -0.2; $0.shadows = 0.3; $0.skinProtect = 0.4 },
        look("rosy", "portrait", ["pink", "cheeks"]) { $0.exposure = 0.12; $0.tint = 0.25; $0.highlightTint = V(0.04, -0.01, 0.02); $0.vibrance = 0.15; $0.contrast = -0.05 },
        look("peach", "portrait", ["warm", "soft"]) { $0.exposure = 0.12; $0.temperature = 0.3; $0.tint = 0.12; $0.fade = 0.25; $0.contrast = -0.1; $0.highlightTint = V(0.04, 0.02, -0.01) },
        look("milk", "portrait", ["milky", "soft", "bright"]) { $0.exposure = 0.25; $0.contrast = -0.25; $0.saturation = -0.2; $0.fade = 0.5; $0.highlights = -0.15; $0.temperature = -0.05 },
        look("porcelain", "portrait", ["cool", "smooth"]) { $0.exposure = 0.22; $0.temperature = -0.2; $0.saturation = -0.25; $0.contrast = -0.08; $0.highlightTint = V(-0.01, 0.0, 0.03); $0.skinProtect = 0.3 },
        look("radiant", "portrait", ["glow", "bright"]) { $0.exposure = 0.2; $0.gamma = 0.25; $0.vibrance = 0.25; $0.highlights = -0.25; $0.shadows = 0.2; $0.temperature = 0.08 },
        look("honey", "portrait", ["warm", "golden"]) { $0.temperature = 0.45; $0.tint = 0.05; $0.saturation = 0.05; $0.shadowTint = V(0.03, 0.01, -0.03); $0.highlightTint = V(0.05, 0.03, -0.03) },
        look("softPortrait", "portrait", ["soft", "matte"]) { $0.contrast = -0.25; $0.fade = 0.35; $0.saturation = -0.1; $0.shadows = 0.25; $0.highlights = -0.2 },
        look("cream", "portrait", ["warm", "pastel"]) { $0.exposure = 0.15; $0.temperature = 0.18; $0.fade = 0.4; $0.saturation = -0.18; $0.highlightTint = V(0.03, 0.025, 0.0) },
        look("sweet", "portrait", ["pink", "cute"]) { $0.exposure = 0.15; $0.tint = 0.2; $0.highlightTint = V(0.05, 0.0, 0.04); $0.vibrance = 0.2; $0.contrast = -0.1 },
        look("clarity", "portrait", ["clear", "crisp"]) { $0.contrast = 0.12; $0.vibrance = 0.2; $0.shadows = 0.2; $0.highlights = -0.2; $0.skinProtect = 0.5 },
        look("bronze", "portrait", ["tan", "summer", "warm"]) { $0.temperature = 0.35; $0.contrast = 0.15; $0.saturation = 0.1; $0.exposure = -0.05; $0.filmic = 0.3; $0.shadowTint = V(0.02, 0.0, -0.03) },
        look("blush", "portrait", ["pink", "soft"]) { $0.tint = 0.3; $0.temperature = 0.1; $0.fade = 0.2; $0.saturation = -0.05; $0.exposure = 0.1 },
    ]

    static let life: [EffectDescriptor] = [
        look("daily", "life", ["everyday", "vlog"]) { $0.vibrance = 0.2; $0.contrast = 0.06; $0.temperature = 0.06 },
        look("fresh", "life", ["clean", "cool"]) { $0.exposure = 0.12; $0.temperature = -0.15; $0.vibrance = 0.25; $0.tint = -0.05 },
        look("bright", "life", ["light", "airy"]) { $0.exposure = 0.35; $0.contrast = -0.05; $0.highlights = -0.3; $0.shadows = 0.2 },
        look("vibrant", "life", ["colourful", "pop"]) { $0.saturation = 0.3; $0.vibrance = 0.3; $0.contrast = 0.12 },
        look("sunny", "life", ["warm", "summer"]) { $0.temperature = 0.3; $0.exposure = 0.12; $0.vibrance = 0.2; $0.highlightTint = V(0.04, 0.03, -0.02) },
        look("breeze", "life", ["cool", "airy"]) { $0.temperature = -0.25; $0.exposure = 0.15; $0.saturation = -0.08; $0.fade = 0.2 },
        look("picnic", "life", ["green", "warm", "outdoor"]) { $0.temperature = 0.18; $0.vibrance = 0.25; $0.shadows = 0.15; $0.hue = -0.008 },
        look("weekend", "life", ["relaxed", "warm"]) { $0.temperature = 0.15; $0.fade = 0.2; $0.contrast = -0.05; $0.vibrance = 0.12 },
        look("clean", "life", ["neutral", "crisp"]) { $0.exposure = 0.08; $0.contrast = 0.1; $0.saturation = -0.05; $0.temperature = -0.05 },
        look("pastel", "life", ["soft", "light"]) { $0.exposure = 0.22; $0.contrast = -0.3; $0.saturation = -0.25; $0.fade = 0.45; $0.tint = 0.05 },
        look("mellow", "life", ["soft", "warm"]) { $0.contrast = -0.18; $0.temperature = 0.12; $0.fade = 0.3; $0.saturation = -0.1 },
        look("latte", "life", ["brown", "cafe", "warm"]) { $0.temperature = 0.25; $0.saturation = -0.25; $0.fade = 0.3; $0.shadowTint = V(0.03, 0.015, -0.01) },
        look("cozy", "life", ["warm", "home"]) { $0.temperature = 0.35; $0.exposure = -0.05; $0.vignette = 0.3; $0.filmic = 0.25; $0.saturation = -0.05 },
        look("spring", "life", ["green", "fresh"]) { $0.exposure = 0.15; $0.tint = -0.08; $0.vibrance = 0.3; $0.temperature = 0.05; $0.hue = -0.01 },
    ]

    static let food: [EffectDescriptor] = [
        look("delicious", "food", ["tasty", "warm"]) { $0.temperature = 0.2; $0.vibrance = 0.3; $0.contrast = 0.1; $0.exposure = 0.05 },
        look("tasty", "food", ["saturated", "red"]) { $0.saturation = 0.25; $0.temperature = 0.12; $0.contrast = 0.15; $0.highlights = -0.15 },
        look("crisp", "food", ["salad", "fresh"]) { $0.contrast = 0.15; $0.vibrance = 0.3; $0.temperature = -0.05; $0.exposure = 0.1 },
        look("bakery", "food", ["warm", "bread"]) { $0.temperature = 0.35; $0.fade = 0.15; $0.contrast = 0.05; $0.highlightTint = V(0.03, 0.02, -0.02) },
        look("dessert", "food", ["sweet", "pink", "cake"]) { $0.exposure = 0.18; $0.tint = 0.12; $0.vibrance = 0.2; $0.contrast = -0.05 },
        look("coffee", "food", ["brown", "cafe", "moody"]) { $0.temperature = 0.3; $0.saturation = -0.2; $0.contrast = 0.15; $0.exposure = -0.08; $0.filmic = 0.3; $0.vignette = 0.25 },
        look("gourmet", "food", ["rich", "dark"]) { $0.contrast = 0.2; $0.vibrance = 0.2; $0.exposure = -0.05; $0.vignette = 0.35; $0.filmic = 0.4 },
        look("juicy", "food", ["fruit", "colourful"]) { $0.saturation = 0.35; $0.vibrance = 0.2; $0.exposure = 0.1; $0.contrast = 0.08 },
        look("brunch", "food", ["bright", "morning"]) { $0.exposure = 0.25; $0.temperature = 0.15; $0.highlights = -0.25; $0.vibrance = 0.15 },
        look("fruity", "food", ["vivid", "summer"]) { $0.vibrance = 0.4; $0.hue = 0.006; $0.exposure = 0.08; $0.tint = 0.05 },
    ]

    static let landscape: [EffectDescriptor] = [
        look("scenery", "landscape", ["nature", "vivid"]) { $0.vibrance = 0.35; $0.contrast = 0.12; $0.highlights = -0.25; $0.shadows = 0.15 },
        look("azure", "landscape", ["blue", "sky"]) { $0.temperature = -0.2; $0.vibrance = 0.3; $0.highlights = -0.2; $0.highlightTint = V(-0.02, 0.0, 0.03) },
        look("forest", "landscape", ["green", "woods"]) { $0.tint = -0.15; $0.contrast = 0.1; $0.saturation = 0.1; $0.shadowTint = V(-0.01, 0.02, 0.0); $0.exposure = -0.05 },
        look("autumn", "landscape", ["fall", "orange"]) { $0.temperature = 0.35; $0.hue = -0.02; $0.saturation = 0.15; $0.contrast = 0.1 },
        look("goldenHour", "landscape", ["sunset", "warm", "golden"]) { $0.temperature = 0.5; $0.tint = 0.08; $0.highlightTint = V(0.06, 0.03, -0.03); $0.contrast = 0.08; $0.vibrance = 0.15 },
        look("ocean", "landscape", ["sea", "blue", "beach"]) { $0.temperature = -0.25; $0.tint = -0.05; $0.vibrance = 0.3; $0.exposure = 0.05; $0.hue = 0.01 },
        look("alpine", "landscape", ["mountain", "cool", "clear"]) { $0.temperature = -0.15; $0.contrast = 0.18; $0.highlights = -0.3; $0.vibrance = 0.15 },
        look("desert", "landscape", ["sand", "warm", "dry"]) { $0.temperature = 0.4; $0.saturation = -0.15; $0.contrast = 0.15; $0.fade = 0.1; $0.highlightTint = V(0.03, 0.01, -0.02) },
        look("tropical", "landscape", ["vivid", "summer", "teal"]) { $0.vibrance = 0.45; $0.hue = 0.015; $0.tint = -0.05; $0.exposure = 0.08 },
        look("meadow", "landscape", ["green", "spring"]) { $0.tint = -0.12; $0.vibrance = 0.3; $0.exposure = 0.1; $0.temperature = 0.08 },
        look("misty", "landscape", ["fog", "soft", "cool"]) { $0.contrast = -0.3; $0.fade = 0.5; $0.saturation = -0.3; $0.temperature = -0.12; $0.exposure = 0.1 },
        look("sunset", "landscape", ["orange", "pink", "evening"]) { $0.temperature = 0.35; $0.tint = 0.18; $0.saturation = 0.15; $0.shadowTint = V(0.02, -0.01, 0.03); $0.highlightTint = V(0.06, 0.01, -0.02) },
        look("lavender", "landscape", ["purple", "soft"]) { $0.tint = 0.22; $0.temperature = -0.12; $0.fade = 0.2; $0.highlightTint = V(0.02, 0.0, 0.04) },
        look("emerald", "landscape", ["green", "teal", "rich"]) { $0.hue = 0.02; $0.tint = -0.1; $0.saturation = 0.15; $0.contrast = 0.12; $0.filmic = 0.25 },
    ]

    static let movies: [EffectDescriptor] = [
        look("tealOrange", "movies", ["blockbuster", "cinematic", "teal"]) { $0.shadowTint = V(-0.05, 0.02, 0.06); $0.highlightTint = V(0.07, 0.02, -0.05); $0.contrast = 0.15; $0.filmic = 0.4; $0.saturation = 0.05; $0.skinProtect = 0.3 },
        look("blockbuster", "movies", ["action", "cinematic"]) { $0.contrast = 0.25; $0.filmic = 0.5; $0.shadowTint = V(-0.03, 0.01, 0.05); $0.highlightTint = V(0.04, 0.02, -0.02); $0.vignette = 0.25 },
        look("greenCode", "movies", ["matrix", "green", "hacker"]) { $0.tint = -0.4; $0.saturation = -0.25; $0.contrast = 0.2; $0.shadowTint = V(-0.02, 0.04, -0.01); $0.filmic = 0.3 },
        look("grandHotel", "movies", ["pastel", "symmetry", "pink"]) { $0.tint = 0.12; $0.temperature = 0.15; $0.fade = 0.3; $0.saturation = 0.05; $0.highlightTint = V(0.04, 0.0, 0.02); $0.contrast = -0.05 },
        look("dunes", "movies", ["desert", "orange", "epic"]) { $0.temperature = 0.55; $0.saturation = -0.15; $0.contrast = 0.2; $0.filmic = 0.4; $0.highlightTint = V(0.05, 0.02, -0.04) },
        look("neonCity", "movies", ["cyberpunk", "magenta", "teal"]) { $0.shadowTint = V(0.0, 0.03, 0.08); $0.highlightTint = V(0.08, -0.02, 0.06); $0.contrast = 0.2; $0.saturation = 0.2; $0.exposure = -0.1 },
        look("western", "movies", ["cowboy", "warm", "dusty"]) { $0.temperature = 0.45; $0.saturation = -0.3; $0.contrast = 0.2; $0.fade = 0.15; $0.grain = 0.25; $0.vignette = 0.3 },
        look("thriller", "movies", ["cold", "dark", "suspense"]) { $0.temperature = -0.3; $0.saturation = -0.35; $0.contrast = 0.2; $0.exposure = -0.12; $0.shadowTint = V(-0.01, 0.02, 0.03); $0.vignette = 0.35 },
        look("romance", "movies", ["warm", "soft", "love"]) { $0.temperature = 0.2; $0.tint = 0.1; $0.fade = 0.2; $0.contrast = -0.05; $0.highlightTint = V(0.04, 0.01, 0.0) },
        look("sciFi", "movies", ["blue", "future"]) { $0.temperature = -0.4; $0.contrast = 0.2; $0.saturation = -0.1; $0.highlightTint = V(-0.02, 0.02, 0.05); $0.filmic = 0.3 },
        look("bleachBypass", "movies", ["desaturated", "gritty", "war"]) { $0.bleach = 0.8; $0.contrast = 0.1; $0.saturation = -0.1 },
        look("moonlight", "movies", ["night", "blue", "moody"]) { $0.temperature = -0.45; $0.exposure = -0.2; $0.saturation = -0.3; $0.contrast = 0.1; $0.shadowTint = V(-0.01, 0.0, 0.04) },
        look("drama", "movies", ["moody", "contrast"]) { $0.contrast = 0.3; $0.saturation = -0.2; $0.filmic = 0.5; $0.vignette = 0.4; $0.exposure = -0.05 },
        look("noirColor", "movies", ["dark", "crime", "red"]) { $0.contrast = 0.35; $0.saturation = -0.55; $0.exposure = -0.1; $0.vignette = 0.45; $0.shadowTint = V(0.02, -0.01, -0.01) },
    ]

    static let film: [EffectDescriptor] = [
        look("film200", "film", ["35mm", "warm", "analog"]) { $0.temperature = 0.18; $0.fade = 0.18; $0.filmic = 0.3; $0.grain = 0.25; $0.shadowTint = V(0.0, 0.01, 0.02); $0.highlightTint = V(0.03, 0.02, -0.01) },
        look("film400", "film", ["35mm", "portrait", "analog"]) { $0.temperature = 0.1; $0.tint = 0.05; $0.fade = 0.22; $0.saturation = -0.1; $0.grain = 0.35; $0.skinProtect = 0.3; $0.highlightTint = V(0.03, 0.01, 0.0) },
        look("slideFilm", "film", ["chrome", "saturated", "analog"]) { $0.contrast = 0.25; $0.saturation = 0.2; $0.filmic = 0.5; $0.shadowTint = V(-0.01, 0.0, 0.03); $0.grain = 0.15 },
        look("expired", "film", ["old", "colour shift", "analog"]) { $0.tint = 0.15; $0.temperature = 0.2; $0.fade = 0.4; $0.crossProcess = 0.3; $0.grain = 0.4; $0.vignette = 0.3 },
        look("instant", "film", ["instant camera", "faded"]) { $0.fade = 0.45; $0.temperature = 0.12; $0.contrast = -0.1; $0.saturation = -0.12; $0.shadowTint = V(0.0, 0.02, 0.03); $0.highlightTint = V(0.03, 0.02, 0.0); $0.vignette = 0.2 },
        look("seventies", "film", ["70s", "retro", "warm"]) { $0.temperature = 0.4; $0.tint = 0.05; $0.fade = 0.35; $0.saturation = -0.15; $0.highlightTint = V(0.05, 0.03, -0.03); $0.grain = 0.3 },
        look("eighties", "film", ["80s", "retro", "magenta"]) { $0.tint = 0.18; $0.saturation = 0.15; $0.contrast = 0.1; $0.shadowTint = V(0.02, -0.01, 0.05); $0.grain = 0.2 },
        look("nineties", "film", ["90s", "retro", "green"]) { $0.tint = -0.1; $0.fade = 0.25; $0.temperature = 0.1; $0.saturation = -0.08; $0.grain = 0.3; $0.shadowTint = V(-0.01, 0.02, 0.0) },
        look("fadedFilm", "film", ["matte", "vintage"]) { $0.fade = 0.6; $0.contrast = -0.15; $0.saturation = -0.25; $0.grain = 0.2 },
        look("crossProcess", "film", ["xpro", "analog", "yellow"]) { $0.crossProcess = 0.8; $0.contrast = 0.1 },
        look("toyCamera", "film", ["lomography", "vignette", "saturated"]) { $0.saturation = 0.3; $0.contrast = 0.25; $0.vignette = 0.6; $0.crossProcess = 0.25; $0.grain = 0.2 },
        look("disposable", "film", ["flash", "party", "analog"]) { $0.exposure = 0.1; $0.contrast = 0.2; $0.tint = -0.06; $0.temperature = 0.08; $0.grain = 0.45; $0.vignette = 0.25 },
        look("vintage", "film", ["old", "warm", "faded"]) { $0.temperature = 0.3; $0.fade = 0.35; $0.saturation = -0.3; $0.vignette = 0.35; $0.grain = 0.3 },
        look("chrome", "film", ["kodachrome", "rich", "classic"]) { $0.contrast = 0.18; $0.saturation = 0.18; $0.temperature = 0.08; $0.filmic = 0.45; $0.shadowTint = V(0.01, 0.0, -0.01) },
    ]

    static let bw: [EffectDescriptor] = [
        look("silver", "bw", ["black and white", "classic"]) { $0.bw = 1; $0.contrast = 0.12; $0.filmic = 0.3 },
        look("highContrast", "bw", ["black and white", "punchy"]) { $0.bw = 1; $0.contrast = 0.45; $0.filmic = 0.6; $0.vignette = 0.2 },
        look("pearl", "bw", ["black and white", "soft"]) { $0.bw = 1; $0.contrast = -0.2; $0.fade = 0.3; $0.exposure = 0.12 },
        look("redFilter", "bw", ["black and white", "dramatic sky"]) { $0.bw = 1; $0.bwMix = V(0.8, 0.2, 0.0); $0.contrast = 0.2 },
        look("greenFilter", "bw", ["black and white", "portrait"]) { $0.bw = 1; $0.bwMix = V(0.25, 0.65, 0.1); $0.contrast = 0.1 },
        look("blueFilter", "bw", ["black and white", "moody"]) { $0.bw = 1; $0.bwMix = V(0.1, 0.3, 0.6); $0.contrast = 0.15 },
        look("selenium", "bw", ["toned", "cool", "black and white"]) { $0.bw = 1; $0.contrast = 0.15; $0.shadowTint = V(0.0, 0.01, 0.04); $0.highlightTint = V(0.0, 0.0, 0.01) },
        look("platinum", "bw", ["toned", "warm", "black and white"]) { $0.bw = 1; $0.contrast = 0.05; $0.shadowTint = V(0.03, 0.015, 0.0); $0.highlightTint = V(0.03, 0.02, 0.0); $0.fade = 0.15 },
        look("grit", "bw", ["grain", "street", "black and white"]) { $0.bw = 1; $0.contrast = 0.35; $0.grain = 0.6; $0.vignette = 0.3 },
        look("faded", "bw", ["matte", "black and white"]) { $0.bw = 1; $0.fade = 0.55; $0.contrast = -0.1 },
    ]

    static let night: [EffectDescriptor] = [
        look("nightCity", "night", ["urban", "lights", "blue"]) { $0.contrast = 0.15; $0.vibrance = 0.25; $0.shadowTint = V(-0.01, 0.0, 0.04); $0.highlights = -0.3; $0.shadows = 0.15 },
        look("neonNights", "night", ["neon", "magenta", "club"]) { $0.saturation = 0.3; $0.tint = 0.2; $0.shadowTint = V(0.02, -0.01, 0.06); $0.contrast = 0.15 },
        look("midnight", "night", ["dark", "blue"]) { $0.temperature = -0.5; $0.exposure = -0.3; $0.saturation = -0.15; $0.contrast = 0.15; $0.vignette = 0.3 },
        look("streetlight", "night", ["sodium", "orange", "urban"]) { $0.temperature = 0.5; $0.contrast = 0.2; $0.saturation = -0.1; $0.shadowTint = V(0.0, 0.01, 0.03); $0.exposure = -0.1 },
        look("cyber", "night", ["cyberpunk", "teal", "purple"]) { $0.shadowTint = V(-0.02, 0.04, 0.07); $0.highlightTint = V(0.06, -0.02, 0.07); $0.saturation = 0.25; $0.contrast = 0.2 },
        look("starlight", "night", ["soft", "cool", "night"]) { $0.temperature = -0.25; $0.exposure = 0.05; $0.shadows = 0.3; $0.highlights = -0.2; $0.fade = 0.15 },
        look("nightfall", "night", ["dusk", "purple"]) { $0.temperature = -0.2; $0.tint = 0.15; $0.exposure = -0.15; $0.shadowTint = V(0.01, 0.0, 0.04) },
        look("brightNight", "night", ["lift", "clear"]) { $0.exposure = 0.3; $0.shadows = 0.45; $0.highlights = -0.35; $0.vibrance = 0.2; $0.contrast = -0.05 },
    ]

    static let style: [EffectDescriptor] = [
        look("pop", "style", ["vivid", "punchy", "colourful"]) { $0.saturation = 0.45; $0.contrast = 0.25; $0.vibrance = 0.2 },
        look("dreamscape", "style", ["dreamy", "purple"]) { $0.tint = 0.2; $0.fade = 0.3; $0.exposure = 0.12; $0.hue = 0.03; $0.highlightTint = V(0.03, 0.0, 0.05) },
        look("cyanPop", "style", ["cyan", "teal"]) { $0.hue = 0.04; $0.saturation = 0.2; $0.temperature = -0.2; $0.contrast = 0.1 },
        look("purpleHaze", "style", ["purple", "violet"]) { $0.tint = 0.35; $0.temperature = -0.2; $0.fade = 0.25; $0.saturation = 0.1 },
        look("matte", "style", ["flat", "faded"]) { $0.fade = 0.55; $0.contrast = -0.1; $0.saturation = -0.1; $0.whitePoint = 0.93 },
        look("hyper", "style", ["hdr", "intense"]) { $0.vibrance = 0.5; $0.contrast = 0.3; $0.shadows = 0.4; $0.highlights = -0.4; $0.filmic = 0.3 },
        look("candy", "style", ["sweet", "pink", "bright"]) { $0.saturation = 0.3; $0.tint = 0.15; $0.exposure = 0.15; $0.hue = -0.01 },
        look("goldTone", "style", ["gold", "monochrome", "warm"]) { $0.bw = 0.85; $0.shadowTint = V(0.02, 0.0, -0.03); $0.highlightTint = V(0.08, 0.05, -0.04); $0.contrast = 0.15 },
        look("aqua", "style", ["water", "blue", "green"]) { $0.hue = 0.06; $0.tint = -0.1; $0.saturation = 0.15; $0.exposure = 0.08 },
        look("sunKissed", "style", ["warm", "glow", "summer"]) { $0.temperature = 0.4; $0.exposure = 0.2; $0.highlights = -0.2; $0.fade = 0.15; $0.highlightTint = V(0.05, 0.03, 0.0) },
    ]

    /// Curated "Featured" picks shown first in the Filters tab (ids).
    public static let featured: [String] = [
        "natural", "tealOrange", "goldenHour", "film400", "fresh", "vintage", "silver", "peach", "blockbuster", "seventies",
        "pastel", "nightCity", "delicious", "moonlight", "chrome", "milk",
    ].map { "montage.filter.\($0)" }

    public static let all: [EffectDescriptor] = legacy + portrait + life + food + landscape + movies + film + bw + night + style
}
