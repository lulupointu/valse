import Foundation

/// A find result inside a caption track (UTF-16 range in the clip's string).
public struct CaptionMatch: Hashable, Sendable {
    public let clipID: ClipID
    public let range: TextSpan
}

/// Pure caption-track operations (TX-019/024/029/037/022). Every function keeps `TimelineOps.validate` green.
/// Word timings are content time (see `CaptionWord`).
public enum CaptionOps {
    // MARK: Queries

    public static func isCaption(_ c: Clip) -> Bool { if case .text(let t) = c.content { return t.caption != nil }; return false }

    public static func isCaptionTrack(_ t: Track) -> Bool { t.kind == .text && t.clips.contains(where: isCaption) }

    public static func text(_ c: Clip) -> TextContent? { if case .text(let t) = c.content { return t }; return nil }

    /// Index of the caption track holding `clip`.
    public static func trackIndex(of clip: ClipID, in tl: Timeline) -> Int? {
        guard let loc = tl.locate(clip), isCaptionTrack(tl.tracks[loc.track]) else { return nil }
        return loc.track
    }

    public static func captionTracks(_ tl: Timeline) -> [Int] { tl.tracks.indices.filter { isCaptionTrack(tl.tracks[$0]) } }

    /// Default caption look (white bold with a black outline, lower third). Used by auto captions and imports.
    /// `canvas` sizes it for the frame (`CaptionLayout`: smaller on vertical canvases); nil = the 16:9 size.
    public static func defaultStyle(canvas: Size2? = nil) -> TextContent {
        var t = TextContent(string: "", fontSize: canvas.map(CaptionLayout.fontSize) ?? 0.055)
        t.bold = true; t.strokeColor = .black; t.strokeWidth = 0.08
        return t
    }
    /// Default caption centre on a 16:9 canvas (`CaptionLayout.position(canvas:)` for others).
    public static let defaultPosition = Vec2(0, 0.36)

    /// Word timings of a caption clip in content time, spreading words evenly over the clip when none are stored
    /// (or when the stored ones no longer match the text).
    public static func words(of c: Clip) -> [CaptionWord] {
        guard let t = text(c) else { return [] }
        let tokens = TextTokenizer.tokens(t.string)
        if let w = t.caption?.words, w.count == tokens.count, !w.isEmpty { return w }
        return evenWords(tokens, start: c.sourceStart, end: c.sourceStart + c.duration)
    }

    /// Words spread over [start, end) proportionally to their length.
    public static func evenWords(_ tokens: [String], start: Time, end: Time) -> [CaptionWord] {
        guard !tokens.isEmpty else { return [] }
        let weights = tokens.map { Double(max($0.count, 1)) + 1 }
        let total = weights.reduce(0, +)
        var acc = 0.0
        let span = end - start
        return zip(tokens, weights).map { tok, w in
            let a = start + span * (acc / total); acc += w
            return CaptionWord(tok, start: a, end: start + span * (acc / total))
        }
    }

    // MARK: Creating

    /// One caption clip per segment (timeline seconds). Word times become content time (sourceStart = 0).
    public static func makeClip(_ s: CaptionSegment, style: TextContent? = nil, origin: CaptionOrigin = .auto,
                                position: Vec2 = defaultPosition) -> Clip {
        var t = style ?? defaultStyle()
        t.string = s.text
        t.runs = []
        let start = Time(s.start)
        var data = t.caption ?? CaptionData()
        data.origin = origin
        data.words = s.words.map { CaptionWord($0.text, start: Time($0.start) - start, end: Time($0.end) - start) }
        data.translation = s.translation
        if s.translation != nil, data.display == nil { data.display = .both }
        t.caption = data
        var c = Clip(content: .text(t), start: start, duration: Time(max(s.end - s.start, 0.1)))
        c.transform.position = position
        c.name = s.text
        return c
    }

