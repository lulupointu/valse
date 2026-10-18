import Foundation

// Caption model (W10 AI, agreed with W7 text via docs/STATUS.md). A caption is an ordinary text clip
// (`ClipContent.text`) carrying `Clip.caption`: the word-level timing from speech recognition, the spoken language and an
// optional translation (bilingual captions). The text team renders `TextContent` as usual and can use `words` for
// karaoke / word-by-word templates (TX-021) and `translation` for main/sub caption styles (TX-023).
// All fields are optional/defaulted, so old project files decode unchanged (no schema bump).

/// One recognised word. Times are **clip-local** (0 = the caption clip's start), like keyframes.
public struct CaptionWord: Hashable, Codable, Sendable {
    public var text: String
    public var start: Time
    public var end: Time
    /// Filler / hesitation ("euh", "um", repeated word) — CapCut "Identify filler words".
    public var isFiller: Bool?
    /// Highlighted keyword (CapCut "Highlight keywords").
    public var isKeyword: Bool?
    public init(text: String, start: Time, end: Time, isFiller: Bool? = nil, isKeyword: Bool? = nil) {
        self.text = text; self.start = start; self.end = end; self.isFiller = isFiller; self.isKeyword = isKeyword
    }
    public var filler: Bool { isFiller ?? false }
    public var keyword: Bool { isKeyword ?? false }
}

/// Where a caption came from.
public enum CaptionSource: String, Codable, Sendable {
    /// Auto captions (speech recognition).
    case auto
    /// Auto lyrics (speech recognition on music).
    case lyrics
    /// Local captions (SRT/VTT/LRC/ASS import).
    case imported
    /// Script → captions (typed text split into captions).
    case script
}

/// Bilingual display (CapCut "Bilingual / Translation only").
public enum CaptionDisplay: String, Codable, Sendable, CaseIterable {
    case original, bilingual, translationOnly
    public var nameKey: String { "captions.display.\(rawValue)" }
}

/// Caption metadata of a text clip. `nil` on ordinary text clips.
public struct CaptionInfo: Hashable, Codable, Sendable {
    public var source: CaptionSource
    /// Word timing (clip-local), in reading order. May be empty (imported captions).
    public var words: [CaptionWord]
    /// BCP-47 code of the spoken language ("fr", "en"…).
    public var language: String?
    /// Translated text (bilingual captions); nil = not translated.
    public var translation: String?
    public var translationLanguage: String?
    public var display: CaptionDisplay?
    /// Media clip the caption was transcribed from (also set as `Clip.linkedTo` when it is on the main track).
    public var sourceClip: ClipID?
    /// Recognition engine ("whisper.cpp", "SpeechTranscriber"…), for diagnostics.
    public var engine: String?
    /// Main (spoken-language) caption text while a bilingual / translation-only display is active (then
    /// `TextContent.string` holds the displayed text). nil when `display` is original: `TextContent.string` is the
    /// main text. Use `CaptionOps.mainText(_:)` instead of reading this directly.
    public var original: String?

    public init(source: CaptionSource, words: [CaptionWord] = [], language: String? = nil, translation: String? = nil,
                translationLanguage: String? = nil, display: CaptionDisplay? = nil, sourceClip: ClipID? = nil, engine: String? = nil) {
        self.source = source; self.words = words; self.language = language; self.translation = translation
        self.translationLanguage = translationLanguage; self.display = display; self.sourceClip = sourceClip; self.engine = engine
    }

    public var effectiveDisplay: CaptionDisplay { translation == nil ? .original : (display ?? .original) }

    /// Spoken text (words joined, language-aware spacing).
    public var spokenText: String { CaptionText.join(words.map(\.text)) }

    /// Words inside [from, to) of clip-local time, shifted so `from` becomes 0.
    public func slice(from: Time, to: Time) -> CaptionInfo {
        var c = self
        c.words = words.filter { w in
            let mid = Time(ticks: (w.start.ticks + w.end.ticks) / 2)
            return mid >= from && mid < to
        }.map { w in
            var w = w
            w.start = max(w.start - from, .zero); w.end = max(w.end - from, w.start)
            return w
        }
        c.translation = nil
        return c
    }

    /// Shifts every word (e.g. after a head trim).
    public mutating func shift(by d: Time) {
        for i in words.indices { words[i].start += d; words[i].end += d }
    }
}

/// Word joining / tokenising shared by caption building and editing (French typography: spaces before ? ! : ;
/// are kept as typed by the recogniser; we only avoid spaces before , . and after an apostrophe).
public enum CaptionText {
    public static func join(_ words: [String]) -> String {
        var out = ""
        for w in words {
            let t = w.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            if out.isEmpty || out.hasSuffix("'") || out.hasSuffix("’")
                || [",", ".", "…", ")", "%", "-"].contains(where: { t.hasPrefix($0) }) {
                out += t
            } else {
                out += " " + t
            }
        }
        return out
    }

    /// Splits typed text into words (whitespace; keeps punctuation attached).
    public static func tokens(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
    }

    /// Normalised word for comparisons (lower-case, no punctuation/diacritic differences in apostrophes).
    public static func normalize(_ s: String) -> String {
        let lowered = s.lowercased().replacingOccurrences(of: "’", with: "'")
        return String(lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "'" }.map(Character.init))
    }
}

extension Clip {
    /// The clip is a caption (text clip with caption metadata).
    public var isCaption: Bool { caption != nil }
}

extension Track {
    /// A text track holding captions (CapCut "caption track").
    public var isCaptionTrack: Bool { kind == .text && !clips.isEmpty && clips.allSatisfy(\.isCaption) }
}
