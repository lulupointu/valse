import Foundation

// Speech → captions (W10 AI). Recognised words (media time) become the text team's `CaptionSegment`s (timeline
// seconds + word timings), added with `CaptionOps.addCaptionTrack` so captions use W7's model (`TextContent.caption`,
// karaoke, bilingual, editor). Nothing here owns caption storage.

/// How recognised words become captions (CapCut: one caption ≤ 2 lines, split on pauses and sentence ends).
public struct CaptionSettings: Hashable, Codable, Sendable {
    public var maxCharsPerLine: Int
    public var maxLines: Int
    /// A pause longer than this starts a new caption (seconds).
    public var maxPause: Double
    /// Longest caption on screen (seconds).
    public var maxDuration: Double
    /// Tag filler words / hesitations / repetitions ("Identify filler words").
    public var identifyFillers: Bool
    /// Drop filler words from the caption text ("Remove filler words").
    public var removeFillers: Bool
    public init(maxCharsPerLine: Int = 28, maxLines: Int = 2, maxPause: Double = 0.6, maxDuration: Double = 6,
                identifyFillers: Bool = false, removeFillers: Bool = false) {
        self.maxCharsPerLine = maxCharsPerLine; self.maxLines = maxLines; self.maxPause = maxPause
        self.maxDuration = maxDuration; self.identifyFillers = identifyFillers; self.removeFillers = removeFillers
    }
}

/// One caption before placement (media time).
public struct SpeechSegment: Hashable, Sendable {
    public var words: [TranscriptWord]
    public var fillers: [FillerWords.Kind?]
    public var lines: [String]
    public var start: Double { words.first?.start ?? 0 }
    public var end: Double { words.last?.end ?? 0 }
    public var text: String { lines.joined(separator: "\n") }
}

/// Word joining / tokenising for recognised text (no space before , . … ; none after an apostrophe).
public enum CaptionText {
    public static func join(_ words: [String]) -> String {
        var out = ""
        for w in words {
            let t = w.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            if out.isEmpty || out.hasSuffix("'") || out.hasSuffix("’") || [",", ".", "…", ")", "%", "-"].contains(where: { t.hasPrefix($0) }) {
                out += t
            } else {
                out += " " + t
            }
        }
        return out
    }

    public static func tokens(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
    }

    /// Lower-case word without punctuation (comparisons).
    public static func normalize(_ s: String) -> String {
        let lowered = s.lowercased().replacingOccurrences(of: "’", with: "'")
        return String(lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "'" }.map(Character.init))
    }
}

public enum SpeechSegmenter {
    /// New caption after a sentence end, a pause > `maxPause`, when the text exceeds `maxLines × maxCharsPerLine`, or
    /// when it would last longer than `maxDuration`.
    public static func segments(_ words: [TranscriptWord], language: String, settings: CaptionSettings = CaptionSettings()) -> [SpeechSegment] {
        let kinds = settings.identifyFillers || settings.removeFillers
            ? FillerWords.classify(words.map(\.text), language: language) : Array(repeating: nil, count: words.count)
        var out: [SpeechSegment] = []
        var cur: [TranscriptWord] = [], curKinds: [FillerWords.Kind?] = []
        let capacity = settings.maxCharsPerLine * max(settings.maxLines, 1)
        func flush() {
            guard !cur.isEmpty else { return }
            let shown = settings.removeFillers ? zip(cur, curKinds).filter { $0.1 == nil }.map(\.0.text) : cur.map(\.text)
            if !shown.isEmpty {
                out.append(SpeechSegment(words: cur, fillers: curKinds, lines: wrap(shown, maxChars: settings.maxCharsPerLine, maxLines: settings.maxLines)))
            }
            cur = []; curKinds = []
        }
        for (i, w) in words.enumerated() {
            let t = w.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            if let last = cur.last, let first = cur.first {
                let len = CaptionText.join(cur.map(\.text) + [t]).count
                let sentenceEnd = last.text.last.map { ".?!…".contains($0) } ?? false
                if sentenceEnd || w.start - last.end > settings.maxPause || len > capacity || w.end - first.start > settings.maxDuration { flush() }
            }
            cur.append(w); curKinds.append(kinds[i])
        }
        flush()
        return out
    }

    /// At most `maxLines` (2) lines, balancing their lengths.
    public static func wrap(_ words: [String], maxChars: Int, maxLines: Int = 2) -> [String] {
        let full = CaptionText.join(words)
        guard full.count > maxChars, maxLines > 1, words.count > 1 else { return [full] }
        var best = 1, bestLen = Int.max
        for k in 1..<words.count {
            let a = CaptionText.join(Array(words[..<k])).count, b = CaptionText.join(Array(words[k...])).count
            if max(a, b) < bestLen { bestLen = max(a, b); best = k }
        }
        return [CaptionText.join(Array(words[..<best])), CaptionText.join(Array(words[best...]))]
    }
}

