import AppKit
import MontageCore

/// U1-7 (owner: marquee selection "stops until I move again my mouse, is too slow … moves with the timeline when the
/// timeline is scrolling, instead of extending"). Pure parts, unit-tested in `OwnerUIFixesU1Tests`.
///
/// Edge autoscroll: while a drag (marquee, clip move, trim, roll, keyframe, marker, scrub) holds the pointer near or past
/// an edge of the clip area, the timeline scrolls on the display link — the mouse doesn't have to move — at a speed that
/// ramps with the distance into / past the edge. Before U1 it scrolled 8 pt per *mouse event* (nothing when the mouse
/// stood still, and the speed depended on the mouse's event rate).
enum EdgeAutoscroll {
    /// Band inside each edge where scrolling starts (points).
    static let zone: CGFloat = 24
    /// Speed at the inner border of the band (points of content per second)…
    static let minSpeed: Double = 120
    /// …plus this much per point deeper (into the band, then past the edge)…
    static let ramp: Double = 28
    /// …up to this.
    static let maxSpeed: Double = 3000
    /// Longest frame step applied at once (a stalled display link must not jump the timeline).
    static let maxStep: Double = 0.1

    /// Signed speed (points / s, + = towards the end / bottom) for a pointer at `p` along an axis whose visible range is
    /// `lower ... upper`. 0 in the middle.
    static func speed(_ p: CGFloat, lower: CGFloat, upper: CGFloat) -> Double {
        guard upper - lower > 2 * zone else { return 0 }
        if p > upper - zone { return min(maxSpeed, minSpeed + ramp * Double(p - (upper - zone))) }
        if p < lower + zone { return -min(maxSpeed, minSpeed + ramp * Double((lower + zone) - p)) }
        return 0
    }

    /// Points to scroll for one display-link step of `dt` seconds.
    static func step(speed: Double, dt: Double) -> Double { speed * min(max(dt, 0), maxStep) }
}

/// The marquee's start point in CONTENT coordinates (a time and a content y), so while the view scrolls the start stays
/// on the same time and track and the rectangle extends instead of sliding with the view.
struct MarqueeAnchor: Equatable {
    var time: Double
    /// y in the scrolled content (view y + scrollY).
    var contentY: CGFloat

    init(viewPoint p: CGPoint, layout l: TimelineLayout) {
        time = Double(p.x - TimelineLayout.headerWidth) / l.pixelsPerSecond + l.scrollTime
        contentY = p.y + l.scrollY
    }

    /// The anchor in view coordinates for the current scroll / zoom.
    func viewPoint(_ l: TimelineLayout) -> CGPoint {
        CGPoint(x: TimelineLayout.headerWidth + CGFloat((time - l.scrollTime) * l.pixelsPerSecond), y: contentY - l.scrollY)
    }

    /// Selection rectangle (view coordinates) from the anchor to the pointer.
    func rect(to current: CGPoint, _ l: TimelineLayout) -> CGRect {
        let o = viewPoint(l)
        return CGRect(x: min(o.x, current.x), y: min(o.y, current.y), width: abs(current.x - o.x), height: abs(current.y - o.y))
    }
}
