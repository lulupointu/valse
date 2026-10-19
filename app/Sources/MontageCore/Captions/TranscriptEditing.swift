import Foundation

/// Transcript-based editing (AI-019/AI-020, CapCut "Transcript"): the transcript of the main-track media is shown as
/// text; deleting words ripple-deletes the matching media from the main track, restoring re-inserts it.
/// Pure and invariant-checked like `TimelineOps`.
public enum TranscriptEditing {
    /// A transcript word placed on the timeline (or deleted from it).
    public struct PlacedWord: Hashable, Sendable {
        public var word: TranscriptWord
        public var media: MediaID
        /// Index in the media transcript.
        public var index: Int
        /// Main-track clip currently showing it, nil = deleted (cut out of the timeline).
        public var clip: ClipID?
        /// Timeline time of the word start (deleted words: the cut where they would be).
        public var time: Time
        public var isDeleted: Bool { clip == nil }
        public var filler: FillerWords.Kind?
    }

    /// Words of every main-track media in timeline order. Words of a used media range that no clip shows any more
    /// are returned as deleted (struck through in the panel) at the position of the cut that removed them.
    public static func placedWords(transcripts: [MediaID: Transcript], timeline tl: Timeline) -> [PlacedWord] {
        guard let main = tl.mainTrack else { return [] }
        var out: [PlacedWord] = []
        // media ranges covered by consecutive clips of the same media → words between two pieces are "deleted"
        var i = 0
        let clips = main.clips
        while i < clips.count {
            guard let mid = clips[i].mediaID, let tr = transcripts[mid] else { i += 1; continue }
            var j = i
            while j + 1 < clips.count, clips[j + 1].mediaID == mid, !clips[j + 1].reversed { j += 1 }
            let run = clips[i...j]
            let lo = run.map(\.sourceRange.start).min()!.seconds, hi = run.map(\.sourceRange.end).max()!.seconds
            let fillers = FillerWords.classify(tr.words.map(\.text), language: tr.language)
            for (k, w) in tr.words.enumerated() {
                let m = (w.start + w.end) / 2
                guard m >= lo, m <= hi else { continue }
                let s = Time(m)
                if let c = run.first(where: { $0.sourceRange.start <= s && s < $0.sourceRange.end }) {
                    let t = c.timelineTime(forSource: Time(w.start).clamped(c.sourceRange.start, c.sourceRange.end)) ?? c.start
                    out.append(PlacedWord(word: w, media: mid, index: k, clip: c.id, time: t, filler: fillers[k]))
                } else {
                    // deleted: at the end of the last piece before it
                    let prev = run.last { $0.sourceRange.end <= s }
                    out.append(PlacedWord(word: w, media: mid, index: k, clip: nil, time: prev?.end ?? run.first!.start, filler: fillers[k]))
                }
            }
            i = j + 1
        }
        return out.sorted { ($0.time, $0.word.start) < ($1.time, $1.word.start) }
    }

    /// Pauses longer than `minimum` seconds between consecutive kept words (CapCut grey "2.40s" chips).
    public static func pauses(_ words: [PlacedWord], minimum: Double) -> [(after: Int, seconds: Double)] {
        var out: [(Int, Double)] = []
        for i in words.indices.dropLast() where !words[i].isDeleted && !words[i + 1].isDeleted && words[i].media == words[i + 1].media {
            let gap = words[i + 1].word.start - words[i].word.end
            if gap >= minimum { out.append((i, gap)) }
        }
        return out
    }

