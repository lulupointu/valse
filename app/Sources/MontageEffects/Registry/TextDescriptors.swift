import Foundation
import MontageCore

// Descriptors of the text engine's content (W7): per-glyph animations, bubbles, text templates, caption templates.
// Pure Swift (no Core Text / Metal): the engine turns them into pixels, the UI into tiles.

// MARK: - Per-glyph animation

/// Transform of one animation unit (character, word, line or the whole text) relative to its rest pose.
public struct GlyphState: Sendable, Equatable {
    /// Offset in em (y down).
    public var offset: Vec2
    public var scale: Vec2
    /// Degrees, clockwise, around the unit centre.
    public var rotation: Double
    public var opacity: Double
    /// 0…1 mix towards the highlight variant (karaoke style).
    public var highlight: Double
    public init(offset: Vec2 = .zero, scale: Vec2 = .one, rotation: Double = 0, opacity: Double = 1, highlight: Double = 0) {
        self.offset = offset; self.scale = scale; self.rotation = rotation; self.opacity = opacity; self.highlight = highlight
    }
    public static let identity = GlyphState()
    public var isIdentity: Bool { self == .identity }

    /// Composition (applied after `self`, i.e. `o` is the outer transform for offsets/rotation; scales and opacity multiply).
    public func combined(with o: GlyphState) -> GlyphState {
        GlyphState(offset: offset + o.offset, scale: scale * o.scale, rotation: rotation + o.rotation,
                   opacity: opacity * o.opacity, highlight: max(highlight, o.highlight))
    }
}

/// What a per-glyph animation moves.
public enum GlyphUnit: String, Sendable, CaseIterable { case character, word, line, all }

/// In which order units start (stagger).
public enum GlyphOrder: String, Sendable { case forward, backward, center, edges, random }

/// Identity of the unit being animated.
public struct GlyphUnitInfo: Sendable {
    public var index: Int
    public var count: Int
    /// Stable pseudo-random value in 0…1 for this unit (scatter, flicker…).
    public var random: Double
    public init(index: Int, count: Int, random: Double) { self.index = index; self.count = count; self.random = random }
    /// Position of the unit in 0…1 across the text (0 = first).
    public var position: Double { count > 1 ? Double(index) / Double(count - 1) : 0.5 }
}

/// Descriptor-driven per-glyph animation (CapCut text In / Out / Loop presets: typewriter, wave, pop, bounce…).
///
/// `apply(t, unit, &state)` receives the unit's own progress `t` ∈ [0,1]:
/// - In: 0 = hidden / start pose → 1 = rest pose.
/// - Out: 0 = rest pose → 1 = gone.
/// - Loop (combo): one cycle 0 → 1 (repeats), already phase-shifted per unit by `waveSpread`.
/// Units start one after the other: each takes `span` of the animation (1 = all together, small = sequential).
public struct GlyphAnimationSpec: Sendable {
    public var unit: GlyphUnit
    public var order: GlyphOrder
    public var span: Double
    /// Loop only: phase offset across the text, in cycles (1 = one full wave across the text).
    public var waveSpread: Double
    /// How far units can travel outside the text box, em (sizes the render margin).
    public var extent: Double
    public var apply: @Sendable (_ t: Double, _ unit: GlyphUnitInfo, _ state: inout GlyphState) -> Void

    public init(unit: GlyphUnit, order: GlyphOrder = .forward, span: Double = 0.35, waveSpread: Double = 0.6, extent: Double = 1,
                apply: @escaping @Sendable (Double, GlyphUnitInfo, inout GlyphState) -> Void) {
        self.unit = unit; self.order = order; self.span = min(max(span, 0.01), 1); self.waveSpread = waveSpread
        self.extent = extent; self.apply = apply
    }

    /// Rank in 0…1 of a unit in the stagger order.
    public func rank(_ u: GlyphUnitInfo) -> Double {
        let p = u.position
        switch order {
        case .forward: return p
        case .backward: return 1 - p
        case .center: return abs(p - 0.5) * 2
        case .edges: return 1 - abs(p - 0.5) * 2
        case .random: return u.random
        }
    }

