import Foundation

// Text model (ARCHITECTURE §17 W7, "Text engine"). Pure values, Codable, Sendable.
//
// Units: every distance in a text style is in **em** = the font size in pixels (`fontSize` × canvas height), so a style
// renders identically at any canvas / export resolution and scales with the font size. Angles are degrees, clockwise
// (screen space, y down). All new fields decode with defaults, so projects saved before they existed open unchanged.

public enum TextAlignment: String, Codable, Sendable, CaseIterable { case left, center, right, justify }

/// CapCut "Case": TT (upper) · tt (lower) · Tt (title). `none` keeps what was typed.
public enum TextCase: String, Codable, Sendable, CaseIterable { case none, upper, lower, title }

/// CapCut's three "vertical" alignment buttons switch to vertical text (characters stacked top → bottom, columns right → left);
/// `alignment` then reads as top (left) / centre / bottom (right).
public enum TextOrientation: String, Codable, Sendable, CaseIterable { case horizontal, vertical }

/// Extra outline drawn outside the primary stroke (CapCut "Triple layer" word art). `width` in em, measured from the glyph edge.
public struct TextStrokeLayer: Hashable, Codable, Sendable {
    public var color: RGBA
    public var width: Double
    public init(color: RGBA, width: Double) { self.color = color; self.width = width }
}

/// Where the primary stroke sits relative to the glyph edge (CapCut Stroke ▸ Position, TX-005).
public enum TextStrokePosition: String, Codable, Sendable, CaseIterable {
    /// Whole width outside the edge, under the fill (default, CapCut "Outside").
    case outside
    /// Half inside, half outside, drawn over the fill.
    case center
    /// Whole width inside the edge (clipped to the glyph), drawn over the fill.
    case inside
}

public enum TextBackgroundMode: String, Codable, Sendable, CaseIterable {
    /// One box around the whole text.
    case block
    /// One box per line (CapCut captions "label" look).
    case line
    /// One box per character ("Letter background").
    case letter
}

/// Text background ("label"). Colour and opacity are `TextContent.backgroundColor` (alpha 0 = off).
public struct TextBackgroundStyle: Hashable, Codable, Sendable {
    public var mode: TextBackgroundMode
    /// 0 = square, 1 = fully rounded ends.
    public var cornerRadius: Double
    /// Padding around the text, em.
    public var paddingX: Double
    public var paddingY: Double
    /// Box offset relative to the text, em.
    public var offset: Vec2
    public init(mode: TextBackgroundMode = .block, cornerRadius: Double = 0.3, paddingX: Double = 0.3, paddingY: Double = 0.12,
                offset: Vec2 = .zero) {
        self.mode = mode; self.cornerRadius = cornerRadius; self.paddingX = paddingX; self.paddingY = paddingY; self.offset = offset
    }
}

/// Drop shadow / 3D shadow. Colour and opacity are `TextContent.shadowColor` (alpha 0 = off).
public struct TextShadowStyle: Hashable, Codable, Sendable {
    /// Offset length, em.
    public var distance: Double
    /// Direction of the offset, degrees (0 = right, 90 = down).
    public var angle: Double
    /// Blur radius, em.
    public var blur: Double
    /// 3D extrusion depth, em (0 = flat drop shadow). The shadow is repeated along the angle up to `distance`.
    public var extrude: Bool
    public init(distance: Double = 0.07, angle: Double = 45, blur: Double = 0.1, extrude: Bool = false) {
        self.distance = distance; self.angle = angle; self.blur = blur; self.extrude = extrude
    }
}

public enum TextGlowMode: String, Codable, Sendable, CaseIterable { case outer, inner, both }

/// "Glow": coloured halo around (outer) and/or inside (inner) the glyphs.
public struct TextGlowStyle: Hashable, Codable, Sendable {
    public var color: RGBA
    /// 0…1.
    public var intensity: Double
    /// Halo radius, em.
    public var radius: Double
    public var mode: TextGlowMode
    public init(color: RGBA, intensity: Double = 0.8, radius: Double = 0.25, mode: TextGlowMode = .outer) {
        self.color = color; self.intensity = intensity; self.radius = radius; self.mode = mode
    }
}

