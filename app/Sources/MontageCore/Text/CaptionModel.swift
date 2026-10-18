import Foundation

/// One recognised / imported word of a caption.
///
/// Times are **content time** of the text clip: clip-local time + `clip.sourceStart`. Text clips keep `sourceStart`
/// consistent through head trims and splits (TimelineOps), so word timings stay attached to the audio they came from.
/// `FrameEvaluator` converts them to clip-local time before rendering.
public struct CaptionWord: Hashable, Codable, Sendable {
    public var text: String
    public var start: Time
    public var end: Time
    /// Emphasised word (CapCut "Highlight keywords"): rendered with the karaoke keyword style.
    public var keyword: Bool?
    /// Filler word ("um", "euh") identified by speech recognition.
    public var filler: Bool?
    public init(_ text: String, start: Time, end: Time, keyword: Bool? = nil, filler: Bool? = nil) {
        self.text = text; self.start = start; self.end = end; self.keyword = keyword; self.filler = filler
    }
    public var isKeyword: Bool { keyword ?? false }
}

/// How a caption with a translation shows (CapCut "Bilingual" / "Translation only").
public enum BilingualDisplay: String, Codable, Sendable, CaseIterable { case both, translationOnly }

/// Where a caption came from (auto captions are the only ones AI emojis / regenerate apply to).
public enum CaptionOrigin: String, Codable, Sendable { case auto, imported, script, manual, lyrics }

/// Style of the translated ("sub") line of a bilingual caption, relative to the main caption.
public struct CaptionSubStyle: Hashable, Codable, Sendable {
    public var color: RGBA
    /// Multiplier on the main font size.
    public var fontScale: Double
    public var fontName: String?
    public var strokeColor: RGBA?
    public var strokeWidth: Double?
    /// Gap between main and sub line, em of the main font.
    public var gap: Double
    public init(color: RGBA = RGBA(1, 0.86, 0.2), fontScale: Double = 0.75, fontName: String? = nil, strokeColor: RGBA? = nil,
                strokeWidth: Double? = nil, gap: Double = 0.15) {
        self.color = color; self.fontScale = fontScale; self.fontName = fontName; self.strokeColor = strokeColor
        self.strokeWidth = strokeWidth; self.gap = gap
    }
}

/// Caption payload of a text clip. A *caption track* is a text track whose clips carry `CaptionData`.
public struct CaptionData: Hashable, Codable, Sendable {
    public var words: [CaptionWord]
    public var translation: String?
    public var display: BilingualDisplay?
    public var subStyle: CaptionSubStyle?
    public var speaker: String?
    public var origin: CaptionOrigin
    public init(words: [CaptionWord] = [], translation: String? = nil, display: BilingualDisplay? = nil,
                subStyle: CaptionSubStyle? = nil, speaker: String? = nil, origin: CaptionOrigin = .manual) {
        self.words = words; self.translation = translation; self.display = display; self.subStyle = subStyle
        self.speaker = speaker; self.origin = origin
    }
}

/// What the karaoke styling does with the word timings (CapCut caption templates: spoken / unspoken word states).
public enum KaraokeMode: String, Codable, Sendable, CaseIterable {
    /// Only the word being spoken takes the highlight style.
    case highlightWord
    /// Words already spoken (and the current one) take the highlight style; unspoken ones dim.
    case fillSpoken
    /// Unspoken words are hidden; each word pops in when spoken.
    case reveal
    /// Word by word: only the current word is shown, centred (CapCut arrangement "Word by word").
    case singleWord
}

/// Word-timed caption styling (TX-021). Highlight colours replace the fill/stroke of highlighted words.
public struct KaraokeStyle: Hashable, Codable, Sendable {
    public var mode: KaraokeMode
    public var highlightColor: RGBA
    public var highlightStroke: RGBA?
    /// Scale of the active word (1 = none).
    public var highlightScale: Double
    /// Rounded box behind the active word (nil = none).
    public var boxColor: RGBA?
    /// Opacity of words not spoken yet (CapCut "Unspoken captions ▸ Opacity").
    public var unspokenOpacity: Double
    /// Upward bounce of a word when it starts, em.
    public var bounce: Double
    /// Keyword (emphasis) colour and scale.
    public var keywordColor: RGBA?
    public var keywordScale: Double
    public init(mode: KaraokeMode = .highlightWord, highlightColor: RGBA = RGBA(hex: 0xFFE14D), highlightStroke: RGBA? = nil,
                highlightScale: Double = 1.1, boxColor: RGBA? = nil, unspokenOpacity: Double = 1, bounce: Double = 0,
                keywordColor: RGBA? = RGBA(hex: 0x4DE1FF), keywordScale: Double = 1.15) {
        self.mode = mode; self.highlightColor = highlightColor; self.highlightStroke = highlightStroke
        self.highlightScale = highlightScale; self.boxColor = boxColor; self.unspokenOpacity = unspokenOpacity
        self.bounce = bounce; self.keywordColor = keywordColor; self.keywordScale = keywordScale
    }
}

/// A caption produced by speech recognition, a subtitle file or a script — the hand-off format between the AI team
/// (auto captions, lyrics, translation) and the text engine. Times are timeline seconds.
public struct CaptionSegment: Hashable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    /// Optional word timings (timeline seconds). Missing → words are spread evenly when needed.
    public var words: [(text: String, start: Double, end: Double)]
    public var translation: String?
    public var speaker: String?
    public init(text: String, start: Double, end: Double, words: [(text: String, start: Double, end: Double)] = [],
                translation: String? = nil, speaker: String? = nil) {
        self.text = text; self.start = start; self.end = end; self.words = words; self.translation = translation; self.speaker = speaker
    }
    public static func == (a: CaptionSegment, b: CaptionSegment) -> Bool {
        a.text == b.text && a.start == b.start && a.end == b.end && a.translation == b.translation && a.speaker == b.speaker
            && a.words.count == b.words.count && zip(a.words, b.words).allSatisfy { $0.text == $1.text && $0.start == $1.start && $0.end == $1.end }
    }
    public func hash(into h: inout Hasher) { h.combine(text); h.combine(start); h.combine(end) }
}
