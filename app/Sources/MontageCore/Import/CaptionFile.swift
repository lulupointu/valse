import Foundation

/// One subtitle cue.
public struct CaptionCue: Equatable, Sendable {
    public var start: Time
    public var end: Time
    public var text: String
    public init(start: Time, end: Time, text: String) { self.start = start; self.end = end; self.text = text }
}

/// Caption file import (CapCut Text → Local captions, MI-020): SRT, WebVTT, LRC and the dialogue subset of ASS/SSA.
/// Pure Swift; charset detection covers UTF-8 (± BOM), UTF-16 (BOM) and legacy Windows-1252 / Latin-1 files.
public enum CaptionFile {
    public enum Format: String, Sendable, CaseIterable { case srt, vtt, lrc, ass }
    public static let extensions: Set<String> = ["srt", "vtt", "lrc", "ass", "ssa"]

    public enum ParseError: Error, Equatable, Sendable { case unreadable, empty }

    public static func format(forExtension ext: String) -> Format? {
        switch ext.lowercased() {
        case "srt": return .srt
        case "vtt": return .vtt
        case "lrc": return .lrc
        case "ass", "ssa": return .ass
        default: return nil
        }
    }

    public static func load(_ url: URL) throws -> [CaptionCue] {
        guard let data = try? Data(contentsOf: url), let text = decode(data) else { throw ParseError.unreadable }
        let fmt = format(forExtension: url.pathExtension) ?? sniff(text)
        let cues = parse(text, format: fmt)
        if cues.isEmpty { throw ParseError.empty }
        return cues
    }

    /// Charset detection ("Character encoding" setting in CapCut = auto).
    public static func decode(_ data: Data) -> String? {
        let b = [UInt8](data.prefix(4))
        if b.count >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF { return String(data: data.dropFirst(3), encoding: .utf8) }
        if b.count >= 2, b[0] == 0xFF, b[1] == 0xFE { return String(data: data, encoding: .utf16LittleEndian).map { $0.hasPrefix("\u{FEFF}") ? String($0.dropFirst()) : $0 } }
        if b.count >= 2, b[0] == 0xFE, b[1] == 0xFF { return String(data: data, encoding: .utf16BigEndian).map { $0.hasPrefix("\u{FEFF}") ? String($0.dropFirst()) : $0 } }
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1)
    }

    static func sniff(_ text: String) -> Format {
        if text.hasPrefix("WEBVTT") { return .vtt }
        if text.contains("[Events]") || text.contains("Dialogue:") { return .ass }
        if text.range(of: #"^\[\d+:\d+"#, options: .regularExpression) != nil { return .lrc }
        return .srt
    }

    public static func parse(_ text: String, format: Format) -> [CaptionCue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        switch format {
        case .srt, .vtt: return parseSRT(normalized)
        case .lrc: return parseLRC(normalized)
        case .ass: return parseASS(normalized)
        }
    }

    /// "00:01:02,500" / "01:02.500" / "00:01:02.5" → Time.
    static func timestamp(_ s: String) -> Time? {
        let parts = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var secs = 0.0
        for p in parts { guard let v = Double(p) else { return nil }; secs = secs * 60 + v }
        return Time(secs)
    }

    static func parseSRT(_ text: String) -> [CaptionCue] {
        var out: [CaptionCue] = []
        for block in text.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let ti = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let arrow = lines[ti].components(separatedBy: "-->")
            guard arrow.count == 2, let a = timestamp(arrow[0]),
                  let b = timestamp(arrow[1].split(separator: " ").first.map(String.init) ?? "") else { continue }
            let body = lines[(ti + 1)...].joined(separator: "\n")
            let clean = stripTags(body)
            if !clean.isEmpty, b > a { out.append(CaptionCue(start: a, end: b, text: clean)) }
        }
        return out.sorted { $0.start < $1.start }
    }

    /// LRC: `[mm:ss.xx]lyric`; a line lasts until the next timestamp (the last one 3 s).
    static func parseLRC(_ text: String) -> [CaptionCue] {
        var stamps: [(Time, String)] = []
        let re = try! NSRegularExpression(pattern: #"\[(\d+:\d+(?:[.:]\d+)?)\]"#)
        for line in text.split(separator: "\n").map(String.init) {
            let ns = line as NSString
            let matches = re.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let lyric = ns.substring(from: last.range.location + last.range.length).trimmingCharacters(in: .whitespaces)
            for m in matches {
                var ts = ns.substring(with: m.range(at: 1))
                // [mm:ss:xx] variant
                let comps = ts.split(separator: ":")
                if comps.count == 3 { ts = "\(comps[0]):\(comps[1]).\(comps[2])" }
                if let t = timestamp(ts) { stamps.append((t, lyric)) }
            }
        }
        stamps.sort { $0.0 < $1.0 }
        var out: [CaptionCue] = []
        for (i, s) in stamps.enumerated() where !s.1.isEmpty {
            let end = i + 1 < stamps.count ? stamps[i + 1].0 : s.0 + Time(3)
            if end > s.0 { out.append(CaptionCue(start: s.0, end: end, text: s.1)) }
        }
        return out
    }

    /// ASS/SSA: `Dialogue:` lines using the `Format:` of `[Events]`; override tags `{\…}` are dropped, `\N` → newline.
    static func parseASS(_ text: String) -> [CaptionCue] {
        var fields = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
        var out: [CaptionCue] = []
        for line in text.split(separator: "\n").map(String.init) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.lowercased().hasPrefix("format:"), t.lowercased().contains("text") {
                fields = t.dropFirst(7).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            } else if t.hasPrefix("Dialogue:") {
                let body = String(t.dropFirst(9))
                let parts = body.split(separator: ",", maxSplits: max(fields.count - 1, 0), omittingEmptySubsequences: false).map(String.init)
                guard parts.count == fields.count,
                      let si = fields.firstIndex(of: "start"), let ei = fields.firstIndex(of: "end"), let xi = fields.firstIndex(of: "text"),
                      let a = timestamp(parts[si]), let b = timestamp(parts[ei]) else { continue }
                var txt = parts[xi].replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
                txt = txt.replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\h", with: " ")
                txt = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !txt.isEmpty, b > a { out.append(CaptionCue(start: a, end: b, text: txt)) }
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\{\\[^}]*\}"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Puts cues on a NEW text track starting at `offset` (overlapping cues are clipped to stay on one track).
    @discardableResult
    public static func insert(_ cues: [CaptionCue], at offset: Time = .zero, style: TextContent = TextContent(string: "", fontSize: 0.05),
                              into p: inout Project) throws -> TrackID {
        let trackID = TimelineOps.addTrack(.text, to: &p.timeline)
        var lastEnd = Time.zero
        for c in cues {
            let start = max(c.start + offset, lastEnd)
            let end = c.end + offset
            guard end - start >= TimelineOps.minimumClipDuration else { continue }
            var content = style; content.string = c.text
            var clip = Clip(content: .text(content), start: start, duration: end - start)
            clip.name = c.text
            clip.transform.position = Vec2(0, 0.38)  // lower third, like CapCut captions
            try TimelineOps.insert(clip, into: &p, target: .track(trackID))
            lastEnd = end
        }
        return trackID
    }
}
