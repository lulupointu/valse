import Foundation

/// How recognised words become caption clips (CapCut: one caption ≤ 2 lines, split on pauses and sentence ends).
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

/// One caption before it becomes a clip (media time).
public struct CaptionSegment: Hashable, Sendable {
    public var words: [TranscriptWord]
    public var fillers: [FillerWords.Kind?]
    public var lines: [String]
    public var start: Double { words.first?.start ?? 0 }
    public var end: Double { words.last?.end ?? 0 }
    public var text: String { lines.joined(separator: "\n") }
}

public enum CaptionSegmenter {
    /// Groups words into captions: a new caption starts after a sentence end, a pause > `maxPause`, when the text no
    /// longer fits in `maxLines` × `maxCharsPerLine`, or when the caption would last longer than `maxDuration`.
    public static func segments(_ words: [TranscriptWord], language: String, settings: CaptionSettings = CaptionSettings()) -> [CaptionSegment] {
        let kinds = settings.identifyFillers || settings.removeFillers
            ? FillerWords.classify(words.map(\.text), language: language) : Array(repeating: nil, count: words.count)
        var out: [CaptionSegment] = []
        var cur: [TranscriptWord] = [], curKinds: [FillerWords.Kind?] = []
        let capacity = settings.maxCharsPerLine * max(settings.maxLines, 1)
        func flush() {
            guard !cur.isEmpty else { return }
            let shown = settings.removeFillers ? zip(cur, curKinds).filter { $0.1 == nil }.map(\.0.text) : cur.map(\.text)
            if !shown.isEmpty || !settings.removeFillers {
                out.append(CaptionSegment(words: cur, fillers: curKinds, lines: wrap(shown, maxChars: settings.maxCharsPerLine, maxLines: settings.maxLines)))
            }
            cur = []; curKinds = []
        }
        for (i, w) in words.enumerated() {
            let t = w.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            if let last = cur.last, let first = cur.first {
                let len = CaptionText.join(cur.map(\.text) + [t]).count
                let sentenceEnd = last.text.last.map { ".?!…".contains($0) } ?? false
                if sentenceEnd || w.start - last.end > settings.maxPause || len > capacity || w.end - first.start > settings.maxDuration {
                    flush()
                }
            }
            cur.append(w); curKinds.append(kinds[i])
        }
        flush()
        return out
    }

    /// Wraps words into at most `maxLines` lines, balancing the line lengths (CapCut breaks long captions in two).
    public static func wrap(_ words: [String], maxChars: Int, maxLines: Int = 2) -> [String] {
        let full = CaptionText.join(words)
        guard full.count > maxChars, maxLines > 1, words.count > 1 else { return [full] }
        // best split point = the one minimising the longer line
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

    /// Splits a caption's words for a timeline split at clip-local `local` and refreshes both texts.
    /// Returns nil when the clip is not a caption or one half would have no words (the text is kept on both sides).
    func splitCaption(at local: Time) -> (left: CaptionInfo, right: CaptionInfo, leftText: String, rightText: String)? {
        guard let cap = caption, !cap.words.isEmpty else { return nil }
        let l = cap.slice(from: .zero, to: local), r = cap.slice(from: local, to: duration)
        guard !l.words.isEmpty, !r.words.isEmpty else { return nil }
        return (l, r, l.spokenText, r.spokenText)
    }
}

/// Pure caption edits (auto captions, caption list editor, translation). All functions keep `TimelineOps.validate`
/// invariants and are wrapped in undoable `Edit` commands by the callers.
public enum CaptionOps {
    /// CapCut default caption look: white, bold, black outline, lower third.
    public static func defaultStyle() -> TextContent {
        var t = TextContent(string: "", fontSize: 0.055)
        t.bold = true; t.strokeColor = .black; t.strokeWidth = 0.08
        return t
    }
    public static let defaultPosition = Vec2(0, 0.36)

    // MARK: Generation

