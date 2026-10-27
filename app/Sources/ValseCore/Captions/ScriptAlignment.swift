import Foundation

/// Text alignment to speech (TX-030): an existing script (typed, pasted or from the AI writer) is aligned to what is
/// actually said, so every script word gets the timing of the matching recognized word. Recognition gives word
/// timestamps (whisper.cpp / Apple speech); this aligns the two word sequences globally (Needleman–Wunsch on normalized
/// tokens, tolerant to recognition errors), interpolates words the recognizer missed between their aligned neighbours,
/// and splits the script into captions that keep the script's own spelling and punctuation, with karaoke word timings.
public enum ScriptAlignment {
    public struct TimedWord: Hashable, Sendable {
        public var text: String
        public var start: Double
        public var end: Double
        public init(_ text: String, _ start: Double, _ end: Double) { self.text = text; self.start = start; self.end = end }
    }

    public struct Result: Sendable {
        /// One entry per script token, in timeline seconds.
        public var words: [TimedWord]
        /// Fraction of script tokens matched to a recognized word (the rest are interpolated).
        public var matchRatio: Double
    }

    /// Recognized words of the given clips on the timeline (timeline seconds, sorted).
    public static func heardWords(transcripts: [MediaID: Transcript], clips: [Clip]) -> [TimedWord] {
        var out: [TimedWord] = []
        for c in clips {
            guard let t = c.mediaID.flatMap({ transcripts[$0] }) else { continue }
            let r = c.sourceRange
            for w in t.words {
                let mid = (w.start + w.end) / 2
                guard mid >= r.start.seconds, mid <= r.end.seconds,
                      let a = c.timelineTime(forSource: Time(w.start).clamped(r.start, r.end)),
                      let b = c.timelineTime(forSource: Time(w.end).clamped(r.start, r.end)) else { continue }
                out.append(TimedWord(w.text, min(a, b).seconds, max(a, b).seconds))
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    /// Script tokens (whitespace separated, punctuation kept on the token).
    public static func tokens(_ script: String) -> [String] {
        script.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
    }

    static func similarity(_ a: String, _ b: String) -> Int {
        if a.isEmpty || b.isEmpty { return -1 }
        if a == b { return 3 }
        if a.count >= 4 && b.count >= 4 && (a.hasPrefix(b) || b.hasPrefix(a)) { return 2 }
        if max(a.count, b.count) >= 4 && levenshtein(a, b) <= max(1, min(a.count, b.count) / 4) { return 1 }
        return -2
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        var prev = Array(0...y.count), cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...max(x.count, 1) where !x.isEmpty {
            cur[0] = i
            for j in 1...max(y.count, 1) where !y.isEmpty {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[y.count]
    }

    /// Global alignment of script tokens to heard words; unmatched tokens are spread between aligned neighbours.
    public static func align(script: [String], heard: [TimedWord]) -> Result {
        let n = script.count, m = heard.count
        guard n > 0 else { return Result(words: [], matchRatio: 0) }
        guard m > 0 else { return Result(words: [], matchRatio: 0) }
        let s = script.map(CaptionText.normalize), h = heard.map { CaptionText.normalize($0.text) }
        let gap = -1
        // DP over (n+1)×(m+1); 0 = diag, 1 = up (skip script token), 2 = left (skip heard word)
        var score = [Int](repeating: 0, count: (n + 1) * (m + 1))
        var move = [UInt8](repeating: 0, count: (n + 1) * (m + 1))
        let w = m + 1
        for i in 1...n { score[i * w] = i * gap; move[i * w] = 1 }
        for j in 1...m { score[j] = j * gap; move[j] = 2 }
        for i in 1...n {
            for j in 1...m {
                let d = score[(i - 1) * w + j - 1] + similarity(s[i - 1], h[j - 1])
                let u = score[(i - 1) * w + j] + gap
                let l = score[i * w + j - 1] + gap
                if d >= u && d >= l { score[i * w + j] = d; move[i * w + j] = 0 }
                else if u >= l { score[i * w + j] = u; move[i * w + j] = 1 }
                else { score[i * w + j] = l; move[i * w + j] = 2 }
            }
        }
        var match = [Int?](repeating: nil, count: n)
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && move[i * w + j] == 0 {
                if similarity(s[i - 1], h[j - 1]) > 0 { match[i - 1] = j - 1 }
                i -= 1; j -= 1
            } else if i > 0 && (j == 0 || move[i * w + j] == 1) { i -= 1 } else { j -= 1 }
        }
        // timings: matched tokens take their heard word; runs of unmatched tokens share the gap between anchors
        var out = [TimedWord?](repeating: nil, count: n)
        for k in 0..<n { if let jj = match[k] { out[k] = TimedWord(script[k], heard[jj].start, heard[jj].end) } }
        let perChar = max(0.04, min(0.12, (heard.last!.end - heard.first!.start) / Double(max(heard.map { $0.text.count + 1 }.reduce(0, +), 1))))
        var k = 0
        while k < n {
            guard out[k] == nil else { k += 1; continue }
            var e = k
            while e < n && out[e] == nil { e += 1 }
            let run = Array(k..<e)
            let lo = k > 0 ? out[k - 1]!.end : max(0, (e < n ? out[e]!.start : heard[0].start) - Double(run.map { script[$0].count + 1 }.reduce(0, +)) * perChar)
            let hi = e < n ? out[e]!.start : lo + Double(run.map { script[$0].count + 1 }.reduce(0, +)) * perChar
            let total = Double(run.map { script[$0].count + 1 }.reduce(0, +))
            var t = lo
            for r in run {
                let d = max(hi - lo, 0) * Double(script[r].count + 1) / max(total, 1)
                out[r] = TimedWord(script[r], t, t + d)
                t += d
            }
            k = e
        }
        let matched = match.compactMap { $0 }.count
        return Result(words: out.map { $0! }, matchRatio: Double(matched) / Double(n))
    }

    /// Caption segments for a script aligned to the heard words (timeline seconds, word timings for karaoke). Lines
    /// in the script are kept as caption boundaries when they're short enough.
    public static func segments(script: String, heard: [TimedWord], language: String,
                                settings: CaptionSettings = CaptionSettings()) -> (segments: [CaptionSegment], matchRatio: Double) {
        let toks = tokens(script)
        let r = align(script: toks, heard: heard)
        guard !r.words.isEmpty else { return ([], 0) }
        // a script line break forces a new caption: mark the last word of each line as a sentence end for the segmenter
        var lineEnds = Set<Int>()
        var idx = 0
        for line in script.split(whereSeparator: \.isNewline) {
            let c = tokens(String(line)).count
            if c > 0 { idx += c; lineEnds.insert(idx - 1) }
        }
        let words = r.words.enumerated().map { k, w in
            TranscriptWord(text: w.text, start: w.start, end: max(w.end, w.start + 0.05), confidence: 1)
        }
        var segs: [CaptionSegment] = []
        var start = 0
        for end in lineEnds.sorted() + [words.count - 1] where end >= start {
            let chunk = Array(words[start...end])
            for seg in SpeechSegmenter.segments(chunk, language: language, settings: settings) {
                let ws = seg.words.map { (text: $0.text, start: $0.start, end: $0.end) }
                segs.append(CaptionSegment(text: seg.text, start: seg.start, end: max(seg.end, seg.start + 0.3), words: ws))
            }
            start = end + 1
        }
        // no overlaps (interpolated words can touch the next caption)
        for i in segs.indices.dropLast() where segs[i].end > segs[i + 1].start { segs[i].end = max(segs[i].start + 0.1, segs[i + 1].start) }
        return (segs, r.matchRatio)
    }
}
