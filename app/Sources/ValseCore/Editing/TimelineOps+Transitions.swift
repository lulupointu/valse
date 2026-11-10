import Foundation

/// Why a transition can't be placed at a cut (CapCut toasts, FEATURES TR-007).
public enum TransitionIssue: String, Error, Sendable, CaseIterable {
    /// "No continuous clips at current position": no clip right after, a gap, or not a video track.
    case noContinuousClips
    /// "Video too short": a neighbour is shorter than `TimelineOps.minTransitionNeighbour` (0.2 s).
    case clipTooShort
    public var messageKey: String { "transition.issue.\(rawValue)" }
}

/// Transitions at cuts, on the main track and on overlay (PiP) video tracks (W5, TR-004/TR-007), CapCut's model
/// (TR-MODEL-CAPCUT, Model/TransitionModel.swift): setting, changing or removing a transition never moves or trims a
/// clip and never changes the timeline's length. The transition is stored on the outgoing clip and spans
/// [cut − d/2, cut + d/2]; d is at least 0.1 s and at most twice the shorter neighbour (see `maxTransitionDuration`).
/// Invariant (all tracks, `validate`): clips never overlap.
extension TimelineOps {
    /// Shortest transition (CapCut: 0.1 s).
    public static let minTransitionDuration = Time(0.1)
    /// Shortest neighbour a transition accepts .
    public static let minTransitionNeighbour = Time(0.2)
    /// Cuts closer than this count as continuous (half a 60 fps frame).
    public static var transitionJoinTolerance: Time { Track.transitionJoinTolerance }

    /// nil when a transition can go between `id` and the next clip on its track.
    public static func transitionIssue(after id: ClipID, in tl: Timeline) -> TransitionIssue? {
        guard let loc = tl.locate(id) else { return .noContinuousClips }
        let track = tl.tracks[loc.track]
        guard track.kind == .video, loc.clip + 1 < track.clips.count else { return .noContinuousClips }
        let a = track.clips[loc.clip], b = track.clips[loc.clip + 1]
        guard isJoined(a, b) else { return .noContinuousClips }
        if a.duration < minTransitionNeighbour || b.duration < minTransitionNeighbour { return .clipTooShort }
        return nil
    }

    /// Longest transition at the cut after `id`: twice the shorter neighbour (the window is centred on the cut, so it
    /// then covers that whole clip on its side), but each side's half-window must also fit what the neighbour still has
    /// after its OTHER transition (a clip with one at each end: d_in/2 + d_out/2 <= its length, so the one being
    /// changed is limited, the other keeps its value; same rule as Premiere/FCP/Resolve, which never let the two
    /// cross). Rounded down to a whole frame of `frameRate`, never below `minTransitionDuration`.
    public static func maxTransitionDuration(after id: ClipID, in tl: Timeline, frameRate: FrameRate) -> Time {
        guard let loc = tl.locate(id), loc.clip + 1 < tl.tracks[loc.track].clips.count else { return minTransitionDuration }
        let clips = tl.tracks[loc.track].clips
        let a = clips[loc.clip], b = clips[loc.clip + 1]
        let aInHalf = loc.clip > 0 ? (clips[loc.clip - 1].transitionOut?.duration.ticks ?? 0) / 2 : 0
        let bOutHalf = (b.transitionOut?.duration.ticks ?? 0) / 2
        let limit = 2 * min(a.duration.ticks - aInHalf, b.duration.ticks - bOutHalf)
        let f = max(frameRate.frameDuration.ticks, 1)
        return max(minTransitionDuration, Time(ticks: max(limit, 0) / f * f))
    }

    /// A transition duration clamped to [0.1 s, max] and rounded to a whole frame (CapCut stores frame multiples).
    public static func quantizedTransitionDuration(_ d: Time, after id: ClipID, in tl: Timeline, frameRate: FrameRate) -> Time {
        let f = max(frameRate.frameDuration.ticks, 1)
        let q = Time(ticks: Int64((Double(d.ticks) / Double(f)).rounded()) * f)
        return min(max(q, minTransitionDuration), maxTransitionDuration(after: id, in: tl, frameRate: frameRate))
    }

    /// Whether an overlap transition at the cut after `id` needs "duplicate frames": one side has less real media
    /// than half the transition past its edge (CapCut's "Create duplicate frames for transition" notice).
    public static func transitionNeedsDuplicateFrames(after id: ClipID, in project: Project) -> Bool {
        let tl = project.timeline
        guard let loc = tl.locate(id), loc.clip + 1 < tl.tracks[loc.track].clips.count,
              let tr = tl.tracks[loc.track].clips[loc.clip].transitionOut, tr.overlaps else { return false }
        let a = tl.tracks[loc.track].clips[loc.clip], b = tl.tracks[loc.track].clips[loc.clip + 1]
        func media(_ c: Clip) -> Time? {
            guard let m = c.mediaID.flatMap(project.asset) else { return nil }
            return m.kind == .image ? .indefinite : m.duration
        }
        let half = Time(ticks: tr.duration.ticks / 2)
        let tol = Time(ticks: Time.ticksPerSecond / 1000)
        return a.tailHandle(mediaDuration: media(a)) + tol < half || b.headHandle(mediaDuration: media(b)) + tol < half
    }

    /// Left clip of the continuous cut on `track` nearest `t` (within `within`), if any.
    public static func transitionCut(near t: Time, track trackID: TrackID, in tl: Timeline, within: Time) -> Clip? {
        guard let ti = tl.trackIndex(trackID) else { return nil }
        let clips = tl.tracks[ti].clips
        guard clips.count > 1 else { return nil }
        return clips.indices.dropLast().filter { isJoined(clips[$0], clips[$0 + 1]) }
            .map { clips[$0] }
            .filter { abs(($0.end - t).ticks) <= within.ticks }
            .min { abs(($0.end - t).ticks) < abs(($1.end - t).ticks) }
    }

    /// b starts where a ends.
    static func isJoined(_ a: Clip, _ b: Clip) -> Bool { Track.isJoined(a, b) }

    /// Overlay tracks: drop transitions whose clips no longer touch (e.g. the right clip was moved away). The main
    /// track keeps them (the magnet re-joins its clips; without it the renderer ignores a transition across a gap).
    static func dropUnjoinedTransitions(_ track: inout Track) {
        guard !track.isMain else { return }
        for i in track.clips.indices where track.clips[i].transitionOut != nil {
            if i + 1 >= track.clips.count || !isJoined(track.clips[i], track.clips[i + 1]) { track.clips[i].transitionOut = nil }
        }
    }
}
