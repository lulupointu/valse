import CoreGraphics
import MontageCore

/// The horizontal volume line drawn over a clip's audio area (CapCut [10], C3-2): its height is the clip volume on a
/// dB scale (−60 dB at the bottom of the area … +20 dB at the top, the inspector's range, 0 dB at 3/4). Dragging it
/// vertically changes the volume; with volume keyframes the whole curve moves by the same dB offset. Pure (tests).
public enum ClipVolumeLine {
    public static let minDB = -60.0
    public static let maxDB = 20.0
    /// Pointer distance (points) from the line that grabs it.
    public static let grabTolerance: CGFloat = 3.5

    /// Gain (linear, 1 = 0 dB) → fraction of the area height from the bottom.
    public static func fraction(gain: Double) -> CGFloat {
        let db = gain <= 0 ? minDB : AudioProps.decibels(gain)
        return CGFloat((min(max(db, minDB), maxDB) - minDB) / (maxDB - minDB))
    }

    /// View y of the line for `gain` inside `area` (flipped coordinates: y grows downward).
    public static func y(gain: Double, in area: CGRect) -> CGFloat {
        area.maxY - fraction(gain: gain) * area.height
    }

    /// dB at the bottom of the scale means silence (the inspector's "−∞").
    public static func gain(db: Double) -> Double { db <= minDB + 0.05 ? 0 : pow(10, db / 20) }

    /// dB after dragging the line by `dy` points (negative = up = louder) from `startDB`, rounded to 0.1 dB and
    /// clamped to the inspector range; sticks to 0 dB within ±0.5 dB.
    public static func draggedDB(from startDB: Double, dy: CGFloat, areaHeight: CGFloat) -> Double {
        let span = maxDB - minDB
        let start = startDB.isFinite ? max(startDB, minDB) : minDB
        var db = start - Double(dy / max(areaHeight, 1)) * span
        db = (min(max(db, minDB), maxDB) * 10).rounded() / 10
        if abs(db) < 0.5 { db = 0 }
        return db
    }

    /// Applies a drag to a clip: the static volume moves to `db`; existing volume keyframes are offset by the same
    /// dB delta as the static value (the curve keeps its shape). `origin` = the clip when the drag began.
    public static func apply(db: Double, origin: Clip, to clip: inout Clip) {
        let startDB = AudioProps.decibels(origin.audio.volume)
        let delta = db - (startDB.isFinite ? max(startDB, minDB) : minDB)
        clip.audio.volume = gain(db: db)
        let key = ParamKey.volume.raw
        guard let track = origin.keyframes[key], !track.isEmpty else { return }
        clip.keyframes[key] = KeyframeTrack(track.keyframes.map { k in
            var k = k
            k.value = .scalar(gain(db: min(max(dB(k) + delta, minDB), maxDB)))
            return k
        })
    }

    // MARK: Keyframed volume (C3b, CapCut [24]/[26])

    /// What a press on the volume line grabs.
    public enum Grab: Equatable {
        /// No volume keyframes: the static clip volume.
        case whole
        /// One keyframe diamond: only that keyframe changes.
        case keyframe(Int)
        /// The line between keyframes `lo` and `hi` (nil = before the first / after the last): the keyframes bounding
        /// it move together. Before the first keyframe the value is held, so moving it changes everything from the clip
        /// start to that keyframe; after the last one, everything after it.
        case segment(lo: Int?, hi: Int?)
    }

    /// Grab at clip-local time `t`; a keyframe within `tolerance` wins.
    public static func grab(_ clip: Clip, at t: Time, tolerance: Time) -> Grab {
        guard let ks = clip.keyframes[ParamKey.volume.raw]?.keyframes, !ks.isEmpty else { return .whole }
        if let i = ks.indices.min(by: { abs((ks[$0].time - t).ticks) < abs((ks[$1].time - t).ticks) }),
           abs((ks[i].time - t).ticks) <= tolerance.ticks { return .keyframe(i) }
        let lo = ks.lastIndex { $0.time <= t }
        let hi = (lo.map { $0 + 1 } ?? 0)
        return .segment(lo: lo, hi: hi < ks.count ? hi : nil)
    }

    /// Keyframe indices a grab moves.
    public static func indices(_ g: Grab, count: Int) -> [Int] {
        switch g {
        case .whole: return []
        case .keyframe(let i): return [i]
        case .segment(let lo, let hi): return [lo, hi].compactMap { $0 }.filter { $0 < count }
        }
    }

    static func dB(_ k: Keyframe) -> Double {
        let g = k.value.component(0) ?? 1
        return g <= 0 ? minDB : max(AudioProps.decibels(g), minDB)
    }

    /// Applies a vertical drag of `dy` points (area height `h`) to what `grab` holds, from the clip at drag start.
    public static func apply(grab g: Grab, dy: CGFloat, areaHeight h: CGFloat, origin: Clip, to clip: inout Clip) {
        let key = ParamKey.volume.raw
        guard g != .whole, let track = origin.keyframes[key], !track.isEmpty else {
            apply(db: draggedDB(from: AudioProps.decibels(origin.audio.volume), dy: dy, areaHeight: h), origin: origin, to: &clip)
            return
        }
        let moved = Set(indices(g, count: track.keyframes.count))
        clip.keyframes[key] = KeyframeTrack(track.keyframes.enumerated().map { i, k in
            guard moved.contains(i) else { return k }
            var k = k
            k.value = .scalar(gain(db: draggedDB(from: dB(k), dy: dy, areaHeight: h)))
            return k
        })
    }

    /// Volume shown at clip-local time `t` (keyframed curve or static value).
    public static func gain(of clip: Clip, at t: Time) -> Double {
        clip.value(.volume, at: t)?.component(0) ?? clip.audio.volume
    }
}
