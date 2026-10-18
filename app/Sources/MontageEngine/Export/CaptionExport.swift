import Foundation
import MontageCore

/// Caption exporting (EX-010 / TX-025): the project's captions → SRT / WebVTT / TXT / ASS / LRC (UTF-8), CapCut
/// "Caption exporting". Uses the text engine's caption model: segments come from `CaptionOps.segments(of:)` (bilingual
/// display, word timings) and files from `CaptionFiles.serialize` (VTT inline / ASS `\k` / enhanced-LRC word timings).
/// Caption tracks are W7 caption tracks (`CaptionOps.isCaptionTrack`) or tracks flagged `Track.isCaptions` (imported
/// subtitles); a project without either falls back to its text tracks. Cues are relative to the exported range.
public enum CaptionExport {
    public enum Format: String, Codable, Sendable, CaseIterable {
        case srt, vtt, txt, ass, lrc
        public var fileExtension: String { rawValue }
        public var label: String { rawValue.uppercased() }
        public var captionFormat: CaptionFormat {
            switch self { case .srt: .srt; case .vtt: .vtt; case .txt: .txt; case .ass: .ass; case .lrc: .lrc }
        }
    }

    public static func captionTrackIDs(_ p: Project) -> [TrackID] {
        let flagged = burnableTrackIDs(p)
        return flagged.isEmpty ? p.timeline.tracks.filter { $0.kind == .text }.map(\.id) : flagged
    }

    /// Real caption tracks only (W7 caption tracks / imported subtitles), without the text-track fallback: what
    /// "Burn captions into the video" switches, so turning it off never hides ordinary titles.
    public static func burnableTrackIDs(_ p: Project) -> [TrackID] {
        p.timeline.tracks.filter { ($0.isCaptions == true || CaptionOps.isCaptionTrack($0)) && !$0.clips.isEmpty }.map(\.id)
    }

    /// Segments sorted by start, clipped to `range` and shifted so the range starts at 0 (seconds).
    public static func segments(_ p: Project, range: TimeRange? = nil) -> [CaptionSegment] {
        let ids = Set(captionTrackIDs(p))
        let full = TimeRange(start: .zero, duration: p.duration)
        let r = range.flatMap { $0.intersection(full) } ?? full
        let a = r.start.seconds, b = r.end.seconds
        var out: [CaptionSegment] = []
        for var t in p.timeline.tracks where ids.contains(t.id) && !t.isHidden {
            t.clips = t.clips.filter { $0.isEnabled }
            for var s in CaptionOps.segments(of: t) {
                s.text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let start = max(s.start, a), end = min(s.end, b)
                guard !s.text.isEmpty, end - start > 1e-6 else { continue }
                s.start = start - a; s.end = end - a
                s.words = s.words.compactMap { w in
                    let ws = max(w.start, a), we = min(w.end, b)
                    return we > ws ? (w.text, ws - a, we - a) : nil
                }
                out.append(s)
            }
        }
        return out.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
    }

    public static func hasCaptions(_ p: Project) -> Bool { !segments(p).isEmpty }

    /// Style of the first caption (ASS header).
    static func style(_ p: Project) -> TextContent? {
        let ids = Set(captionTrackIDs(p))
        return p.timeline.tracks.lazy.filter { ids.contains($0.id) }.flatMap(\.clips).lazy.compactMap(CaptionOps.text).first
    }

    public static func serialize(_ p: Project, format: Format, range: TimeRange? = nil) -> String {
        CaptionFiles.serialize(segments(p, range: range), format: format.captionFormat, style: style(p),
                               canvas: p.settings.canvasSize)
    }

    public static func write(_ p: Project, format: Format, range: TimeRange? = nil, to url: URL) throws {
        try Data(serialize(p, format: format, range: range).utf8).write(to: url, options: .atomic)
    }
}
