import Foundation

extension QuickCut {
    /// Applies a plan as one edit (owner rules, docs/QUICK_CUT.md §2):
    /// - main-track clips: the slices ripple out of the main track (`RippleCut`: captions follow, the main track closes
    ///   up, linked clips move with their pieces); the audio extracted from a main clip is cut at the same places;
    /// - clips on other tracks: cut and closed up inside their own footprint (later items on the track don't move).
    /// Linked items (titles, stickers, overlays…) that start inside a removed main-track range are kept, at the cut point.
    /// Throws `EditError.nothingToDo` when the plan removes nothing from this project.
    public static func apply(_ plan: QuickCutPlan, to target: inout Project) throws {
        var project = target   // untouched when this throws
        var tl = project.timeline
        let tol = TimelineOps.minimumClipDuration
        var mainRanges: [TimeRange] = []
        var cutElsewhere = 0
        var removedWithMain = Set<ClipID>()   // pieces of extracted audio the ripple deletes with their main pieces
        for item in plan.items {
            guard let loc = tl.locate(item.target.primary), !tl.tracks[loc.track].isLocked else { continue }
            let primary = tl.tracks[loc.track].clips[loc.clip]
            let isMain = tl.tracks[loc.track].isMain
            let slices = clipped(item.slices, to: primary.range)
            guard !slices.isEmpty else { continue }
            if isMain { mainRanges += slices } else { cutInFootprint(primary.id, slices, in: &tl); cutElsewhere += 1 }
            for m in item.target.members where m != primary.id {
                guard let ml = tl.locate(m), !tl.tracks[ml.track].isLocked else { continue }
                let c = tl.tracks[ml.track].clips[ml.clip]
                let own = clipped(slices, to: c.range)
                guard !own.isEmpty else { continue }
                if isMain, c.linkedTo == primary.id, TimelineOps.followsMain(c, on: tl.tracks[ml.track].kind, in: tl) {
                    // split only: the ripple deletes the inner pieces with the main pieces they are linked to
                    removedWithMain.formUnion(splitPieces(m, at: own, in: &tl).inside)
                } else {
                    cutInFootprint(m, own, in: &tl)
                    cutElsewhere += 1
                }
            }
        }
        guard !mainRanges.isEmpty || cutElsewhere > 0 else { throw EditError.nothingToDo }
        if !mainRanges.isEmpty {
            let merged = RippleCut.merge(mainRanges)
            // linked items starting inside a removed range would be deleted with it: unlink them, place them afterwards
            var kept: [(id: ClipID, range: Int)] = []
            for ti in tl.tracks.indices where !tl.tracks[ti].isMain && !tl.tracks[ti].isLocked && !CaptionOps.isCaptionTrack(tl.tracks[ti]) {
                let kind = tl.tracks[ti].kind
                for ci in tl.tracks[ti].clips.indices {
                    let c = tl.tracks[ti].clips[ci]
                    guard c.linkedTo != nil, !removedWithMain.contains(c.id), TimelineOps.followsMain(c, on: kind, in: tl),
                          let k = merged.firstIndex(where: { c.start >= $0.start - tol && c.start < $0.end }) else { continue }
                    tl.tracks[ti].clips[ci].linkedTo = nil
                    kept.append((c.id, k))
                }
            }
            project.timeline = tl
            try RippleCut.rippleDelete(merged, in: &project)
            tl = project.timeline
            for (id, k) in kept {
                let removedBefore = merged[..<k].reduce(Time.zero) { $0 + $1.duration }
                place(id, at: max(.zero, merged[k].start - removedBefore), in: &tl)
            }
            separateOverlaps(in: &tl)
        }
        TimelineOps.removeEmptyTracks(&tl)
        project.timeline = tl
        target = project
    }