    /// Unit progress for overall animation progress `p` (in / out), or loop phase.
    public func unitProgress(_ p: Double, phase: AnimationPhaseKind, unit u: GlyphUnitInfo) -> Double {
        switch phase {
        case .combo:
            let x = p - rank(u) * waveSpread
            return x - floor(x)
        case .in, .out:
            guard u.count > 1, unit != .all else { return min(max(p, 0), 1) }
            let start = rank(u) * (1 - span)
            return min(max((p - start) / span, 0), 1)
        }
    }

    public func state(progress p: Double, phase: AnimationPhaseKind, unit u: GlyphUnitInfo) -> GlyphState {
        var s = GlyphState()
        apply(unitProgress(p, phase: phase, unit: u), u, &s)
        return s
    }
}

/// Stable hash → 0…1 (for `GlyphUnitInfo.random`).
public func glyphRandom(_ i: Int, seed: Int = 0) -> Double {
    var x = UInt64(bitPattern: Int64(i &* 0x9E3779B1 &+ seed &* 0x85EBCA77))
    x ^= x >> 33; x = x &* 0xff51afd7ed558ccd; x ^= x >> 33; x = x &* 0xc4ceb9fe1a85ec53; x ^= x >> 33
    return Double(x % 10_000) / 10_000
}

// MARK: - Shapes (bubbles, template shapes)

/// Tail placement of a speech bubble.
public enum BubbleTail: String, Sendable { case bottomLeft, bottomRight, bottom, left, right, top, none }

/// Vector shape drawn behind / around the text box, sized by the engine to the padded text box (so corner radii stay
/// round on any aspect ratio). Radii and sizes in em.
public enum BubbleShape: Sendable, Equatable {
    case roundedRect(radius: Double)
    case capsule
    case ellipse
    case speech(radius: Double, tail: BubbleTail)
    case thought
    case cloud(bumps: Int)
    case burst(spikes: Int, depth: Double)
    case banner(fold: Double)
    case tag
    case ribbon
    case underlineBar(height: Double)
    case brackets
    case hexagon
    case arrow
}

/// "Text ▸ Bubble" frame (TX-014): a shape auto-sized to the text box.
public struct TextBubbleDescriptor: Sendable, Identifiable {
    public let id: String
    public let nameKey: String
    public let groupKey: String
    public let shape: BubbleShape
    /// Padding between the text and the shape, em.
    public let padding: Vec2
    public let fill: RGBA
    public let stroke: RGBA?
    /// Stroke width, em.
    public let strokeWidth: Double
    /// Text colour that reads well on this bubble (applied when the bubble is picked).
    public let textColor: RGBA
    public init(id: String, nameKey: String, groupKey: String = "bubble.group.basic", shape: BubbleShape,
                padding: Vec2 = Vec2(0.45, 0.3), fill: RGBA, stroke: RGBA? = nil, strokeWidth: Double = 0.06, textColor: RGBA = .black) {
        self.id = id; self.nameKey = nameKey; self.groupKey = groupKey; self.shape = shape; self.padding = padding
        self.fill = fill; self.stroke = stroke; self.strokeWidth = strokeWidth; self.textColor = textColor
    }
}

// MARK: - Text templates

/// One layer of a text template: a text slot or a shape, with its own placement, time window and animations.
public struct TextTemplateLayer: Sendable {
    public enum Kind: Sendable {
        /// Text slot `slot` (0 = the clip's main text), styled from the clip's style by `style`.
        case text(slot: Int, style: @Sendable (inout TextContent) -> Void)
        /// Filled shape of `size` em (x = width, y = height).
        case shape(BubbleShape, size: Vec2, color: RGBA)
    }
    public var kind: Kind
    /// Centre offset from the template centre, em of the clip font size.
    public var offset: Vec2
    public var rotation: Double
    public var scale: Double
    /// Visible window as fractions of the clip duration.
    public var start: Double
    public var end: Double
    /// Animation ids (`Registries.animations`) with durations in seconds.
    public var inAnim: (id: String, duration: Double)?
    public var outAnim: (id: String, duration: Double)?
    public var loopAnim: (id: String, period: Double)?
    /// Shapes only: grow the width to fit text slot `fitSlot` plus `fitPadding` em on each side (lower thirds, pills).
    public var fitSlot: Int?
    public var fitPadding: Double

