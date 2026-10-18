import Foundation
import MontageCore

/// Asset-panel / inspector grouping of effect-stack items.
public enum EffectCategory: String, Sendable, CaseIterable {
    /// "Filters" tab: look presets with one Intensity slider.
    case filter
    /// "Effects" tab → video effects.
    case effect
    /// "Adjustment" tab: colour/light controls.
    case adjustment
    /// Keyers (chroma key) — inspector Cutout tab only, never listed in the asset panel.
    case key
    /// Canvas background styles — inspector Canvas section only, never listed in the asset panel.
    case canvas
}

/// Declares one parameter. The inspector builds its controls from these, keyframes key off `key`,
/// and the engine packs values into the shader's `p[]` array in declaration order (colour = 4 floats).
public struct ParamSpec: Sendable {
    public enum Kind: Sendable {
        case scalar(min: Double, max: Double, defaultValue: Double)
        case color(defaultValue: RGBA)
        case bool(defaultValue: Bool)
        case choice(optionKeys: [String], defaultValue: Int)
    }
    public let key: String
    public let nameKey: String
    public let kind: Kind
    /// Inspector display multiplier (e.g. 100 to show 0…1 as 0…100).
    public let displayScale: Double

    public init(_ key: String, nameKey: String, _ kind: Kind, displayScale: Double = 1) {
        self.key = key; self.nameKey = nameKey; self.kind = kind; self.displayScale = displayScale
    }

    public static func scalar(_ key: String, _ nameKey: String, _ min: Double, _ max: Double, _ def: Double, display: Double = 1) -> ParamSpec {
        ParamSpec(key, nameKey: nameKey, .scalar(min: min, max: max, defaultValue: def), displayScale: display)
    }

    public var defaultValue: ParamValue {
        switch kind {
        case .scalar(_, _, let d): return .scalar(d)
        case .color(let d): return .color(d)
        case .bool(let d): return .bool(d)
        case .choice(_, let d): return .choice(d)
        }
    }

    public var floatCount: Int { if case .color = kind { return 4 }; return 1 }
}

/// Extra GPU resource bound to an effect's shader (beyond `src`).
///
/// When a descriptor declares `inputs`, its shader signature gains one trailing argument per input, in order:
/// - `.lut3D(id:)` → `texture3d<float> lut` (rgba16Float lattice over [0,1]³, linear filtering; sample at
///   `c * (N-1)/N + 0.5/N`, or use the prelude helper `fx_lut3d(lut, s3, rgb)` — `s3` is passed as a 3D sampler).
///   The id names a LUT in the engine's `LUTLibrary`. If the resource is missing the effect is skipped for that frame.
/// ```metal
/// float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx,
///               texture3d<float> lut, sampler s3)
/// ```
public enum EffectInput: Sendable, Hashable {
    case lut3D(id: String)
    /// The effect's own input before its first pass → `texture2d<float> orig` (sampled with `s`). Lets multi-pass
    /// effects (glow, bloom, halation) combine a blurred intermediate with the untouched layer in their last pass.
    case original
}

/// A shader-based effect, filter or adjustment applied to one layer (or, on an adjustment clip, to the composite below).
///
/// `shader` is Metal Shading Language defining:
/// ```metal
/// float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx)
/// ```
/// - `src` is the layer in straight RGBA (linear filtering, clamp-to-edge), `uv` in [0,1] (y down);
/// - `p` holds the params in `params` order; `ctx.time` = clip-local seconds, `ctx.size` = texture size in px,
///   `ctx.pass` = pass index (0..<passes) for multi-pass effects (ping-pong, e.g. separable blur).
/// Helpers available to all shaders: `fx_luma`, `fx_hash`, `fx_rgb2hsv`, `fx_hsv2rgb` (see `ShaderPrelude`).
/// Each effect compiles into its own Metal library, so a broken shader only disables that effect.
public struct EffectDescriptor: Sendable, Identifiable {
    public let id: String
    public let category: EffectCategory
    public let nameKey: String
    /// Sub-category in the asset panel (localization key), e.g. "fx.group.basic".
    public let groupKey: String
    public let params: [ParamSpec]
    public let shader: String
    public let passes: Int
    /// SF Symbol for the asset tile until real thumbnails are generated.
    public let symbol: String
    /// Extra textures bound to the shader (see `EffectInput`). Empty for ordinary effects.
    public let inputs: [EffectInput]
    /// Preset constants appended to `p[]` after the parameters (never shown, stored or keyframed). Presets of one base
    /// shader differ only by these, so they share the same source and therefore one compiled pipeline.
    public let constants: [Float]
    /// Extra search keywords (English, lowercase), matched in addition to the localized name and group.
    public let tags: [String]

