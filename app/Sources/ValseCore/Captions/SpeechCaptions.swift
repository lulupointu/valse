import Foundation

// Speech → captions (W10 AI). Recognised words (media time) become the text team's `CaptionSegment`s (timeline
// seconds + word timings), added with `CaptionOps.addCaptionTrack` so captions use W7's model (`TextContent.caption`,
// karaoke, bilingual, editor). Nothing here owns caption storage.

/// How recognised words become captions (CapCut: one caption ≤ 2 lines, ~1–3 s, split on sentence ends, pauses and
/// punctuation).
public struct CaptionSettings: Hashable, Codable, Sendable {
    /// Characters per line (the generator lowers it to what fits the canvas, `CaptionLayout.maxCharsPerLine`).
    public var maxCharsPerLine: Int
    public var maxLines: Int
    /// A pause longer than this starts a new caption (seconds). Shorter pauses between captions are bridged (the
    /// caption stays up until the next one) so captions don't flicker.
    public var maxPause: Double
    /// Longest caption on screen (seconds).
    public var maxDuration: Double
    /// Leave filler words out of the caption text (EditPilot captions).
    public var removeFillers: Bool
    public init(maxCharsPerLine: Int = 28, maxLines: Int = 2, maxPause: Double = 0.5, maxDuration: Double = 3.2,
                removeFillers: Bool = false) {
        self.maxCharsPerLine = maxCharsPerLine; self.maxLines = maxLines; self.maxPause = maxPause
        self.maxDuration = maxDuration; self.removeFillers = removeFillers
    }
    /// How long a caption stays after its last word when silence follows (seconds).
    public static let tail = 0.2
    /// Shortest caption on screen when the next one leaves room (seconds).
    public static let minDuration = 0.6
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
    /// Words a caption (or a line) should not end on: articles, prepositions, conjunctions, clitics (fr + en).
    static let weakEnd: Set<String> = Set("""
    le la les l' un une des du de d' au aux à et ou mais donc car ni que qu' qui ce cet cette ces mon ma mes ton ta tes son sa \
    ses notre nos votre vos leur leurs je j' tu il elle on nous vous ils elles me m' te t' se s' ne n' en y pour par sur dans \
    avec sans sous chez vers très plus c' the a an and or but of to in on at for with from by as my your his her our their \
    is are was i you he she we they it this that
    """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))

    static func isSentenceEnd(_ w: String) -> Bool { w.last.map { ".?!…".contains($0) } ?? false }
    static func isClauseEnd(_ w: String) -> Bool { w.last.map { ",;:—–)".contains($0) } ?? false }
    static func isWeak(_ w: String) -> Bool {
        let n = CaptionText.normalize(w)
        return weakEnd.contains(n) || n.hasSuffix("'")
    }

    /// Splits recognised words into captions. Hard breaks: sentence ends and pauses > `maxPause`. A run longer than
    /// `maxLines × maxCharsPerLine` characters or `maxDuration` seconds is cut at its best break point — punctuation,
    /// then the longest pause, preferring well-filled captions and never ending on an article / preposition — rather
    /// than wherever the limit is hit.
    public static func segments(_ words: [TranscriptWord], language: String, settings: CaptionSettings = CaptionSettings()) -> [SpeechSegment] {
        let allKinds = settings.removeFillers
            ? FillerWords.classify(words.map(\.text), language: language) : Array(repeating: nil, count: words.count)
        var ws: [TranscriptWord] = [], kinds: [FillerWords.Kind?] = []
        for (w, k) in zip(words, allKinds) where !w.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var w = w; w.text = w.text.trimmingCharacters(in: .whitespacesAndNewlines)
            ws.append(w); kinds.append(k)
        }
        let n = ws.count
        guard n > 0 else { return [] }
        let capacity = max(settings.maxCharsPerLine, 4) * max(settings.maxLines, 1)
        func shown(_ r: ClosedRange<Int>) -> [String] {
            settings.removeFillers ? r.filter { kinds[$0] == nil }.map { ws[$0].text } : r.map { ws[$0].text }
        }
        func chars(_ r: ClosedRange<Int>) -> Int { CaptionText.join(shown(r)).count }
        func gap(after k: Int) -> Double { k + 1 < n ? max(0, ws[k + 1].start - ws[k].end) : .infinity }
        func hardBreak(after k: Int) -> Bool { isSentenceEnd(ws[k].text) || gap(after: k) > settings.maxPause }

        var out: [SpeechSegment] = []
        var start = 0
        while start < n {
            var end = start
            var limited = false
            while end + 1 < n, !hardBreak(after: end) {
                let c = end + 1
                if chars(start...c) > capacity || ws[c].end - ws[start].start > settings.maxDuration { limited = true; break }
                end = c
            }
            if limited, end > start {
                // best break point in start...end (the caption ends after word k)
                var best = end, bestScore = -Double.infinity
                for k in start...end {
                    let fill = Double(chars(start...k)) / Double(capacity)
                    let dur = ws[k].end - ws[start].start
                    var score = min(fill, 1) * 2 + min(dur / settings.maxDuration, 1)
                    if isClauseEnd(ws[k].text) { score += 3 }
                    score += min(gap(after: k), 0.5) * 8
                    if isWeak(ws[k].text) { score -= 3 }
                    if k == start { score -= 1.5 }        // a lone word
                    if k + 1 == end { score -= 0.5 }      // strands one word before the limit
                    if score > bestScore { bestScore = score; best = k }
                }
                end = best
            }
            let r = start...end
            let text = shown(r)
            if !text.isEmpty {
                out.append(SpeechSegment(words: Array(ws[r]), fillers: Array(kinds[r]),
                                         lines: wrap(text, maxChars: settings.maxCharsPerLine, maxLines: settings.maxLines)))
            }
            start = end + 1
        }
        return out
    }

    /// At most `maxLines` (2) lines, balancing their lengths; prefers breaking after punctuation and not after an
    /// article / preposition.
    public static func wrap(_ words: [String], maxChars: Int, maxLines: Int = 2) -> [String] {
        let full = CaptionText.join(words)
        guard full.count > maxChars, maxLines > 1, words.count > 1 else { return [full] }
        var best = 1, bestCost = Double.infinity
        for k in 1..<words.count {
            let a = CaptionText.join(Array(words[..<k])).count, b = CaptionText.join(Array(words[k...])).count
            var cost = Double(max(a, b))
            if max(a, b) > maxChars { cost += 1000 }
            if isClauseEnd(words[k - 1]) || isSentenceEnd(words[k - 1]) { cost -= 4 }
            if isWeak(words[k - 1]) { cost += 4 }
            if cost < bestCost { bestCost = cost; best = k }
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
            out.append(CaptionSegment(text: seg.text, start: min(a0, b0), end: max(a0, b0), words: ws))
        }
        return settle(out, clipEnd: mediaClip.end.seconds, settings: settings)
    }

    /// Display timing of consecutive captions (timeline seconds): no overlaps; a pause ≤ `maxPause` between two captions
    /// is bridged (the first stays until the next starts); after a longer pause the caption lingers `tail` seconds;
    /// very short captions are held to `minDuration` when there is room. Never past `clipEnd`.
    public static func settle(_ segs: [CaptionSegment], clipEnd: Double, settings: CaptionSettings) -> [CaptionSegment] {
        var out = segs.sorted { $0.start < $1.start }
        for i in out.indices {
            let next = i + 1 < out.count ? out[i + 1].start : max(clipEnd, out[i].end)
            var e = out[i].end
            if next - e <= settings.maxPause { e = next } else { e += CaptionSettings.tail }
            e = max(e, out[i].start + CaptionSettings.minDuration)
            out[i].end = max(min(e, next), out[i].start + 0.1)
        }
        return out
    }

    /// After `CaptionOps.addCaptionTrack`: links captions to the main-track clip under them (CapCut: captions follow
    /// their source clips).
    public static func finish(trackID: TrackID, in project: inout Project) {
        guard let ti = project.timeline.trackIndex(trackID) else { return }
        let main = project.timeline.mainTrack
        for i in project.timeline.tracks[ti].clips.indices {
            var c = project.timeline.tracks[ti].clips[i]
            guard case .text(let t) = c.content, t.caption != nil else { continue }
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
}
