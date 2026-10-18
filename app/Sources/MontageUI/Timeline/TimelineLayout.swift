import CoreGraphics
import MontageCore

/// Pure timeline geometry + hit-testing (no drawing, no AppKit) — unit-testable.
///
/// Row order (top → bottom): overlay/text/sticker/effect tracks in reverse compositing order (top layer first), the
/// main track, then audio tracks. Coordinates in points; x = 0 at the left of the clip area (after the header).
public struct TimelineLayout {
    public struct Row: Equatable {
        public let trackIndex: Int
        public let trackID: TrackID
        public let kind: TrackKind
        public let isMain: Bool
        public let y: CGFloat
        public let height: CGFloat
        public var rect: CGRect { CGRect(x: 0, y: y, width: .greatestFiniteMagnitude, height: height) }
    }

    public enum Hit: Equatable {
        case ruler
        case header(row: Int)
        case clip(ClipID, region: ClipRegion, row: Int)
        case track(row: Int)
        /// Above the first row / below the last: creating a new track.
        case newTrack(above: Bool)
        case none
    }
    public enum ClipRegion: Equatable { case body, leadingEdge, trailingEdge }

    public static let rulerHeight: CGFloat = 24
    public static let headerWidth: CGFloat = 120
    public static let rowGap: CGFloat = 4
    public static let edgeHandle: CGFloat = 7
    public static let topPadding: CGFloat = 18

    public static func height(for kind: TrackKind, isMain: Bool) -> CGFloat {
        // UX.md §6.4: main ≈ 76 pt, audio ≈ 50 pt, every other lane 24 pt (overlay video lanes a bit taller for filmstrips).
        if isMain { return 76 }
        switch kind {
        case .video: return 40
        case .audio: return 50
        default: return 24
        }
    }

    public let rows: [Row]
    public let pixelsPerSecond: Double
    /// Leftmost visible time (scroll position).
    public let scrollTime: Double
    /// Vertical scroll offset (points).
    public let scrollY: CGFloat
    public let viewSize: CGSize

    public init(timeline: Timeline, pixelsPerSecond: Double, scrollTime: Double, scrollY: CGFloat, viewSize: CGSize) {
        self.pixelsPerSecond = pixelsPerSecond; self.scrollTime = scrollTime; self.scrollY = scrollY; self.viewSize = viewSize
        var order: [Int] = []
        let visual = timeline.tracks.indices.filter { timeline.tracks[$0].kind.isVisual && !timeline.tracks[$0].isMain }
        order += visual.reversed()
        if let m = timeline.mainTrackIndex { order.append(m) }
        order += timeline.tracks.indices.filter { timeline.tracks[$0].kind == .audio }
        // Vertically: centre the stack around the main track like CapCut when there is room.
        var y = Self.rulerHeight + Self.topPadding - scrollY
        var rows: [Row] = []
        for i in order {
            let t = timeline.tracks[i]
            let h = Self.height(for: t.kind, isMain: t.isMain)
            rows.append(Row(trackIndex: i, trackID: t.id, kind: t.kind, isMain: t.isMain, y: y, height: h))
            y += h + Self.rowGap
        }
        self.rows = rows
    }

    public var contentHeight: CGFloat { (rows.last.map { $0.y + $0.height + scrollY } ?? Self.rulerHeight) + 40 }
    public var clipAreaWidth: CGFloat { viewSize.width - Self.headerWidth }

    /// View x of a timeline time.
    public func x(_ t: Time) -> CGFloat { Self.headerWidth + CGFloat((t.seconds - scrollTime) * pixelsPerSecond) }
    /// Timeline time at a view x.
    public func time(atX x: CGFloat) -> Time { Time(max(0, Double(x - Self.headerWidth) / pixelsPerSecond + scrollTime)) }

    public var visibleRange: TimeRange {
        TimeRange(start: Time(scrollTime), duration: Time(Double(clipAreaWidth) / pixelsPerSecond))
    }

    public func rowIndex(atY y: CGFloat) -> Int? { rows.firstIndex { y >= $0.y && y < $0.y + $0.height + Self.rowGap } }
    public func row(for track: TrackID) -> Row? { rows.first { $0.trackID == track } }

    public func clipRect(_ c: Clip, row: Row) -> CGRect {
        CGRect(x: x(c.start), y: row.y, width: max(1, CGFloat(c.duration.seconds * pixelsPerSecond)), height: row.height)
    }

    public func hitTest(_ p: CGPoint, timeline: Timeline) -> Hit {
        if p.y < Self.rulerHeight { return .ruler }
        guard let first = rows.first, let last = rows.last else { return .newTrack(above: true) }
        if p.y < first.y { return .newTrack(above: true) }
        if p.y > last.y + last.height + Self.rowGap { return .newTrack(above: false) }
        guard let ri = rowIndex(atY: p.y) else { return .none }
        if p.x < Self.headerWidth { return .header(row: ri) }
        let row = rows[ri]
        let track = timeline.tracks[row.trackIndex]
        // last matching clip wins (transition overlaps on main)
        for c in track.clips.reversed() {
            let r = clipRect(c, row: row)
            guard p.x >= r.minX - 2, p.x <= r.maxX + 2, p.y >= r.minY, p.y < r.maxY else { continue }
            let handle = min(Self.edgeHandle, r.width / 3)
            if p.x <= r.minX + handle { return .clip(c.id, region: .leadingEdge, row: ri) }
            if p.x >= r.maxX - handle { return .clip(c.id, region: .trailingEdge, row: ri) }
            return .clip(c.id, region: .body, row: ri)
        }
        return .track(row: ri)
    }

    /// Snaps `t` to the nearest candidate (playhead, clip edges, markers, 0) within `tolerance` points.
    public func snap(_ t: Time, timeline: Timeline, playhead: Time, excluding: Set<ClipID> = [], tolerance: CGFloat = 8) -> (Time, snapped: Bool) {
        var best = t, bestD = CGFloat.greatestFiniteMagnitude
        func consider(_ c: Time) {
            let d = abs(CGFloat((c - t).seconds * pixelsPerSecond))
            if d < bestD { bestD = d; best = c }
        }
        consider(.zero); consider(playhead)
        for m in timeline.markers { consider(m.time) }
        for tr in timeline.tracks { for c in tr.clips where !excluding.contains(c.id) { consider(c.start); consider(c.end) } }
        return bestD <= tolerance ? (best, true) : (t, false)
    }

    /// Adaptive ruler tick spacing (seconds) for the zoom level: major ticks ≥ 80 pt apart.
    public static func tickStep(pixelsPerSecond: Double, fps: Double) -> (major: Double, minor: Double) {
        let steps: [Double] = [1 / fps, 2 / fps, 5 / fps, 10 / fps, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800]
        let major = steps.first { $0 * pixelsPerSecond >= 80 } ?? 3600
        let minor = steps.last { $0 < major && $0 * pixelsPerSecond >= 10 } ?? major
        return (major, minor)
    }
}
