import Foundation

/// Playback speed of a media clip: constant or a curve ("Curve speed" in CapCut).
///
/// Time remapping maps clip-local *output* time (timeline) to *source* offset (media time after `sourceStart`).
/// For a curve, `points` define speed `v(x)` piecewise-linearly over normalized output position x ∈ [0,1].
/// The source extent consumed by an output duration D is `D · ∫₀¹ v(x) dx`, so the remap is the exact integral
/// (piecewise quadratic, analytically invertible). Preview, export and audio all use these functions.
public enum Speed: Hashable, Codable, Sendable {
    case constant(Double)
    case curve(SpeedCurve)

    public static let normal = Speed.constant(1)
    public static let range: ClosedRange<Double> = 0.1...100

    public var isNormal: Bool { if case .constant(let v) = self { return v == 1 }; return false }

    /// Average speed over the clip (source extent / output duration).
    public var averageRate: Double {
        switch self {
        case .constant(let v): return v
        case .curve(let c): return c.integral(to: 1)
        }
    }

    /// Source extent consumed when the clip lasts `output` on the timeline.
    public func sourceDuration(forOutput output: Time) -> Time { output * averageRate }
    /// Timeline duration needed to play `source` of media.
    public func outputDuration(forSource source: Time) -> Time { source / averageRate }

    /// Source offset (from `sourceStart`) shown at clip-local output time `t` for a clip of `outputDuration`.
    public func sourceOffset(at t: Time, outputDuration: Time) -> Time {
        switch self {
        case .constant(let v): return t * v
        case .curve(let c):
            guard outputDuration.ticks > 0 else { return .zero }
            let x = min(max(t / outputDuration, 0), 1)
            return outputDuration * c.integral(to: x)
        }
    }

    /// Instantaneous speed at clip-local time `t` (for audio rate automation / UI).
    public func rate(at t: Time, outputDuration: Time) -> Double {
        switch self {
        case .constant(let v): return v
        case .curve(let c): return c.value(at: outputDuration.ticks > 0 ? t / outputDuration : 0)
        }
    }

    /// Piecewise-constant approximation used by the AVComposition builder (scaleTimeRange per segment).
    /// Returns contiguous (output range, source range) pairs relative to the clip (output from 0, source from 0).
    public func segments(outputDuration: Time, maxSegments: Int = 32) -> [(output: TimeRange, source: TimeRange)] {
        switch self {
        case .constant:
            return [(TimeRange(start: .zero, duration: outputDuration),
                     TimeRange(start: .zero, duration: sourceDuration(forOutput: outputDuration)))]
        case .curve:
            let n = max(1, maxSegments)
            var out: [(TimeRange, TimeRange)] = []
            var prevO = Time.zero, prevS = Time.zero
            for i in 1...n {
                let o = i == n ? outputDuration : outputDuration * (Double(i) / Double(n))
                let s = sourceOffset(at: o, outputDuration: outputDuration)
                if o > prevO, s > prevS { out.append((TimeRange(start: prevO, end: o), TimeRange(start: prevS, end: s))) }
                prevO = o; prevS = s
            }
            return out
        }
    }
}

public struct SpeedPoint: Hashable, Codable, Sendable {
    /// Normalized output position 0…1.
    public var x: Double
    /// Speed multiplier (> 0).
    public var v: Double
    public init(_ x: Double, _ v: Double) { self.x = x; self.v = v }
}

public enum SpeedInterpolation: String, Hashable, Codable, Sendable {
    /// Straight segments between beats.
    case linear
    /// Monotone cubic (Fritsch–Carlson) through the beats: CapCut's smooth curve, never overshoots between two beats
    /// (so speed stays > 0 and within the beats' range). Integral is exact (closed-form Hermite antiderivative).
    case smooth
}

public struct SpeedCurve: Hashable, Codable, Sendable {
    /// Sorted by x, first x = 0, last x = 1, all v > 0.
    public var points: [SpeedPoint]
    /// Preset this curve came from (e.g. "montage.speed.montage"), for UI highlighting.
    public var presetID: String?
    /// nil = `.linear` (files written before smooth curves existed).
    public var interpolation: SpeedInterpolation?