/// Gradient fill ("Line" gradient in CapCut). Stops are spread evenly across the text box along `angle`.
public struct TextGradient: Hashable, Codable, Sendable {
    public var colors: [RGBA]
    /// 0 = left → right, 90 = top → bottom.
    public var angle: Double
    public init(_ colors: [RGBA], angle: Double = 90) { self.colors = colors; self.angle = angle }
}

/// Procedural texture fill ("Select texture"): ids are listed in `TextTextures.all`.
public struct TextTexture: Hashable, Codable, Sendable {
    public var id: String
    /// Tile size, em.
    public var scale: Double
    public init(id: String, scale: Double = 1) { self.id = id; self.scale = scale }
}

/// Non-solid glyph fill. nil on `TextContent.fill` = solid `color`.
public enum TextFill: Hashable, Codable, Sendable {
    case gradient(TextGradient)
    case texture(TextTexture)
}

/// "Text path": glyphs follow a shape instead of a straight baseline (TX-010). Points are normalized: the path is scaled so
/// that its length matches the text's natural width.
public struct TextPathShape: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case circle, wave, arch, spiral, custom }
    public var kind: Kind
    /// Shape strength (wave amplitude, arch height…), 0…1.
    public var amount: Double
    /// Polyline for `.custom`, any coordinates (scaled to fit), y down.
    public var points: [Vec2]
    public init(_ kind: Kind, amount: Double = 0.5, points: [Vec2] = []) { self.kind = kind; self.amount = amount; self.points = points }
}

/// UTF-16 range inside `TextContent.string` (Core Text / NSTextView units).
public struct TextSpan: Hashable, Codable, Sendable {
    public var location: Int
    public var length: Int
    public init(_ location: Int, _ length: Int) { self.location = location; self.length = length }
    public var end: Int { location + length }
    public func intersects(_ o: TextSpan) -> Bool { location < o.end && o.location < end }
}

/// Per-range style overrides (CapCut "multiple values"). nil = inherit the clip-wide value.
public struct TextRunStyle: Hashable, Codable, Sendable {
    public var color: RGBA?
    public var fontName: String?
    /// Multiplier on the clip font size.
    public var sizeScale: Double?
    public var bold: Bool?
    public var italic: Bool?
    public var underline: Bool?
    public var strokeColor: RGBA?
    public var backgroundColor: RGBA?
    /// Text effect (word-art style id, `Registries.textStyles`) painted on this range only (TX-040): its outlines,
    /// shadow, glow and fill replace the clip's on these characters.
    public var effectID: String?
    public init(color: RGBA? = nil, fontName: String? = nil, sizeScale: Double? = nil, bold: Bool? = nil, italic: Bool? = nil,
                underline: Bool? = nil, strokeColor: RGBA? = nil, backgroundColor: RGBA? = nil, effectID: String? = nil) {
        self.color = color; self.fontName = fontName; self.sizeScale = sizeScale; self.bold = bold; self.italic = italic
        self.underline = underline; self.strokeColor = strokeColor; self.backgroundColor = backgroundColor; self.effectID = effectID
    }
    public var isEmpty: Bool { self == TextRunStyle() }
    /// `o` wins where it sets a value.
    public func merged(with o: TextRunStyle) -> TextRunStyle {
        TextRunStyle(color: o.color ?? color, fontName: o.fontName ?? fontName, sizeScale: o.sizeScale ?? sizeScale,
                     bold: o.bold ?? bold, italic: o.italic ?? italic, underline: o.underline ?? underline,
                     strokeColor: o.strokeColor ?? strokeColor, backgroundColor: o.backgroundColor ?? backgroundColor,
                     effectID: o.effectID ?? effectID)
    }
}

public struct TextRun: Hashable, Codable, Sendable {
    public var range: TextSpan
    public var style: TextRunStyle
    public init(_ range: TextSpan, _ style: TextRunStyle) { self.range = range; self.style = style }
}

