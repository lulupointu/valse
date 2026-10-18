import CoreGraphics
import MontageCore

/// Pure timeline geometry + hit-testing (no drawing, no AppKit) — unit-testable.
///
/// Row order (top → bottom): overlay/text/sticker/effect tracks in reverse compositing order (top layer first), the
/// main track, then audio tracks. Coordinates in points; x = 0 at the left of the view (clips start after the header).
/// Every query is O(rows + log clips) so a 500+ clip timeline stays cheap to hit-test.
public struct TimelineLayout {
    public struct Row: Equatable {
        public let trackIndex: Int
        public let trackID: TrackID
        public let kind: TrackKind
        public let isMain: Bool
        public let y: CGFloat
        public let height: CGFloat
        public var rect: CGRect { CGRect(x: 0, y: y, width: .greatestFiniteMagnitude, height: height) }
        public var maxY: CGFloat { y + height }
    }

    public enum Hit: Equatable {
        case ruler
        /// A timeline marker flag on the ruler.
        case marker(MarkerID)
        case header(row: Int)
        case clip(ClipID, region: ClipRegion, row: Int)
        /// Transition block between `clip` and the next clip; `edge` = dragging its left/right border.
        case transition(ClipID, edge: TrimEdge?, row: Int)
        /// Keyframe diamond of a selected clip.
        case keyframe(ClipID, key: String, time: Time, row: Int)
        case track(row: Int)
        /// Above the first row / below the last: creating a new track.
        case newTrack(above: Bool)
        case none
    }
    public enum ClipRegion: Equatable { case body, leadingEdge, trailingEdge }

    public static let rulerHeight: CGFloat = 24
    /// Header column: 120 pt of track controls plus the 52 pt gap that holds the main track's Cover button (UX.md §6.3/§6.4).
    public static let headerWidth: CGFloat = 172
    public static let headerControlsWidth: CGFloat = 120
    public static let rowGap: CGFloat = 4
    public static let edgeHandle: CGFloat = 7
    public static let topPadding: CGFloat = 18
    public static let scrollbarHeight: CGFloat = 8
    /// Keyframe diamonds are centred vertically on a selected clip; this is the height of their hit band.
    public static let keyframeBand: CGFloat = 12

    public static func height(for kind: TrackKind, isMain: Bool, preset: TrackHeight? = nil) -> CGFloat {
        // UX.md §6.4: main ≈ 76 pt, audio ≈ 50 pt, every other lane 24 pt (overlay video lanes a bit taller for filmstrips).
        let base: CGFloat
        if isMain { base = 76 } else {
            switch kind {
            case .video: base = 40
            case .audio: base = 50
            default: base = 24
            }
        }
        return (base * CGFloat((preset ?? .standard).scale)).rounded()
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
        var y = Self.rulerHeight + Self.topPadding - scrollY
        var rows: [Row] = []
        for i in order {
            let t = timeline.tracks[i]
            let h = Self.height(for: t.kind, isMain: t.isMain, preset: t.heightPreset)
            rows.append(Row(trackIndex: i, trackID: t.id, kind: t.kind, isMain: t.isMain, y: y, height: h))
            y += h + Self.rowGap
        }
        self.rows = rows
    }

    public var contentHeight: CGFloat { (rows.last.map { $0.y + $0.height + scrollY } ?? Self.rulerHeight) + 40 }
    public var clipAreaWidth: CGFloat { viewSize.width - Self.headerWidth }
    public var mainRowIndex: Int? { rows.firstIndex { $0.isMain } }

    /// View x of a timeline time.
    public func x(_ t: Time) -> CGFloat { Self.headerWidth + CGFloat((t.seconds - scrollTime) * pixelsPerSecond) }
    /// Timeline time at a view x.
    public func time(atX x: CGFloat) -> Time { Time(max(0, Double(x - Self.headerWidth) / pixelsPerSecond + scrollTime)) }
    /// Time span of `points` at this zoom.
    public func duration(points: CGFloat) -> Time { Time(Double(points) / pixelsPerSecond) }

    public var visibleRange: TimeRange {
        TimeRange(start: Time(scrollTime), duration: Time(Double(clipAreaWidth) / pixelsPerSecond))
    }

    public func rowIndex(atY y: CGFloat) -> Int? { rows.firstIndex { y >= $0.y && y < $0.y + $0.height + Self.rowGap } }
    public func row(for track: TrackID) -> Row? { rows.first { $0.trackID == track } }

