import Foundation

/// TX-BUBBLE2 bubble ↔ text pairing: the text "look" fields a bubble pick sets (colour and effects, plus font, case,
/// letter spacing and the word-art id). Words, size, alignment, box, line spacing, orientation, path, runs, captions,
/// karaoke and templates are never part of it. `TextContent.bubblePriorLook` stores the look from before the first
/// bubble so None can bring it back.
public struct TextLook: Hashable, Codable, Sendable {
    public var color: RGBA
    public var bold: Bool
    public var italic: Bool
    public var strokeColor: RGBA
    public var strokeWidth: Double
    public var strokePosition: TextStrokePosition
    public var extraStrokes: [TextStrokeLayer]
    public var shadowColor: RGBA
    public var shadow: TextShadowStyle
    public var glow: TextGlowStyle?
    public var neon: TextNeonStyle?
    public var fill: TextFill?
    public var backgroundColor: RGBA
    public var styleID: String?
    public var fontName: String
    public var textCase: TextCase
    public var letterSpacing: Double

    public init(_ t: TextContent) {
        color = t.color; bold = t.bold; italic = t.italic
        strokeColor = t.strokeColor; strokeWidth = t.strokeWidth; strokePosition = t.strokePosition; extraStrokes = t.extraStrokes
        shadowColor = t.shadowColor; shadow = t.shadow; glow = t.glow; neon = t.neon; fill = t.fill
        backgroundColor = t.backgroundColor; styleID = t.styleID
        fontName = t.fontName; textCase = t.textCase; letterSpacing = t.letterSpacing
    }

    /// Plain look (white, no effects) with the given typography: what None falls back to without a snapshot.
    public static func plain(fontName: String = "", textCase: TextCase = .none, letterSpacing: Double = 0) -> TextLook {
        var t = TextContent(string: "")
        t.fontName = fontName; t.textCase = textCase; t.letterSpacing = letterSpacing
        return TextLook(t)
    }

    /// One look field: how to read / write it, and whether it is "typography" (font, case, spacing: kept when the user
    /// chose it explicitly) rather than colour / effects.
    public struct Field: Sendable {
        public let typography: Bool
        let equal: @Sendable (TextLook, TextLook) -> Bool
        let copy: @Sendable (inout TextLook, TextLook) -> Void
        /// Equal in this field.
        public func same(_ a: TextLook, _ b: TextLook) -> Bool { equal(a, b) }
        /// Copies this field of `from` into `to`.
        public func take(_ to: inout TextLook, from: TextLook) { copy(&to, from) }
    }

    static func f<V: Equatable & Sendable>(_ kp: WritableKeyPath<TextLook, V> & Sendable, typography: Bool = false) -> Field {
        Field(typography: typography, equal: { $0[keyPath: kp] == $1[keyPath: kp] }, copy: { $0[keyPath: kp] = $1[keyPath: kp] })
    }

    public static let fields: [Field] = [
        f(\.color), f(\.bold), f(\.italic), f(\.strokeColor), f(\.strokeWidth), f(\.strokePosition), f(\.extraStrokes),
        f(\.shadowColor), f(\.shadow), f(\.glow), f(\.neon), f(\.fill), f(\.backgroundColor), f(\.styleID),
        f(\.fontName, typography: true), f(\.textCase, typography: true), f(\.letterSpacing, typography: true),
    ]
}

/// Heap box of a `TextLook` (encoded as the look itself): keeps `TextContent` — stored inline in every `Clip` — from
/// growing by a whole second look (an inline `TextLook?` field crashed in `Clip?` copies in debug builds).
public struct TextLookBox: Hashable, Codable, Sendable {
    final class Storage: Sendable { let value: TextLook; init(_ v: TextLook) { value = v } }
    let storage: Storage
    public var value: TextLook { storage.value }
    public init(_ v: TextLook) { storage = Storage(v) }
    public init(from decoder: any Decoder) throws { self.init(try TextLook(from: decoder)) }
    public func encode(to encoder: any Encoder) throws { try value.encode(to: encoder) }
    public static func == (a: TextLookBox, b: TextLookBox) -> Bool { a.storage === b.storage || a.value == b.value }
    public func hash(into h: inout Hasher) { value.hash(into: &h) }
}

extension TextContent {
    /// TX-BUBBLE2 pairing: the text look from before the first bubble pick (None restores it); nil = no bubble, or one
    /// set before pairing existed.
    public var bubblePriorLook: TextLook? {
        get { bubblePrior?.value }
        set { bubblePrior = newValue.map(TextLookBox.init) }
    }

    /// The clip's current look fields.
    public var look: TextLook {
        get { TextLook(self) }
        set {
            color = newValue.color; bold = newValue.bold; italic = newValue.italic
            strokeColor = newValue.strokeColor; strokeWidth = newValue.strokeWidth; strokePosition = newValue.strokePosition
            extraStrokes = newValue.extraStrokes; shadowColor = newValue.shadowColor; shadow = newValue.shadow
            glow = newValue.glow; neon = newValue.neon; fill = newValue.fill; backgroundColor = newValue.backgroundColor
            styleID = newValue.styleID; fontName = newValue.fontName; textCase = newValue.textCase
            letterSpacing = newValue.letterSpacing
        }
    }
}