/// A multi-layer animated title instance (TX-013/041). Slot 0 is `TextContent.string`; `texts` holds slots 1…
public struct TextTemplateInstance: Hashable, Codable, Sendable {
    public var templateID: String
    public var texts: [String]
    /// "Separate text template" (TX-032): indices of the template layers this clip shows (nil = all). Each separated
    /// part is its own clip showing one layer, with the full slot texts (shapes fitted to a slot keep their width).
    public var layers: [Int]?
    /// Language of the default slot texts (TX-033, nil = app language when added).
    public var language: String?
    public init(templateID: String, texts: [String] = [], layers: [Int]? = nil, language: String? = nil) {
        self.templateID = templateID; self.texts = texts; self.layers = layers; self.language = language
    }
    public func showsLayer(_ i: Int) -> Bool { layers?.contains(i) ?? true }
}

/// Text clip content. Sizes are canvas-relative so a project renders identically at any export resolution.
public struct TextContent: Hashable, Codable, Sendable {
    public var string: String
    /// PostScript or family name; empty = system font.
    public var fontName: String
    /// Font size as a fraction of canvas height (CapCut default 15 → 0.06; the inspector shows `fontSize × 250`).
    public var fontSize: Double
    public var color: RGBA
    public var alignment: TextAlignment
    public var bold: Bool
    public var italic: Bool
    /// Primary outline (`strokeWidth` em, 0 = off). Drawn outside the glyph edge (the fill is painted on top).
    public var strokeColor: RGBA
    public var strokeWidth: Double
    /// Position of the primary stroke (extra stroke layers are always outside).
    public var strokePosition: TextStrokePosition
    /// Background / label colour (alpha 0 = off); shape in `background`.
    public var backgroundColor: RGBA
    /// Shadow colour (alpha 0 = off; alpha = opacity); geometry in `shadow`.
    public var shadowColor: RGBA
    /// Extra line spacing, em (CapCut "Line").
    public var lineSpacing: Double
    /// Extra character spacing, em (CapCut "Character").
    public var letterSpacing: Double
    /// Text style / word-art preset id (`Registries.textStyles`), if any.
    public var styleID: String?

    // Rich styling (W7). Defaults keep old projects unchanged.
    public var underline: Bool
    public var textCase: TextCase
    public var orientation: TextOrientation
    public var extraStrokes: [TextStrokeLayer]
    public var background: TextBackgroundStyle
    public var shadow: TextShadowStyle
    public var glow: TextGlowStyle?
    public var fill: TextFill?
    /// "Curve": bend along an arc, −1…1 (positive = arch ∩).
    public var curve: Double
    public var path: TextPathShape?
    /// Fixed text-box width as a fraction of the canvas width (wraps lines); nil = auto width.
    public var boxWidth: Double?
    /// Per-range overrides, non-overlapping, sorted by location.
    public var runs: [TextRun]
    /// Speech-bubble / banner shape behind the text (`Registries.textBubbles`).
    public var bubbleID: String?
    public var bubbleColor: RGBA?
    /// Present on caption clips (word timings, translation…).
    public var caption: CaptionData?
    /// Word-highlight (karaoke) styling; needs `caption.words` (or spreads words evenly over the clip).
    public var karaoke: KaraokeStyle?
    /// Multi-layer text template this clip instantiates.
    public var template: TextTemplateInstance?
    /// Animated number / timer / date counter replacing the displayed string (TX-039); nil = plain text.
    public var counter: TextCounter?