    public init(points: [SpeedPoint], presetID: String? = nil, interpolation: SpeedInterpolation? = nil) {
        var p = points.sorted { $0.x < $1.x }.map { SpeedPoint(min(max($0.x, 0), 1), max($0.v, 0.01)) }
        if p.first?.x != 0 { p.insert(SpeedPoint(0, p.first?.v ?? 1), at: 0) }
        if p.last?.x != 1 { p.append(SpeedPoint(1, p.last?.v ?? 1)) }
        self.points = p
        self.presetID = presetID
        self.interpolation = interpolation
    }

    public var isSmooth: Bool { interpolation == .smooth }

    public func value(at x: Double) -> Double {
        guard let i = points.lastIndex(where: { $0.x <= x }) else { return points.first?.v ?? 1 }
        guard i + 1 < points.count else { return points[i].v }
        let a = points[i], b = points[i + 1]
        let h = b.x - a.x
        let t = h > 0 ? (x - a.x) / h : 0
        guard isSmooth, h > 0 else { return a.v + (b.v - a.v) * t }
        let m = tangents
        let t2 = t * t, t3 = t2 * t
        return (2 * t3 - 3 * t2 + 1) * a.v + (t3 - 2 * t2 + t) * h * m[i] + (-2 * t3 + 3 * t2) * b.v + (t3 - t2) * h * m[i + 1]
    }

    /// ∫₀ˣ v(u) du — exact for both interpolations (trapezoids for linear, Hermite antiderivative for smooth).
    public func integral(to x: Double) -> Double {
        var acc = 0.0
        let m = isSmooth ? tangents : []
        for i in 0..<(points.count - 1) {
            let a = points[i], b = points[i + 1]
            if x <= a.x { break }
            let xe = min(x, b.x)
            let h = b.x - a.x
            if isSmooth, h > 0 {
                let τ = (xe - a.x) / h
                let τ2 = τ * τ, τ3 = τ2 * τ, τ4 = τ3 * τ
                let H00 = τ4 / 2 - τ3 + τ, H10 = τ4 / 4 - 2 * τ3 / 3 + τ2 / 2
                let H01 = -τ4 / 2 + τ3, H11 = τ4 / 4 - τ3 / 3
                acc += h * (H00 * a.v + H10 * h * m[i] + H01 * b.v + H11 * h * m[i + 1])
            } else {
                let ve = a.v + (b.v - a.v) * ((xe - a.x) / max(h, 1e-12))
                acc += (a.v + ve) / 2 * (xe - a.x)
            }
        }
        return acc
    }

    /// Fritsch–Carlson monotone tangents (dv/dx) at each point.
    var tangents: [Double] {
        let n = points.count
        guard n >= 2 else { return Array(repeating: 0, count: n) }
        var d = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            let h = points[i + 1].x - points[i].x
            d[i] = h > 0 ? (points[i + 1].v - points[i].v) / h : 0
        }
        var m = [Double](repeating: 0, count: n)
        // CapCut beats are flat at their apex: zero slope at the ends and at local extrema.
        for i in 1..<(n - 1) {
            m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2
        }
        for i in 0..<(n - 1) where d[i] != 0 {
            let a = m[i] / d[i], b = m[i + 1] / d[i]
            let s = a * a + b * b
            if s > 9 { let k = 3 / s.squareRoot(); m[i] = k * a * d[i]; m[i + 1] = k * b * d[i] }
        }
        return m
    }

    /// Max number of beats in the editor (CapCut: "control points reached the upper limit").
    public static let maxPoints = 10
    public static let speedRange: ClosedRange<Double> = 0.1...10

    /// Adds a beat at `x` on the current curve (no-op at the limit or too close to an existing beat).
    public mutating func insertPoint(at x: Double, minGap: Double = 0.03) -> Int? {
        guard points.count < Self.maxPoints, x > minGap, x < 1 - minGap,
              !points.contains(where: { abs($0.x - x) < minGap }) else { return nil }
        let p = SpeedPoint(x, value(at: x))
        let i = points.firstIndex { $0.x > x } ?? points.count
        points.insert(p, at: i)
        presetID = nil
        return i
    }

    /// Removes an inner beat (the first and last beats are fixed at x = 0 and 1).
    public mutating func removePoint(at i: Int) {
        guard i > 0, i < points.count - 1 else { return }
        points.remove(at: i)
        presetID = nil
    }

    /// Drags beat `i`: x is clamped between its neighbours (ends stay at 0 / 1), v to `speedRange`.
    public mutating func movePoint(_ i: Int, x: Double, v: Double, minGap: Double = 0.02) {
        guard points.indices.contains(i) else { return }
        let lo = i == 0 ? 0 : points[i - 1].x + minGap
        let hi = i == points.count - 1 ? 1 : points[i + 1].x - minGap
        let nx = (i == 0) ? 0 : (i == points.count - 1 ? 1 : min(max(x, lo), max(lo, hi)))
        points[i] = SpeedPoint(nx, min(max(v, Self.speedRange.lowerBound), Self.speedRange.upperBound))
        presetID = nil
    }
}

