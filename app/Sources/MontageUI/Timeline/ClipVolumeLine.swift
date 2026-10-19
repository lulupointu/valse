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
            let g = k.value.component(0) ?? 1
            let d0 = g <= 0 ? minDB : max(AudioProps.decibels(g), minDB)
            k.value = .scalar(gain(db: min(max(d0 + delta, minDB), maxDB)))
            return k
        })
    }

    /// Volume shown at clip-local time `t` (keyframed curve or static value).
    public static func gain(of clip: Clip, at t: Time) -> Double {
        clip.value(.volume, at: t)?.component(0) ?? clip.audio.volume
    }
}
