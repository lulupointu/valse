import Foundation

/// Why a transition can't be placed at a cut (CapCut toasts, FEATURES TR-007).
public enum TransitionIssue: String, Error, Sendable, CaseIterable {
    /// "No continuous clips at current position": no clip right after, a gap, or not a video track.
    case noContinuousClips
    /// "Video too short": a neighbour is shorter than `TimelineOps.minTransitionNeighbour`.
    case clipTooShort
    public var messageKey: String { "transition.issue.\(rawValue)" }
}

/// Transitions at cuts, on the main track and on overlay (PiP) video tracks (W5, TR-004/TR-007).
///
/// Main track: neighbours overlap by the transition duration and the magnet repacks the track. Overlay tracks have no
/// magnet: setting a transition of duration d slides the right clip left so it overlaps the left one by exactly d
/// (later clips keep their place); removing it slides the right clip back, pushing contiguous followers if needed.
/// Invariant (all tracks, `validate`): clip i may overlap clip i+1 only by `clips[i].transitionOut.duration`.
extension TimelineOps {
    /// Shortest neighbour a transition accepts (transitions are 0.1 s minimum and at most half of either side).
    public static let minTransitionNeighbour = Time(0.2)
    /// Cuts closer than this count as continuous (half a 60 fps frame).
    public static let transitionJoinTolerance = Time(ticks: Time.ticksPerSecond / 120)

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

    /// Left clip of the continuous cut on `track` nearest `t` (within `within`), if any.
    public static func transitionCut(near t: Time, track trackID: TrackID, in tl: Timeline, within: Time) -> Clip? {
        guard let ti = tl.trackIndex(trackID) else { return nil }
        let clips = tl.tracks[ti].clips
        guard clips.count > 1 else { return nil }
        return clips.indices.dropLast().filter { isJoined(clips[$0], clips[$0 + 1]) }
            .map { clips[$0] }
            .filter { abs(($0.end - ($0.transitionOut?.duration ?? .zero) / 2.0 - t).ticks) <= within.ticks }
            .min { abs(($0.end - t).ticks) < abs(($1.end - t).ticks) }
    }

    /// b starts where a ends (or inside a by exactly a's transition).
    static func isJoined(_ a: Clip, _ b: Clip) -> Bool {
        abs((b.start - (a.end - (a.transitionOut?.duration ?? .zero))).ticks) <= transitionJoinTolerance.ticks
    }

    /// Overlay-track part of `setTransition`.
    static func setOverlayTransition(track ti: Int, clip ci: Int, _ transition: TransitionInstance?, in tl: inout Timeline) throws {
        var track = tl.tracks[ti]
        guard ci + 1 < track.clips.count else { track.clips[ci].transitionOut = nil; tl.tracks[ti] = track; return }
        let a = track.clips[ci]
        let joined = isJoined(a, track.clips[ci + 1])
        if var tr = transition {
            guard track.kind == .video else { throw EditError.incompatibleTrack }
            guard joined else { throw EditError.invalidTime }
            let b = track.clips[ci + 1]
            let maxD = min(a.duration, b.duration) / 2.0
            tr.duration = min(tr.duration, maxD)
            track.clips[ci].transitionOut = tr
            track.clips[ci + 1].start = max(.zero, a.end - tr.duration)
        } else {
            track.clips[ci].transitionOut = nil
            if joined { track.clips[ci + 1].start = a.end }
        }
        pushOverlaps(&track, from: ci + 1)
        tl.tracks[ti] = track
    }

    /// Slides clips right (from index `i`) until no clip overlaps its predecessor beyond the allowed transition.
    static func pushOverlaps(_ track: inout Track, from i: Int) {
        guard i > 0, i < track.clips.count else { return }
        for k in max(i, 1)..<track.clips.count {
            let p = track.clips[k - 1]
            let earliest = p.end - (p.transitionOut?.duration ?? .zero)
            if track.clips[k].start < earliest { track.clips[k].start = earliest } else if k > i { break }
        }
    }

    /// Overlay tracks after a clamp: keep each transition's overlap equal to its duration; drop transitions whose
    /// clips no longer touch (e.g. the right clip was moved away).
    static func normalizeOverlayTransitions(_ track: inout Track) {
        guard !track.isMain else { return }
        for i in track.clips.indices {
            guard let tr = track.clips[i].transitionOut else { continue }
            guard i + 1 < track.clips.count else { track.clips[i].transitionOut = nil; continue }
            let a = track.clips[i], b = track.clips[i + 1]
            if b.start > a.end + transitionJoinTolerance { track.clips[i].transitionOut = nil; continue }
            let want = a.end - tr.duration
            if b.start != want {
                track.clips[i + 1].start = max(.zero, want)
                pushOverlaps(&track, from: i + 2)
            }
        }
    }
}
