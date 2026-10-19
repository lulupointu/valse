import Foundation

/// "Remove filler words" (C4, CapCut transcript ▸ Remove filler words / Captions ▸ Identify filler words): finds the
/// pauses, hesitations, fillers and repetitions of the main-track speech **in timeline time** and cuts them with one
/// ripple edit. Pure (the UI only picks which candidates to apply).
///
/// Pauses are measured on the timeline, not in media time, so a pause is found wherever silence is heard:
/// - at the **start** of a run of speech clips (the silence before the first word, e.g. a clip that starts on a breath),
/// - at the **end** of a run (silence after the last word until the clip ends),
/// - **between** two words, also across a cut between two clips (the tail of one clip plus the head of the next),
/// - over a whole speech clip in which nothing is said.
/// A run is a sequence of consecutive main-track clips whose media has a transcript with words; clips without speech
/// (b-roll, music, photos) end a run and are never cut.
public enum FillerCleanup {
    public enum Kind: String, Sendable, Codable, CaseIterable { case pause, hesitation, filler, repetition }

    /// Where a pause sits relative to the words of its run.
    public enum Edge: String, Sendable, Codable { case leading, middle, trailing, whole }

    public struct Options: Hashable, Sendable {
        public var kinds: Set<FillerWords.Kind>
        public var pauses: Bool
        /// Shortest pause that counts (seconds).
        public var minPause: Double
        /// Silence kept next to speech on each side of a cut pause (seconds), so words never sound clipped.
        public var margin: Double
        public init(kinds: Set<FillerWords.Kind> = [.hesitation, .filler, .repetition], pauses: Bool = true,
                    minPause: Double = 1.0, margin: Double = 0.15) {
            self.kinds = kinds; self.pauses = pauses; self.minPause = minPause; self.margin = margin
        }
    }

    /// One thing "Remove filler words" can cut.
    public struct Candidate: Hashable, Sendable, Identifiable {
        /// Stable while the timeline doesn't change: `w:<media>:<word index>` or `p:<…>`.
        public var id: String
        public var kind: Kind
        /// Pauses only.
        public var edge: Edge?
        /// Timeline range removed.
        public var range: TimeRange
        /// The filler's text ("euh") — empty for pauses.
        public var text: String
        /// Length of the silence / word (seconds, before margins).
        public var seconds: Double
        /// Index in the `placedWords` array: the filler word itself, or the word a pause sits before
        /// (`words.count` = after the last word).
        public var anchor: Int
        /// Main-track clip the cut starts in.
        public var clip: ClipID
    }

    /// Timeline span of a placed (kept) word.
    public static func span(_ w: TranscriptEditing.PlacedWord, in tl: Timeline) -> TimeRange? {
        guard let id = w.clip, let c = tl.clip(id) else { return nil }
        let r = c.sourceRange
        guard let a = c.timelineTime(forSource: Time(w.word.start).clamped(r.start, r.end)),
              let b = c.timelineTime(forSource: Time(w.word.end).clamped(r.start, r.end)) else { return nil }
        return TimeRange(start: min(a, b), end: max(a, b))
    }

    /// Everything removable, in timeline order. `scope` = main-track clips to limit the cuts to (nil = everywhere):
    /// fillers whose word is in one of them, pauses clipped to them.
    public static func candidates(words: [TranscriptEditing.PlacedWord], transcripts: [MediaID: Transcript], timeline tl: Timeline,
                                  options: Options, scope: Set<ClipID>? = nil) -> [Candidate] {
        guard let main = tl.mainTrack else { return [] }
        var out: [Candidate] = []
        // fillers
        if !options.kinds.isEmpty {
            for (i, w) in words.enumerated() where !w.isDeleted {
                guard let k = w.filler, options.kinds.contains(k), let s = span(w, in: tl), s.duration > .zero, let clip = w.clip else { continue }
                if let scope, !scope.contains(clip) { continue }
                out.append(Candidate(id: "w:\(w.media):\(w.index)", kind: Kind(rawValue: k.rawValue) ?? .filler, edge: nil, range: s,
                                     text: w.word.text, seconds: s.duration.seconds, anchor: i, clip: clip))
            }
        }
        if options.pauses {
            out += pauses(words: words, transcripts: transcripts, main: main, timeline: tl, options: options, scope: scope)
        }
        return out.sorted { ($0.range.start, $0.anchor) < ($1.range.start, $1.anchor) }
    }

