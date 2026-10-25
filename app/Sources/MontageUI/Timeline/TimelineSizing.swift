import CoreGraphics
import MontageCore

/// Lane sizes of the timeline for each "Track height ▸ Short / Default / Tall" preset (TL-SIZE-PRESETS, values picked
/// by the owner with the former TL-SIZE-TUNER popover, 2026-10-25). `TimelineLayout` reads these instead of literals:
/// this table is the only place the numbers live. Text / sticker / effect lanes are not in it (24 pt × `TrackHeight.scale`).
public struct TimelineSizing: Equatable, Sendable {
    /// Main + overlay video lanes, in points.
    public var videoLaneHeight: CGFloat
    /// Share of a video clip's height taken by its audio strip (waveform under the filmstrip), 0...1.
    public var audioStripFraction: CGFloat
    /// Standalone audio lanes, in points.
    public var audioLaneHeight: CGFloat

    public init(videoLaneHeight: CGFloat, audioStripFraction: CGFloat, audioLaneHeight: CGFloat) {
        self.videoLaneHeight = videoLaneHeight; self.audioStripFraction = audioStripFraction; self.audioLaneHeight = audioLaneHeight
    }

    /// "Short": video 70 pt, audio 40 %, audio lane 35 pt.
    public static let short = TimelineSizing(videoLaneHeight: 70, audioStripFraction: 0.4, audioLaneHeight: 35)
    /// "Default": video 120 pt, audio 30 %, audio lane 60 pt.
    public static let standard = TimelineSizing(videoLaneHeight: 120, audioStripFraction: 0.3, audioLaneHeight: 60)
    /// "Tall": video 170 pt, audio 30 %, audio lane 85 pt.
    public static let tall = TimelineSizing(videoLaneHeight: 170, audioStripFraction: 0.3, audioLaneHeight: 85)

    /// Sizes of a lane with this preset (nil = Default).
    public static func preset(_ p: TrackHeight?) -> TimelineSizing {
        switch p ?? .standard {
        case .short: return .short
        case .standard: return .standard
        case .tall: return .tall
        }
    }
}
