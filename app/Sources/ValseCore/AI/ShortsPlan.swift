import Foundation

// Home ▸ Long video to shorts (AI-031, UX_AI §10.1): a long talking video → N short 9:16 projects. The pure part:
// input validation, duration buckets, and building one project per highlight (ValseAI's `LongToShorts` does the
// transcription, reframing and captions).

public enum ShortsDuration: String, Codable, Sendable, CaseIterable {
    case auto, under60, from60to90, from90to180
    public var nameKey: String { "shorts.duration.\(rawValue)" }
    /// Allowed short length (seconds).
    public var range: ClosedRange<Double> {
        switch self {
        case .auto: return 20...60
        case .under60: return 15...59
        case .from60to90: return 60...90
        case .from90to180: return 90...180
        }
    }
}

public enum ShortsPlanner {
    /// "Duration: 1 to 180 minutes" (CapCut: ≥ 1 min, ≤ ~3 h, needs audio).
    public static let minSeconds = 60.0
    public static let maxSeconds: Double = 10_800

    public enum Problem: String, Sendable, Equatable {
        case tooShort, tooLong, noAudio, notVideo
        public var messageKey: String { "shorts.error.\(rawValue)" }
    }

    public static func validate(_ a: MediaAsset) -> Problem? {
        guard a.kind == .video else { return .notVideo }
        guard a.hasAudio else { return .noAudio }
        let d = a.duration.seconds
        if d < minSeconds { return .tooShort }
        if d > maxSeconds { return .tooLong }
        return nil
    }

    /// Highlights to keep for a range of `seconds` of speech: ~1 per 2 minutes, at least 1, at most 10.
    public static func count(forSeconds seconds: Double) -> Int { min(10, max(1, Int((seconds / 120).rounded(.up)))) }

    /// Transcript words inside the selected range (media seconds).
    public static func words(_ t: Transcript, in range: ClosedRange<Double>?) -> [TranscriptWord] {
        guard let range else { return t.words }
        return t.words.filter { ($0.start + $0.end) / 2 >= range.lowerBound && ($0.start + $0.end) / 2 <= range.upperBound }
    }

    /// One short: a new 9:16 project "<name> · Short <n>" with the highlight (+0.15 s / 0.25 s handles inside the media)
    /// on the main track, scaled to fill the frame (auto reframe then moves it onto the subject).
    public static func project(for h: Highlight, asset: MediaAsset, index: Int, name: String,
                               frameRate: FrameRate = .fps30) -> Project {
        let canvas = ProjectSettings.presetSize("9:16") ?? Size2(1080, 1920)
        var p = Project(name: name, settings: ProjectSettings(canvasSize: canvas, frameRate: frameRate, aspectPreset: "9:16"))
        p.media = [asset]
        let total = asset.duration.seconds
        let a = max(0, h.start - 0.15), b = min(total > 0 ? total : h.end + 0.25, h.end + 0.25)
        var c = TimelineOps.makeClip(for: asset, at: .zero)
        c.sourceStart = Time(a)
        c.duration = Time(max(b - a, 0.5))
        let s = asset.pixelSize
        if s.width > 0, s.height > 0 {
            let fit = min(canvas.width / s.width, canvas.height / s.height), cover = max(canvas.width / s.width, canvas.height / s.height)
            c.transform.scale = Vec2(cover / fit, cover / fit)
        }
        try? TimelineOps.insert(c, into: &p)
        return p
    }
}
