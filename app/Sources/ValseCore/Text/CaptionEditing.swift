import Foundation

/// How a caption track is split into captions (caption editor ▸ Split options, CAP-EDITOR-UX): at most `lines` lines of
/// at most `charsPerLine` characters per caption.
public struct CaptionSplitRule: Hashable, Codable, Sendable {
    public var charsPerLine: Int
    public var lines: Int
    public init(charsPerLine: Int, lines: Int) {
        self.charsPerLine = min(max(charsPerLine, 8), 60); self.lines = min(max(lines, 1), 3)
    }
    /// Presets offered by the editor (Shorts / Reels first, CapCut "Captions line wrap").
    public static let presets: [CaptionSplitRule] = [
        CaptionSplitRule(charsPerLine: 16, lines: 1), CaptionSplitRule(charsPerLine: 24, lines: 1),
        CaptionSplitRule(charsPerLine: 32, lines: 2), CaptionSplitRule(charsPerLine: 42, lines: 2),
    ]
    public var maxChars: Int { charsPerLine * lines }
}

/// Caption editor helpers (CAP-EDITOR-UX): pure queries and edits on one caption track, unit-tested in
/// `CaptionEditingTests`.
extension CaptionOps {
    /// Reading speed above which a caption is flagged (characters per second).
    public static let maxCharsPerSecond = 20.0

    /// First UTF-16 offset where `a` and `b` differ (`min(len)` when one is a prefix of the other). Used to put the
    /// caret where an undo / redo changed the text.
    public static func firstDifference(_ a: String, _ b: String) -> Int {
        let x = Array(a.utf16), y = Array(b.utf16)
        var i = 0
        while i < x.count, i < y.count, x[i] == y[i] { i += 1 }
        return i
    }

    /// Index of the caption playing at `t` (binary search; clips are sorted and never overlap on a caption track).
    public static func clipIndex(at t: Time, in clips: [Clip]) -> Int? {
        var lo = 0, hi = clips.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let c = clips[mid]
            if t < c.start { hi = mid - 1 } else if t >= c.end { lo = mid + 1 } else { return mid }
        }
        return nil
    }

    /// Characters a caption shows (line breaks excluded).
    public static func visibleCharacters(_ s: String) -> Int { s.filter { $0 != "\n" }.count }

    /// Reading speed of a caption (characters per second).
    public static func charsPerSecond(_ s: String, duration: Time) -> Double {
        Double(visibleCharacters(s)) / max(duration.seconds, 0.001)
    }

    /// The over-limit badge of a row: (shown, limit) when the caption has more lines / characters than the split rule
    /// allows, or reads faster than `maxCharsPerSecond`; nil when it is fine. Informative only.
    public static func overLimit(_ s: String, duration: Time, rule: CaptionSplitRule?) -> (count: Int, limit: Int)? {
        let n = visibleCharacters(s)
        if let r = rule {
            let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
            let longest = lines.map(\.count).max() ?? 0
            if lines.count > r.lines || longest > r.charsPerLine || n > r.maxChars { return (n, r.maxChars) }
        }
        if n > 0, charsPerSecond(s, duration: duration) > maxCharsPerSecond {
            return (n, Int((maxCharsPerSecond * duration.seconds).rounded(.down)))
        }
        return nil
    }

    /// Previous / next caption of the same track (nil at the ends).
    public static func neighbour(of id: ClipID, _ delta: Int, in tl: Timeline) -> ClipID? {
        guard let loc = tl.locate(id) else { return nil }
        let clips = tl.tracks[loc.track].clips
        let i = loc.clip + delta
        return clips.indices.contains(i) ? clips[i].id : nil
    }

    /// Caret position after merging `id` into the caption before it (Delete at the start): the start of the former
    /// second text inside the merged caption.
    public static func mergeCaret(previousText a: String, text b: String) -> Int {
        a.utf16.count + (a.isEmpty || b.isEmpty ? 0 : 1)
    }

    /// Sets a caption edge to `t` (⌥⌘I / ⌥⌘O, "Set start / end to playhead"), clamped to the neighbours.
    public static func setEdge(_ id: ClipID, start: Bool, to t: Time, in project: inout Project) throws {
        guard let c = project.timeline.clip(id) else { throw EditError.clipNotFound }
        if start {
            guard t < c.end else { throw EditError.invalidTime }
            try setTimes(id, start: t, in: &project)
        } else {
            guard t > c.start else { throw EditError.invalidTime }
            try setTimes(id, end: t, in: &project)
        }
    }

    /// Deletes every caption of a track (top bar ▸ "Delete all … captions"). The track goes with its last clip.
    public static func deleteAll(trackID: TrackID, in project: inout Project) throws {
        guard let ti = project.timeline.trackIndex(trackID) else { throw EditError.clipNotFound }
        guard !project.timeline.tracks[ti].isLocked else { throw EditError.trackLocked }
        project.timeline.tracks.remove(at: ti)
    }

    /// Re-splits a whole track with `rule` (Split options) and stores the rule on the track. Returns the caption count.
    @discardableResult
    public static func resplit(trackID: TrackID, rule: CaptionSplitRule, in project: inout Project) throws -> Int {
        guard let ti = project.timeline.trackIndex(trackID) else { throw EditError.clipNotFound }
        guard !project.timeline.tracks[ti].isLocked else { throw EditError.trackLocked }
        wrap(trackIndex: ti, maxCharsPerLine: rule.charsPerLine, maxLines: rule.lines, in: &project)
        project.timeline.tracks[ti].captionSplit = rule
        return project.timeline.tracks[ti].clips.count
    }
}