    /// Ripple-deletes timeline ranges from the main track (splits at the range edges, deletes the pieces in between;
    /// the main-track magnet closes the gaps and linked clips go with their pieces). Forces the magnet on (CapCut:
    /// "Main track magnet can't be turned off when using transcript-based editing").
    public static func rippleDelete(_ ranges: [TimeRange], in project: inout Project) throws {
        var tl = project.timeline
        tl.mainTrackMagnet = true
        let merged = merge(ranges.filter { $0.duration > .zero })
        guard !merged.isEmpty else { throw EditError.nothingToDo }
        // C4: captions follow the cuts themselves (linkage on or off): unlink them, ripple them per cut, relink after
        let captionTracks = Set(tl.tracks.filter { CaptionOps.isCaptionTrack($0) && !$0.isLocked }.map(\.id))
        var wasLinked = Set<ClipID>()
        for ti in tl.tracks.indices where captionTracks.contains(tl.tracks[ti].id) {
            for ci in tl.tracks[ti].clips.indices where tl.tracks[ti].clips[ci].linkedTo != nil {
                wasLinked.insert(tl.tracks[ti].clips[ci].id)
                tl.tracks[ti].clips[ci].linkedTo = nil
            }
        }
        // right to left so earlier ranges keep their timeline positions
        for r in merged.reversed() {
            guard let mi = tl.mainTrackIndex else { throw EditError.trackNotFound }
            // how far what follows the cut moves = how far the end of the main track moves
            let oldEnd = tl.tracks[mi].clips.last?.end ?? .zero
            for c in tl.tracks[mi].clips where c.range.contains(r.start) && r.start - c.start >= TimelineOps.minimumClipDuration {
                _ = try? TimelineOps.split(c.id, at: r.start, in: &tl)
            }
            for c in tl.tracks[mi].clips where c.range.contains(r.end) && r.end - c.start >= TimelineOps.minimumClipDuration
                && c.end - r.end >= TimelineOps.minimumClipDuration {
                _ = try? TimelineOps.split(c.id, at: r.end, in: &tl)
            }
            let tol = TimelineOps.minimumClipDuration
            let doomed = Set(tl.tracks[mi].clips.filter { $0.start >= r.start - tol && $0.end <= r.end + tol }.map(\.id))
            if !doomed.isEmpty { try TimelineOps.delete(doomed, in: &tl) }
            let newEnd = tl.mainTrackIndex.flatMap { tl.tracks[$0].clips.last?.end } ?? .zero
            let delta = r.end < oldEnd ? newEnd - oldEnd : -r.duration
            rippleCaptions(cut: r, shift: delta, tracks: captionTracks, in: &tl)
        }
        if tl.linkage {
            for ti in tl.tracks.indices where captionTracks.contains(tl.tracks[ti].id) {
                for ci in tl.tracks[ti].clips.indices where wasLinked.contains(tl.tracks[ti].clips[ci].id) {
                    tl.tracks[ti].clips[ci].linkedTo = TimelineOps.mainClip(at: tl.tracks[ti].clips[ci].start, in: tl)?.id
                }
            }
        }
        CaptionOps.resolveOverlaps(in: &tl)   // back-to-back captions spanning a cut
        TimelineOps.removeEmptyTracks(&tl)
        project.timeline = tl
    }

    /// Captions over a cut lose the words spoken in it (text + timings), captions inside it go, later ones move by
    /// `shift` (C4: auto captions stay in sync after "Remove filler words" / transcript deletes).
    static func rippleCaptions(cut r: TimeRange, shift: Time, tracks: Set<TrackID>, in tl: inout Timeline) {
        let tol = TimelineOps.minimumClipDuration
        for ti in tl.tracks.indices where tracks.contains(tl.tracks[ti].id) {
            var kept: [Clip] = []
            for var c in tl.tracks[ti].clips {
                if c.end <= r.start + tol / 2 { kept.append(c); continue }
                if c.start >= r.end - tol / 2 { c.start = max(.zero, c.start + shift); kept.append(c); continue }
                if c.start >= r.start - tol, c.end <= r.end + tol { continue }   // said entirely in the cut
                // overlaps the cut: drop the words in it, close the gap inside the clip
                let a = max(c.start, r.start), b = min(c.end, r.end)
                let cs = c.sourceStart + (a - c.start), ce = c.sourceStart + (b - c.start)   // cut in content time
                if case .text(var t) = c.content, var data = t.caption {
                    let tokens = TextTokenizer.words(in: t.string)
                    if data.words.count == tokens.count, !tokens.isEmpty {
                        var s: String
                        var words: [CaptionWord] = []
                        let u = Array(t.string.utf16)
                        var drop: [TextSpan] = []
                        for (k, w) in data.words.enumerated() {
                            let mid = Time(ticks: (w.start.ticks + w.end.ticks) / 2)
                            if mid >= cs && mid < ce { drop.append(tokens[k]); continue }
                            var w = w
                            if c.start < r.start, w.start >= ce { w.start = w.start - (ce - cs); w.end = w.end - (ce - cs) }
                            words.append(w)
                        }
                        if words.isEmpty { continue }   // nothing left to show
                        var units = u
                        for sp in drop.reversed() {
                            var lo = sp.location, hi = sp.end
                            // take the following space (or the preceding one at the end)
                            if hi < units.count, units[hi] == 0x20 { hi += 1 } else if lo > 0, units[lo - 1] == 0x20 { lo -= 1 }
                            units.removeSubrange(lo..<hi)
                        }
                        s = String(utf16CodeUnits: units, count: units.count).trimmingCharacters(in: .whitespacesAndNewlines)
                        t.setString(s)
                        data.words = words
                        t.caption = data
                        c.content = .text(t)
                        c.name = s
                    }
                }
                if c.start < r.start {
                    c.duration = c.duration - (b - a)   // spans the start (and maybe the whole cut)
                } else {
                    c.sourceStart = c.sourceStart + (b - c.start)   // head trimmed: words stay on their audio
                    c.duration = c.end - b
                    c.start = max(.zero, r.end + shift)
                }
                if c.duration >= tol { kept.append(c) }
            }
            tl.tracks[ti].clips = kept.sorted { $0.start < $1.start }
        }
    }

