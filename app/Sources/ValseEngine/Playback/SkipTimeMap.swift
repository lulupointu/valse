import Foundation
import ValseCore

/// Quick cut preview (TL-048, PB-QC): the preview composition leaves the marked slices out, so playback runs straight
/// over them (no seek at each slice, no hitch). This maps timeline time ↔ player-item time for that composition.
/// The project itself is unchanged; the compositor evaluates the timeline at `timeline(itemTime)`.
public struct SkipTimeMap: Sendable, Hashable {
    /// Sorted, disjoint, non-empty timeline ranges that are left out.
    public let skips: [TimeRange]

    public static let identity = SkipTimeMap(skips: [])
    private init(skips: [TimeRange]) { self.skips = skips }

    /// `ranges` clamped to `[0, duration)`, sorted and merged (shorter than a tick: dropped).
    public init(_ ranges: [TimeRange], duration: Time) {
        let clamped = ranges.compactMap { $0.intersection(TimeRange(start: .zero, duration: max(duration, .zero))) }
            .filter { !$0.isEmpty }.sorted { $0.start < $1.start }
        var out: [TimeRange] = []
        for r in clamped {
            if let last = out.last, r.start <= last.end { out[out.count - 1] = TimeRange(start: last.start, end: max(last.end, r.end)) }
            else { out.append(r) }
        }
        skips = out
    }

    public var isIdentity: Bool { skips.isEmpty }

    /// Item time of timeline time `t` (inside a skipped range: where that range ends).
    public func item(_ t: Time) -> Time {
        var removed = Time.zero
        for r in skips {
            if r.end <= t { removed += r.duration }
            else if r.start <= t { return r.start - removed }
            else { break }
        }
        return t - removed
    }

    /// Timeline time of item time `i` (a skip boundary is the end of the skipped range).
    public func timeline(_ i: Time) -> Time {
        var t = i
        for r in skips {
            if r.start <= t { t += r.duration } else { break }
        }
        return t
    }

    /// The skipped range containing timeline time `t`, if any.
    public func skip(containing t: Time) -> TimeRange? { skips.first { $0.contains(t) } }

    /// Parts of timeline range `r` that are kept (in timeline time), in order.
    public func kept(_ r: TimeRange) -> [TimeRange] {
        guard !isIdentity else { return r.isEmpty ? [] : [r] }
        var out: [TimeRange] = []
        var cursor = r.start
        for s in skips where s.end > r.start {
            if s.start >= r.end { break }
            if s.start > cursor { out.append(TimeRange(start: cursor, end: s.start)) }
            cursor = max(cursor, s.end)
            if cursor >= r.end { break }
        }
        if cursor < r.end { out.append(TimeRange(start: cursor, end: r.end)) }
        return out
    }
}
