import Foundation

/// Reverse and freeze-frame edits (W9). Pure, invariant-preserving like the rest of `TimelineOps`.
extension TimelineOps {
    /// CapCut freeze default length.
    public static let freezeDuration = Time(3)

    /// Sets "Reverse" on a media clip. Keyframes are mirrored in time (CapCut behaviour) so animations still read
    /// the same way relative to the reversed picture. The source extent is unchanged.
    public static func setReversed(_ id: ClipID, _ reversed: Bool, in tl: inout Timeline) throws {
        guard let loc = tl.locate(id) else { throw EditError.clipNotFound }
        guard !tl.tracks[loc.track].isLocked else { throw EditError.trackLocked }
        var c = tl.tracks[loc.track].clips[loc.clip]
        guard c.mediaID != nil, c.reversed != reversed else { throw EditError.nothingToDo }
        c.reversed = reversed
        for (k, track) in c.keyframes {
            c.keyframes[k] = KeyframeTrack(track.keyframes.map { var f = $0; f.time = c.duration - f.time; return f })
        }
        tl.tracks[loc.track].clips[loc.clip] = c
    }

    /// Freeze frame at timeline time `t`: splits `id` at `t` (when strictly inside) and inserts a still clip of
    /// `duration` showing `still` (the frame grabbed at `clip.sourceTime(at: t)`) between the halves. Everything after
    /// it on that track moves right by `duration` (main track: magnet/linkage handle followers). The still inherits the
    /// clip's look at that instant (transform, opacity, blend, crop, mask, effects, keyframes resolved). Returns the
    /// freeze clip id.
    @discardableResult
    public static func insertFreeze(of id: ClipID, at t: Time, still: MediaAsset, duration: Time = freezeDuration,
                                    in project: inout Project) throws -> ClipID {
        guard let loc = project.timeline.locate(id) else { throw EditError.clipNotFound }
        guard !project.timeline.tracks[loc.track].isLocked else { throw EditError.trackLocked }
        let original = project.timeline.tracks[loc.track].clips[loc.clip]
        guard let mid = original.mediaID, project.asset(mid)?.kind == .video else { throw EditError.incompatibleTrack }
        guard original.range.contains(t) || t == original.end else { throw EditError.invalidTime }
        if project.asset(still.id) == nil { project.media.append(still) }

        var tl = project.timeline
        let trackID = tl.tracks[loc.track].id
        let local = (t - original.start).clamped(.zero, original.duration)
        // split when strictly inside; otherwise the freeze goes before/after the clip
        var insertAt = t
        if local >= minimumClipDuration, original.duration - local >= minimumClipDuration {
            try split(id, at: t, in: &tl)
        } else if local < minimumClipDuration {
            insertAt = original.start
        } else {
            insertAt = original.end
        }
        let oldMainStarts = mainStarts(tl)
        let ti = tl.trackIndex(trackID)!

        let r = original.resolved(at: local)
        var f = Clip(content: .media(still.id), start: insertAt, duration: max(duration, minimumClipDuration))
        f.transform = r.transform; f.opacity = r.opacity; f.blendMode = r.blendMode; f.crop = r.crop; f.mask = r.mask
        f.effects = r.effects; f.chromaKey = r.chromaKey; f.matte = nil
        f.audio.isMuted = true
        f.linkedTo = original.linkedTo
        f.freezeOf = FreezeOrigin(media: mid, sourceTime: original.sourceTime(at: t))

        if tl.tracks[ti].isMain && tl.mainTrackMagnet {
            // drop the transition at the cut (neighbours changed) and let compaction ripple
            if let li = tl.tracks[ti].clips.lastIndex(where: { $0.end <= insertAt + Time(ticks: 1) && $0.start < insertAt }) {
                tl.tracks[ti].clips[li].transitionOut = nil
            }
            let idx = tl.tracks[ti].clips.firstIndex { $0.start >= insertAt } ?? tl.tracks[ti].clips.count
            tl.tracks[ti].clips.insert(f, at: idx)
            compactMain(&tl, previousStarts: oldMainStarts)
        } else {
            for ci in tl.tracks[ti].clips.indices where tl.tracks[ti].clips[ci].start >= insertAt {
                tl.tracks[ti].clips[ci].start += f.duration
            }
            if let li = tl.tracks[ti].clips.lastIndex(where: { $0.start < insertAt }) { tl.tracks[ti].clips[li].transitionOut = nil }
            tl.tracks[ti].clips.append(f)
            tl.tracks[ti].sortClips()
        }
        project.timeline = tl
        return f.id
    }
}
