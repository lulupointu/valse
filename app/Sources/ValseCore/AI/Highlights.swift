import Foundation

// Long video to shorts / AI clipper (W10, AI-031, UX_AI §10): transcript sentences → candidate moments of the chosen
// length → score (local LLM picks when available, else the heuristics below) → non-overlapping highlights → the main
// track is rebuilt from them (one undo step).

public enum ClipDuration: String, Codable, Sendable, CaseIterable {
    case auto, upTo15, upTo30, upTo60, over60
    public var nameKey: String { "clipper.duration.\(rawValue)" }
    /// Allowed highlight length (seconds).
    public var range: ClosedRange<Double> {
        switch self {
        case .auto: return 15...60
        case .upTo15: return 5...15
        case .upTo30: return 15...30
        case .upTo60: return 30...60
        case .over60: return 60...180
        }
    }
}

public enum ClipperStyle: String, Codable, Sendable, CaseIterable {
    /// Highlights in source order.
    case chronological
    /// Best moments first.
    case speech
    public var nameKey: String { "clipper.style.\(rawValue)" }
}

public struct Highlight: Hashable, Codable, Sendable, Identifiable {
    public var id: Double { start }
    /// Media seconds.
    public var start: Double
    public var end: Double
    public var text: String
    public var score: Double
    public init(start: Double, end: Double, text: String, score: Double) { self.start = start; self.end = end; self.text = text; self.score = score }
    public var duration: Double { end - start }
    /// First words, for the result list.
    public var title: String {
        let w = text.split(separator: " ")
        return w.prefix(8).joined(separator: " ") + (w.count > 8 ? "…" : "")
    }
}

public enum Highlights {
    public struct Sentence: Hashable, Sendable { public var start: Double, end: Double, text: String }

    /// Sentences from timed words: ends at . ! ? … or a pause > 0.8 s (punctuation-less ASR output).
    public static func sentences(_ words: [TranscriptWord]) -> [Sentence] {
        var out: [Sentence] = []
        var cur: [TranscriptWord] = []
        func flush() {
            guard let f = cur.first, let l = cur.last else { return }
            out.append(Sentence(start: f.start, end: l.end, text: CaptionText.join(cur.map(\.text))))
            cur = []
        }
        for (i, w) in words.enumerated() {
            cur.append(w)
            let endsSentence = w.text.last.map { ".!?…".contains($0) } ?? false
            let pause = i + 1 < words.count ? words[i + 1].start - w.end : 0
            if endsSentence || pause > 0.8 { flush() }
        }
        flush()
        return out
    }

    /// Windows of consecutive sentences whose length fits `range` (start and end on sentence boundaries).
    public static func candidates(_ s: [Sentence], range: ClosedRange<Double>) -> [ClosedRange<Int>] {
        var out: [ClosedRange<Int>] = []
        for i in s.indices {
            var j = i
            while j < s.count {
                let d = s[j].end - s[i].start
                if d > range.upperBound { break }
                if d >= range.lowerBound { out.append(i...j) }
                j += 1
            }
        }
        return out
    }

    static let weakStarts: Set<String> = ["et", "mais", "donc", "alors", "puis", "parce", "and", "but", "so", "because", "then", "or", "ou"]

    /// Heuristic interest score of a window: keyword weight (TF-IDF over the whole transcript), speech density,
    /// complete-thought bonus (ends on punctuation, doesn't start with a conjunction), questions / exclamations /
    /// numbers. Roughly 0…1.
    public static func score(_ w: ClosedRange<Int>, _ s: [Sentence], idf: [String: Double]) -> Double {
        let text = w.map { s[$0].text }.joined(separator: " ")
        let tokens = CaptionText.tokens(text).map(CaptionText.normalize).filter { $0.count >= 4 }
        let dur = max(s[w.upperBound].end - s[w.lowerBound].start, 0.5)
        let kw = tokens.reduce(0) { $0 + (idf[$1] ?? 0) } / Double(max(tokens.count, 1)) / max(idf.values.max() ?? 1, 1e-6)
        let density = min(1, Double(CaptionText.tokens(text).count) / dur / 3)   // ~3 words/s = lively
        var bonus = 0.0
        if let l = s[w.upperBound].text.last, ".!?".contains(l) { bonus += 0.1 }
        if let first = CaptionText.tokens(s[w.lowerBound].text).first.map(CaptionText.normalize), weakStarts.contains(first) { bonus -= 0.15 }
        if text.contains("?") || text.contains("!") { bonus += 0.05 }
        if text.contains(where: \.isNumber) { bonus += 0.05 }
        return 0.6 * kw + 0.3 * density + bonus
    }