    /// Adds a caption track built from `segments` (the AI team's auto captions / lyrics, imported SRT/VTT/ASS/LRC, scripts).
    /// `replacing` removes existing captions of the same origin first (CapCut "Delete current captions"): their tracks
    /// go away, except a track that also holds other clips (a title dropped on the caption track), which keeps those.
    /// Overlapping segments are clipped so captions never overlap. Returns the new track id (nil when nothing was added).
    /// `style` / `position` default to the canvas-aware caption look (`CaptionLayout`).
    /// BUG-AUTOCAPTION-SHIFT: the captions always go on a NEW text track just above the main track; no pre-existing
    /// clip (any track) changes track, start or duration, and the other tracks keep their relative order.
    @discardableResult
    public static func addCaptionTrack(_ segments: [CaptionSegment], to project: inout Project, style: TextContent? = nil,
                                       origin: CaptionOrigin = .auto, position: Vec2? = nil,
                                       replacing: Bool = false) -> TrackID? {
        let canvas = project.settings.canvasSize
        let style = style ?? defaultStyle(canvas: canvas)
        let position = position ?? CaptionLayout.position(canvas: canvas)
        var tl = project.timeline
        if replacing {
            func replaced(_ c: Clip) -> Bool { text(c)?.caption?.origin == origin }
            for ti in tl.tracks.indices where isCaptionTrack(tl.tracks[ti]) && !tl.tracks[ti].clips.allSatisfy(replaced) {
                tl.tracks[ti].clips.removeAll(where: replaced)   // keeps the other clips where they are
            }
            tl.tracks.removeAll { t in isCaptionTrack(t) && t.clips.allSatisfy(replaced) }
        }
        var clips: [Clip] = []
        var last = Time.zero
        for s in segments.sorted(by: { $0.start < $1.start }) where !s.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var c = makeClip(s, style: style, origin: origin, position: position)
            if c.start < last {
                let cut = last - c.start
                guard c.duration - cut >= TimelineOps.minimumClipDuration else { continue }
                c.start = last; c.duration -= cut; c.sourceStart = cut
            }
            c.start = max(c.start, .zero)
            clips.append(c)
            last = c.end
        }
        guard !clips.isEmpty else { project.timeline = tl; return nil }
        let id = TimelineOps.addTrack(.text, to: &tl, above: tl.mainTrackIndex)
        let ti = tl.trackIndex(id)!
        tl.tracks[ti].name = nil
        tl.tracks[ti].clips = clips
        project.timeline = tl
        return id
    }

    /// Trims caption clips that run into the next caption of their track (after ripple edits moved linked captions
    /// onto back-to-back neighbours). A caption that would become shorter than the minimum is removed.
    public static func resolveOverlaps(in tl: inout Timeline) {
        for ti in tl.tracks.indices where isCaptionTrack(tl.tracks[ti]) {
            var clips = tl.tracks[ti].clips.sorted { $0.start < $1.start }
            var i = 0
            while i + 1 < clips.count {
                if clips[i].end > clips[i + 1].start {
                    let d = clips[i + 1].start - clips[i].start
                    if d >= TimelineOps.minimumClipDuration { clips[i].duration = d } else { clips.remove(at: i); continue }
                }
                i += 1
            }
            tl.tracks[ti].clips = clips
        }
    }

    /// Captions of a track as segments in timeline seconds (export). `translation` picks what the main text is when the
    /// caption is bilingual: nil = as displayed (main + sub on two lines when shown both).
    public static func segments(of track: Track) -> [CaptionSegment] {
        track.clips.compactMap { c -> CaptionSegment? in
            guard let t = text(c), t.caption != nil || track.kind == .text else { return nil }
            var s = t.displayString
            if let tr = t.caption?.translation, !tr.isEmpty {
                switch t.caption?.display ?? .both {
                case .both: s += "\n" + tr
                case .translationOnly: s = tr
                }
            }
            let origin = c.start - c.sourceStart
            let w = t.caption.map { _ in words(of: c) } ?? []
            return CaptionSegment(text: s, start: c.start.seconds, end: c.end.seconds,
                                  words: w.map { ($0.text, (origin + $0.start).seconds, (origin + $0.end).seconds) },
                                  translation: t.caption?.translation)
        }
    }

    // MARK: Editing

    /// Edits a caption's text, keeping word timings when the word count is unchanged and re-spreading them otherwise.
    public static func setText(_ id: ClipID, _ string: String, in project: inout Project) throws {
        guard var c = project.timeline.clip(id), var t = text(c) else { throw EditError.clipNotFound }
        let old = words(of: c)
        t.setString(string)
        if t.caption != nil {
            let tokens = TextTokenizer.tokens(string)
            if tokens.count == old.count {
                t.caption?.words = zip(old, tokens).map { w, tok in var w = w; w.text = tok; return w }
            } else {
                // words still matching keep their timing; changed / added ones are interpolated (CAP-UX2-SPLIT)
                let a = min(old.first?.start ?? c.sourceStart, c.sourceStart)
                let b = max(old.last?.end ?? (c.sourceStart + c.duration), c.sourceStart + c.duration)
                t.caption?.words = retimeWords(tokens, old: old, lo: a, hi: b)
            }
        }
        c.content = .text(t); c.name = string
        project.timeline[clip: id] = c
    }

    /// Splits a caption at a UTF-16 offset of its text (Enter in the caption editor). The cut time is the start of the
    /// first word after the offset (or proportional to the text when there are no timings). Returns the new clip id.
    @discardableResult
    public static func split(_ id: ClipID, at offset: Int, in project: inout Project) throws -> ClipID {
        guard let c = project.timeline.clip(id), let t = text(c) else { throw EditError.clipNotFound }
        let u = Array(t.string.utf16)
        guard offset > 0, offset < u.count else { throw EditError.invalidTime }
        let leftS = String(utf16CodeUnits: Array(u[..<offset]), count: offset).trimmingCharacters(in: .whitespacesAndNewlines)
        let rightS = String(utf16CodeUnits: Array(u[offset...]), count: u.count - offset).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !leftS.isEmpty, !rightS.isEmpty else { throw EditError.invalidTime }
        let ranges = TextTokenizer.words(in: t.string)
        let k = ranges.filter { $0.location < offset }.count
        let ws = words(of: c)
        var cut: Time
        if k < ws.count, k > 0 {
            cut = c.start + (ws[k].start - c.sourceStart)
        } else {
            cut = c.start + c.duration * (Double(offset) / Double(u.count))
        }
        let minD = TimelineOps.minimumClipDuration
        cut = cut.clamped(c.start + minD, c.end - minD)
        var tl = project.timeline
        let rightID = try TimelineOps.split(id, at: cut, in: &tl)
        guard var left = tl.clip(id), var right = tl.clip(rightID), var lt = text(left), var rt = text(right) else { throw EditError.clipNotFound }
        let leftLen = leftS.utf16.count
        let leadTrim = rightLeadingTrim(u, offset)
        lt.string = leftS; lt.runs = TextContent.normalized(t.runs, length: leftLen)
        rt.string = rightS
        rt.runs = TextContent.normalized(t.runs.map { TextRun(TextSpan($0.range.location - offset - leadTrim, $0.range.length), $0.style) },
                                         length: rightS.utf16.count)
        if t.caption != nil {
            lt.caption?.words = Array(ws.prefix(k))
            rt.caption?.words = Array(ws.dropFirst(k))
            if lt.caption?.words.count != TextTokenizer.tokens(leftS).count { lt.caption?.words = [] }
            if rt.caption?.words.count != TextTokenizer.tokens(rightS).count { rt.caption?.words = [] }
        }
        left.content = .text(lt); left.name = leftS
        right.content = .text(rt); right.name = rightS
        tl[clip: id] = left; tl[clip: rightID] = right
        project.timeline = tl
        return rightID
    }

    private static func rightLeadingTrim(_ u: [UTF16.CodeUnit], _ offset: Int) -> Int {
        var i = offset
        while i < u.count, let s = Unicode.Scalar(u[i]), CharacterSet.whitespacesAndNewlines.contains(s) { i += 1 }
        return i - offset
    }

    /// Merges a caption with the next caption on its track (Fn+Delete at the end / Delete at the start of the next).
    public static func mergeWithNext(_ id: ClipID, in project: inout Project) throws {
        var tl = project.timeline
        guard let loc = tl.locate(id) else { throw EditError.clipNotFound }
        let track = tl.tracks[loc.track]
        guard loc.clip + 1 < track.clips.count else { throw EditError.invalidTime }
        var a = track.clips[loc.clip]
        let b = track.clips[loc.clip + 1]
        guard var ta = text(a), let tb = text(b) else { throw EditError.invalidTime }
        let wa = ta.caption != nil ? words(of: a) : [], wb = tb.caption != nil ? words(of: b) : []
        let sep = ta.string.isEmpty || tb.string.isEmpty ? "" : " "
        let shift = ta.string.utf16.count + sep.utf16.count
        // b's content time → a's content time
        let k = (b.start - b.sourceStart) - (a.start - a.sourceStart)
        ta.runs = TextContent.normalized(ta.runs + tb.runs.map { TextRun(TextSpan($0.range.location + shift, $0.range.length), $0.style) },
                                         length: shift + tb.string.utf16.count)
        ta.string += sep + tb.string
        if ta.caption != nil || tb.caption != nil {
            if ta.caption == nil { ta.caption = tb.caption }
            ta.caption?.words = wa + wb.map { var w = $0; w.start = w.start + k; w.end = w.end + k; return w }
            if let x = ta.caption?.translation, let y = tb.caption?.translation { ta.caption?.translation = x + " " + y }
        }
        a.content = .text(ta); a.name = ta.string
        a.duration = b.end - a.start
        tl.tracks[loc.track].clips[loc.clip] = a
        tl.tracks[loc.track].clips.remove(at: loc.clip + 1)
        project.timeline = tl
    }

    /// Shortest a neighbouring caption gets when a caption edge pushes into it (CAP-UX2-PUSH).
    public static let pushMinimumDuration = Time(0.1)

    /// Moves a caption's start and/or end (timing nudges in the caption list, ⌥⌘I / ⌥⌘O). An edge moved into the
    /// neighbouring caption pushes that caption's edge along (trimming it, CapCut-like) down to `pushMinimumDuration`;
    /// beyond that it stops. Word timings stay attached to the audio (a later start trims the head like TimelineOps.trim).
    public static func setTimes(_ id: ClipID, start: Time? = nil, end: Time? = nil, in project: inout Project) throws {
        var tl = project.timeline
        guard let loc = tl.locate(id) else { throw EditError.clipNotFound }
        let clips = tl.tracks[loc.track].clips
        var c = clips[loc.clip]
        let minD = TimelineOps.minimumClipDuration
        let prev = loc.clip > 0 ? clips[loc.clip - 1] : nil
        let next = loc.clip + 1 < clips.count ? clips[loc.clip + 1] : nil
        // how far an edge may go: into the neighbour until it is pushMinimumDuration long (never shorter than it is)
        let lo = prev.map { max(.zero, min($0.end, $0.start + pushMinimumDuration)) } ?? .zero
        let hi = next.map { max($0.start, $0.end - pushMinimumDuration) } ?? Time.indefinite
        var s = (start ?? c.start).clamped(lo, hi - minD)
        var e = (end ?? c.end).clamped(lo + minD, hi)
        if e - s < minD { if start != nil { s = e - minD } else { e = s + minD } }
        moveStart(&c, to: s)
        c.duration = e - s
        tl.tracks[loc.track].clips[loc.clip] = c
        if var p = prev, p.end > s { p.duration = s - p.start; tl.tracks[loc.track].clips[loc.clip - 1] = p }
        if var n = next, n.start < e { moveStart(&n, to: e); tl.tracks[loc.track].clips[loc.clip + 1] = n }
        project.timeline = tl
    }

    /// Moves a clip's start keeping its end (head trim: content time, keyframes and words stay on the audio).
    static func moveStart(_ c: inout Clip, to s: Time) {
        let d = s - c.start
        guard d != .zero else { return }
        let end = c.end
        c.sourceStart = c.sourceStart + d
        for k in c.keyframes.keys { c.keyframes[k]?.shift(by: -d) }
        c.start = s; c.duration = end - s
    }

    /// Nudges both edges by the given deltas.
    public static func nudge(_ id: ClipID, start ds: Time = .zero, end de: Time = .zero, in project: inout Project) throws {
        guard let c = project.timeline.clip(id) else { throw EditError.clipNotFound }
        try setTimes(id, start: ds == .zero ? nil : c.start + ds, end: de == .zero ? nil : c.end + de, in: &project)
    }

    // MARK: Find & replace

    public static func find(_ query: String, in track: Track, caseSensitive: Bool = false) -> [CaptionMatch] {
        guard !query.isEmpty else { return [] }
        let opts: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive, .diacriticInsensitive]
        var out: [CaptionMatch] = []
        for c in track.clips {
            guard let t = text(c) else { continue }
            let ns = t.string as NSString
            var r = NSRange(location: 0, length: ns.length)
            while r.length > 0 {
                let f = ns.range(of: query, options: NSString.CompareOptions(rawValue: opts.rawValue), range: r)
                guard f.location != NSNotFound else { break }
                out.append(CaptionMatch(clipID: c.id, range: TextSpan(f.location, f.length)))
                let next = f.location + max(f.length, 1)
                r = NSRange(location: next, length: ns.length - next)
            }
        }
        return out
    }

    /// Replaces every match on the track. Returns the number of replacements.
    @discardableResult
    public static func replaceAll(_ query: String, with replacement: String, trackIndex ti: Int, in project: inout Project,
                                  caseSensitive: Bool = false) -> Int {
        guard ti < project.timeline.tracks.count else { return 0 }
        let matches = find(query, in: project.timeline.tracks[ti], caseSensitive: caseSensitive)
        let byClip = Dictionary(grouping: matches, by: \.clipID)
        for (id, ms) in byClip {
            guard let c = project.timeline.clip(id), let t = text(c) else { continue }
            let ns = NSMutableString(string: t.string)
            for m in ms.sorted(by: { $0.range.location > $1.range.location }) {
                ns.replaceCharacters(in: NSRange(location: m.range.location, length: m.range.length), with: replacement)
            }
            try? setText(id, ns as String, in: &project)
        }
        return matches.count
    }

    // MARK: Bulk style

    /// "Apply to all captions": copies the look (font, colours, stroke, background, karaoke, position, animations) of
    /// one caption to every caption of its track. Text, timings and per-range styles stay.
    public static func applyLookToAll(from id: ClipID, in project: inout Project, includePosition: Bool = true,
                                      includeAnimations: Bool = true) {
        guard let src = project.timeline.clip(id), let st = text(src), let ti = project.timeline.locate(id)?.track else { return }
        for i in project.timeline.tracks[ti].clips.indices {
            var c = project.timeline.tracks[ti].clips[i]
            guard c.id != id, var t = text(c) else { continue }
            let keepData = t.caption
            t.adoptLook(of: st)
            if var d = keepData { d.subStyle = st.caption?.subStyle ?? d.subStyle; d.display = st.caption?.display ?? d.display; t.caption = d }
            c.content = .text(t)
            if includePosition { c.transform = src.transform; c.opacity = src.opacity; c.blendMode = src.blendMode }
            if includeAnimations {
                var a = src.animations
                if let x = a.inAnim { a.inAnim?.duration = min(x.duration, c.duration * 0.5) }
                if let x = a.outAnim { a.outAnim?.duration = min(x.duration, c.duration * 0.5) }
                c.animations = a
            }
            project.timeline.tracks[ti].clips[i] = c
        }
    }

    // MARK: Line wrap / re-segmentation

    /// Greedy line breaking at word boundaries (≤ `maxChars` per line, a longer single word stays whole).
    public static func breakLines(_ tokens: [String], maxChars: Int, unspaced: Bool = false) -> [[Int]] {
        var lines: [[Int]] = []
        var cur: [Int] = []
        var len = 0
        for (i, tok) in tokens.enumerated() {
            let add = tok.count + (cur.isEmpty || unspaced ? 0 : 1)
            if !cur.isEmpty, len + add > maxChars { lines.append(cur); cur = []; len = 0 }
            len += cur.isEmpty ? tok.count : add
            cur.append(i)
        }
        if !cur.isEmpty { lines.append(cur) }
        return lines
    }

    /// CapCut "Captions line wrap" / "Split captions" (TX-024): every caption of the track is broken into lines of at most
    /// `maxCharsPerLine`, and captions with more than `maxLines` lines are split into several clips (timed by their words).
    public static func wrap(trackIndex ti: Int, maxCharsPerLine: Int, maxLines: Int, in project: inout Project) {
        guard ti < project.timeline.tracks.count, maxCharsPerLine > 0, maxLines > 0 else { return }
        let ids = project.timeline.tracks[ti].clips.map(\.id)
        for id in ids {
            guard let c = project.timeline.clip(id), let t = text(c) else { continue }
            let tokens = TextTokenizer.tokens(t.string)
            guard !tokens.isEmpty else { continue }
            let unspaced = !t.string.contains(" ")
            let lines = breakLines(tokens, maxChars: maxCharsPerLine, unspaced: unspaced)
            let chunks = stride(from: 0, to: lines.count, by: maxLines).map { Array(lines[$0..<min($0 + maxLines, lines.count)]) }
            let ws = words(of: c)
            let join = unspaced ? "" : " "
            func chunkText(_ ch: [[Int]]) -> String { ch.map { $0.map { tokens[$0] }.joined(separator: join) }.joined(separator: "\n") }
            // first chunk stays in this clip; later chunks become new clips at their first word
            var current = id
            for (n, ch) in chunks.enumerated() {
                if n > 0 {
                    // split `current` at the first word of this chunk
                    guard let cc = project.timeline.clip(current) else { break }
                    let firstWord = ch[0][0]
                    let local = ws.count == tokens.count ? ws[firstWord].start - cc.sourceStart
                        : cc.duration / Double(chunks.count - n + 1)
                    let at = (cc.start + local).clamped(cc.start + TimelineOps.minimumClipDuration, cc.end - TimelineOps.minimumClipDuration)
                    guard let right = try? TimelineOps.split(current, at: at, in: &project.timeline) else { break }
                    current = right
                }
                let wordIdx = ch.flatMap { $0 }
                guard var cc = project.timeline.clip(current), var ct = text(cc) else { break }
                ct.string = chunkText(ch); ct.runs = []
                if ct.caption != nil { ct.caption?.words = ws.count == tokens.count ? wordIdx.map { ws[$0] } : [] }
                cc.content = .text(ct); cc.name = ct.string.replacingOccurrences(of: "\n", with: " ")
                project.timeline[clip: current] = cc
            }
        }
    }

    // MARK: Script → captions

    /// "Enter scripts → Split into captions" (TX-029): sentences / lines become captions of ≤ `maxChars`, timed back to
    /// back from `start` at `charsPerSecond` (or spread over `totalDuration` when given).
    public static func scriptSegments(_ script: String, start: Double = 0, totalDuration: Double? = nil, maxChars: Int = 32,
                                      charsPerSecond: Double = 14) -> [CaptionSegment] {
        var pieces: [String] = []
        for line in script.components(separatedBy: .newlines) {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty else { continue }
            // sentence split
            var sentence = ""
            for ch in l {
                sentence.append(ch)
                if ".!?。！？".contains(ch) { pieces.append(sentence.trimmingCharacters(in: .whitespaces)); sentence = "" }
            }
            if !sentence.trimmingCharacters(in: .whitespaces).isEmpty { pieces.append(sentence.trimmingCharacters(in: .whitespaces)) }
        }
        var chunks: [String] = []
        for p in pieces {
            let toks = TextTokenizer.tokens(p)
            let unspaced = !p.contains(" ")
            for line in breakLines(toks, maxChars: maxChars, unspaced: unspaced) {
                chunks.append(line.map { toks[$0] }.joined(separator: unspaced ? "" : " "))
            }
        }
        guard !chunks.isEmpty else { return [] }
        let weights = chunks.map { Double($0.count) + 4 }
        let natural = weights.map { max(1, $0 / charsPerSecond) }
        let k = totalDuration.map { $0 / natural.reduce(0, +) } ?? 1
        var t = start
        return zip(chunks, natural).map { s, d in
            let seg = CaptionSegment(text: s, start: t, end: t + d * k)
            t += d * k
            return seg
        }
    }
}