    /// Caption clips for `transcript` (media time) as shown by `mediaClip` on the timeline.
    public static func makeCaptions(_ transcript: Transcript, for mediaClip: Clip, linked: Bool,
                                    style: TextContent = defaultStyle(), transform: Transform? = nil,
                                    settings: CaptionSettings = CaptionSettings()) -> [Clip] {
        let range = mediaClip.sourceRange
        let words = transcript.words.filter { w in
            let mid = (w.start + w.end) / 2
            return mid >= range.start.seconds && mid <= range.end.seconds
        }
        var out: [Clip] = []
        for seg in CaptionSegmenter.segments(words, language: transcript.language, settings: settings) {
            func tl(_ s: Double) -> Time? { mediaClip.timelineTime(forSource: Time(s).clamped(range.start, range.end)) }
            guard let a0 = tl(seg.start), let b0 = tl(seg.end) else { continue }
            let a = min(a0, b0), b = max(a0, b0)
            var t = style
            t.string = seg.text
            var c = Clip(content: .text(t), start: a, duration: max(b - a, Time(0.3)))
            c.transform = transform ?? { var tr = Transform(); tr.position = defaultPosition; return tr }()
            c.name = seg.lines.joined(separator: " ")
            var cw: [CaptionWord] = []
            for (w, kind) in zip(seg.words, seg.fillers) {
                guard let s0 = tl(w.start), let e0 = tl(w.end) else { continue }
                if settings.removeFillers && kind != nil { continue }
                let s = min(s0, e0), e = max(s0, e0)
                cw.append(CaptionWord(text: w.text, start: max(s - a, .zero), end: max(e - a, .zero),
                                      isFiller: kind != nil ? true : nil))
            }
            c.caption = CaptionInfo(source: .auto, words: cw, language: transcript.language,
                                    sourceClip: mediaClip.id, engine: transcript.engine)
            if linked { c.linkedTo = mediaClip.id }
            out.append(c)
        }
        return out
    }

    /// Clips with auto captions (`source` auto/lyrics) in the timeline.
    public static func autoCaptionIDs(_ tl: Timeline) -> Set<ClipID> {
        Set(tl.allClips.filter { $0.caption.map { $0.source == .auto || $0.source == .lyrics } ?? false }.map(\.id))
    }

    /// Inserts caption clips on a caption track (reusing an existing caption track when they fit, else a new text
    /// track). `replaceExisting` first removes the current auto captions ("Delete current captions").
    @discardableResult
    public static func insert(_ captions: [Clip], into project: inout Project, replaceExisting: Bool) throws -> TrackID {
        guard !captions.isEmpty else { throw EditError.nothingToDo }
        var tl = project.timeline
        if replaceExisting {
            let ids = autoCaptionIDs(tl)
            for ti in tl.tracks.indices { tl.tracks[ti].clips.removeAll { ids.contains($0.id) } }
            TimelineOps.removeEmptyTracks(&tl)
        }
        var clips = captions.sorted { $0.start < $1.start }
        // no overlaps between consecutive captions
        for i in clips.indices.dropLast() where clips[i].end > clips[i + 1].start {
            clips[i].duration = max(clips[i + 1].start - clips[i].start, Time(0.1))
            if clips[i].end > clips[i + 1].start { clips[i + 1].start = clips[i].end }
        }
        let fits: (Track) -> Bool = { t in !clips.contains { c in t.clips.contains { $0.range.overlaps(c.range) } } }
        let trackID: TrackID
        if let ti = tl.tracks.firstIndex(where: { $0.isCaptionTrack && !$0.isLocked && fits($0) }) {
            trackID = tl.tracks[ti].id
        } else {
            trackID = TimelineOps.addTrack(.text, to: &tl)
        }
        let ti = tl.trackIndex(trackID)!
        tl.tracks[ti].clips.append(contentsOf: clips)
        tl.tracks[ti].sortClips()
        project.timeline = tl
        return trackID
    }

    // MARK: Text