    public static func idf(_ s: [Sentence]) -> [String: Double] {
        var df: [String: Int] = [:]
        for x in s { for t in Set(CaptionText.tokens(x.text).map(CaptionText.normalize).filter { $0.count >= 4 }) { df[t, default: 0] += 1 } }
        let n = Double(max(s.count, 1))
        return df.mapValues { log(1 + n / Double($0)) }
    }

    /// How many highlights to keep: ~1 per 2 minutes of speech, 1…10.
    public static func autoCount(_ s: [Sentence]) -> Int {
        guard let f = s.first, let l = s.last else { return 0 }
        return min(10, max(1, Int(((l.end - f.start) / 120).rounded(.up))))
    }

    /// Greedy non-overlapping selection by score (`boost` = indices of windows a language model preferred).
    public static func pick(_ s: [Sentence], duration: ClipDuration, count: Int? = nil, boost: Set<ClosedRange<Int>> = []) -> [Highlight] {
        pick(s, range: duration.range, count: count, boost: boost)
    }

    /// Same with any allowed length range (Home "Long video to shorts" buckets).
    public static func pick(_ s: [Sentence], range: ClosedRange<Double>, count: Int? = nil, boost: Set<ClosedRange<Int>> = []) -> [Highlight] {
        let cands = candidates(s, range: range)
        guard !cands.isEmpty else {
            // short video: one highlight of everything
            guard let f = s.first, let l = s.last else { return [] }
            return [Highlight(start: f.start, end: l.end, text: s.map(\.text).joined(separator: " "), score: 1)]
        }
        let idf = idf(s)
        let scored = cands.map { ($0, score($0, s, idf: idf) + (boost.contains($0) ? 1 : 0)) }.sorted { $0.1 > $1.1 }
        let want = count ?? autoCount(s)
        var used = IndexSet()
        var out: [Highlight] = []
        for (w, sc) in scored where out.count < want {
            if used.intersects(integersIn: w.lowerBound..<(w.upperBound + 1)) { continue }
            used.insert(integersIn: w.lowerBound..<(w.upperBound + 1))
            out.append(Highlight(start: s[w.lowerBound].start, end: s[w.upperBound].end,
                                 text: w.map { s[$0].text }.joined(separator: " "), score: sc))
        }
        return out
    }

    /// Replaces the main track with the highlights of `media` (small handles: 0.15 s before / 0.25 s after each, inside
    /// the media). Keyframes / speed of the old clips go away (CapCut warns about it).
    public static func rebuildMainTrack(_ hs: [Highlight], media: MediaID, style: ClipperStyle, in p: inout Project) throws {
        guard let asset = p.asset(media), let mi = p.timeline.tracks.firstIndex(where: \.isMain) else { throw EditError.mediaNotFound }
        let ordered = style == .chronological ? hs.sorted { $0.start < $1.start } : hs.sorted { $0.score > $1.score }
        var t = Time.zero
        var clips: [Clip] = []
        let total = asset.duration.seconds
        for h in ordered {
            let a = max(0, h.start - 0.15), b = min(total > 0 ? total : h.end + 0.25, h.end + 0.25)
            guard b - a > 0.2 else { continue }
            var c = TimelineOps.makeClip(for: asset, at: t)
            c.sourceStart = Time(a)
            c.duration = Time(b - a)
            clips.append(c)
            t = t + c.duration
        }
        guard !clips.isEmpty else { throw EditError.nothingToDo }
        p.timeline.tracks[mi].clips = clips
    }
}
