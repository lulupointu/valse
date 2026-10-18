import Foundation

/// A recognised word in **media time** (seconds from the start of the media file).
public struct TranscriptWord: Hashable, Codable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    /// 0…1 when the engine reports it.
    public var confidence: Double?
    public init(text: String, start: Double, end: Double, confidence: Double? = nil) {
        self.text = text; self.start = start; self.end = end; self.confidence = confidence
    }
}

/// Speech-to-text result for one media range (cached per media content hash by MontageAI's `TranscriptStore`).
public struct Transcript: Hashable, Codable, Sendable {
    /// Engine id ("whisper.cpp", "SpeechTranscriber", "DictationTranscriber", "SFSpeechRecognizer").
    public var engine: String
    /// BCP-47 language actually used / detected ("fr", "en").
    public var language: String
    public var words: [TranscriptWord]
    public init(engine: String, language: String, words: [TranscriptWord]) {
        self.engine = engine; self.language = language; self.words = words
    }
    public var text: String { CaptionText.join(words.map(\.text)) }

    /// Words shifted by `offset` seconds (transcribing an excerpt that starts at `offset` in the media).
    public func shifted(by offset: Double) -> Transcript {
        var t = self
        t.words = words.map { TranscriptWord(text: $0.text, start: $0.start + offset, end: $0.end + offset, confidence: $0.confidence) }
        return t
    }
}

/// Word error rate (Levenshtein over normalised words), used to verify recognition quality against a reference.
public enum WordErrorRate {
    public static func words(_ s: String) -> [String] {
        // numbers are compared as written words in references, keep tokens as-is after normalisation
        s.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: { $0.isWhitespace || $0 == "'" }).map { CaptionText.normalize(String($0)) }.filter { !$0.isEmpty }
    }

    /// (substitutions + deletions + insertions) / reference word count.
    public static func compute(reference: String, hypothesis: String) -> Double {
        let r = words(reference), h = words(hypothesis)
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        var prev = Array(0...h.count), cur = [Int](repeating: 0, count: h.count + 1)
        for i in 1...r.count {
            cur[0] = i
            for j in stride(from: 1, through: h.count, by: 1) {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return Double(prev[h.count]) / Double(r.count)
    }
}

/// Filler words / hesitations (CapCut "Identify filler words": Filler, Hesitation, Repetition), FR + EN.
public enum FillerWords {
    public enum Kind: String, Sendable, Codable { case hesitation, filler, repetition }

    static let hesitations: Set<String> = ["euh", "euhm", "heu", "hum", "hmm", "hm", "mmh", "mh", "bah", "beh", "ben",
                                           "um", "umm", "uh", "uhh", "uhm", "erm", "er", "ah", "eh", "mhm"]
    static let fillersFR: Set<String> = ["hein", "genre", "voilà"]
    static let fillersEN: Set<String> = ["like", "basically", "actually"]
    /// Words that legitimately repeat ("nous nous sommes", "that that", "had had").
    static let legitDoubles: Set<String> = ["nous", "vous", "that", "had"]
    static let bigramsFR: Set<String> = ["du coup", "en fait", "tu vois", "vous voyez", "en gros"]
    static let bigramsEN: Set<String> = ["you know", "i mean", "kind of", "sort of"]

    /// Classifies every word (nil = not a filler). Multi-word fillers mark all their words; a word repeated right
    /// after itself ("le le") marks the first occurrence as a repetition. Context fillers ("like", "genre") are only
    /// flagged when isolated by pauses or punctuation, to avoid false positives.
    public static func classify(_ words: [String], language: String) -> [Kind?] {
        let n = words.map { CaptionText.normalize($0) }
        let fr = language.hasPrefix("fr")
        var out = [Kind?](repeating: nil, count: words.count)
        for i in n.indices {
            if hesitations.contains(n[i]) { out[i] = .hesitation; continue }
            if i + 1 < n.count, !n[i].isEmpty, n[i] == n[i + 1], !legitDoubles.contains(n[i]) { out[i] = .repetition; continue }
            let ctx = fr ? fillersFR : fillersEN
            if ctx.contains(n[i]) {
                let raw = words[i]
                let isolated = raw.hasSuffix(",") || (i > 0 && words[i - 1].hasSuffix(","))
                if isolated { out[i] = .filler }
            }
        }
        let bigrams = fr ? bigramsFR : bigramsEN
        for i in n.indices.dropLast() where out[i] == nil && out[i + 1] == nil {
            if bigrams.contains("\(n[i]) \(n[i + 1])"), words[i + 1].hasSuffix(",") || (i > 0 && words[i - 1].hasSuffix(",")) {
                out[i] = .filler; out[i + 1] = .filler
            }
        }
        return out
    }
}
