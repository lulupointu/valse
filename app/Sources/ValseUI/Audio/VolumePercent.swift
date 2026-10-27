import Foundation
import ValseCore

/// AU-VOL-PCT (owner 2026-10-24, iMovie's volume tooltip "63%" / "251%"): every volume the UI shows or takes is a
/// percentage of unity gain. 100 % = 0 dB, % = linear amplitude gain × 100 rounded to an integer, 0 % = silence.
/// Storage is unchanged (`AudioProps.volume`, `Track.volume`: linear gain).
enum VolumePercent {
    /// Whole percent of a linear gain.
    static func percent(_ gain: Double) -> Int { gain > 0 ? Int((gain * 100).rounded()) : 0 }
    /// "63%" in English, "63 %" (narrow no-break space) in French (`Fmt.unit`, ARCHITECTURE §11).
    static func label(_ gain: Double, french: Bool = Fmt.isFrench) -> String { labelPercent(Double(percent(gain)), french: french) }
    /// Same for a value already in percent (inspector rows).
    static func labelPercent(_ p: Double) -> String { labelPercent(p, french: Fmt.isFrench) }
    static func labelPercent(_ p: Double, french: Bool) -> String {
        let n = String(Int(max(0, p).rounded()))
        return french ? n + "\u{202F}%" : n + "%"
    }
    /// Linear gain of a percent value.
    static func gain(percent p: Double) -> Double { max(0, p) / 100 }

    /// Inspector slider scale: same as the timeline volume line (100 % at 3/4).
    static var sliderScale: SliderScale {
        SliderScale(toUnit: { Double(ClipVolumeLine.fraction(gain: $0 / 100)) },
                    fromUnit: { ClipVolumeLine.gain(fraction: $0) * 100 })
    }

    /// One-step nudge (⌘. / ⌘,): ±1 % of unity gain in whole percents, never above 400 % (an older project's louder
    /// value only goes down).
    static func nudged(_ gain: Double, by stepPercent: Double) -> Double {
        let cur = (max(gain, 0) * 100).rounded()
        let top = max(ClipVolumeLine.maxGain * 100, cur)
        return min(max(cur + stepPercent, 0), top) / 100
    }
}
