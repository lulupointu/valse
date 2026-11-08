import Foundation
import CoreGraphics
import ValseCore

/// Pure maths of the full-screen seek bar (PB-006b): pointer x ↔ time, snapping, fine scrubbing (⌥ = 10× slower and
/// drag-away bands, owner Q4 = C), scroll-to-frames. No AppKit: unit-tested in FullscreenTransportTests.
nonisolated struct ScrubTrack: Equatable, Sendable {
    /// Track width in points (x = 0 at its left end).
    var width: CGFloat
    /// Bar range length (timeline duration, compound duration inside a compound, preview item length).
    var duration: Time
    var rate: FrameRate

    /// Last frame start (the knob never goes past it: seeking to `duration` shows nothing).
    var lastFrame: Time {
        guard duration > .zero else { return .zero }
        return max(.zero, rate.time(ofFrame: rate.frame(containing: duration - Time(ticks: 1))))
    }

    var secondsPerPoint: Double { width > 0 ? duration.seconds / Double(width) : 0 }

    /// Time under `x`, clamped to [0, last frame] and frame-snapped.
    func time(atX x: CGFloat) -> Time {
        guard width > 0, duration > .zero else { return .zero }
        let f = min(max(Double(x / width), 0), 1)
        return clamp(Time(seconds: duration.seconds * f))
    }

    /// Clamped, frame-snapped.
    func clamp(_ t: Time) -> Time { rate.snap(t).clamped(.zero, lastFrame) }

    /// x of time `t` (0…width).
    func x(of t: Time) -> CGFloat {
        guard width > 0, duration > .zero else { return 0 }
        return CGFloat(min(max(t.seconds / duration.seconds, 0), 1)) * width
    }

    /// Snaps `t` to the nearest target within `tolerance` points (markers, in / out, 0, end).
    func snapped(_ t: Time, to targets: [Time], tolerance: CGFloat = 6) -> (time: Time, snapped: Bool) {
        let x0 = x(of: t)
        guard let best = targets.min(by: { abs(x(of: $0) - x0) < abs(x(of: $1) - x0) }),
              abs(x(of: best) - x0) <= tolerance else { return (t, false) }
        return (clamp(best), true)
    }

    /// Indices of `times` within `tolerance` points of `x` (hover tooltip lists every marker there).
    func near(_ times: [Time], x: CGFloat, tolerance: CGFloat = 6) -> [Int] {
        times.indices.filter { abs(self.x(of: times[$0]) - x) <= tolerance }
    }
}

/// Fine-scrub speed: drag-away bands (the further above the bar, the finer: iOS "Hi-speed / Half / Quarter / Fine")
/// and ⌥ (10× slower).
nonisolated enum ScrubSpeed: Equatable, Sendable {
    case normal, half, quarter, frame
    /// Points above the track before each band starts.
    static let bandHeight: CGFloat = 60
    /// Frame-by-frame band: one frame per this many points of horizontal movement.
    static let pointsPerFrame: CGFloat = 8

    static func band(distanceAbove d: CGFloat) -> ScrubSpeed {
        switch d {
        case ..<bandHeight: return .normal
        case ..<(2 * bandHeight): return .half
        case ..<(3 * bandHeight): return .quarter
        default: return .frame
        }
    }

    var factor: Double {
        switch self {
        case .normal: return 1
        case .half: return 0.5
        case .quarter: return 0.25
        case .frame: return 0
        }
    }
}

/// What the fine-scrub label shows (nil = plain scrubbing).
nonisolated enum FineScrubLabel: Equatable, Sendable {
    case half, quarter, frame, option
    var speedKey: String {
        switch self {
        case .half: return "fullscreen.fineScrub.half"
        case .quarter: return "fullscreen.fineScrub.quarter"
        case .frame: return "fullscreen.fineScrub.frame"
        case .option: return "fullscreen.fineScrub.option"
        }
    }
}