extension Clip {
    /// Timeline time at which this media clip shows media time `s` (inverse time remap, incl. speed curves and
    /// reverse). nil when `s` is outside the clip's source range.
    public func timelineTime(forSource s: Time) -> Time? {
        let r = sourceRange
        guard s >= r.start, s <= r.end else { return nil }
        var lo = start, hi = end
        for _ in 0..<48 {
            let mid = Time(ticks: (lo.ticks + hi.ticks) / 2)
            let v = sourceTime(at: mid)
            if (v < s) != reversed { lo = mid } else { hi = mid }
            if hi.ticks - lo.ticks <= 1 { break }
        }
        return lo
    }
}

/// Builds text-team `CaptionSegment`s from transcripts and finishes the caption track (fillers, linkage).
public enum SpeechCaptions {
    /// Caption segments (timeline seconds, with word timings) for `transcript` as shown by `mediaClip`.
    public static func segments(_ transcript: Transcript, for mediaClip: Clip, settings: CaptionSettings = CaptionSettings()) -> [CaptionSegment] {
        let range = mediaClip.sourceRange
        let words = transcript.words.filter { w in
            let mid = (w.start + w.end) / 2
            return mid >= range.start.seconds && mid <= range.end.seconds
        }
        func tl(_ s: Double) -> Double? { mediaClip.timelineTime(forSource: Time(s).clamped(range.start, range.end))?.seconds }
        var out: [CaptionSegment] = []
        for seg in SpeechSegmenter.segments(words, language: transcript.language, settings: settings) {
            guard let a0 = tl(seg.start), let b0 = tl(seg.end) else { continue }
            var ws: [(text: String, start: Double, end: Double)] = []
            for (w, kind) in zip(seg.words, seg.fillers) {
                if settings.removeFillers && kind != nil { continue }
                guard let s0 = tl(w.start), let e0 = tl(w.end) else { continue }
                ws.append((w.text, min(s0, e0), max(s0, e0)))
            }
            // the caption text is what the words spell (two lines), so word timings stay aligned with tokens
            out.append(CaptionSegment(text: seg.text, start: min(a0, b0), end: max(max(a0, b0), min(a0, b0) + 0.3), words: ws))
        }
        return out
    }

    /// After `CaptionOps.addCaptionTrack`: flags filler words (`CaptionWord.filler`) and links captions to the main-track
    /// clip under them (CapCut: captions follow their source clips).
    public static func finish(trackID: TrackID, language: String, in project: inout Project, identifyFillers: Bool) {
        guard let ti = project.timeline.trackIndex(trackID) else { return }
        let main = project.timeline.mainTrack
        for i in project.timeline.tracks[ti].clips.indices {
            var c = project.timeline.tracks[ti].clips[i]
            guard case .text(var t) = c.content, var data = t.caption else { continue }
            if identifyFillers {
                let kinds = FillerWords.classify(data.words.map(\.text), language: language)
                for k in data.words.indices where kinds[k] != nil { data.words[k].filler = true }
                t.caption = data
                c.content = .text(t)
            }
            if project.timeline.linkage, let m = main?.clips.first(where: { $0.range.contains(c.start) }) { c.linkedTo = m.id }
            project.timeline.tracks[ti].clips[i] = c
        }
    }

    /// Caption clips of every caption track (timeline order).
    public static func captions(in tl: Timeline) -> [Clip] {
        tl.tracks.filter(CaptionOps.isCaptionTrack).flatMap(\.clips).filter(CaptionOps.isCaption).sorted { $0.start < $1.start }
    }

    /// Bilingual captions (AI-003): stores translated text per caption clip and the display mode.
    public static func setTranslations(_ map: [ClipID: String], display: BilingualDisplay, in tl: inout Timeline) {
        for (id, text) in map {
            guard var c = tl.clip(id), case .text(var t) = c.content, t.caption != nil else { continue }
            t.caption?.translation = text
            t.caption?.display = display
            c.content = .text(t)
            tl[clip: id] = c
        }
    }

    public static func clearTranslations(in tl: inout Timeline) {
        for c0 in captions(in: tl) {
            guard var c = tl.clip(c0.id), case .text(var t) = c.content else { continue }
            t.caption?.translation = nil; t.caption?.display = nil
            c.content = .text(t)
            tl[clip: c.id] = c
        }
    }

    /// Flags keyword words (normalised match) on every caption; returns how many words were flagged.
    @discardableResult
    public static func markKeywords(_ keywords: Set<String>, in tl: inout Timeline) -> Int {
        let keys = Set(keywords.map(CaptionText.normalize))
        var n = 0
        for c0 in captions(in: tl) {
            guard var c = tl.clip(c0.id), case .text(var t) = c.content, t.caption != nil else { continue }
            var ws = CaptionOps.words(of: c)
            for k in ws.indices {
                let hit = keys.contains(CaptionText.normalize(ws[k].text))
                ws[k].keyword = hit ? true : nil
                if hit { n += 1 }
            }
            t.caption?.words = ws
            c.content = .text(t)
            tl[clip: c.id] = c
        }
        return n
    }
}