    public func clipRect(_ c: Clip, row: Row) -> CGRect {
        CGRect(x: x(c.start), y: row.y, width: max(1, CGFloat(c.duration.seconds * pixelsPerSecond)), height: row.height)
    }

    /// Transition block of `clip` (straddling the cut; width = duration, at least 14 pt so it stays grabbable).
    public func transitionRect(_ clip: Clip, row: Row) -> CGRect? {
        guard let tr = clip.transitionOut else { return nil }
        let x0 = x(clip.end - tr.duration), x1 = x(clip.end)
        let w = max(14, x1 - x0), mid = (x0 + x1) / 2
        return CGRect(x: mid - w / 2, y: row.y + 4, width: w, height: row.height - 8)
    }

    /// Clips of a track intersecting the time span around view x (binary search).
    private func candidates(_ track: Track, x px: CGFloat, slop: CGFloat) -> ArraySlice<Clip> {
        let t0 = time(atX: px - slop), t1 = time(atX: px + slop) + Time(ticks: 1)
        return track.clips(in: TimeRange(start: t0, end: t1))
    }

    public func hitTest(_ p: CGPoint, timeline: Timeline, selection: Set<ClipID> = []) -> Hit {
        if p.y < Self.rulerHeight {
            guard p.x >= Self.headerWidth else { return .ruler }
            if let m = marker(atX: p.x, timeline: timeline) { return .marker(m) }
            return .ruler
        }
        guard let first = rows.first, let last = rows.last else { return .newTrack(above: true) }
        if p.y < first.y { return p.x < Self.headerWidth ? .none : .newTrack(above: true) }
        if p.y > last.y + last.height + Self.rowGap { return p.x < Self.headerWidth ? .none : .newTrack(above: false) }
        guard let ri = rowIndex(atY: p.y) else { return .none }
        if p.x < Self.headerWidth { return .header(row: ri) }
        let row = rows[ri]
        let track = timeline.tracks[row.trackIndex]
        let cands = candidates(track, x: p.x, slop: max(Self.edgeHandle, 10))
        // keyframes of selected clips
        for c in cands where selection.contains(c.id) && !c.keyframes.isEmpty {
            let r = clipRect(c, row: row)
            guard abs(p.y - r.midY) <= Self.keyframeBand / 2 + 1, r.contains(CGPoint(x: p.x, y: r.midY)) else { continue }
            var best: (String, Time, CGFloat)?
            for (k, track) in c.keyframes.sorted(by: { $0.key < $1.key }) {   // deterministic pick when keys share a time
                for f in track.keyframes {
                    let d = abs(x(c.start + f.time) - p.x)
                    if d <= 5, d < (best?.2 ?? .greatestFiniteMagnitude) { best = (k, f.time, d) }
                }
            }
            if let best { return .keyframe(c.id, key: best.0, time: best.1, row: ri) }
        }
        // transitions next (they sit on top of the cut)
        for c in cands where c.transitionOut != nil {
            guard let r = transitionRect(c, row: row), r.insetBy(dx: -2, dy: 0).contains(p) else { continue }
            if p.x <= r.minX + 4 { return .transition(c.id, edge: .head, row: ri) }
            if p.x >= r.maxX - 4 { return .transition(c.id, edge: .tail, row: ri) }
            return .transition(c.id, edge: nil, row: ri)
        }
        // last matching clip wins (transition overlaps on main)
        for c in cands.reversed() {
            let r = clipRect(c, row: row)
            guard p.x >= r.minX - 2, p.x <= r.maxX + 2, p.y >= r.minY, p.y < r.maxY else { continue }
            let handle = min(Self.edgeHandle, r.width / 3)
            if p.x <= r.minX + handle { return .clip(c.id, region: .leadingEdge, row: ri) }
            if p.x >= r.maxX - handle { return .clip(c.id, region: .trailingEdge, row: ri) }
            return .clip(c.id, region: .body, row: ri)
        }
        return .track(row: ri)
    }

    /// Marker flag under a ruler x (within 6 pt).
    public func marker(atX px: CGFloat, timeline: Timeline) -> MarkerID? {
        var best: (MarkerID, CGFloat)?
        for m in timeline.markers {
            let d = abs(x(m.time) - px)
            if d <= 6, d < (best?.1 ?? .greatestFiniteMagnitude) { best = (m.id, d) }
        }
        return best?.0
    }

