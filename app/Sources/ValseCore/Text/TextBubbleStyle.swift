import Foundation

/// "Text ▸ Bubble" look (TX-BUBBLE2): one vector shape fitted to the padded text block, drawn behind the glyphs.
/// Presets (`TextBubbleDescriptor.style`) and the clip's own edits (`TextContent.bubbleStyle`) share this value.
/// Sizes in em of the clip font size. Every field decodes with a default, so older / newer files stay readable.
public struct TextBubbleStyle: Hashable, Codable, Sendable {
    public enum Family: String, Codable, CaseIterable, Sendable {
        /// `circle`: a true circle around the text box (diameter = its diagonal + 2 × max(padding)).
        case box, pill, oval, circle, cloud, burst, banner, ribbon, tag, hexagon, arrow, brackets, underline

        /// Families that can carry a tail.
        public var hasTail: Bool { [.box, .pill, .oval, .circle, .cloud, .burst].contains(self) }
        /// Families with an Edge (Calm / Spiky / Wild) control.
        public var hasEdge: Bool { self == .cloud || self == .burst }
        /// Families whose shape can be grown to contain the padded text rectangle.
        public var canContain: Bool { self == .oval || self == .circle || self == .cloud || self == .burst }
    }

    /// The Edge control's three looks (burst spikes / depth, cloud bumps).
    public enum Edge: String, CaseIterable, Sendable { case calm, spiky, wild }

    public var family: Family
    /// Corner radius, em (box only; clamped to half the height).
    public var cornerRadius: Double
    /// Burst spikes / depth, cloud bumps.
    public var spikes: Int
    public var depth: Double
    public var bumps: Int
    /// 0…1 irregular spike / bump size (Wild).
    public var jitter: Double
    /// Banner fold, fraction of the height; underline bar height, em.
    public var fold: Double
    public var barHeight: Double
    public var tail: TextBubbleTail?
    /// Padding between the text and the shape, em, horizontal (x) and vertical (y); ≥ `minPadding` (negative = the
    /// shape hugs the text box). 0 = the shape touches the text box.
    public var padding: Vec2
    /// Fill colour; alpha 0 = transparent.
    public var fill: RGBA
    public var outline: TextBubbleOutline?
    public var shadow: TextBubbleShadow?
    /// The shape contains the padded text rectangle (new presets, edited shapes): oval / cloud / burst grow around
    /// it, box / pill corners never cut into it. Legacy presets keep the v1 sizing (false), so they render as before.
    public var containsText: Bool

    public init(family: Family, cornerRadius: Double = 0.3, spikes: Int = 14, depth: Double = 0.25, bumps: Int = 9,
                jitter: Double = 0, fold: Double = 0.5, barHeight: Double = 0.18, tail: TextBubbleTail? = nil,
                padding: Vec2 = TextBubbleStyle.defaultPadding, fill: RGBA, outline: TextBubbleOutline? = nil, shadow: TextBubbleShadow? = nil,
                containsText: Bool = false) {
        self.family = family; self.cornerRadius = cornerRadius; self.spikes = spikes; self.depth = depth; self.bumps = bumps
        self.jitter = jitter; self.fold = fold; self.barHeight = barHeight; self.tail = tail; self.padding = padding
        self.fill = fill; self.outline = outline; self.shadow = shadow; self.containsText = containsText
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(family: try c.decodeIfPresent(Family.self, forKey: .family) ?? .box, fill: .white)
        func v<T: Decodable>(_ k: CodingKeys, _ d: T) throws -> T { try c.decodeIfPresent(T.self, forKey: k) ?? d }
        cornerRadius = try v(.cornerRadius, cornerRadius); spikes = try v(.spikes, spikes); depth = try v(.depth, depth)
        bumps = try v(.bumps, bumps); jitter = try v(.jitter, jitter); fold = try v(.fold, fold); barHeight = try v(.barHeight, barHeight)
        tail = try c.decodeIfPresent(TextBubbleTail.self, forKey: .tail)
        padding = try v(.padding, padding); fill = try v(.fill, fill)
        outline = try c.decodeIfPresent(TextBubbleOutline.self, forKey: .outline)
        shadow = try c.decodeIfPresent(TextBubbleShadow.self, forKey: .shadow)
        containsText = try v(.containsText, containsText)
    }