    /// Pauses only (also the grey "1.2s" chips of the transcript): `scope` nil = every pause.
    public static func pauses(words: [TranscriptEditing.PlacedWord], transcripts: [MediaID: Transcript], timeline tl: Timeline,
                              options: Options, scope: Set<ClipID>? = nil) -> [Candidate] {
        guard let main = tl.mainTrack else { return [] }
        return pauses(words: words, transcripts: transcripts, main: main, timeline: tl, options: options, scope: scope)
    }

    private static func pauses(words: [TranscriptEditing.PlacedWord], transcripts: [MediaID: Transcript], main: Track, timeline tl: Timeline,
                               options: Options, scope: Set<ClipID>?) -> [Candidate] {
        let minPause = Time(options.minPause), m = Time(options.margin)
        // kept words with their timeline spans, by clip
        var byClip: [ClipID: [(i: Int, r: TimeRange)]] = [:]
        for (i, w) in words.enumerated() where !w.isDeleted {
            guard let id = w.clip, let r = span(w, in: tl) else { continue }
            byClip[id, default: []].append((i, r))
        }
        func speech(_ c: Clip) -> Bool {
            guard !c.reversed, let id = c.mediaID, let t = transcripts[id] else { return false }
            return !t.words.isEmpty
        }
        // runs of consecutive speech clips
        var runs: [[Clip]] = []
        var cur: [Clip] = []
        for c in main.clips {
            if speech(c) { cur.append(c) } else if !cur.isEmpty { runs.append(cur); cur = [] }
        }
        if !cur.isEmpty { runs.append(cur) }
        let scopeRanges: [TimeRange]? = scope.map { s in main.clips.filter { s.contains($0.id) }.map(\.range) }
        var out: [Candidate] = []
        func add(_ id: String, _ edge: Edge, _ cut: TimeRange, silence: Time, anchor: Int) {
            guard silence >= minPause, cut.duration > .zero else { return }
            var pieces = [cut]
            if let sr = scopeRanges { pieces = sr.compactMap { $0.intersection(cut) } }
            for (k, p) in pieces.enumerated() where p.duration >= TimelineOps.minimumClipDuration {
                guard let clip = TimelineOps.mainClip(at: p.start, in: tl)?.id else { continue }
                out.append(Candidate(id: pieces.count > 1 ? "\(id)#\(k)" : id, kind: .pause, edge: edge, range: p, text: "",
                                     seconds: silence.seconds, anchor: anchor, clip: clip))
            }
        }
        for run in runs {
            let start = run.first!.start, end = run.last!.end
            let spans = run.flatMap { byClip[$0.id] ?? [] }.sorted { $0.r.start < $1.r.start }
            let key = run.first!.id.description
            guard let first = spans.first, let last = spans.last else {
                add("p:\(key):whole", .whole, TimeRange(start: start, end: end), silence: end - start, anchor: nextAnchor(after: run, words))
                continue
            }
            add("p:\(key):lead", .leading, TimeRange(start: start, end: first.r.start - m), silence: first.r.start - start, anchor: first.i)
            for (a, b) in zip(spans, spans.dropFirst()) {
                let gap = b.r.start - a.r.end
                guard gap >= minPause else { continue }
                let wa = words[a.i], wb = words[b.i]
                add("p:\(wa.media):\(wa.index)-\(wb.media):\(wb.index)", .middle, TimeRange(start: a.r.end + m, end: b.r.start - m),
                    silence: gap, anchor: b.i)
            }
            add("p:\(key):trail", .trailing, TimeRange(start: last.r.end + m, end: end), silence: end - last.r.end, anchor: last.i + 1)
        }
        return out
    }

    /// Anchor of a run without words: before the first word placed after it.
    private static func nextAnchor(after run: [Clip], _ words: [TranscriptEditing.PlacedWord]) -> Int {
        let end = run.last!.end
        return words.firstIndex { !$0.isDeleted && $0.time >= end } ?? words.count
    }

    /// Cuts the candidates out of the timeline as ONE ripple edit (captions follow, see `TranscriptEditing.rippleDelete`).
    public static func apply(_ candidates: [Candidate], in project: inout Project) throws {
        try TranscriptEditing.rippleDelete(candidates.map(\.range), in: &project)
    }

    /// Total time the candidates remove (overlaps counted once).
    public static func totalDuration(_ candidates: [Candidate]) -> Time {
        TranscriptEditing.merge(candidates.map(\.range)).reduce(.zero) { $0 + $1.duration }
    }
}