    public init(string: String, fontName: String = "", fontSize: Double = 0.06, color: RGBA = .white,
                alignment: TextAlignment = .center) {
        self.string = string; self.fontName = fontName; self.fontSize = fontSize; self.color = color
        self.alignment = alignment; bold = false; italic = false
        strokeColor = .black; strokeWidth = 0; strokePosition = .outside; backgroundColor = .clear; shadowColor = .clear
        lineSpacing = 0; letterSpacing = 0; styleID = nil
        underline = false; textCase = .none; orientation = .horizontal; extraStrokes = []
        background = TextBackgroundStyle(); shadow = TextShadowStyle(); glow = nil; fill = nil
        curve = 0; path = nil; boxWidth = nil; runs = []; bubbleID = nil; bubbleColor = nil
        caption = nil; karaoke = nil; template = nil
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(string: try c.decode(String.self, forKey: .string))
        func v<T: Decodable>(_ k: CodingKeys, _ d: T) throws -> T { try c.decodeIfPresent(T.self, forKey: k) ?? d }
        fontName = try v(.fontName, fontName); fontSize = try v(.fontSize, fontSize); color = try v(.color, color)
        alignment = try v(.alignment, alignment); bold = try v(.bold, bold); italic = try v(.italic, italic)
        strokeColor = try v(.strokeColor, strokeColor); strokeWidth = try v(.strokeWidth, strokeWidth)
        strokePosition = try v(.strokePosition, strokePosition)
        backgroundColor = try v(.backgroundColor, backgroundColor); shadowColor = try v(.shadowColor, shadowColor)
        lineSpacing = try v(.lineSpacing, lineSpacing); letterSpacing = try v(.letterSpacing, letterSpacing)
        styleID = try c.decodeIfPresent(String.self, forKey: .styleID)
        underline = try v(.underline, underline); textCase = try v(.textCase, textCase)
        orientation = try v(.orientation, orientation); extraStrokes = try v(.extraStrokes, extraStrokes)
        background = try v(.background, background); shadow = try v(.shadow, shadow)
        glow = try c.decodeIfPresent(TextGlowStyle.self, forKey: .glow)
        fill = try c.decodeIfPresent(TextFill.self, forKey: .fill)
        curve = try v(.curve, curve); path = try c.decodeIfPresent(TextPathShape.self, forKey: .path)
        boxWidth = try c.decodeIfPresent(Double.self, forKey: .boxWidth); runs = try v(.runs, runs)
        bubbleID = try c.decodeIfPresent(String.self, forKey: .bubbleID)
        bubbleColor = try c.decodeIfPresent(RGBA.self, forKey: .bubbleColor)
        caption = try c.decodeIfPresent(CaptionData.self, forKey: .caption)
        karaoke = try c.decodeIfPresent(KaraokeStyle.self, forKey: .karaoke)
        template = try c.decodeIfPresent(TextTemplateInstance.self, forKey: .template)
        counter = try c.decodeIfPresent(TextCounter.self, forKey: .counter)
    }

    /// How far the outlines reach outside the glyph edge, em (primary stroke by position + extra layers).
    public var strokeExtentEm: Double {
        let primary: Double
        switch strokePosition {
        case .outside: primary = strokeWidth
        case .center: primary = strokeWidth / 2
        case .inside: primary = 0
        }
        return ([primary] + extraStrokes.map(\.width)).max() ?? 0
    }

    /// The string as displayed (case transform applied). Same UTF-16 length as `string` for every `TextCase` except
    /// rare locale-specific expansions (ß → SS), in which case runs are clamped.
    public var displayString: String { textCase.apply(string) }

    /// Clip-wide style as a run style (the base every run overrides).
    public var baseRunStyle: TextRunStyle {
        TextRunStyle(color: color, fontName: fontName, sizeScale: 1, bold: bold, italic: italic, underline: underline,
                     strokeColor: strokeColor, backgroundColor: nil)
    }

    /// Effective style at a UTF-16 offset.
    public func runStyle(at offset: Int) -> TextRunStyle {
        guard let r = runs.first(where: { $0.range.location <= offset && offset < $0.range.end }) else { return baseRunStyle }
        return baseRunStyle.merged(with: r.style)
    }

    /// True when every visual property except the string/timing matches (used by "apply to all captions").
    public func sameLook(as o: TextContent) -> Bool {
        var a = self, b = o
        a.string = ""; b.string = ""; a.caption = nil; b.caption = nil; a.runs = []; b.runs = []
        return a == b
    }

    /// Copies every visual property of `style` onto self, keeping the string, runs, caption data and template text.
    public mutating func adoptLook(of style: TextContent) {
        let keep = (string, runs, caption, template, counter)
        self = style
        string = keep.0; runs = keep.1; caption = keep.2
        if style.counter == nil { counter = keep.4 }
        if let t = keep.3, t.templateID == style.template?.templateID { template = t }
    }
}

extension TextCase {
    public func apply(_ s: String) -> String {
        switch self {
        case .none: return s
        case .upper: return s.uppercased()
        case .lower: return s.lowercased()
        case .title: return s.capitalized
        }
    }
}
