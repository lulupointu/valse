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

    /// Frame-accurate piecewise-linear remap for the AVComposition (preview AND export use it).
    ///
    /// Output frames are only ever requested at `firstFrame + k·frameDuration` (clip-local). Segment boundaries are
    /// placed on those frame times and grown greedily while the linear interpolation inside the segment stays within
    /// `tolerance` of the exact remap (`sourceOffset`) at every frame time it covers. So every composed frame shows the
    /// source frame the exact integral asks for (tolerance ≪ one source frame), with as few edits as possible
    /// (constant speed → 1 segment; gentle curves → a handful; steep ramps → up to one per frame).
    /// Audio uses the same segments, so it follows the identical remap (piecewise-constant rate).
    /// - `sourceFrame`: optional (media time of `sourceOffset` 0, source frame duration). When given, a segment is only
    ///   accepted if the interpolated time also falls in the SAME source frame as the exact remap at every frame time.
    public func frameAccurateSegments(outputDuration: Time, frameDuration: Time, firstFrame: Time = .zero,
                                      tolerance: Time, sourceFrame: (origin: Time, duration: Time)? = nil)
    -> [(output: TimeRange, source: TimeRange)] {
        guard case .curve = self, outputDuration.ticks > 0, frameDuration.ticks > 0 else {
            return segments(outputDuration: outputDuration)
        }
        // Candidate boundaries: 0, every frame time inside (0, D), D.
        var cand: [Time] = [.zero]
        let fd = frameDuration.ticks
        var f = Time(ticks: ((firstFrame.ticks % fd) + fd) % fd)
        while f < outputDuration {
            if f > .zero { cand.append(f) }
            f += frameDuration
        }
        cand.append(outputDuration)
        let src = cand.map { sourceOffset(at: $0, outputDuration: outputDuration) }
        var out: [(TimeRange, TimeRange)] = []
        var a = 0
        let tol = Double(max(tolerance.ticks, 1))
        while a < cand.count - 1 {
            var b = a + 1
            // grow while every interior candidate is within tolerance of the chord a → c
            while b + 1 < cand.count {
                let c = b + 1
                let o0 = Double(cand[a].ticks), o1 = Double(cand[c].ticks)
                let s0 = Double(src[a].ticks), s1 = Double(src[c].ticks)
                var ok = true
                for i in (a + 1)..<c {
                    let lin = s0 + (s1 - s0) * (Double(cand[i].ticks) - o0) / (o1 - o0)
                    let exact = Double(src[i].ticks)
                    if abs(lin - exact) > tol { ok = false; break }
                    if let (o, d) = sourceFrame {
                        let dd = Double(d.ticks), oo = Double(o.ticks)
                        if ((oo + lin) / dd).rounded(.down) != ((oo + exact) / dd).rounded(.down) { ok = false; break }
                    }
                }
                if !ok { break }
                b = c
            }
            if cand[b] > cand[a], src[b] > src[a] {
                out.append((TimeRange(start: cand[a], end: cand[b]), TimeRange(start: src[a], end: src[b])))
            }
            a = b
        }
        return out
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
