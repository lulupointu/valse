import Foundation

/// Split options re-flow (CAP-UX2-SPLIT, owner 2026-10-27): choosing a split rule re-cuts the whole language from the
/// CURRENT caption texts (the user's corrections are the source, never the generated words): consecutive captions are
/// merged, then cut to the rule at word boundaries, breaking at sentence ends and real pauses. Words keep their stored
/// timing when it still matches them; changed / added words are interpolated inside the caption they came from.
/// Invariant (CaptionReflowTests): the word sequence of the language is the same before and after any re-split.
extension CaptionOps {
    /// A pause at least this long between two words always starts a new caption.
    public static let reflowPause = Time(0.5)

    /// Word timings for `tokens` (a caption's current words) from its stored `old` words, in [lo, hi] (content time).
    /// Words that still match a stored word (longest common subsequence on a case / punctuation-insensitive form) keep
    /// its timing; the others are spread by character count between the nearest anchored words.
    public static func retimeWords(_ tokens: [String], old: [CaptionWord], lo: Time, hi: Time) -> [CaptionWord] {
        guard !tokens.isEmpty else { return [] }
        guard hi > lo else { return tokens.map { CaptionWord($0, start: lo, end: lo) } }
        func key(_ s: String) -> String {
            let k = s.lowercased().filter { $0.isLetter || $0.isNumber }
            return k.isEmpty ? s.lowercased() : k
        }
        let a = tokens.map(key), b = old.map { key($0.text) }
        // LCS table
        var match = [Int?](repeating: nil, count: tokens.count)
        if !b.isEmpty {
            let n = a.count, m = b.count
            var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
                }
            }
            var i = 0, j = 0
            while i < n, j < m {
                if a[i] == b[j] { match[i] = j; i += 1; j += 1 } else if dp[i + 1][j] >= dp[i][j + 1] { i += 1 } else { j += 1 }
            }
        }
        var out: [CaptionWord] = []
        out.reserveCapacity(tokens.count)
        var cursor = lo   // end of the last placed word: keeps the timings monotonic and inside [lo, hi]
        var i = 0
        while i < tokens.count {
            if let j = match[i] {
                let s = old[j].start.clamped(cursor, hi), e = old[j].end.clamped(s, hi)
                var w = old[j]; w.text = tokens[i]; w.start = s; w.end = e
                out.append(w); cursor = e; i += 1
                continue
            }
            // a run of unanchored words up to the next anchor (or the end)
            var k = i
            while k < tokens.count, match[k] == nil { k += 1 }
            let until = k < tokens.count ? old[match[k]!].start.clamped(cursor, hi) : hi
            let run = evenWords(Array(tokens[i..<k]), start: cursor, end: max(until, cursor))
            out.append(contentsOf: run)
            cursor = run.last?.end ?? cursor
            i = k
        }
        return out
    }

    /// One word of the language being re-flowed (timeline time).
    struct ReflowWord {
        var text: String
        var start: Time
        var end: Time
        var filler: Bool?
        /// Index of the caption it came from, and whether it is that caption's first / last word.
        var source: Int
        var first: Bool
        var last: Bool
        /// Per-range styles of the word, relative to the word.
        var runs: [TextRun]
    }

    static func separator(_ a: String, _ b: String) -> String {
        if let x = a.last, let y = b.first, TextTokenizer.isUnspacedScript(x), TextTokenizer.isUnspacedScript(y) { return "" }
        return " "
    }

    static func endsSentence(_ w: String) -> Bool {
        guard let c = w.trimmingCharacters(in: CharacterSet(charactersIn: "\"'»”)]")).last else { return false }
        return ".!?…。！？".contains(c)
    }

    /// Greedy lines (≤ `chars` each, a longer single word stays whole) of a word list.
    static func lines(_ words: [String], chars: Int) -> [[Int]] {
        var out: [[Int]] = [], cur: [Int] = [], len = 0
        for (i, w) in words.enumerated() {
            let add = w.count + (cur.isEmpty ? 0 : separator(words[cur.last!], w).count)
            if !cur.isEmpty, len + add > chars { out.append(cur); cur = []; len = 0 }
            len += cur.isEmpty ? w.count : add
            cur.append(i)
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// Re-cuts every caption of track `ti` to `rule` (see the type comment). Empty captions stay where they are.
    /// Returns the caption count.
    @discardableResult
    public static func reflow(trackIndex ti: Int, rule: CaptionSplitRule, in project: inout Project) -> Int {
        guard ti < project.timeline.tracks.count else { return 0 }
        let clips = project.timeline.tracks[ti].clips.sorted { $0.start < $1.start }
        let minD = TimelineOps.minimumClipDuration
        // 1. the word stream (current texts, timings anchored to the stored words)
        var stream: [ReflowWord] = []
        var keptEmpty: [Clip] = []
        var hardBreakBefore = Set<Int>()   // stream indices after an empty caption
        for (ci, c) in clips.enumerated() {
            guard let t = text(c) else { keptEmpty.append(c); continue }
            let spans = TextTokenizer.words(in: t.string)
            guard !spans.isEmpty else { keptEmpty.append(c); hardBreakBefore.insert(stream.count); continue }
            let u = Array(t.string.utf16)
            let tokens = spans.map { String(utf16CodeUnits: Array(u[$0.location..<$0.end]), count: $0.length) }
            let lo = c.sourceStart, hi = c.sourceStart + c.duration
            let stored = t.caption?.words ?? []
            let ws = stored.count == tokens.count ? stored : retimeWords(tokens, old: stored, lo: lo, hi: hi)
            let origin = c.start - c.sourceStart
            var cursor = c.start
            for (k, sp) in spans.enumerated() {
                let s = (origin + ws[k].start).clamped(cursor, c.end)
                let e = (origin + ws[k].end).clamped(s, c.end)
                cursor = e
                let runs = t.runs.compactMap { r -> TextRun? in
                    let a = max(r.range.location, sp.location), b = min(r.range.end, sp.end)
                    return b > a ? TextRun(TextSpan(a - sp.location, b - a), r.style) : nil
                }
                stream.append(ReflowWord(text: tokens[k], start: s, end: e, filler: ws[k].filler, source: ci,
                                         first: k == 0, last: k == spans.count - 1, runs: runs))
            }
        }
        guard !stream.isEmpty else { return clips.count }
        // 2. groups: as many words as the rule's lines hold, cut at sentence ends and pauses
        var groups: [Range<Int>] = []
        var g0 = 0
        for k in 1..<stream.count + 1 {
            if k == stream.count { groups.append(g0..<k); break }
            let prev = stream[k - 1], w = stream[k]
            let pause = w.start - prev.end >= reflowPause
                || (w.first && prev.last && clips[w.source].start - clips[prev.source].end >= reflowPause)
            let fits = lines(stream[g0...k].map(\.text), chars: rule.charsPerLine).count <= rule.lines
            if pause || hardBreakBefore.contains(k) || endsSentence(prev.text) || !fits {
                groups.append(g0..<k); g0 = k
            }
        }
        // 3. one caption per group
        var used = Set<ClipID>()
        var out: [Clip] = []
        var prevEnd = Time.zero
        for (gi, g) in groups.enumerated() {
            let ws = Array(stream[g])
            let template = clips[ws[0].source]
            let nextWord = g.upperBound < stream.count ? stream[g.upperBound] : nil
            var start = ws[0].first ? template.start : ws[0].start
            var end = ws.last!.last ? clips[ws.last!.source].end : (nextWord?.start ?? clips[ws.last!.source].end)
            start = max(start, prevEnd)
            if end - start < minD { end = start + minD }
            if let n = groups.indices.contains(gi + 1) ? stream[groups[gi + 1].lowerBound] : nil, n.first {
                end = min(end, clips[n.source].start)
            }
            // text: rule lines, words re-joined (unspaced scripts without spaces)
            let ls = lines(ws.map(\.text), chars: rule.charsPerLine)
            var s = "", runs: [TextRun] = []
            for (li, line) in ls.enumerated() {
                if li > 0 { s += "\n" }
                for (n, wi) in line.enumerated() {
                    if n > 0 { s += separator(ws[line[n - 1]].text, ws[wi].text) }
                    let at = s.utf16.count
                    runs += ws[wi].runs.map { TextRun(TextSpan($0.range.location + at, $0.range.length), $0.style) }
                    s += ws[wi].text
                }
            }
            // unchanged caption: kept as it is (same clip, same id)
            let src = clips[ws[0].source]
            if ws[0].first, ws.last!.last, ws[0].source == ws.last!.source, text(src)?.string == s,
               src.start == start, src.end == end, !used.contains(src.id) {
                used.insert(src.id); out.append(src); prevEnd = src.end
                continue
            }
            var c = template
            if used.contains(c.id) { c.id = ClipID() }
            used.insert(c.id)
            let d = start - template.start
            let origin = template.start - template.sourceStart   // content-time origin kept: word times stay on the audio
            c.start = start
            c.duration = max(end - start, minD)
            c.sourceStart = start - origin
            for k in c.keyframes.keys { c.keyframes[k]?.shift(by: -d) }
            if let ms = template.markers {
                let m = ms.compactMap { m -> Marker? in
                    var m = m; m.time = m.time - d
                    return m.time >= .zero && m.time < c.duration ? m : nil
                }
                c.markers = m.isEmpty ? nil : m
            }
            if !ws[0].first { c.animations.inAnim = nil }
            if !ws.last!.last { c.animations.outAnim = nil }
            if let x = c.animations.inAnim { c.animations.inAnim?.duration = min(x.duration, c.duration * 0.5) }
            if let x = c.animations.outAnim { c.animations.outAnim?.duration = min(x.duration, c.duration * 0.5) }
            if var t = text(c) {
                t.string = s
                t.runs = TextContent.normalized(runs, length: s.utf16.count)
                if t.caption != nil {
                    t.caption?.words = ws.map { CaptionWord($0.text, start: $0.start - origin, end: $0.end - origin, filler: $0.filler) }
                    t.caption?.translation = nil
                }
                c.content = .text(t)
            }
            c.name = s.replacingOccurrences(of: "\n", with: " ")
            out.append(c)
            prevEnd = c.end
        }
        project.timeline.tracks[ti].clips = (out + keptEmpty).sorted { $0.start < $1.start }
        return project.timeline.tracks[ti].clips.count
    }
}
