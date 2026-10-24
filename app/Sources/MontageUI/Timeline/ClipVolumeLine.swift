import CoreGraphics
import Foundation
import MontageCore

/// The horizontal volume line drawn over a clip's audio area (CapCut [10], C3-2): its height is the clip volume. Dragging
/// it vertically changes the volume; with volume keyframes the whole curve moves by the same amount. Pure (tests).
///
/// AU-VOL-PCT (owner 2026-10-24, iMovie): volumes are shown in percent (100 % = unity gain, 0 % = silence, max 400 %).
/// The vertical scale is `fraction(gain:)`: 0 … 100 % follows √gain up to 3/4 of the area (fine control on the quiet
/// half), 100 … 400 % fills the top quarter (two octaves of gain). Drag results are whole percents; 100 % is sticky.
public enum ClipVolumeLine {
    /// Highest gain the line / inspector can set (400 %, ≈ +12 dB, iMovie's cap).
    public static let maxGain = 4.0
    /// Area fraction of 100 %.
    public static let unityFraction = 0.75
    /// Pointer distance (points) from the line that grabs it.
    public static let grabTolerance: CGFloat = 3.5
    /// Drag results within this many percent of 100 % snap to 100 %.
    public static let snapPercent = 2.0

    /// Gain (linear, 1 = 100 %) → fraction of the area height from the bottom.
    public static func fraction(gain: Double) -> CGFloat {
        guard gain > 0 else { return 0 }   // also NaN
        if gain <= 1 { return CGFloat(unityFraction * gain.squareRoot()) }
        return CGFloat(min(1, unityFraction + (1 - unityFraction) * log2(min(gain, maxGain)) / log2(maxGain)))
    }

    /// Inverse of `fraction(gain:)`.
    public static func gain(fraction f: Double) -> Double {
        let f = min(max(f, 0), 1)
        if f <= unityFraction { let r = f / unityFraction; return r * r }
        return pow(2, (f - unityFraction) / (1 - unityFraction) * log2(maxGain))
    }

    /// View y of the line for `gain` inside `area` (flipped coordinates: y grows downward).
    public static func y(gain: Double, in area: CGRect) -> CGFloat {
        area.maxY - fraction(gain: gain) * area.height
    }

    /// Whole-percent gain (0, 0.01 … 4), 100 % within `snapPercent`.
    public static func quantized(_ gain: Double) -> Double {
        var p = (min(max(gain, 0), maxGain) * 100).rounded()
        if abs(p - 100) <= snapPercent { p = 100 }
        return p / 100
    }

    /// Gain after dragging the line by `dy` points (negative = up = louder) from `startGain`.
    public static func draggedGain(from startGain: Double, dy: CGFloat, areaHeight: CGFloat) -> Double {
        let f = Double(fraction(gain: startGain)) - Double(dy / max(areaHeight, 1))
        return quantized(gain(fraction: f))
    }

    /// Applies a drag to a clip: the static volume moves to `newGain`; existing volume keyframes move by the same
    /// distance on the line's scale (the curve keeps its shape). `origin` = the clip when the drag began.
    public static func apply(gain newGain: Double, origin: Clip, to clip: inout Clip) {
        let delta = Double(fraction(gain: newGain) - fraction(gain: origin.audio.volume))
        clip.audio.volume = newGain
        let key = ParamKey.volume.raw
        guard let track = origin.keyframes[key], !track.isEmpty else { return }
        clip.keyframes[key] = KeyframeTrack(track.keyframes.map { k in
            var k = k
            k.value = .scalar(quantized(gain(fraction: Double(fraction(gain: k.value.component(0) ?? 1)) + delta)))
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

    /// Applies a vertical drag of `dy` points (area height `h`) to what `grab` holds, from the clip at drag start.
    public static func apply(grab g: Grab, dy: CGFloat, areaHeight h: CGFloat, origin: Clip, to clip: inout Clip) {
        let key = ParamKey.volume.raw
        guard g != .whole, let track = origin.keyframes[key], !track.isEmpty else {
            apply(gain: draggedGain(from: origin.audio.volume, dy: dy, areaHeight: h), origin: origin, to: &clip)
            return
        }
        let moved = Set(indices(g, count: track.keyframes.count))
        clip.keyframes[key] = KeyframeTrack(track.keyframes.enumerated().map { i, k in
            guard moved.contains(i) else { return k }
            var k = k
            k.value = .scalar(draggedGain(from: k.value.component(0) ?? 1, dy: dy, areaHeight: h))
            return k
        })
    }

    /// Volume shown at clip-local time `t` (keyframed curve or static value).
    public static func gain(of clip: Clip, at t: Time) -> Double {
        clip.value(.volume, at: t)?.component(0) ?? clip.audio.volume
    }
}
