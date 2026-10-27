import Foundation

/// Speed ▸ Velocity effects ▸ "Sync to beats" (SP-006): a speed ramp that slows down on every (or every 2nd) music
/// beat and speeds up between beats, normalised so the clip keeps its length (the beats stay where they are); plus the
/// beat times inside the clip for the optional visual punch (an effect whose strength spikes on each beat).
public enum VelocitySync {
    public static let slow = 0.35
    public static let fast = 2.2
    /// Points cap: dense music falls back to every 2nd / 3rd… beat so the curve stays editable.
    public static let maxBeats = 12

    /// Beats of the other clips (music) inside clip `id`, clip-local output time, every `every`-th one.
    public static func beats(for id: ClipID, in tl: Timeline, every: Int = 1) -> [Time] {
        guard let c = tl.clip(id) else { return [] }
        let edge = TimelineOps.minimumClipDuration
        var inside = TimelineOps.beatTimes(tl, excluding: [id]).filter { $0 > c.start + edge && $0 < c.end - edge }.map { $0 - c.start }
        let step = max(1, every)
        inside = inside.enumerated().filter { $0.offset % step == 0 }.map(\.element)
        while inside.count > maxBeats { inside = inside.enumerated().filter { $0.offset % 2 == 0 }.map(\.element) }
        return inside
    }

    /// The ramp for beats at `xs` (0…1 of the clip): slow at each beat, fast midway, averaging 1×.
    public static func curve(beats xs: [Double]) -> SpeedCurve? {
        let b = xs.filter { $0 > 0.01 && $0 < 0.99 }.sorted()
        guard !b.isEmpty else { return nil }
        var pts: [SpeedPoint] = [SpeedPoint(0, fast)]
        var prev = 0.0
        for x in b {
            let mid = (prev + x) / 2
            if mid - prev > 0.02, x - mid > 0.02, prev > 0 { pts.append(SpeedPoint(mid, fast)) }
            pts.append(SpeedPoint(x, slow))
            prev = x
        }
        pts.append(SpeedPoint(1, fast))
        var c = SpeedCurve(points: pts, presetID: presetID, interpolation: .smooth)
        // normalise: average rate 1 ⇒ same output duration ⇒ beats stay aligned
        let avg = Speed.curve(c).averageRate
        if avg > 0 {
            c = SpeedCurve(points: pts.map { SpeedPoint($0.x, min(max($0.v / avg, SpeedCurve.speedRange.lowerBound), SpeedCurve.speedRange.upperBound)) },
                           presetID: presetID, interpolation: .smooth)
        }
        return c
    }

    public static let presetID = "valse.velocity.beatSync"

    /// Applies the beat-synced ramp to clip `id`. Returns the clip-local beat times (for the punch effect).
    @discardableResult
    public static func apply(_ id: ClipID, every: Int = 1, in tl: inout Timeline) throws -> [Time] {
        guard let c = tl.clip(id) else { throw EditError.clipNotFound }
        let bs = beats(for: id, in: tl, every: every)
        guard let curve = curve(beats: bs.map { $0 / c.duration }) else { throw EditError.nothingToDo }
        try TimelineOps.setSpeed(id, .curve(curve), in: &tl)
        return bs
    }

    /// Keyframes for a punch parameter: 0 between beats, `peak` on each beat, back to 0 after `decay`.
    public static func punchKeyframes(beats: [Time], peak: Double, decay: Time = Time(0.18), duration: Time) -> KeyframeTrack {
        var k: [Keyframe] = [Keyframe(time: .zero, value: .scalar(0))]
        let lead = Time(0.04)
        for b in beats {
            if b - lead > (k.last?.time ?? .zero) { k.append(Keyframe(time: b - lead, value: .scalar(0))) }
            k.append(Keyframe(time: b, value: .scalar(peak), easing: .easeOut))
            k.append(Keyframe(time: min(duration, b + decay), value: .scalar(0)))
        }
        return KeyframeTrack(k)
    }
}
