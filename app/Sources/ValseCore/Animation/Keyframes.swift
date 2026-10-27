import Foundation

/// Value of an animatable property. Interpolation is component-wise.
public enum AnimValue: Hashable, Codable, Sendable {
    case scalar(Double)
    case vec2(Vec2)
    case color(RGBA)

    public var scalar: Double? { if case .scalar(let v) = self { return v }; return nil }
    public var vec2: Vec2? { if case .vec2(let v) = self { return v }; return nil }
    public var color: RGBA? { if case .color(let v) = self { return v }; return nil }

    /// Linear interpolation; mismatched kinds hold `self` until t reaches 1.
    public func lerp(_ o: AnimValue, _ t: Double) -> AnimValue {
        switch (self, o) {
        case let (.scalar(a), .scalar(b)): return .scalar(a + (b - a) * t)
        case let (.vec2(a), .vec2(b)): return .vec2(Vec2(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t))
        case let (.color(a), .color(b)): return .color(a.mix(b, t))
        default: return t < 1 ? self : o
        }
    }
}

/// Easing of the segment that *starts* at a keyframe.
public enum Easing: Hashable, Codable, Sendable {
    case linear
    /// Step: keep this keyframe's value until the next keyframe.
    case hold
    case easeIn, easeOut, easeInOut
    /// CSS-style cubic bezier on (time → progress), control points in [0,1]² (y may overshoot).
    case bezier(x1: Double, y1: Double, x2: Double, y2: Double)
    /// Bouncing / elastic arrival (W5 preset curves; not expressible as one cubic).
    case bounceOut, elasticOut

    /// Maps linear segment progress `t` ∈ [0,1] to eased progress.
    public func apply(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        switch self {
        case .linear: return t
        case .hold: return 0
        case .easeIn: return CubicBezier.solve(t, 0.42, 0, 1, 1)
        case .easeOut: return CubicBezier.solve(t, 0, 0, 0.58, 1)
        case .easeInOut: return CubicBezier.solve(t, 0.42, 0, 0.58, 1)
        case let .bezier(x1, y1, x2, y2): return CubicBezier.solve(t, x1, y1, x2, y2)
        case .bounceOut:
            let n1 = 7.5625, d1 = 2.75
            if t < 1 / d1 { return n1 * t * t }
            if t < 2 / d1 { let u = t - 1.5 / d1; return n1 * u * u + 0.75 }
            if t < 2.5 / d1 { let u = t - 2.25 / d1; return n1 * u * u + 0.9375 }
            let u = t - 2.625 / d1; return n1 * u * u + 0.984375
        case .elasticOut:
            if t == 0 || t == 1 { return t }
            return pow(2, -10 * t) * sin((t * 10 - 0.75) * (2 * .pi / 3)) + 1
        }
    }
}

/// Cubic-bezier timing function solver (same semantics as CSS `cubic-bezier()`).
public enum CubicBezier {
    public static func solve(_ x: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        let cx = 3 * x1, bx = 3 * (x2 - x1) - cx, ax = 1 - cx - bx
        let cy = 3 * y1, by = 3 * (y2 - y1) - cy, ay = 1 - cy - by
        func sx(_ t: Double) -> Double { ((ax * t + bx) * t + cx) * t }
        func sy(_ t: Double) -> Double { ((ay * t + by) * t + cy) * t }
        func dx(_ t: Double) -> Double { (3 * ax * t + 2 * bx) * t + cx }
        // Newton-Raphson, then bisection fallback.
        var t = x
        for _ in 0..<8 {
            let err = sx(t) - x
            if abs(err) < 1e-7 { return sy(t) }
            let d = dx(t)
            if abs(d) < 1e-6 { break }
            t -= err / d
        }
        var lo = 0.0, hi = 1.0
        t = x
        for _ in 0..<40 {
            let v = sx(t)
            if abs(v - x) < 1e-7 { break }
            if v < x { lo = t } else { hi = t }
            t = (lo + hi) / 2
        }
        return sy(t)
    }
}

public struct Keyframe: Hashable, Codable, Sendable {
    /// Clip-local time (timeline time relative to the clip's start).
    public var time: Time
    public var value: AnimValue
    /// Easing toward the next keyframe.
    public var easing: Easing
    public init(time: Time, value: AnimValue, easing: Easing = .linear) {
        self.time = time; self.value = value; self.easing = easing
    }
}

/// Sorted keyframes of one property.
public struct KeyframeTrack: Hashable, Codable, Sendable {
    public private(set) var keyframes: [Keyframe]

    public init(_ keyframes: [Keyframe] = []) { self.keyframes = keyframes.sorted { $0.time < $1.time } }

    public var isEmpty: Bool { keyframes.isEmpty }

    /// Value at clip-local time `t`. Before the first / after the last keyframe the value is held.
    public func value(at t: Time) -> AnimValue? {
        guard let first = keyframes.first else { return nil }
        if t <= first.time { return first.value }
        let last = keyframes[keyframes.count - 1]
        if t >= last.time { return last.value }
        // binary search: last index with time <= t
        var lo = 0, hi = keyframes.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if keyframes[mid].time <= t { lo = mid } else { hi = mid - 1 }
        }
        let a = keyframes[lo], b = keyframes[lo + 1]
        let span = (b.time - a.time).ticks
        guard span > 0 else { return b.value }
        let p = a.easing.apply(Double((t - a.time).ticks) / Double(span))
        return a.value.lerp(b.value, p)
    }

    /// Inserts or replaces (within `tolerance`) the keyframe at `time`.
    public mutating func set(_ value: AnimValue, at time: Time, easing: Easing? = nil, tolerance: Time = Time(ticks: 1)) {
        if let i = index(near: time, tolerance: tolerance) {
            keyframes[i].value = value
            if let easing { keyframes[i].easing = easing }
        } else {
            let k = Keyframe(time: time, value: value, easing: easing ?? .linear)
            let i = keyframes.firstIndex { $0.time > time } ?? keyframes.count
            keyframes.insert(k, at: i)
        }
    }

    public mutating func remove(near time: Time, tolerance: Time = Time(ticks: 1)) {
        if let i = index(near: time, tolerance: tolerance) { keyframes.remove(at: i) }
    }

    public func index(near time: Time, tolerance: Time) -> Int? {
        keyframes.firstIndex { abs(($0.time - time).ticks) <= tolerance.ticks }
    }

    /// Shifts all keyframes (used when trimming a clip's head) and drops those outside [0, duration].
    public mutating func shift(by delta: Time, keepWithin duration: Time? = nil) {
        keyframes = keyframes.map { var k = $0; k.time += delta; return k }
        if let duration { keyframes.removeAll { $0.time < .zero || $0.time > duration } }
    }

    public mutating func setEasing(_ easing: Easing, at index: Int) { keyframes[index].easing = easing }
}