    /// Edge look of the current spikes / bumps (nil = a custom value).
    public var edge: Edge? {
        switch family {
        case .burst:
            if jitter > 0 { return .wild }
            return Self.burstEdges.first { $0.value.spikes == spikes && abs($0.value.depth - depth) < 1e-6 }?.key
        case .cloud:
            if jitter > 0 { return .wild }
            return Self.cloudBumps.first { $0.value == bumps }?.key
        default: return nil
        }
    }

    static let burstEdges: [Edge: (spikes: Int, depth: Double)] = [.calm: (10, 0.15), .spiky: (14, 0.25), .wild: (18, 0.32)]
    static let cloudBumps: [Edge: Int] = [.calm: 7, .spiky: 10, .wild: 13]

    /// Writes an Edge look (burst: 10 / 0.15 · 14 / 0.25 · 18 / 0.32 + jitter; cloud: 7 / 10 / 13 bumps).
    public mutating func setEdge(_ e: Edge) {
        if let b = Self.burstEdges[e] { spikes = b.spikes; depth = b.depth }
        bumps = Self.cloudBumps[e] ?? bumps
        jitter = e == .wild ? 0.5 : 0
    }

    /// A bubble built from scratch (Bubble ▸ Shape with no bubble): that shape, white fill, no outline, default
    /// padding, containing the text.
    public static func blank(_ f: Family) -> TextBubbleStyle { TextBubbleStyle(family: f, fill: .white, containsText: true) }

    /// Changes the shape family (Customize ▸ Shape): the shape then contains the text; tails are dropped on families
    /// without one.
    public mutating func setFamily(_ f: Family) {
        family = f
        containsText = true
        if !f.hasTail { tail = nil }
    }

    /// Smallest padding, em: below 0 the shape hugs / overlaps the text box (the engine keeps a minimum shape size).
    public static let minPadding = -1.0
    /// Padding of a bubble built from scratch (and of the box family), em.
    public static let defaultPadding = Vec2(0.45, 0.3)

    /// Padding scale relative to `base` (keeps the x:y ratio), clamped to `minPadding`.
    public mutating func scalePadding(to k: Double, base: Vec2) {
        padding = Vec2(max(base.x * k, Self.minPadding), max(base.y * k, Self.minPadding))
    }

    /// Sets one axis (0 = horizontal, 1 = vertical) to `v` em, clamped to `minPadding`. Linked, the other axis follows
    /// by the same ratio (keeps the x:y shape), or by the same amount when either value is ≤ 0 (never stuck at 0).
    public mutating func setPadding(axis: Int, to v0: Double, linked: Bool) {
        let v = max(v0, Self.minPadding)
        let old = axis == 0 ? padding.x : padding.y
        var other = axis == 0 ? padding.y : padding.x
        if linked {
            other = old > 1e-9 && other > 1e-9 ? other * v / old : other + (v - old)
            other = max(other, Self.minPadding)
        }
        padding = axis == 0 ? Vec2(v, other) : Vec2(other, v)
    }

    /// How far the bubble's light and shadow reach beyond the outline, em (render bounds).
    public var effectExtentEm: Double {
        var e = (outline?.width ?? 0)
        if let n = outline?.neon { e += n.glowSize * 1.6 + (outline?.width ?? 0) }
        if let s = shadow { e += s.offsetEm + s.blurEm * 1.5 }
        return e
    }
}

