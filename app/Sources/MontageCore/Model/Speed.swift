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

public struct SpeedCurve: Hashable, Codable, Sendable {
    /// Sorted by x, first x = 0, last x = 1, all v > 0.
    public var points: [SpeedPoint]
    /// Preset this curve came from (e.g. "montage.speed.montage"), for UI highlighting.
    public var presetID: String?

    public init(points: [SpeedPoint], presetID: String? = nil) {
        var p = points.sorted { $0.x < $1.x }.map { SpeedPoint(min(max($0.x, 0), 1), max($0.v, 0.01)) }
        if p.first?.x != 0 { p.insert(SpeedPoint(0, p.first?.v ?? 1), at: 0) }
        if p.last?.x != 1 { p.append(SpeedPoint(1, p.last?.v ?? 1)) }
        self.points = p
        self.presetID = presetID
    }

    public func value(at x: Double) -> Double {
        guard let i = points.lastIndex(where: { $0.x <= x }) else { return points.first?.v ?? 1 }
        guard i + 1 < points.count else { return points[i].v }
        let a = points[i], b = points[i + 1]
        let t = b.x > a.x ? (x - a.x) / (b.x - a.x) : 0
        return a.v + (b.v - a.v) * t
    }

    /// ∫₀ˣ v(u) du (trapezoids are exact for piecewise-linear v).
    public func integral(to x: Double) -> Double {
        var acc = 0.0
        for i in 0..<(points.count - 1) {
            let a = points[i], b = points[i + 1]
            if x <= a.x { break }
            let xe = min(x, b.x)
            let ve = a.v + (b.v - a.v) * ((xe - a.x) / max(b.x - a.x, 1e-12))
            acc += (a.v + ve) / 2 * (xe - a.x)
        }
        return acc
    }
}