    /// Splits clip `id` at the edges of `slices` (timeline, sorted, inside the clip). Returns the pieces outside the
    /// slices (`kept`) and inside them (`inside`). Edges closer than the minimum clip length to a piece's edge are not
    /// split (the slice then takes the sliver with it).
    static func splitPieces(_ id: ClipID, at slices: [TimeRange], in tl: inout Timeline) -> (kept: [ClipID], inside: [ClipID]) {
        let minD = TimelineOps.minimumClipDuration
        var cur: ClipID? = id
        var kept: [ClipID] = [], inside: [ClipID] = []
        for s in slices.reversed() {
            guard let cid = cur, let c = tl.clip(cid) else { break }
            if s.start >= c.end { continue }
            if s.end - c.start >= minD, c.end - s.end >= minD, let r = try? TimelineOps.split(cid, at: s.end, in: &tl) {
                kept.append(r)
            }
            if s.start - c.start >= minD, let r = try? TimelineOps.split(cid, at: s.start, in: &tl) {
                inside.append(r)
            } else {
                inside.append(cid)   // the slice reaches the clip's start: nothing left on its left
                cur = nil
            }
        }
        if let cur { kept.append(cur) }
        return (kept, inside)
    }

    /// Cuts `slices` out of a clip and closes the pieces up from the clip's start, inside its own footprint.
    static func cutInFootprint(_ id: ClipID, _ slices: [TimeRange], in tl: inout Timeline) {
        guard let loc = tl.locate(id) else { return }
        let original = tl.tracks[loc.track].clips[loc.clip]
        let (kept, inside) = splitPieces(id, at: slices, in: &tl)
        let ti = loc.track
        let drop = Set(inside), keep = Set(kept)
        tl.tracks[ti].clips.removeAll { drop.contains($0.id) }
        var t = original.start
        let relink = original.linkedTo != nil && tl.linkage
        let order = tl.tracks[ti].clips.indices.filter { keep.contains(tl.tracks[ti].clips[$0].id) }
            .sorted { tl.tracks[ti].clips[$0].start < tl.tracks[ti].clips[$1].start }
        for ci in order {
            tl.tracks[ti].clips[ci].start = t
            t += tl.tracks[ti].clips[ci].duration
            if relink { tl.tracks[ti].clips[ci].linkedTo = TimelineOps.mainClip(at: tl.tracks[ti].clips[ci].start, in: tl)?.id }
        }
        tl.tracks[ti].sortClips()
    }

    /// Linked clips ripple with the main piece under their start: a clip reaching past a later cut stays put while the
    /// next one on its track moves left onto it. Such a later clip keeps its time and goes to a free track (`place`).
    static func separateOverlaps(in tl: inout Timeline) {
        for id in tl.tracks.filter({ !$0.isMain && !$0.isLocked && !CaptionOps.isCaptionTrack($0) }).map(\.id) {
            while let ti = tl.trackIndex(id) {
                let clips = tl.tracks[ti].clips
                guard let i = clips.indices.dropFirst().first(where: {
                    clips[$0].start < clips[$0 - 1].end - (clips[$0 - 1].transitionOut?.duration ?? .zero)
                }) else { break }
                place(clips[i].id, at: clips[i].start, in: &tl)
            }
        }
    }

    /// Moves a (non-main) clip to `start`: on its own track when it fits there, else on another unlocked track of the
    /// same kind, else on a new track above it. Relinks it to the main clip under it (linkage on).
    static func place(_ id: ClipID, at start: Time, in tl: inout Timeline) {
        guard let loc = tl.locate(id) else { return }
        var c = tl.tracks[loc.track].clips.remove(at: loc.clip)
        let kind = tl.tracks[loc.track].kind
        c.start = start
        var ti = loc.track
        if !TimelineOps.fits(c.range, in: tl.tracks[ti]) {
            if let other = tl.tracks.indices.first(where: { $0 != loc.track && !tl.tracks[$0].isMain && tl.tracks[$0].kind == kind
                && !tl.tracks[$0].isLocked && TimelineOps.fits(c.range, in: tl.tracks[$0]) }) {
                ti = other
            } else {
                let nid = TimelineOps.addTrack(kind, to: &tl, above: loc.track)
                ti = tl.trackIndex(nid) ?? loc.track
            }
        }
        if tl.linkage { c.linkedTo = TimelineOps.mainClip(at: c.start, in: tl)?.id }
        tl.tracks[ti].clips.append(c)
        tl.tracks[ti].sortClips()
    }
}

/// Quick cut as one undoable edit ("Quick cut" in the Edit menu's undo name).
public struct ApplyQuickCut: EditCommand {
    public let nameKey = "cmd.quickCut"
    public let plan: QuickCutPlan
    public init(_ plan: QuickCutPlan) { self.plan = plan }
    public func apply(to project: inout Project) throws { try QuickCut.apply(plan, to: &project) }
}
