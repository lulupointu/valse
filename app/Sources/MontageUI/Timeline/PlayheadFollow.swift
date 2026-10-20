import Foundation

/// U1-6: how the timeline follows the playhead during playback. Pure so it can be unit-tested (`PlayheadFollowTests`).
///
/// Owner: "I can always scroll freely. When I press play, if the playing mark is not on screen, move the timeline: mark
/// off-screen to the left → the line at the left of the screen + padding; off-screen to the right → the line at the right
/// of the screen − padding." While playing (CapCut's page follow): when the line reaches the right edge the timeline jumps
/// one page so the line is back at the left + padding. A wheel / trackpad / scrollbar scroll during playback turns the
/// follow off until the next play or seek — the timeline never pulls the user back (before U1 it snapped back to the
/// playhead on every frame, so the user couldn't scroll the line out of view).
struct PlayheadFollow: Equatable {
    /// Distance between the playhead and the visible edge after a follow scroll (points).
    static let padding: Double = 40
    /// A forward step larger than this between two updates is a seek, not playback (seconds of media time).
    static let seekJump: Double = 1.0

    /// The user scrolled the timeline during this playback: no automatic scroll until the next play / seek.
    private(set) var manual = false
    private var wasPlaying = false
    private var lastPlayhead: Double?

    /// A user scroll (wheel, trackpad, scrollbar, pinch). Only matters while playing.
    mutating func userScrolled(isPlaying: Bool) {
        if isPlaying { manual = true }
    }

    /// New left-edge time for the timeline, or nil to leave it where it is.
    /// - Parameters: `visibleWidth` = clip area width in points (without the track headers).
    mutating func update(isPlaying: Bool, playhead: Double, scrollTime: Double, pixelsPerSecond: Double,
                         visibleWidth: Double) -> Double? {
        let started = isPlaying && !wasPlaying
        let jumped = isPlaying && !started && lastPlayhead.map { playhead < $0 - 1e-6 || playhead > $0 + Self.seekJump } == true
        wasPlaying = isPlaying
        lastPlayhead = isPlaying ? playhead : nil
        guard isPlaying else { manual = false; return nil }
        guard pixelsPerSecond > 0, visibleWidth > 0 else { return nil }
        if started || jumped { manual = false }
        guard !manual else { return nil }
        let span = visibleWidth / pixelsPerSecond
        let pad = min(Self.padding, visibleWidth / 4) / pixelsPerSecond
        let end = scrollTime + span
        if playhead < scrollTime {   // off-screen to the left (or a loop back to the start)
            return max(0, playhead - pad)
        }
        if started || jumped {
            // off-screen to the right when playback starts / after a seek: line at the right edge − padding
            return playhead > end ? max(0, playhead - span + pad) : nil
        }
        // playing: the line reached the right edge → next page, line at the left + padding
        return playhead >= end ? max(0, playhead - pad) : nil
    }
}
