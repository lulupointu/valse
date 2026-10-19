import Foundation

extension TimelineOps {
    /// Beat times on the timeline (absolute), from every enabled clip's marked beats (`Clip.beats`, clip-local).
    public static func beatTimes(_ tl: Timeline, excluding: Set<ClipID> = []) -> [Time] {
        var out: [Time] = []
        for t in tl.tracks {
            for c in t.clips where c.isEnabled && !excluding.contains(c.id) {
                for b in c.beats ?? [] where b >= .zero && b <= c.duration { out.append(c.start + b) }
            }
        }
        return Array(Set(out)).sorted()
    }

    /// "Match cut" (TL-036): splits the given clips at every beat that falls inside them (at least the minimum clip
    /// length from their edges), so the cuts follow the music. Returns how many splits were made.
    @discardableResult
    public static func matchCut(_ ids: Set<ClipID>, in tl: inout Timeline) throws -> Int {
        let beats = beatTimes(tl, excluding: ids)
        guard !beats.isEmpty else { throw EditError.nothingToDo }
        var count = 0
        for id in ids {
            guard let c = tl.clip(id) else { continue }
            var current = id
            for b in beats where b - c.start >= minimumClipDuration && c.end - b >= minimumClipDuration {
                guard let cur = tl.clip(current), cur.range.contains(b) else { continue }
                current = try split(current, at: b, in: &tl)
                count += 1
            }
        }
        guard count > 0 else { throw EditError.nothingToDo }
        return count
    }
}

extension TimelineOps {
    /// "Split audio track" (AU-018): the clip keeps the left channel (`leftToBoth`), a copy with the right channel
    /// (`rightToBoth`) goes on a new audio track just above; both share a group. Returns the new clip's id.
    @discardableResult
    public static func splitAudioChannels(_ id: ClipID, in tl: inout Timeline) throws -> ClipID {
        guard let loc = tl.locate(id) else { throw EditError.clipNotFound }
        guard !tl.tracks[loc.track].isLocked else { throw EditError.trackLocked }
        var c = tl.tracks[loc.track].clips[loc.clip]
        guard c.mediaID != nil, c.audio.channels == .stereo else { throw EditError.nothingToDo }
        let g = c.groupID ?? ClipGroupID()
        c.groupID = g
        c.audio.channels = .leftToBoth
        var r = c
        r.id = ClipID()
        r.audio.channels = .rightToBoth
        r.linkedTo = c.linkedTo
        r.beats = nil
        tl.tracks[loc.track].clips[loc.clip] = c
        let tid = addTrack(.audio, to: &tl, above: loc.track)
        let ti = tl.trackIndex(tid)!
        tl.tracks[ti].clips = [r]
        return r.id
    }
}
