import Foundation

/// Ripple cuts of timeline ranges out of the main track, with captions following the cuts (EditPilot "remove
/// silences"). What is left of the former transcript-based editing (W10, removed in FB-01). Pure, like `TimelineOps`.
public enum RippleCut {
    /// Ripple-deletes timeline ranges from the main track (splits at the range edges, deletes the pieces in between;
    /// the main-track magnet closes the gaps and linked clips go with their pieces). Forces the magnet on.
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
    /// `shift` (auto captions stay in sync with the cut).
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