/// Tail of a bubble. `position` nil = the classic placement of the v1 speech bubbles (pixel-identical).
public struct TextBubbleTail: Hashable, Codable, Sendable {
    public enum Side: String, Codable, CaseIterable, Sendable { case top, right, bottom, left, topLeft, topRight, bottomLeft, bottomRight }
    public enum Kind: String, Codable, CaseIterable, Sendable { case point, curve, dots }
    public var side: Side
    public var kind: Kind
    /// Tail length and base width, em (maxima).
    public var length: Double
    public var width: Double
    /// −1…1 tip offset along the side.
    public var lean: Double
    /// 0…1 along the side; nil = classic placement.
    public var position: Double?

    public static let defaultLength = 0.8, defaultWidth = 0.9

    public init(side: Side, kind: Kind = .point, length: Double = TextBubbleTail.defaultLength, width: Double = TextBubbleTail.defaultWidth,
                lean: Double = 0, position: Double? = nil) {
        self.side = side; self.kind = kind; self.length = length; self.width = width; self.lean = lean; self.position = position
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(side: try c.decodeIfPresent(Side.self, forKey: .side) ?? .bottom)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? kind
        length = try c.decodeIfPresent(Double.self, forKey: .length) ?? length
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? width
        lean = try c.decodeIfPresent(Double.self, forKey: .lean) ?? lean
        position = try c.decodeIfPresent(Double.self, forKey: .position)
    }
}

public struct TextBubbleOutline: Hashable, Codable, Sendable {
    /// dashed = 3w on / 2w off; dotted = round dots every 2w.
    public enum Dash: String, Codable, CaseIterable, Sendable { case solid, dashed, dotted }
    public var color: RGBA
    /// Width, em.
    public var width: Double
    public var dash: Dash
    /// Neon tube along the outline; its colour and thickness come from `color` / `width` when drawn.
    public var neon: TextNeonStyle?
    /// TX-NEON "Tube break": a solid neon outline has one small gap with round ends near its top right, like the bent
    /// glass segments of a real sign. Ignored without `neon` or with dashes.
    public var tubeBreak: Bool

    public init(color: RGBA, width: Double = 0.06, dash: Dash = .solid, neon: TextNeonStyle? = nil, tubeBreak: Bool = true) {
        self.color = color; self.width = width; self.dash = dash; self.neon = neon; self.tubeBreak = tubeBreak
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(color: try c.decodeIfPresent(RGBA.self, forKey: .color) ?? .white)
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? width
        dash = try c.decodeIfPresent(Dash.self, forKey: .dash) ?? dash
        neon = try c.decodeIfPresent(TextNeonStyle.self, forKey: .neon)
        tubeBreak = try c.decodeIfPresent(Bool.self, forKey: .tubeBreak) ?? tubeBreak
    }

    /// Neon defaults of the bubble presets (= the owner's reference sign): glow 0.35 em, intensity 0.8, no flicker.
    public static func neonStyle(glow: Double = 0.35, flicker: TextNeonFlicker = .off) -> TextNeonStyle {
        TextNeonStyle(color: .white, intensity: 0.8, glowSize: glow, thickness: 0.05, flicker: flicker)
    }
}

public struct TextBubbleShadow: Hashable, Codable, Sendable {
    /// soft: 0.08 em straight down, blur 0.2 em · hard: 0.12 em down-right, no blur (comic offset).
    public enum Kind: String, Codable, CaseIterable, Sendable { case soft, hard }
    public var color: RGBA
    public var kind: Kind

    public init(color: RGBA, kind: Kind = .soft) { self.color = color; self.kind = kind }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(color: try c.decodeIfPresent(RGBA.self, forKey: .color) ?? RGBA(0, 0, 0, 0.4))
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? kind
    }

    public var offsetEm: Double { kind == .soft ? 0.08 : 0.12 }
    public var angleDegrees: Double { kind == .soft ? 90 : 45 }
    public var blurEm: Double { kind == .soft ? 0.2 : 0 }
}