    /// The caption's main (spoken-language) text, whatever the bilingual display.
    public static func mainText(_ c: Clip) -> String {
        guard case .text(let t) = c.content else { return "" }
        guard let cap = c.caption, cap.effectiveDisplay != .original else { return t.string }
        return cap.original ?? cap.spokenText
    }

    /// Displayed string for a main text and the caption's display mode.
    public static func displayString(main: String, _ cap: CaptionInfo) -> String {
        switch cap.effectiveDisplay {
        case .original: return main
        case .bilingual: return main + "\n" + (cap.translation ?? "")
        case .translationOnly: return cap.translation ?? main
        }
    }

    /// Re-times words after the text changed: unchanged tokens keep their timing, others share the caption's span
    /// proportionally to their length (CapCut keeps word highlighting usable after edits).
    public static func resync(_ words: [CaptionWord], to text: String, duration: Time) -> [CaptionWord] {
        let tokens = CaptionText.tokens(text)
        guard !tokens.isEmpty else { return [] }
        if tokens.count == words.count {
            return zip(words, tokens).map { w, t in var w = w; if CaptionText.normalize(w.text) != CaptionText.normalize(t) { w.isFiller = nil }; w.text = t; return w }
        }
        let a = words.first?.start ?? .zero, b = max(words.last?.end ?? duration, a + Time(0.1))
        let total = Double(tokens.reduce(0) { $0 + $1.count + 1 })
        var acc = 0.0
        var out: [CaptionWord] = []
        for t in tokens {
            let s = a + (b - a) * (acc / total)
            acc += Double(t.count + 1)
            let e = a + (b - a) * (acc / total)
            // keep flags of an identical word at the same rank if any
            let old = words.first { CaptionText.normalize($0.text) == CaptionText.normalize(t) && abs(($0.start - s).seconds) < 1 }
            out.append(CaptionWord(text: t, start: s, end: e, isFiller: old?.isFiller, isKeyword: old?.isKeyword))
        }
        return out
    }

    /// Sets a caption's main text (caption list editor, find & replace). Plain text clips just get the string.
    public static func setText(_ id: ClipID, _ text: String, in tl: inout Timeline) throws {
        guard var c = tl.clip(id), case .text(var t) = c.content else { throw EditError.clipNotFound }
        if var cap = c.caption {
            cap.words = resync(cap.words, to: text, duration: c.duration)
            if cap.effectiveDisplay != .original { cap.original = text }
            t.string = displayString(main: text, cap)
            c.caption = cap
        } else {
            t.string = text
        }
        c.content = .text(t)
        c.name = text.replacingOccurrences(of: "\n", with: " ")
        tl[clip: id] = c
    }

