import Foundation
import MontageCore

/// Timeline ruler tick / label generator (TL-RULER), CapCut-style.
///
/// Every tick sits on an integer project frame index and is placed at that frame's exact start time
/// (`FrameRate.time(ofFrame:)`), so nothing drifts while scrolling (no floating-point accumulation) and the 1f ticks of
/// a 29.97 / 23.976 project line up with the frames the playhead steps through. Seconds are counted like the app's
/// timecode (`Timecode`, non-drop-frame): `unitsPerSecond = round(fps)` frames per labelled second (30 at 29.97, 24 at
/// 23.976). Second marks fall on `frame % unitsPerSecond == 0` and are labelled `mm:ss` (`hh:mm:ss` from 1 h); the
/// other majors are labelled `"Nf"` with `0 < N < unitsPerSecond` (never "30f" at 30 fps).
///
/// The major step is the first rung of a "nice" ladder whose on-screen spacing is ≥ `minMajorSpacing` points (labels
/// never overlap): frame rungs that divide a second (1f, 2f, 5f, 10f, quarter / half second when they are whole frames,
/// e.g. 15f at 30 fps, 12f at 24 fps), then 1 s, 2 s, 5 s, 10 s, 15 s, 30 s, 1 min, 2, 5, 10, 15, 30 min, 1 h…
/// Minor ticks evenly subdivide each major: the smallest ladder rung dividing the major with ≥ `minMinorSpacing`
/// points and at most `maxMinorsPerMajor` subdivisions.
public nonisolated enum TimelineRuler {
    public static let minMajorSpacing: Double = 80
    public static let minMinorSpacing: Double = 12
    public static let maxMinorsPerMajor = 10

    /// Major / minor steps in frames of `rate`.
    public nonisolated struct Scale: Equatable, Sendable {
        public let rate: FrameRate
        public let major: Int
        public let minor: Int
        /// Frames per labelled second (`round(fps)`).
        public var unitsPerSecond: Int { TimelineRuler.unitsPerSecond(rate) }
    }

    public nonisolated struct Tick: Equatable, Sendable {
        /// Frame index of the tick.
        public let frame: Int64
        public let isMajor: Bool
        /// Exact start time of `frame`.
        public let time: Time
    }

    /// Frames per labelled second (29.97 → 30, 23.976 → 24, 59.94 → 60), as `Timecode` counts them.
    public static func unitsPerSecond(_ rate: FrameRate) -> Int { max(1, Int(rate.fps.rounded())) }

    /// The step ladder in frames, ascending.
    public static func ladder(unitsPerSecond n: Int) -> [Int] {
        var frames = Set<Int>()
        for c in [1, 2, 5, 10] where c < n && n % c == 0 { frames.insert(c) }
        if n % 4 == 0, n / 4 > 1 { frames.insert(n / 4) }
        if n % 2 == 0, n / 2 > 1 { frames.insert(n / 2) }
        let seconds = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 10800, 21600, 43200, 86400]
        return frames.sorted() + seconds.map { $0 * n }
    }

    public static func scale(pixelsPerSecond pps: Double, rate: FrameRate) -> Scale {
        let steps = ladder(unitsPerSecond: unitsPerSecond(rate))
        let pxPerFrame = max(pps, 1e-9) / rate.fps
        let major = steps.first { Double($0) * pxPerFrame >= minMajorSpacing } ?? steps[steps.count - 1]
        let candidates = steps.filter { $0 < major && major % $0 == 0 && Double($0) * pxPerFrame >= minMinorSpacing }
        let minor = candidates.first { major / $0 <= maxMinorsPerMajor } ?? major
        return Scale(rate: rate, major: major, minor: minor)
    }

    /// Ticks covering `[from, to]` (from is clamped at 0); the first tick is at or before `from`.
    public static func ticks(from: Time, to: Time, scale s: Scale) -> [Tick] {
        let step = Int64(s.minor), major = Int64(s.major)
        let lo = max(from, .zero)
        guard to >= lo else { return [] }
        let first = (s.rate.frame(containing: lo) / step) * step
        let last = s.rate.frame(containing: to) + 1
        guard (last - first) / step < 100_000 else { return [] }
        var out: [Tick] = []
        out.reserveCapacity(Int((last - first) / step) + 1)
        var f = first
        while f <= last {
            out.append(Tick(frame: f, isMajor: f % major == 0, time: s.rate.time(ofFrame: f)))
            f += step
        }
        return out
    }

    /// Major tick label: `mm:ss` (`hh:mm:ss` from 1 h) on whole seconds, `"Nf"` (frame within the second) otherwise.
    public static func label(frame: Int64, unitsPerSecond n: Int) -> String {
        let n64 = Int64(max(1, n))
        let f = frame % n64
        if f != 0 { return "\(f)f" }
        let total = frame / n64
        let h = total / 3600, m = (total / 60) % 60, sec = total % 60
        return h > 0 ? String(format: "%02lld:%02lld:%02lld", h, m, sec) : String(format: "%02lld:%02lld", m, sec)
    }
}

extension TimelineView {
    /// The ruler ticks to draw for `layout` across a view `width` points wide. Starts one major before the left edge
    /// so a label whose tick just scrolled out still shows its tail.
    func rulerTicks(layout l: TimelineLayout, width: Double, rate: FrameRate) -> (TimelineRuler.Scale, [TimelineRuler.Tick]) {
        let s = TimelineRuler.scale(pixelsPerSecond: l.pixelsPerSecond, rate: rate)
        let from = Time(seconds: l.scrollTime) - Time(ticks: rate.frameDuration.ticks * Int64(s.major))
        let to = Time(seconds: l.scrollTime + width / l.pixelsPerSecond)
        return (s, TimelineRuler.ticks(from: from, to: to, scale: s))
    }

    /// Labels of the major ticks whose tick line is inside the visible ruler, left to right (state dump `ui.rulerLabels`).
    var visibleRulerLabels: [String] {
        let l = layoutNow, w = Double(bounds.width)
        let (s, ticks) = rulerTicks(layout: l, width: w, rate: store.project.settings.frameRate)
        return ticks.filter { $0.isMajor }.compactMap { t in
            let x = Double(l.x(t.time))
            return x >= Double(TimelineLayout.headerWidth) && x < w ? TimelineRuler.label(frame: t.frame, unitsPerSecond: s.unitsPerSecond) : nil
        }
    }
}
