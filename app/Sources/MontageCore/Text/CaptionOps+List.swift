import Foundation

/// Caption list row actions (C4, CapCut Inspector ▸ Captions: hover ＋ = add a caption after, 🗑 = delete). Timing is
/// edited on the timeline, so neither moves the other captions.
extension CaptionOps {
    /// Adds an empty-looking caption (`text`) right after `id`, with the same look: in the gap before the next caption
    /// (up to 2 s), else in the second half of `id` (which gets shorter). Returns the new clip id.
    @discardableResult
    public static func insertAfter(_ id: ClipID, text: String, newID: ClipID = ClipID(), in project: inout Project) throws -> ClipID {
        var tl = project.timeline
        guard let loc = tl.locate(id), let src = tl.clip(id), var t = CaptionOps.text(src) else { throw EditError.clipNotFound }
        guard !tl.tracks[loc.track].isLocked else { throw EditError.trackLocked }
        let clips = tl.tracks[loc.track].clips
        let next = loc.clip + 1 < clips.count ? clips[loc.clip + 1].start : Time.indefinite
        let minD = TimelineOps.minimumClipDuration
        var c = src
        c.id = newID
        c.keyframes = [:]
        c.linkedTo = src.linkedTo
        let gap = next - src.end
        if gap >= Time(0.3) {
            c.start = src.end
            c.duration = min(gap, Time(2))
        } else {
            guard src.duration >= minD * 2 + Time(0.2) else { throw EditError.invalidTime }
            let half = src.duration * 0.5
            tl.tracks[loc.track].clips[loc.clip].duration = half
            c.start = src.start + half
            c.duration = src.duration - half
        }
        c.sourceStart = .zero
        t.string = text
        t.runs = []
        if var d = t.caption {
            d.words = []; d.translation = nil
            d.origin = .manual
            t.caption = d
        }
        c.content = .text(t)
        c.name = text
        tl.tracks[loc.track].clips.insert(c, at: loc.clip + 1)
        project.timeline = tl
        return c.id
    }

    /// Deletes one caption without moving the others (the caption track keeps its timing).
    public static func delete(_ id: ClipID, in project: inout Project) throws {
        guard let loc = project.timeline.locate(id) else { throw EditError.clipNotFound }
        guard !project.timeline.tracks[loc.track].isLocked else { throw EditError.trackLocked }
        project.timeline.tracks[loc.track].clips.remove(at: loc.clip)
        TimelineOps.removeEmptyTracks(&project.timeline)
    }
}