    /// Splits a caption at a character offset of its main text (Enter in the caption list). The time split is the
    /// start of the first word of the right part. Returns the new right-hand clip.
    @discardableResult
    public static func split(_ id: ClipID, atCharacter offset: Int, in tl: inout Timeline) throws -> ClipID {
        guard let c = tl.clip(id) else { throw EditError.clipNotFound }
        let main = mainText(c)
        let idx = main.index(main.startIndex, offsetBy: min(max(offset, 0), main.count))
        let left = String(main[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
        let right = String(main[idx...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty, !right.isEmpty else { throw EditError.invalidTime }
        let words = c.caption?.words ?? []
        let k = CaptionText.tokens(left).count
        var local: Time
        if k < words.count, k > 0 { local = words[k].start }
        else { local = c.duration * (Double(left.count) / Double(max(main.count, 1))) }
        local = local.clamped(TimelineOps.minimumClipDuration, c.duration - TimelineOps.minimumClipDuration)
        var cap = c.caption
        cap?.translation = nil; cap?.original = nil; cap?.display = nil
        var base = c
        base.caption = cap
        if case .text(var t) = base.content { t.string = main; base.content = .text(t) }
        tl[clip: id] = base
        let rightID = try TimelineOps.split(id, at: c.start + local, in: &tl)
        if var l = tl.clip(id) {
            l.caption?.words = Array(words.prefix(k))
            tl[clip: id] = l
        }
        if var r = tl.clip(rightID) {
            r.caption?.words = words.dropFirst(k).map { w in var w = w; w.start = max(w.start - local, .zero); w.end = max(w.end - local, w.start); return w }
            tl[clip: rightID] = r
        }
        try setText(id, left, in: &tl)
        try setText(rightID, right, in: &tl)
        return rightID
    }

    /// Merges a caption with the next caption on the same track (Delete at the start of a caption = merge up is
    /// `merge(previous)`; Fn-Delete at the end = merge down).
    public static func mergeWithNext(_ id: ClipID, in tl: inout Timeline) throws {
        guard let loc = tl.locate(id), loc.clip + 1 < tl.tracks[loc.track].clips.count else { throw EditError.invalidTime }
        let a = tl.tracks[loc.track].clips[loc.clip], b = tl.tracks[loc.track].clips[loc.clip + 1]
        guard a.isCaption || b.isCaption, case .text = a.content, case .text = b.content else { throw EditError.invalidTime }
        let text = mainText(a) + " " + mainText(b)
        var m = a
        m.duration = b.end - a.start
        var cap = a.caption ?? CaptionInfo(source: b.caption?.source ?? .auto)
        let shift = b.start - a.start
        cap.words += (b.caption?.words ?? []).map { w in var w = w; w.start += shift; w.end += shift; return w }
        cap.translation = nil; cap.original = nil; cap.display = nil
        m.caption = cap
        m.transitionOut = b.transitionOut
        tl.tracks[loc.track].clips[loc.clip] = m
        tl.tracks[loc.track].clips.remove(at: loc.clip + 1)
        try setText(m.id, text, in: &tl)
    }

    /// Find & replace across caption texts. Returns the number of replacements.
    @discardableResult
    public static func replaceAll(_ find: String, with replacement: String, caseSensitive: Bool = false, in tl: inout Timeline) -> Int {
        guard !find.isEmpty else { return 0 }
        var count = 0
        let opts: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        for c in tl.allClips where c.isCaption {
            let text = mainText(c)
            let n = text.ranges(of: find, options: opts).count
            guard n > 0 else { continue }
            count += n
            try? setText(c.id, text.replacingOccurrences(of: find, with: replacement, options: opts), in: &tl)
        }
        return count
    }

    /// Caption clips matching a search string (case/diacritic-insensitive), in timeline order.
    public static func search(_ query: String, in tl: Timeline) -> [ClipID] {
        guard !query.isEmpty else { return [] }
        return captions(in: tl).filter { mainText($0).range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }.map(\.id)
    }

    /// All caption clips in timeline order.
    public static func captions(in tl: Timeline) -> [Clip] {
        tl.tracks.filter { $0.kind == .text }.flatMap(\.clips).filter(\.isCaption).sorted { $0.start < $1.start }
    }

    /// "Apply to all captions": copies the style (font, colours, stroke, background, shadow, spacing, alignment,
    /// style preset), position/scale/rotation and animations of `id` to every other caption. Text stays.
    public static func applyStyleToAll(from id: ClipID, in tl: inout Timeline) throws {
        guard let src = tl.clip(id), case .text(let style) = src.content else { throw EditError.clipNotFound }
        for c in captions(in: tl) where c.id != id {
            guard var d = tl.clip(c.id), case .text(var t) = d.content else { continue }
            let s = t.string
            t = style; t.string = s
            d.content = .text(t)
            d.transform = src.transform
            d.animations = src.animations
            tl[clip: c.id] = d
        }
    }

    // MARK: Translation (bilingual captions)

    /// Stores translations (clip → translated main text) and shows them with `display`.
    public static func setTranslations(_ map: [ClipID: String], language: String, display: CaptionDisplay, in tl: inout Timeline) {
        for (id, tr) in map {
            guard var c = tl.clip(id), var cap = c.caption, case .text(var t) = c.content else { continue }
            let main = mainText(c)
            cap.translation = tr
            cap.translationLanguage = language
            cap.display = display
            cap.original = display == .original ? nil : main
            t.string = displayString(main: main, cap)
            c.caption = cap; c.content = .text(t)
            tl[clip: id] = c
        }
    }

    /// Switches the bilingual display of every translated caption.
    public static func setDisplay(_ display: CaptionDisplay, in tl: inout Timeline) {
        for c0 in captions(in: tl) {
            guard var c = tl.clip(c0.id), var cap = c.caption, cap.translation != nil, case .text(var t) = c.content else { continue }
            let main = mainText(c)
            cap.display = display
            cap.original = display == .original ? nil : main
            t.string = displayString(main: main, cap)
            c.caption = cap; c.content = .text(t)
            tl[clip: c.id] = c
        }
    }

    /// Removes translations (back to monolingual captions).
    public static func clearTranslations(in tl: inout Timeline) {
        for c0 in captions(in: tl) {
            guard var c = tl.clip(c0.id), var cap = c.caption, cap.translation != nil, case .text(var t) = c.content else { continue }
            let main = mainText(c)
            cap.translation = nil; cap.translationLanguage = nil; cap.display = nil; cap.original = nil
            t.string = main
            c.caption = cap; c.content = .text(t)
            tl[clip: c.id] = c
        }
    }

    // MARK: Keywords / fillers

    /// Marks keyword words by normalised text (Highlight keywords). Returns the number of words marked.
    @discardableResult
    public static func markKeywords(_ keywords: Set<String>, in tl: inout Timeline) -> Int {
        var n = 0
        let keys = Set(keywords.map(CaptionText.normalize))
        for c0 in captions(in: tl) {
            guard var c = tl.clip(c0.id), var cap = c.caption else { continue }
            for i in cap.words.indices {
                let hit = keys.contains(CaptionText.normalize(cap.words[i].text))
                cap.words[i].isKeyword = hit ? true : nil
                if hit { n += 1 }
            }
            c.caption = cap
            tl[clip: c.id] = c
        }
        return n
    }
}

/// Caption file writers (TX-025 "Export captions": SRT / TXT, plus WebVTT).
public enum CaptionExport {
    public enum Format: String, Sendable, CaseIterable { case srt, vtt, txt }

    static func stamp(_ t: Time, comma: Bool) -> String {
        let ms = max(0, Int((t.seconds * 1000).rounded()))
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, comma ? "," : ".", ms % 1000)
    }

    /// Caption cues in timeline order (captions; when the timeline has none, every text clip).
    public static func cues(_ tl: Timeline) -> [(start: Time, end: Time, text: String)] {
        var clips = CaptionOps.captions(in: tl)
        if clips.isEmpty { clips = tl.tracks.filter { $0.kind == .text }.flatMap(\.clips).filter { if case .text = $0.content { return true }; return false }.sorted { $0.start < $1.start } }
        return clips.compactMap { c in
            guard case .text(let t) = c.content else { return nil }
            let text = c.isCaption ? t.string : t.string
            return (c.start, c.end, text)
        }
    }

    public static func export(_ tl: Timeline, format: Format) -> String {
        let cs = cues(tl)
        switch format {
        case .srt:
            return cs.enumerated().map { i, c in "\(i + 1)\n\(stamp(c.start, comma: true)) --> \(stamp(c.end, comma: true))\n\(c.text)\n" }
                .joined(separator: "\n")
        case .vtt:
            return "WEBVTT\n\n" + cs.map { "\(stamp($0.start, comma: false)) --> \(stamp($0.end, comma: false))\n\($0.text)\n" }.joined(separator: "\n")
        case .txt:
            return cs.map { $0.text.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\n") + "\n"
        }
    }
}

extension String {
    func ranges(of s: String, options: String.CompareOptions) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        var from = startIndex
        while from < endIndex, let r = range(of: s, options: options, range: from..<endIndex) {
            out.append(r); from = r.upperBound
        }
        return out
    }
}
