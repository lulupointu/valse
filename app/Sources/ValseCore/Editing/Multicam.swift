import Foundation

/// Multi-camera editing (TL-024): "Create multi-camera clip" turns the selected videos into one compound clip whose
/// nested timeline holds one angle per track, synced (by audio, by their timeline positions, or by their starts).
/// Exactly one angle is enabled at any time: "switch to angle k at t" splits every angle at t and enables angle k
/// until the next cut, so the result is an ordinary nested edit (renders, exports, undoes like anything else).
/// The enabled angle also provides the sound.
public enum Multicam {
    public static let maxAngles = 9

    /// `starts`: each clip's position inside the multicam (sync result); the earliest becomes 0.
    @discardableResult
    public static func create(_ ids: [ClipID], starts: [ClipID: Time], name: String, in p: inout Project) throws -> ClipID {
        let clips = ids.compactMap { p.timeline.clip($0) }
        guard clips.count >= 2, clips.count <= maxAngles, clips.allSatisfy({ $0.mediaID.flatMap(p.asset)?.kind == .video }) else {
            throw EditError.nothingToDo
        }
        let cid = try TimelineOps.createCompound(Set(ids), name: name, in: &p)
        guard case .compound(let compID)? = p.timeline.clip(cid)?.content,
              let ci = p.compounds?.firstIndex(where: { $0.id == compID }) else { throw EditError.nothingToDo }
        let base = clips.map { starts[$0.id] ?? .zero }.min() ?? .zero
        var nested = Timeline()
        nested.mainTrackMagnet = false
        let mi = nested.mainTrackIndex!
        for (k, c) in clips.enumerated() {
            var n = c
            n.start = (starts[c.id] ?? .zero) - base
            n.linkedTo = nil; n.groupID = nil; n.transitionOut = nil
            n.isEnabled = k == 0
            if k == 0 { nested.tracks[mi].clips = [n] } else { nested.tracks.append(Track(kind: .video, clips: [n])) }
        }
        p.compounds![ci].timeline = nested
        p.compounds![ci].multicam = true
        // the multicam clip spans its angles
        if let loc = p.timeline.locate(cid) {
            p.timeline.tracks[loc.track].clips[loc.clip].sourceStart = .zero
            p.timeline.tracks[loc.track].clips[loc.clip].duration = nested.duration
            p.timeline.tracks[loc.track].clips[loc.clip].speed = .normal
            if p.timeline.tracks[loc.track].isMain && p.timeline.mainTrackMagnet { TimelineOps.compactMain(&p.timeline) }
        }
        return cid
    }

    /// Angle tracks of a multicam timeline (main first, then the video tracks bottom → top).
    public static func angleTracks(_ tl: Timeline) -> [Int] {
        let mi = tl.mainTrackIndex ?? 0
        return [mi] + tl.tracks.indices.filter { $0 != mi && tl.tracks[$0].kind == .video }
    }

    public static func compound(of clipID: ClipID, in p: Project) -> CompoundClip? {
        guard case .compound(let id)? = p.timeline.clip(clipID)?.content, let c = p.compound(id), c.multicam == true else { return nil }
        return c
    }

    /// Inner (multicam) time of parent time `t` on clip `c`.
    static func inner(_ c: Clip, _ t: Time) -> Time { c.sourceStart + (t - c.start) * max(c.speed.averageRate, 0.01) }

    /// The enabled angle at parent time `t` of multicam clip `clipID`.
    public static func activeAngle(_ clipID: ClipID, at t: Time, in p: Project) -> Int? {
        guard let comp = compound(of: clipID, in: p), let c = p.timeline.clip(clipID) else { return nil }
        let it = inner(c, t)
        for (k, ti) in angleTracks(comp.timeline).enumerated() {
            if comp.timeline.tracks[ti].clips.contains(where: { $0.isEnabled && $0.range.contains(it) }) { return k }
        }
        return nil
    }

    /// Switch to angle `k` from parent time `t` until the next cut.
    public static func switchAngle(_ clipID: ClipID, to k: Int, at t: Time, in p: inout Project) throws {
        guard let comp = compound(of: clipID, in: p), let c = p.timeline.clip(clipID),
              let ci = p.compounds?.firstIndex(where: { $0.id == comp.id }) else { throw EditError.nothingToDo }
        var tl = comp.timeline
        let angles = angleTracks(tl)
        guard angles.indices.contains(k) else { throw EditError.nothingToDo }
        let it = inner(c, t)
        let eps = Time(ticks: 1000)
        // cut every angle at t
        for ti in angles {
            if let x = tl.tracks[ti].clips.first(where: { $0.range.contains(it) }),
               it - x.start >= TimelineOps.minimumClipDuration, x.end - it >= TimelineOps.minimumClipDuration {
                _ = try TimelineOps.split(x.id, at: it, in: &tl)
            }
        }
        // until the next cut of any angle
        let next = angles.flatMap { tl.tracks[$0].clips.map(\.start) }.filter { $0 > it + eps }.min() ?? .indefinite
        var changed = false
        for (ai, ti) in angles.enumerated() {
            for j in tl.tracks[ti].clips.indices {
                let s = tl.tracks[ti].clips[j].start
                // pieces starting in [t, next), or the piece covering t when it could not be split (t near an edge)
                let covers = tl.tracks[ti].clips[j].range.contains(it)
                guard (s >= it - eps && s < next) || covers else { continue }
                let on = ai == k
                if tl.tracks[ti].clips[j].isEnabled != on { tl.tracks[ti].clips[j].isEnabled = on; changed = true }
            }
        }
        guard changed else { throw EditError.nothingToDo }
        p.compounds![ci].timeline = tl
    }

    /// Source of angle `k` at parent time `t` (for the angle viewer thumbnails): the media and its source time.
    public static func angleSource(_ clipID: ClipID, angle k: Int, at t: Time, in p: Project) -> (MediaID, Time)? {
        guard let comp = compound(of: clipID, in: p), let c = p.timeline.clip(clipID) else { return nil }
        let angles = angleTracks(comp.timeline)
        guard angles.indices.contains(k) else { return nil }
        let it = inner(c, t)
        let clips = comp.timeline.tracks[angles[k]].clips
        guard let x = clips.first(where: { $0.range.contains(it) }) ?? clips.last(where: { $0.start <= it }) ?? clips.first,
              let m = x.mediaID else { return nil }
        return (m, x.sourceTime(at: min(max(it, x.start), x.end)))
    }
}
