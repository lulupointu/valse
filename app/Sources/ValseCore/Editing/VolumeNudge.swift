import Foundation

/// "Volume +0.1 dB / −0.1 dB" (AU-004, CapCut ⌘. / ⌘,): steps a clip's linear gain in dB, rounded to 0.1 dB, inside the
/// clip volume range −∞…+20 dB (linear 0…10). Stepping up from silence starts at `floorDB`.
public enum VolumeNudge {
    public static let maxDB = 20.0
    /// Below this the clip is treated as silent (−∞ dB).
    public static let floorDB = -60.0

    public static func db(_ gain: Double) -> Double { gain <= 0 ? -.infinity : 20 * log10(gain) }
    public static func gain(_ db: Double) -> Double { db == -.infinity || db < floorDB ? 0 : pow(10, min(db, maxDB) / 20) }

    /// New linear gain after moving `gain` by `stepDB` (±0.1).
    public static func nudged(_ gain: Double, by stepDB: Double) -> Double {
        let cur = db(gain)
        guard cur.isFinite else { return stepDB > 0 ? Self.gain(floorDB) : 0 }
        let next = ((cur + stepDB) * 10).rounded() / 10
        if next < floorDB { return 0 }
        return Self.gain(min(next, maxDB))
    }
}
