import Foundation
import CoreGraphics
import Perception
import MontageCore

/// Standard-preset lane sizes of the timeline (TL-SIZE-TUNER). `TimelineLayout` reads these instead of literals; the
/// "Track height ▸ Short / Default / Tall" preset still scales them. To adopt values the owner picked with the Sizes
/// popover as the new defaults, change the three defaults below (that is the only place they live).
public struct TimelineSizing: Equatable, Sendable {
    /// Main + overlay video lanes, in points (TL-IMOVIE-HEIGHT: 110 pt).
    public var videoLaneHeight: CGFloat = 110
    /// Share of a video lane taken by the clip's audio strip (waveform under the filmstrip), 0...1 (iMovie: ~25 %).
    public var audioStripFraction: CGFloat = 0.25
    /// Standalone audio lanes, in points (TL-IMOVIE-HEIGHT: 83 pt).
    public var audioLaneHeight: CGFloat = 83

    public init(videoLaneHeight: CGFloat = 110, audioStripFraction: CGFloat = 0.25, audioLaneHeight: CGFloat = 83) {
        self.videoLaneHeight = videoLaneHeight; self.audioStripFraction = audioStripFraction; self.audioLaneHeight = audioLaneHeight
    }

    public static let defaults = TimelineSizing()
    /// Slider ranges of the Sizes popover; stored values are clamped to them.
    public static let videoRange: ClosedRange<CGFloat> = 40...220
    public static let audioShareRange: ClosedRange<CGFloat> = 0...0.6
    public static let audioLaneRange: ClosedRange<CGFloat> = 30...200

    /// Whole points / whole percents, inside the slider ranges.
    public var clamped: TimelineSizing {
        func c(_ v: CGFloat, _ r: ClosedRange<CGFloat>) -> CGFloat { min(max(v.isFinite ? v : r.lowerBound, r.lowerBound), r.upperBound) }
        return TimelineSizing(videoLaneHeight: c(videoLaneHeight.rounded(), Self.videoRange),
                              audioStripFraction: c((audioStripFraction * 100).rounded() / 100, Self.audioShareRange),
                              audioLaneHeight: c(audioLaneHeight.rounded(), Self.audioLaneRange))
    }

    /// "video 110 pt · audio 25 % · audio lane 83 pt" (the owner copies this line to report the values he picked).
    public var summary: String {
        tr("sizes.summary", Int(videoLaneHeight), Int((audioStripFraction * 100).rounded()), Int(audioLaneHeight))
    }

    // MARK: app-wide current value (UserDefaults, not the project, not undoable)

    static let keys = (video: "montage.timeline.sizing.video", share: "montage.timeline.sizing.audioShare",
                       audio: "montage.timeline.sizing.audioLane")
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: TimelineSizing?

    /// The sizes every timeline uses now: the saved preference (`AppDefaults.store`, a throwaway domain in UI tests),
    /// else `defaults`. Readable from any thread; set it through `TimelineSizingPrefs.shared` so timelines redraw.
    public static var current: TimelineSizing {
        lock.lock(); defer { lock.unlock() }
        if let c = cached { return c }
        let c = load(from: AppDefaults.store)
        cached = c
        return c
    }

    static func load(from d: UserDefaults) -> TimelineSizing {
        var s = TimelineSizing.defaults
        if let v = d.object(forKey: keys.video) as? Double { s.videoLaneHeight = CGFloat(v) }
        if let v = d.object(forKey: keys.share) as? Double { s.audioStripFraction = CGFloat(v) }
        if let v = d.object(forKey: keys.audio) as? Double { s.audioLaneHeight = CGFloat(v) }
        return s.clamped
    }

    static func setCurrent(_ s: TimelineSizing) { lock.lock(); cached = s; lock.unlock() }

    static func store(_ s: TimelineSizing, in d: UserDefaults) {
        if s == .defaults {
            [keys.video, keys.share, keys.audio].forEach { d.removeObject(forKey: $0) }
        } else {
            d.set(Double(s.videoLaneHeight), forKey: keys.video)
            d.set(Double(s.audioStripFraction), forKey: keys.share)
            d.set(Double(s.audioLaneHeight), forKey: keys.audio)
        }
    }
}

/// Observable mirror of `TimelineSizing.current` for the Sizes popover and the timeline canvases (which redraw when
/// it changes). App-wide: every open editor window follows it.
@MainActor @Perceptible
public final class TimelineSizingPrefs {
    public static let shared = TimelineSizingPrefs()
    public private(set) var sizing: TimelineSizing

    init() { sizing = TimelineSizing.current }

    public func set(_ s: TimelineSizing) {
        let c = s.clamped
        guard c != sizing else { return }
        TimelineSizing.setCurrent(c)   // before `sizing`: observers redraw with layouts built from `current`
        sizing = c
        TimelineSizing.store(c, in: AppDefaults.store)
    }

    public func reset() { set(.defaults) }
}