    public init(_ kind: Kind, offset: Vec2 = .zero, rotation: Double = 0, scale: Double = 1, start: Double = 0, end: Double = 1,
                inAnim: (id: String, duration: Double)? = nil, outAnim: (id: String, duration: Double)? = nil,
                loopAnim: (id: String, period: Double)? = nil, fitSlot: Int? = nil, fitPadding: Double = 0.6) {
        self.kind = kind; self.offset = offset; self.rotation = rotation; self.scale = scale; self.start = start; self.end = end
        self.inAnim = inAnim; self.outAnim = outAnim; self.loopAnim = loopAnim; self.fitSlot = fitSlot; self.fitPadding = fitPadding
    }

    public var slot: Int? { if case .text(let s, _) = kind { return s }; return nil }
}

/// "Text template": designed, animated multi-layer title with editable text slots (TX-013/041).
public struct TextTemplateDescriptor: Sendable, Identifiable {
    public let id: String
    public let nameKey: String
    public let groupKey: String
    /// Localization keys of the default text of each slot.
    public let slotKeys: [String]
    public let defaultDuration: Time
    /// Base style applied to the clip when the template is added (font size, colour…).
    public let base: @Sendable (inout TextContent) -> Void
    public let layers: [TextTemplateLayer]
    public init(id: String, nameKey: String, groupKey: String, slotKeys: [String], defaultDuration: Time = Time(4),
                base: @escaping @Sendable (inout TextContent) -> Void = { _ in }, layers: [TextTemplateLayer]) {
        self.id = id; self.nameKey = nameKey; self.groupKey = groupKey; self.slotKeys = slotKeys
        self.defaultDuration = defaultDuration; self.base = base; self.layers = layers
    }

    /// New text content instantiating this template with the localized default texts.
    public func makeContent() -> TextContent {
        var t = TextContent(string: slotKeys.first.map { tr($0) } ?? "")
        base(&t)
        t.template = TextTemplateInstance(templateID: id, texts: slotKeys.dropFirst().map { tr($0) })
        return t
    }

    /// Text of slot `i` for an instance (slot 0 = the clip string).
    public static func text(slot i: Int, of t: TextContent, descriptor d: TextTemplateDescriptor?) -> String {
        if i == 0 { return t.string }
        if let x = t.template?.texts, i - 1 < x.count { return x[i - 1] }
        if let d, i < d.slotKeys.count { return tr(d.slotKeys[i]) }
        return ""
    }
}

// MARK: - Caption templates

/// "Caption templates": styled + karaoke-animated looks applied to all captions (TX-021/026).
public struct CaptionTemplateDescriptor: Sendable, Identifiable {
    public let id: String
    public let nameKey: String
    public let groupKey: String
    /// Writes the look (style + karaoke) onto a caption's text; text and timings are kept by the caller.
    public let apply: @Sendable (inout TextContent) -> Void
    /// Optional in / out animation ids.
    public let inAnim: String?
    public let outAnim: String?
    public init(id: String, nameKey: String, groupKey: String = "captionTemplate.group.karaoke", inAnim: String? = nil,
                outAnim: String? = nil, apply: @escaping @Sendable (inout TextContent) -> Void) {
        self.id = id; self.nameKey = nameKey; self.groupKey = groupKey; self.apply = apply; self.inAnim = inAnim; self.outAnim = outAnim
    }
}

/// Text style kinds: the Basic tab's preset row vs the word-art "Text effects" library.
public enum TextStyleKind: String, Sendable { case preset, effect }