/// CapCut's curve-speed presets (Speed ▸ Curve). Shapes traced from the preset glyphs: beats at the extrema,
/// smooth interpolation. The source extent is preserved when a preset is applied (`TimelineOps.setSpeed`).
public struct SpeedCurvePreset: Sendable, Identifiable {
    public let id: String
    public let nameKey: String
    public let points: [SpeedPoint]
    public var curve: SpeedCurve { SpeedCurve(points: points, presetID: id, interpolation: .smooth) }

    /// "Customized": starts flat at 1× with five editable beats.
    public static let customized = SpeedCurvePreset(id: "montage.speed.custom", nameKey: "speed.preset.custom", points: [
        SpeedPoint(0, 1), SpeedPoint(0.25, 1), SpeedPoint(0.5, 1), SpeedPoint(0.75, 1), SpeedPoint(1, 1)])
    public static let montage = SpeedCurvePreset(id: "montage.speed.montage", nameKey: "speed.preset.montage", points: [
        SpeedPoint(0, 1), SpeedPoint(0.1, 1), SpeedPoint(0.5, 5.2), SpeedPoint(0.65, 0.2), SpeedPoint(0.8, 1), SpeedPoint(1, 1)])
    public static let heroTime = SpeedCurvePreset(id: "montage.speed.hero", nameKey: "speed.preset.hero", points: [
        SpeedPoint(0, 1), SpeedPoint(0.18, 5), SpeedPoint(0.42, 0.25), SpeedPoint(0.58, 0.25), SpeedPoint(0.82, 5), SpeedPoint(1, 1)])
    public static let bullet = SpeedCurvePreset(id: "montage.speed.bullet", nameKey: "speed.preset.bullet", points: [
        SpeedPoint(0, 5), SpeedPoint(0.3, 5), SpeedPoint(0.5, 0.2), SpeedPoint(0.7, 5), SpeedPoint(1, 5)])
    public static let jumpCut = SpeedCurvePreset(id: "montage.speed.jumpcut", nameKey: "speed.preset.jumpcut", points: [
        SpeedPoint(0, 0.5), SpeedPoint(0.4, 0.5), SpeedPoint(0.5, 8), SpeedPoint(0.6, 0.5), SpeedPoint(1, 0.5)])
    public static let flashIn = SpeedCurvePreset(id: "montage.speed.flashin", nameKey: "speed.preset.flashin", points: [
        SpeedPoint(0, 5), SpeedPoint(0.3, 5), SpeedPoint(0.55, 1), SpeedPoint(1, 1)])
    public static let flashOut = SpeedCurvePreset(id: "montage.speed.flashout", nameKey: "speed.preset.flashout", points: [
        SpeedPoint(0, 1), SpeedPoint(0.45, 1), SpeedPoint(0.7, 5), SpeedPoint(1, 5)])

    /// In CapCut's tile order (after "None").
    public static let all: [SpeedCurvePreset] = [customized, montage, heroTime, bullet, jumpCut, flashIn, flashOut]
    public static func preset(_ id: String?) -> SpeedCurvePreset? { all.first { $0.id == id } }
}