    /// Deletes words (by placement) from the timeline: their media spans become ripple cuts. Consecutive words are cut
    /// as one range including the pause between them.
    public static func deleteWords(_ words: [PlacedWord], in project: inout Project) throws {
        var ranges: [TimeRange] = []
        for w in words where !w.isDeleted {
            guard let id = w.clip, let c = project.timeline.clip(id) else { continue }
            let s = c.timelineTime(forSource: Time(w.word.start).clamped(c.sourceRange.start, c.sourceRange.end)) ?? c.start
            let e = c.timelineTime(forSource: Time(w.word.end).clamped(c.sourceRange.start, c.sourceRange.end)) ?? c.end
            ranges.append(TimeRange(start: min(s, e), end: max(s, e)))
        }
        // join neighbours closer than 0.25 s (the pause between deleted words goes too)
        let joined = merge(ranges, slack: Time(0.25))
        try rippleDelete(joined, in: &project)
    }

    /// Restores deleted words: re-inserts the media span (from the first to the last word) at the cut where it was
    /// removed, as a new main-track piece (inherits the neighbouring piece's settings).
    public static func restore(_ words: [PlacedWord], in project: inout Project) throws {
        let del = words.filter(\.isDeleted).sorted { $0.word.start < $1.word.start }
        guard let first = del.first, let last = del.last, del.allSatisfy({ $0.media == first.media }) else { throw EditError.nothingToDo }
        var tl = project.timeline
        guard let mi = tl.mainTrackIndex else { throw EditError.trackNotFound }
        let pieces = tl.tracks[mi].clips.filter { $0.mediaID == first.media }
        let s = Time(first.word.start), e = Time(last.word.end)
        // template: the piece just before the gap (or after)
        guard let before = pieces.last(where: { $0.sourceRange.end <= s + TimelineOps.minimumClipDuration }) ?? pieces.first else { throw EditError.clipNotFound }
        // extend the span to the neighbouring pieces' edges when the gap is small (restore the pause too)
        let after = pieces.first { $0.sourceRange.start >= e - TimelineOps.minimumClipDuration }
        let a = before.sourceRange.end <= s && (s - before.sourceRange.end).seconds < 0.6 ? before.sourceRange.end : s
        let b = after.map { $0.sourceRange.start >= e && ($0.sourceRange.start - e).seconds < 0.6 ? $0.sourceRange.start : e } ?? e
        guard b > a else { throw EditError.nothingToDo }
        var piece = before
        piece.id = ClipID()
        piece.sourceStart = a
        piece.speed = .constant(before.speed.averageRate)
        piece.duration = (b - a) / before.speed.averageRate
        piece.keyframes = [:]
        piece.transitionOut = nil
        piece.animations = ClipAnimations()
        piece.audio.fadeIn = .zero; piece.audio.fadeOut = .zero
        let at = before.sourceRange.end <= s ? before.end : before.start
        // ripple insert on the magnetic main track: later pieces (and their linked clips) move right
        tl.mainTrackMagnet = true
        let old = TimelineOps.mainStarts(tl)
        piece.start = at
        let idx = tl.tracks[mi].clips.firstIndex { $0.start >= at } ?? tl.tracks[mi].clips.count
        tl.tracks[mi].clips.insert(piece, at: idx)
        TimelineOps.compactMain(&tl, previousStarts: old)
        project.timeline = tl
    }

    static func merge(_ ranges: [TimeRange], slack: Time = .zero) -> [TimeRange] {
        let s = ranges.sorted { $0.start < $1.start }
        var out: [TimeRange] = []
        for r in s {
            if let l = out.last, r.start <= l.end + slack {
                out[out.count - 1] = TimeRange(start: l.start, duration: max(l.end, r.end) - l.start)
            } else { out.append(r) }
        }
        return out
    }
}
