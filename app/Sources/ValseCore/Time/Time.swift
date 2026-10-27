import Foundation

/// Exact timeline time, stored as integer "flicks" (1/705,600,000 s).
///
/// 705,600,000 is divisible by every common frame rate (23.976, 24, 25, 29.97, 30, 48, 50, 59.94, 60, 90, 100, 120)
/// and audio sample rate (8k … 192k, 44.1k), so frame and sample boundaries are exact integers and edits
/// never accumulate floating-point drift. Int64 covers ±414 years. Converts losslessly to CMTime
/// (timescale 705_600_000 fits in Int32).
public struct Time: Hashable, Comparable, Sendable, CustomStringConvertible {
    public static let ticksPerSecond: Int64 = 705_600_000

    public var ticks: Int64

    @inlinable public init(ticks: Int64) { self.ticks = ticks }
    /// Rounds to the nearest tick.
    @inlinable public init(seconds: Double) {
        self.ticks = Int64((seconds * Double(Time.ticksPerSecond)).rounded())
    }
    @inlinable public init(_ seconds: Double) { self.init(seconds: seconds) }

    @inlinable public var seconds: Double { Double(ticks) / Double(Time.ticksPerSecond) }

    public static let zero = Time(ticks: 0)
    /// Sentinel for "unbounded" (e.g. still images). Never do arithmetic on it.
    public static let indefinite = Time(ticks: .max / 4)

    @inlinable public static func + (a: Time, b: Time) -> Time { Time(ticks: a.ticks + b.ticks) }
    @inlinable public static func - (a: Time, b: Time) -> Time { Time(ticks: a.ticks - b.ticks) }
    @inlinable public static func += (a: inout Time, b: Time) { a.ticks += b.ticks }
    @inlinable public static func -= (a: inout Time, b: Time) { a.ticks -= b.ticks }
    @inlinable public static prefix func - (a: Time) -> Time { Time(ticks: -a.ticks) }
    /// Scales by a real factor, rounding to the nearest tick.
    @inlinable public static func * (a: Time, k: Double) -> Time { Time(ticks: Int64((Double(a.ticks) * k).rounded())) }
    @inlinable public static func / (a: Time, k: Double) -> Time { Time(ticks: Int64((Double(a.ticks) / k).rounded())) }
    /// Ratio of two times.
    @inlinable public static func / (a: Time, b: Time) -> Double { Double(a.ticks) / Double(b.ticks) }
    @inlinable public static func < (a: Time, b: Time) -> Bool { a.ticks < b.ticks }

    @inlinable public func clamped(_ lo: Time, _ hi: Time) -> Time { Swift.min(Swift.max(self, lo), hi) }

    public var description: String { String(format: "%.4fs", seconds) }
}

extension Time: Codable {
    public init(from decoder: any Decoder) throws { ticks = try decoder.singleValueContainer().decode(Int64.self) }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer(); try c.encode(ticks)
    }
}

extension Time: ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral {
    /// `let t: Time = 2` means two seconds.
    public init(integerLiteral value: Int) { self.init(ticks: Int64(value) * Time.ticksPerSecond) }
    public init(floatLiteral value: Double) { self.init(seconds: value) }
}

/// Rational frame rate (e.g. 30000/1001).
public struct FrameRate: Hashable, Codable, Sendable, CustomStringConvertible {
    public var numerator: Int32
    public var denominator: Int32

    public init(_ numerator: Int32, _ denominator: Int32 = 1) {
        precondition(numerator > 0 && denominator > 0)
        self.numerator = numerator; self.denominator = denominator
    }

    public static let fps23_976 = FrameRate(24000, 1001)
    public static let fps24 = FrameRate(24)
    public static let fps25 = FrameRate(25)
    public static let fps29_97 = FrameRate(30000, 1001)
    public static let fps30 = FrameRate(30)
    public static let fps50 = FrameRate(50)
    public static let fps59_94 = FrameRate(60000, 1001)
    public static let fps60 = FrameRate(60)
    /// Rates offered in project settings / export.
    public static let common: [FrameRate] = [.fps23_976, .fps24, .fps25, .fps29_97, .fps30, .fps50, .fps59_94, .fps60]

    public var fps: Double { Double(numerator) / Double(denominator) }
    /// Exact for all `common` rates.
    public var frameDuration: Time { Time(ticks: Time.ticksPerSecond * Int64(denominator) / Int64(numerator)) }

    /// Index of the frame containing `t` (floor).
    public func frame(containing t: Time) -> Int64 {
        let num = t.ticks * Int64(numerator), den = Time.ticksPerSecond * Int64(denominator)
        return num >= 0 ? num / den : -((-num + den - 1) / den)
    }
    /// Start time of frame `n`.
    public func time(ofFrame n: Int64) -> Time {
        Time(ticks: n * Time.ticksPerSecond * Int64(denominator) / Int64(numerator))
    }
    /// Snaps to the nearest frame boundary.
    public func snap(_ t: Time) -> Time {
        let f = frameDuration.ticks
        let n = (Double(t.ticks) / Double(f)).rounded()
        return time(ofFrame: Int64(n))
    }

    public static func nearest(to fps: Double) -> FrameRate {
        common.min { abs($0.fps - fps) < abs($1.fps - fps) } ?? .fps30
    }

    public var description: String {
        denominator == 1 ? "\(numerator)" : String(format: "%.3f", fps)
    }
}

/// Half-open time range [start, start + duration).
public struct TimeRange: Hashable, Codable, Sendable, CustomStringConvertible {
    public var start: Time
    public var duration: Time

    public init(start: Time, duration: Time) { self.start = start; self.duration = duration }
    public init(start: Time, end: Time) { self.start = start; self.duration = end - start }

    public var end: Time { start + duration }
    public var isEmpty: Bool { duration.ticks <= 0 }
    public func contains(_ t: Time) -> Bool { t >= start && t < end }
    public func overlaps(_ o: TimeRange) -> Bool { start < o.end && o.start < end }
    public func intersection(_ o: TimeRange) -> TimeRange? {
        let s = max(start, o.start), e = min(end, o.end)
        return s < e ? TimeRange(start: s, end: e) : nil
    }
    public func offset(by d: Time) -> TimeRange { TimeRange(start: start + d, duration: duration) }
    public var description: String { "[\(start) +\(duration)]" }
}

