import Foundation

/// CapCut's transition model (TR-MODEL-CAPCUT): a transition never moves or trims clips. It is stored on the outgoing
/// clip (`Clip.transitionOut`) and covers the window [cut − d/2, cut + d/2] centred on the cut between two butted
/// clips. Overlap transitions (`TransitionInstance.overlaps`) show both clips over the whole window: the outgoing clip
/// keeps playing past its out point (its tail handle) and the incoming one starts before its in point (head handle);
/// where the media has no such handle the edge frame is held ("duplicate frames", measured on CapCut's exports:
/// a freeze, not a time shift). Non-overlap transitions play their first half over the outgoing clip only and their
/// second half over the incoming clip only.
extension Track {
    /// Cuts closer than this count as continuous (half a 60 fps frame).
    public static let transitionJoinTolerance = Time(ticks: Time.ticksPerSecond / 120)

    /// `b` starts where `a` ends (a continuous cut that can carry a transition).
    public static func isJoined(_ a: Clip, _ b: Clip) -> Bool {
        abs((b.start - a.end).ticks) <= transitionJoinTolerance.ticks
    }

    /// Window of the transition out of `clips[i]`: [cut − d/2, cut + d/2]; nil without a transition or a continuous cut.
    public func transitionWindow(after i: Int) -> TimeRange? {
        guard i >= 0, i + 1 < clips.count, let tr = clips[i].transitionOut, tr.duration.ticks > 0,
              Track.isJoined(clips[i], clips[i + 1]) else { return nil }
        let half = Time(ticks: tr.duration.ticks / 2)
        return TimeRange(start: clips[i].end - half, duration: tr.duration)
    }

    /// The transition whose window contains `t`: outgoing clip index `a` (incoming = a + 1), the instance and its window.
    public func activeTransition(at t: Time) -> (a: Int, transition: TransitionInstance, window: TimeRange)? {
        // first clip ending after t (clips never overlap)
        var lo = 0, hi = clips.count
        while lo < hi { let m = (lo + hi) / 2; if clips[m].end <= t { lo = m + 1 } else { hi = m } }
        for i in [lo - 1, lo] where i >= 0 && i + 1 < clips.count {
            if let w = transitionWindow(after: i), w.contains(t), let tr = clips[i].transitionOut { return (i, tr, w) }
        }
        return nil
    }

    /// Timeline time a clip is decoded for beyond its own range: the halves of the overlap transitions at its cuts.
    public func transitionExtension(of i: Int) -> (head: Time, tail: Time) {
        var head = Time.zero, tail = Time.zero
        if let w = transitionWindow(after: i - 1), clips[i - 1].transitionOut?.overlaps == true { head = clips[i].start - w.start }
        if let w = transitionWindow(after: i), clips[i].transitionOut?.overlaps == true { tail = w.end - clips[i].end }
        return (max(head, .zero), max(tail, .zero))
    }
}

extension Clip {
    /// Speed at the clip's first (`head`) or last output instant: the rate its transition handles play at.
    public func edgeRate(head: Bool) -> Double {
        max(speed.rate(at: head ? .zero : duration, outputDuration: duration), 1e-6)
    }

    /// Media time shown at timeline time `t`, continuing past the clip's edges at the edge speed (transition handles,
    /// TR-MODEL-CAPCUT). With `mediaDuration`, the result is held inside the media ("duplicate frames": the first /
    /// last frame, `frame` = one source frame) — inside the clip it equals `sourceTime(at:)`.
    public func handleSourceTime(at t: Time, mediaDuration: Time?, frame: Time) -> Time {
        let local = t - start
        guard local < .zero || local > duration else { return sourceTime(at: t) }
        let off = local < .zero ? local * edgeRate(head: true) : sourceDuration + (local - duration) * edgeRate(head: false)
        var s = reversed ? sourceStart + sourceDuration - off : sourceStart + off
        if let md = mediaDuration, md != .indefinite { s = s.clamped(.zero, max(.zero, md - frame)) }
        return max(s, .zero)
    }

    /// Timeline time of real media past the clip's out point (its tail handle); `.indefinite` for stills, text, solids.
    public func tailHandle(mediaDuration: Time?) -> Time {
        guard let md = mediaDuration, md != .indefinite else { return .indefinite }
        let src = reversed ? sourceStart : md - (sourceStart + sourceDuration)
        return max(.zero, src) / edgeRate(head: false)
    }

    /// Timeline time of real media before the clip's in point (its head handle); `.indefinite` for stills, text, solids.
    public func headHandle(mediaDuration: Time?) -> Time {
        guard let md = mediaDuration, md != .indefinite else { return .indefinite }
        let src = reversed ? md - (sourceStart + sourceDuration) : sourceStart
        return max(.zero, src) / edgeRate(head: true)
    }
}

extension TransitionInstance {
    /// CapCut `isOverlap` (default true): both clips visible over the whole window. False: first half over the
    /// outgoing clip only, second half over the incoming clip only.
    public var overlaps: Bool { isOverlap ?? true }
}
