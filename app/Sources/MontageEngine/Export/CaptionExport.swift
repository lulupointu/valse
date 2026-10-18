import Foundation
import MontageCore

/// Caption exporting (EX-010): the project's caption cues → SRT / WebVTT / TXT (UTF-8), CapCut "Caption exporting".
/// Caption tracks are tracks flagged `Track.isCaptions` (imported subtitles, auto captions); a project without flagged
/// tracks falls back to its text tracks. Cues are relative to the exported range.
public enum CaptionExport {
    public enum Format: String, Codable, Sendable, CaseIterable {
        case srt, vtt, txt
        public var fileExtension: String { rawValue }
        public var label: String { rawValue.uppercased() }
    }

    public static func captionTrackIDs(_ p: Project) -> [TrackID] {
        let flagged = p.timeline.tracks.filter { $0.isCaptions == true }
        let tracks = flagged.isEmpty ? p.timeline.tracks.filter { $0.kind == .text } : flagged
        return tracks.map(\.id)
    }

    /// Cues sorted by start, clipped to `range` and shifted so the range starts at 0.
    public static func cues(_ p: Project, range: TimeRange? = nil) -> [CaptionCue] {
        let ids = Set(captionTrackIDs(p))
        let full = TimeRange(start: .zero, duration: p.duration)
        let r = range.flatMap { $0.intersection(full) } ?? full
        var out: [CaptionCue] = []
        for t in p.timeline.tracks where ids.contains(t.id) && !t.isHidden {
            for c in t.clips where c.isEnabled {
                guard case .text(let content) = c.content else { continue }
                let text = content.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, let i = c.range.intersection(r), i.duration > .zero else { continue }
                out.append(CaptionCue(start: i.start - r.start, end: i.end - r.start, text: text))
            }
        }
        return out.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
    }

    public static func hasCaptions(_ p: Project) -> Bool { !cues(p).isEmpty }

    public static func serialize(_ cues: [CaptionCue], format: Format) -> String {
        switch format {
        case .srt:
            return cues.enumerated().map { i, c in
                "\(i + 1)\n\(stamp(c.start, sep: ",")) --> \(stamp(c.end, sep: ","))\n\(c.text)\n"
            }.joined(separator: "\n")
        case .vtt:
            return "WEBVTT\n\n" + cues.map { "\(stamp($0.start, sep: ".")) --> \(stamp($0.end, sep: "."))\n\($0.text)\n" }.joined(separator: "\n")
        case .txt:
            return cues.map(\.text).joined(separator: "\n") + (cues.isEmpty ? "" : "\n")
        }
    }

    public static func write(_ p: Project, format: Format, range: TimeRange? = nil, to url: URL) throws {
        try Data(serialize(cues(p, range: range), format: format).utf8).write(to: url, options: .atomic)
    }

    /// HH:MM:SS,mmm
    static func stamp(_ t: Time, sep: String) -> String {
        let ms = max(0, Int((t.seconds * 1000).rounded()))
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, sep, ms % 1000)
    }
}