    public init(id: String, category: EffectCategory, nameKey: String, groupKey: String, params: [ParamSpec] = [],
                passes: Int = 1, symbol: String = "sparkles", inputs: [EffectInput] = [], constants: [Float] = [],
                tags: [String] = [], shader: String) {
        self.id = id; self.category = category; self.nameKey = nameKey; self.groupKey = groupKey
        self.params = params; self.passes = passes; self.symbol = symbol; self.inputs = inputs; self.shader = shader
        self.constants = constants; self.tags = tags
    }

    /// Index of the first preset constant in `p[]` (= total float count of `params`).
    public var constantsOffset: Int { params.reduce(0) { $0 + $1.floatCount } }

    /// New instance with every parameter at its default.
    public func makeInstance() -> EffectInstance {
        EffectInstance(typeID: id, params: Dictionary(uniqueKeysWithValues: params.map { ($0.key, $0.defaultValue) }))
    }

    /// Flattens instance params (missing → default) into the shader's float array.
    public func packParams(_ values: [String: ParamValue]) -> [Float] {
        var out: [Float] = []
        for p in params { out += (values[p.key] ?? p.defaultValue).floats }
        out += constants
        return out.isEmpty ? [0] : out
    }
}

/// A transition between two adjacent main-track clips.
///
/// `shader` defines:
/// ```metal
/// float4 transition(float2 uv, texture2d<float> from, texture2d<float> to, sampler s, float progress,
///                   constant float* p, FXContext ctx)
/// ```
/// `from`/`to` are both layers already placed on the canvas (canvas-sized, straight alpha).
public struct TransitionDescriptor: Sendable, Identifiable {
    public let id: String
    public let nameKey: String
    public let groupKey: String
    public let params: [ParamSpec]
    public let defaultDuration: Time
    public let symbol: String
    public let shader: String

    public init(id: String, nameKey: String, groupKey: String, params: [ParamSpec] = [], defaultDuration: Time = Time(0.5),
                symbol: String = "rectangle.on.rectangle", shader: String) {
        self.id = id; self.nameKey = nameKey; self.groupKey = groupKey; self.params = params
        self.defaultDuration = defaultDuration; self.symbol = symbol; self.shader = shader
    }

    public func makeInstance() -> TransitionInstance {
        TransitionInstance(typeID: id, duration: defaultDuration,
                           params: Dictionary(uniqueKeysWithValues: params.map { ($0.key, $0.defaultValue) }))
    }

    public func packParams(_ values: [String: ParamValue]) -> [Float] {
        var out: [Float] = []
        for p in params { out += (values[p.key] ?? p.defaultValue).floats }
        return out.isEmpty ? [0] : out
    }
}

/// Mutable per-frame layer state an animation may change. Applied after keyframes, before rendering.
public struct AnimatedLayerState: Sendable {
    public var transform: Transform
    public var opacity: Double
    /// Extra blur in canvas-height fractions (0 = none) — honoured by the renderer.
    public var blur: Double
    public init(transform: Transform, opacity: Double, blur: Double = 0) {
        self.transform = transform; self.opacity = opacity; self.blur = blur
    }
}

public enum AnimationPhaseKind: String, Sendable, CaseIterable { case `in`, out, combo }