/// One drag on the bar. Absolute (knob under the pointer) at normal speed without ⌥; relative to an anchor (re-taken
/// whenever the speed changes) when slowed down, so the knob never jumps when ⌥ is pressed or the pointer moves up.
nonisolated struct ScrubDrag: Equatable, Sendable {
    private(set) var anchorX: CGFloat
    private(set) var anchorTime: Time
    private(set) var speed: ScrubSpeed = .normal
    private(set) var option = false
    private(set) var time: Time

    init(x: CGFloat, track: ScrubTrack) {
        anchorX = x
        time = track.time(atX: x)
        anchorTime = time
    }

    var isFine: Bool { speed != .normal || option }

    var label: FineScrubLabel? {
        switch speed {
        case .half: return .half
        case .quarter: return .quarter
        case .frame: return .frame
        case .normal: return option ? .option : nil
        }
    }

    /// New time for the pointer at `x`, `distanceAbove` points above the track (negative = below), ⌥ held or not.
    /// `snapTargets` apply only to absolute (normal-speed) scrubbing.
    mutating func update(x: CGFloat, distanceAbove: CGFloat, option opt: Bool, track: ScrubTrack,
                         snapTargets: [Time] = []) -> (time: Time, snapped: Bool) {
        let s = ScrubSpeed.band(distanceAbove: distanceAbove)
        if s != speed || opt != option {   // speed change: re-anchor where the knob is now
            speed = s; option = opt
            anchorX = x; anchorTime = time
        }
        guard isFine else {
            let r = track.snapped(track.time(atX: x), to: snapTargets)
            time = r.time
            return r
        }
        let dx = x - anchorX
        if speed == .frame {
            let frames = Int64((dx / ScrubSpeed.pointsPerFrame).rounded(.towardZero))
            time = track.clamp(anchorTime + Time(ticks: track.rate.frameDuration.ticks * frames))
        } else {
            let k = speed.factor * (option ? 0.1 : 1)
            time = track.clamp(anchorTime + Time(seconds: Double(dx) * track.secondsPerPoint * k))
        }
        return (time, false)
    }
}

/// Two-finger horizontal swipe / wheel over the bar: whole frames, the remainder carried to the next event.
nonisolated struct ScrollFrameStepper: Equatable, Sendable {
    /// Points of precise (trackpad) scrolling per frame.
    static let pointsPerFrame: CGFloat = 8
    private(set) var carry: CGFloat = 0

    /// Frames to step for one scroll event. Swiping left (content moves left, dx < 0) goes forward, like dragging a
    /// filmstrip; a classic wheel tick = one frame (down = forward).
    mutating func frames(dx: CGFloat, dy: CGFloat, precise: Bool) -> Int {
        if !precise {
            let d = abs(dx) > abs(dy) ? -dx : -dy
            return d > 0 ? 1 : (d < 0 ? -1 : 0)
        }
        guard abs(dx) >= abs(dy) else { return 0 }   // vertical trackpad scroll: ignored (not a seek gesture)
        carry += -dx
        let n = Int((carry / Self.pointsPerFrame).rounded(.towardZero))
        carry -= CGFloat(n) * Self.pointsPerFrame
        return n
    }

    mutating func reset() { carry = 0 }
}

/// The context chip (owner Q5 / Q6 = label only): breadcrumb inside a compound, timeline name with several timelines,
/// "Previewing — X" during a library preview, nothing otherwise.
nonisolated enum FullscreenContext {
    static func label(previewTitle: String?, compoundPath: [String], rootName: String, timelineNames: [String],
                      activeTimeline: String?) -> String? {
        if let previewTitle { return previewTitle }
        if !compoundPath.isEmpty { return ([rootName] + compoundPath).joined(separator: " › ") }
        if timelineNames.count > 1, let activeTimeline { return activeTimeline }
        return nil
    }
}

/// Keys that still act in full screen (owner Q1 = A: a viewing mode; markers and in / out are review tools and stay).
nonisolated enum FullscreenKeys {
    static let allowed: Set<String> = [
        "playPause", "shuttleBack", "shuttleStop", "shuttleForward",
        "prevFrame", "nextFrame", "prevFrames", "nextFrames", "prevCut", "nextCut", "home", "end",
        "playerFullscreen", "exitPlayerFullscreen",
        "marker", "markerColor", "nextMarker", "prevMarker", "inPoint", "outPoint",
    ]
    /// Menu commands blocked in full screen (they edit the project you cannot see).
    static let blockedMenuCommands = ["menu.undo", "menu.redo"]
    /// Keys that move the playhead / play state: they flash the progress line while the bar is hidden (owner Q3 = B).
    static let flashes: Set<String> = [
        "playPause", "shuttleBack", "shuttleStop", "shuttleForward",
        "prevFrame", "nextFrame", "prevFrames", "nextFrames", "prevCut", "nextCut", "home", "end", "nextMarker", "prevMarker",
    ]
}
