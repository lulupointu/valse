import Foundation

/// How "active" a media file is over time: audio level (dBFS per 50 ms) and visual motion (mean absolute luma change
/// per 0.25 s, 0…1). Computed once per media by ValseAI's `ActivityAnalyzer` (cached by content hash) and used by
/// EditPilot's "cut the silences" and "speed up the boring parts" (AI-048). Times are media seconds.
public struct ActivityProfile: Codable, Sendable, Equatable {
    public static let audioStep = 0.05
    public static let motionStep = 0.25
    /// Audio level per `audioStep` (dBFS, −100 = digital silence). Empty = no audio track.
    public var levels: [Float]
    /// Motion per `motionStep` (0 = still). Empty = audio-only media / still image.
    public var motion: [Float]
    public init(levels: [Float], motion: [Float]) { self.levels = levels; self.motion = motion }

    public var hasAudio: Bool { !levels.isEmpty }
    public var duration: Double { max(Double(levels.count) * Self.audioStep, Double(motion.count) * Self.motionStep) }

    /// Level under which audio counts as silence: adaptive between the noise floor (10th percentile) and the speech
    /// level (90th percentile); nil when the media has no audio. Material without dynamics (constant music, room tone)
    /// has no silence unless it is near digital silence.
    public var silenceThreshold: Float? {
        guard !levels.isEmpty else { return nil }
        let s = levels.sorted()
        let floor = s[Int(Double(s.count - 1) * 0.10)], loud = s[Int(Double(s.count - 1) * 0.90)]
        if loud < -50 { return loud + 1 }                    // everything is (near) silent
        if loud - floor < 10 { return min(floor - 1, -50) }  // no pauses to find
        return min(floor + max(6, 0.35 * (loud - floor)), loud - 6)
    }

    /// Silent runs of at least `minimum` s inside `range` (media time), each shrunk by `padding` at both ends so cuts
    /// keep a breath around words.
    public func silences(minimum: Double, in range: TimeRange? = nil, padding: Double = 0.12) -> [TimeRange] {
        guard let thr = silenceThreshold else { return [] }
        let lo = range?.start.seconds ?? 0, hi = range?.end.seconds ?? duration
        let step = Self.audioStep
        var out: [TimeRange] = []
        var runStart: Double?
        let first = max(0, Int(lo / step)), last = min(levels.count, Int((hi / step).rounded(.up)))
        guard first < last else { return [] }
        func close(_ end: Double) {
            guard let s = runStart else { return }
            runStart = nil
            let a = max(s, lo), b = min(end, hi)
            guard b - a >= minimum else { return }
            // runs touching the range edges keep no padding on that side (nothing to protect)
            let pa = a <= lo + 1e-6 ? 0 : padding, pb = b >= hi - 1e-6 ? 0 : padding
            if b - pb - (a + pa) >= 0.2 { out.append(TimeRange(start: Time(a + pa), end: Time(b - pb))) }
        }
        for i in first..<last {
            let t = Double(i) * step
            if levels[i] < thr { if runStart == nil { runStart = t } } else { close(t) }
        }
        close(Double(last) * step)
        return out
    }

    /// "Boring" runs inside `range` (media time): no speech/sound above the silence threshold AND little motion (below
    /// the media's 40th motion percentile, or nearly still), at least `minimum` s long. Without audio only motion counts;
    /// without motion only audio counts.
    public func boringRuns(minimum: Double = 1.5, in range: TimeRange? = nil) -> [TimeRange] {
        let lo = range?.start.seconds ?? 0, hi = range?.end.seconds ?? duration
        let step = Self.motionStep
        let n = Int(((hi - lo) / step).rounded(.down))
        guard n > 0 else { return [] }
        let thr = silenceThreshold
        let sortedMotion = motion.sorted()
        let motionThr: Float? = sortedMotion.isEmpty ? nil : max(0.004, min(sortedMotion[Int(Double(sortedMotion.count - 1) * 0.4)], 0.03))
        func quiet(_ t: Double) -> Bool {
            guard let thr else { return true }
            let a = Int(t / Self.audioStep), b = min(levels.count, Int((t + step) / Self.audioStep))
            guard a < b else { return true }
            return levels[a..<b].max()! < thr
        }
        func still(_ t: Double) -> Bool {
            guard let motionThr else { return true }
            let i = Int(t / step)
            return i < motion.count ? motion[i] <= motionThr : true
        }
        guard thr != nil || motionThr != nil else { return [] }
        var out: [TimeRange] = []
        var runStart: Double?
        for k in 0...n {
            let t = lo + Double(k) * step
            let boring = k < n && quiet(t) && still(t)
            if boring { if runStart == nil { runStart = t } } else if let s = runStart {
                runStart = nil
                let e = min(t, hi)
                if e - s >= minimum { out.append(TimeRange(start: Time(s), end: Time(e))) }
            }
        }
        return out
    }
}