/// What an animation can be applied to (CapCut has separate libraries for video and text animations).
public struct AnimationTargets: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let video = AnimationTargets(rawValue: 1)
    public static let text = AnimationTargets(rawValue: 2)
    public static let sticker = AnimationTargets(rawValue: 4)
    public static let all: AnimationTargets = [.video, .text, .sticker]
}

/// In / out / combo animation as a pure function of progress (no shader).
/// For `.in`, progress goes 0 → 1 over the animation (0 = start of clip); for `.out`, 0 → 1 toward the clip end.
public struct AnimationDescriptor: Sendable, Identifiable {
    public let id: String
    public let phase: AnimationPhaseKind
    public let targets: AnimationTargets
    public let nameKey: String
    public let symbol: String
    public let defaultDuration: Time
    public let apply: @Sendable (_ progress: Double, _ state: inout AnimatedLayerState) -> Void
    /// Per-glyph part (text only): characters / words / lines animate individually (W7 text engine). `apply` still
    /// runs on the whole layer, so an animation may combine both.
    public let glyph: GlyphAnimationSpec?

    public init(id: String, phase: AnimationPhaseKind, targets: AnimationTargets = .all, nameKey: String,
                symbol: String = "wand.and.stars", defaultDuration: Time = Time(0.5), glyph: GlyphAnimationSpec? = nil,
                apply: @escaping @Sendable (Double, inout AnimatedLayerState) -> Void = { _, _ in }) {
        self.id = id; self.phase = phase; self.targets = targets; self.nameKey = nameKey; self.symbol = symbol
        self.defaultDuration = defaultDuration; self.apply = apply; self.glyph = glyph
    }
}

/// Sticker (asset panel "Stickers"). `emoji` stickers render through Core Text; `image` stickers load a bundled PNG.
public struct StickerDescriptor: Sendable, Identifiable {
    public enum Source: Sendable { case emoji(String), image(resource: String, bundle: @Sendable () -> Bundle) }
    public let id: String
    public let nameKey: String
    public let groupKey: String
    public let source: Source
    public init(id: String, nameKey: String, groupKey: String, source: Source) {
        self.id = id; self.nameKey = nameKey; self.groupKey = groupKey; self.source = source
    }
}

/// Text style preset ("Text ▸ Basic" preset row) or word-art text effect ("Text effects" library).
/// Procedural families share a `nameKey` and differ by `number` ("Neon 3").
public struct TextStyleDescriptor: Sendable, Identifiable {
    public let id: String
    public let nameKey: String
    public let groupKey: String
    public let kind: TextStyleKind
    public let number: Int?
    public let apply: @Sendable (inout TextContent) -> Void
    public init(id: String, nameKey: String, groupKey: String = "textStyle.group.basic", kind: TextStyleKind = .preset,
                number: Int? = nil, apply: @escaping @Sendable (inout TextContent) -> Void) {
        self.id = id; self.nameKey = nameKey; self.groupKey = groupKey; self.kind = kind; self.number = number; self.apply = apply
    }
    public var displayName: String { number.map { "\(tr(nameKey)) \($0)" } ?? tr(nameKey) }

    /// Applies the style to `t`, keeping its text, size, alignment, box, caption data and runs' text (CapCut presets
    /// replace the look, not the content).
    public func restyle(_ t: inout TextContent) {
        var n = TextContent(string: t.string, fontName: t.fontName, fontSize: t.fontSize, alignment: t.alignment)
        n.boxWidth = t.boxWidth; n.caption = t.caption; n.karaoke = t.karaoke; n.template = t.template
        n.orientation = t.orientation; n.lineSpacing = t.lineSpacing; n.letterSpacing = t.letterSpacing; n.textCase = t.textCase
        n.runs = t.runs.compactMap { r in
            var st = r.style; st.color = nil; st.strokeColor = nil; st.backgroundColor = nil
            return st.isEmpty ? nil : TextRun(r.range, st)
        }
        apply(&n)
        n.styleID = id
        t = n
    }
}