    /// When dragging vertically: a y close to the boundary between two rows (or above the top / below the bottom)
    /// means "insert a new track here". Returns the row index the new track goes *above* (rows.count = below all).
    public func insertionSlot(atY y: CGFloat) -> Int? {
        guard let first = rows.first, let last = rows.last else { return 0 }
        if y < first.y + 3 { return 0 }
        if y > last.maxY + Self.rowGap - 1 { return rows.count }
        for i in 1..<max(rows.count, 1) where i < rows.count {
            let boundary = (rows[i - 1].maxY + rows[i].y) / 2
            if abs(y - boundary) <= 4 { return i }
        }
        return nil
    }

    /// Clips intersecting a view rectangle (marquee selection).
    public func clips(in rect: CGRect, timeline: Timeline) -> Set<ClipID> {
        let t0 = time(atX: rect.minX), t1 = time(atX: rect.maxX) + Time(ticks: 1)
        var out = Set<ClipID>()
        for row in rows where row.y < rect.maxY && row.maxY > rect.minY {
            let track = timeline.tracks[row.trackIndex]
            guard !track.isLocked else { continue }
            for c in track.clips(in: TimeRange(start: t0, end: t1)) { out.insert(c.id) }
        }
        return out
    }

    /// Snaps `t` to the nearest candidate (playhead, clip edges, markers, beats, 0) within `tolerance` points.
    public func snap(_ t: Time, timeline: Timeline, playhead: Time, excluding: Set<ClipID> = [], tolerance: CGFloat = 8) -> (Time, snapped: Bool) {
        SnapIndex(timeline: timeline, excluding: excluding).snap(t, playhead: playhead, pixelsPerSecond: pixelsPerSecond, tolerance: tolerance)
    }

    /// Adaptive ruler tick spacing (seconds) for the zoom level: major ticks ≥ 80 pt apart.
    public static func tickStep(pixelsPerSecond: Double, fps: Double) -> (major: Double, minor: Double) {
        let steps: [Double] = [1 / fps, 2 / fps, 5 / fps, 10 / fps, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800]
        let major = steps.first { $0 * pixelsPerSecond >= 80 } ?? 3600
        let minor = steps.last { $0 < major && $0 * pixelsPerSecond >= 10 } ?? major
        return (major, minor)
    }
}

/// Sorted snap candidates (clip edges, markers, beats, in/out, 0), built once per drag gesture; queries are O(log n).
public struct SnapIndex {
    public private(set) var times: [Time]

    public init(timeline: Timeline, excluding: Set<ClipID> = []) {
        var s: [Time] = [.zero]
        for tr in timeline.tracks {
            for c in tr.clips where !excluding.contains(c.id) {
                s.append(c.start); s.append(c.end)
                if let b = c.beats { for x in b { s.append(c.start + x) } }
            }
        }
        for m in timeline.markers { s.append(m.time) }
        if let i = timeline.inPoint { s.append(i) }
        if let o = timeline.outPoint { s.append(o) }
        times = Array(Set(s)).sorted()
    }

    /// Nearest candidate to `t` (plus the playhead) within `tolerance` points.
    public func snap(_ t: Time, playhead: Time?, pixelsPerSecond: Double, tolerance: CGFloat = 8) -> (Time, snapped: Bool) {
        var best = t, bestD = CGFloat.greatestFiniteMagnitude
        func consider(_ c: Time) {
            let d = abs(CGFloat((c - t).seconds * pixelsPerSecond))
            if d < bestD { bestD = d; best = c }
        }
        var lo = 0, hi = times.count
        while lo < hi { let m = (lo + hi) / 2; if times[m] < t { lo = m + 1 } else { hi = m } }
        if lo < times.count { consider(times[lo]) }
        if lo > 0 { consider(times[lo - 1]) }
        if let playhead { consider(playhead) }
        return bestD <= tolerance ? (best, true) : (t, false)
    }

    /// Best snap for a moving span [start, start + duration]: whichever edge is closer to a candidate.
    public func snapSpan(start: Time, duration: Time, playhead: Time?, pixelsPerSecond: Double, tolerance: CGFloat = 8) -> (start: Time, line: Time?) {
        let a = snap(start, playhead: playhead, pixelsPerSecond: pixelsPerSecond, tolerance: tolerance)
        let b = snap(start + duration, playhead: playhead, pixelsPerSecond: pixelsPerSecond, tolerance: tolerance)
        if a.snapped && (!b.snapped || abs((a.0 - start).ticks) <= abs((b.0 - start - duration).ticks)) { return (a.0, a.0) }
        if b.snapped { return (b.0 - duration, b.0) }
        return (start, nil)
    }
}
