import Foundation

/// Subtitle / lyrics file formats (TX-025 export, "Local captions" import). Parsers are tolerant (BOM, CRLF, missing
/// indices, "." or "," decimals, styling tags stripped) and return segments in timeline seconds; serializers write
/// standard files. Word timings round-trip through VTT inline timestamps, ASS `\k` karaoke tags and enhanced LRC.
public enum CaptionFormat: String, CaseIterable, Sendable {
    case srt, vtt, ass, lrc, txt

    public var fileExtension: String { rawValue }

    public static func detect(fileExtension ext: String, content: String) -> CaptionFormat? {
        switch ext.lowercased() {
        case "srt": return .srt
        case "vtt", "webvtt": return .vtt
        case "ass", "ssa": return .ass
        case "lrc": return .lrc
        case "txt": return .txt
        default: break
        }
        let head = content.prefix(400)
        if head.contains("WEBVTT") { return .vtt }
        if head.contains("[Script Info]") || head.contains("[Events]") { return .ass }
        if head.contains("-->") { return .srt }
        if head.range(of: #"\[\d+:\d+(\.\d+)?\]"#, options: .regularExpression) != nil { return .lrc }
        return nil
    }
}

public enum CaptionFormatError: Error, Equatable, Sendable { case unsupported, empty, tooLarge }

public enum CaptionFiles {
    /// CapCut refuses imports above 3 MB ("File needs to be no more than 3MB").
    public static let maxImportBytes = 3 * 1024 * 1024

    public static func parse(_ content: String, format: CaptionFormat) throws -> [CaptionSegment] {
        let text = content.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
        let segs: [CaptionSegment]
        switch format {
        case .srt: segs = parseSRT(text)
        case .vtt: segs = parseVTT(text)
        case .ass: segs = parseASS(text)
        case .lrc: segs = parseLRC(text)
        case .txt: segs = CaptionOps.scriptSegments(text)
        }
        guard !segs.isEmpty else { throw CaptionFormatError.empty }
        return segs
    }

    public static func serialize(_ segments: [CaptionSegment], format: CaptionFormat, style: TextContent? = nil,
                                 canvas: Size2 = Size2(1920, 1080)) -> String {
        switch format {
        case .srt: return srt(segments)
        case .vtt: return vtt(segments)
        case .ass: return ass(segments, style: style ?? CaptionOps.defaultStyle(canvas: canvas), canvas: canvas)
        case .lrc: return lrc(segments)
        case .txt: return segments.map(\.text).joined(separator: "\n") + "\n"
        }
    }

    // MARK: Timestamps

    /// "01:02:03,456", "02:03.456", "1:02:03.45" → seconds.
    public static func parseClock(_ s: String) -> Double? {
        let parts = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0.0
        for p in parts {
            guard let v = Double(p) else { return nil }
            total = total * 60 + v
        }
        return total
    }

    static func clock(_ t: Double, msSep: String, hours: Bool = true, centis: Bool = false) -> String {
        let t = max(0, t)
        let unit = centis ? 100.0 : 1000.0
        let total = Int((t * unit).rounded())
        let frac = total % Int(unit), s = (total / Int(unit)) % 60, m = (total / Int(unit) / 60) % 60, h = total / Int(unit) / 3600
        let f = centis ? String(format: "%02d", frac) : String(format: "%03d", frac)
        if hours { return centis ? String(format: "%d:%02d:%02d", h, m, s) + msSep + f : String(format: "%02d:%02d:%02d", h, m, s) + msSep + f }
        return String(format: "%02d:%02d", m + h * 60, s) + msSep + f
    }

    static func stripTags(_ s: String) -> String {
        var out = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
        return out.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&nbsp;", with: " ")
    }

    static func blocks(_ text: String) -> [[String]] {
        var out: [[String]] = []
        var cur: [String] = []
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { if !cur.isEmpty { out.append(cur); cur = [] } } else { cur.append(line) }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// "00:00:01,000 --> 00:00:02,000 [settings]" → (start, end).
    static func cueTimes(_ line: String) -> (Double, Double)? {
        guard let r = line.range(of: "-->") else { return nil }
        let a = String(line[..<r.lowerBound])
        let rest = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
        let b = String(rest.split(separator: " ").first ?? "")
        guard let s = parseClock(a), let e = parseClock(b) else { return nil }
        return (s, max(e, s))
    }

    // MARK: SRT

    static func parseSRT(_ text: String) -> [CaptionSegment] {
        blocks(text).compactMap { b in
            guard let ti = b.firstIndex(where: { $0.contains("-->") }), let (s, e) = cueTimes(b[ti]) else { return nil }
            let body = b[(ti + 1)...].map(stripTags).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? nil : CaptionSegment(text: body, start: s, end: e)
        }
    }

    static func srt(_ segs: [CaptionSegment]) -> String {
        segs.enumerated().map { i, s in
            "\(i + 1)\n\(clock(s.start, msSep: ",")) --> \(clock(s.end, msSep: ","))\n\(s.text)\n"
        }.joined(separator: "\n")
    }

    // MARK: WebVTT

    static func parseVTT(_ text: String) -> [CaptionSegment] {
        blocks(text).compactMap { b in
            guard let ti = b.firstIndex(where: { $0.contains("-->") }), let (s, e) = cueTimes(b[ti]) else { return nil }
            if b.first?.hasPrefix("NOTE") == true || b.first?.hasPrefix("STYLE") == true { return nil }
            let raw = b[(ti + 1)...].joined(separator: "\n")
            let body = stripTags(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return nil }
            return CaptionSegment(text: body, start: s, end: e, words: vttWords(raw, start: s, end: e))
        }
    }

    /// Inline karaoke timestamps: "<00:00:01.200>word <00:00:01.500>next".
    static func vttWords(_ raw: String, start: Double, end: Double) -> [(text: String, start: Double, end: Double)] {
        guard raw.contains("<0") || raw.contains("<1") || raw.contains("<2") else { return [] }
        var stamps: [(Double, String)] = []
        var t = start
        var buf = ""
        var i = raw.startIndex
        while i < raw.endIndex {
            if raw[i] == "<", let close = raw[i...].firstIndex(of: ">") {
                let tag = String(raw[raw.index(after: i)..<close])
                if let v = parseClock(tag) {
                    if !buf.isEmpty { stamps.append((t, buf)); buf = "" }
                    t = v
                }
                i = raw.index(after: close); continue
            }
            buf.append(raw[i]); i = raw.index(after: i)
        }
        if !buf.isEmpty { stamps.append((t, buf)) }
        var words: [(String, Double, Double)] = []
        for (k, (st, chunk)) in stamps.enumerated() {
            let next = k + 1 < stamps.count ? stamps[k + 1].0 : end
            let toks = TextTokenizer.tokens(chunk)
            for (j, tok) in toks.enumerated() {
                let a = st + (next - st) * Double(j) / Double(toks.count)
                words.append((tok, a, st + (next - st) * Double(j + 1) / Double(toks.count)))
            }
        }
        return words.map { (text: $0.0, start: $0.1, end: $0.2) }
    }

    static func vtt(_ segs: [CaptionSegment]) -> String {
        "WEBVTT\n\n" + segs.enumerated().map { i, s in
            var body = s.text
            if !s.words.isEmpty, !s.text.contains("\n"), TextTokenizer.tokens(s.text).count == s.words.count {
                body = s.words.enumerated().map { j, w in j == 0 ? w.text : "<\(clock(w.start, msSep: "."))>\(w.text)" }.joined(separator: " ")
            }
            return "\(i + 1)\n\(clock(s.start, msSep: ".")) --> \(clock(s.end, msSep: "."))\n\(body)\n"
        }.joined(separator: "\n")
    }

    // MARK: ASS / SSA

    static func parseASS(_ text: String) -> [CaptionSegment] {
        var format: [String] = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
        var inEvents = false
        var out: [CaptionSegment] = []
        for line in text.components(separatedBy: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("[") { inEvents = l.lowercased() == "[events]"; continue }
            guard inEvents else { continue }
            if l.lowercased().hasPrefix("format:") {
                format = l.dropFirst(7).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                continue
            }
            guard l.lowercased().hasPrefix("dialogue:") else { continue }
            let fields = l.dropFirst(9).split(separator: ",", maxSplits: max(format.count - 1, 0), omittingEmptySubsequences: false)
                .map { String($0) }
            func f(_ k: String) -> String? { format.firstIndex(of: k).flatMap { $0 < fields.count ? fields[$0] : nil } }
            guard let s = f("start").flatMap(parseClock), let e = f("end").flatMap(parseClock), let raw = f("text") else { continue }
            let normalized = raw.replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\h", with: " ")
            let body = stripTags(normalized).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            out.append(CaptionSegment(text: body, start: s, end: e, words: assWords(normalized, start: s)))
        }
        return out
    }

    /// `{\k25}Hel{\k30}lo` karaoke durations (centiseconds) → word timings.
    static func assWords(_ raw: String, start: Double) -> [(text: String, start: Double, end: Double)] {
        guard raw.range(of: #"\\[kK][fo]?\d+"#, options: .regularExpression) != nil else { return [] }
        var syllables: [(String, Double)] = []
        let scanner = raw
        var i = scanner.startIndex
        var pending: Double = 0
        var buf = ""
        while i < scanner.endIndex {
            if scanner[i] == "{", let close = scanner[i...].firstIndex(of: "}") {
                let tag = String(scanner[scanner.index(after: i)..<close])
                if let m = tag.range(of: #"\\[kK][fo]?(\d+)"#, options: .regularExpression) {
                    if !buf.isEmpty || pending > 0 { syllables.append((buf, pending)); buf = "" }
                    let digits = tag[m].filter(\.isNumber)
                    pending = (Double(digits) ?? 0) / 100
                }
                i = scanner.index(after: close); continue
            }
            buf.append(scanner[i]); i = scanner.index(after: i)
        }
        if !buf.isEmpty || pending > 0 { syllables.append((buf, pending)) }
        // group syllables into words at whitespace
        var words: [(String, Double, Double)] = []
        var t = start
        var cur = "", curStart = start
        for (text, d) in syllables {
            for (j, piece) in text.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
                if j > 0, !cur.isEmpty { words.append((cur, curStart, t)); cur = "" }
                if cur.isEmpty { curStart = t }
                cur += piece
            }
            t += d
            if text.hasSuffix(" "), !cur.isEmpty { words.append((cur, curStart, t)); cur = "" }
        }
        if !cur.isEmpty { words.append((cur, curStart, t)) }
        return words.filter { !$0.0.trimmingCharacters(in: .whitespaces).isEmpty }.map { (text: $0.0, start: $0.1, end: $0.2) }
    }

    static func assColor(_ c: RGBA) -> String {
        func b(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "&H%02X%02X%02X%02X", 255 - b(c.a), b(c.b), b(c.g), b(c.r))
    }

    static func ass(_ segs: [CaptionSegment], style t: TextContent, canvas: Size2) -> String {
        let fontPx = Int((t.fontSize * canvas.height).rounded())
        let outline = t.strokeWidth > 0 ? max(1, Int((t.strokeWidth * Double(fontPx)).rounded())) : 0
        let font = t.fontName.isEmpty ? "Helvetica" : t.fontName
        var s = """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: \(Int(canvas.width))
        PlayResY: \(Int(canvas.height))
        WrapStyle: 0

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,\(font),\(fontPx),\(assColor(t.color)),\(assColor(t.karaoke?.highlightColor ?? t.color)),\(assColor(t.strokeColor)),\(assColor(t.shadowColor.a > 0 ? t.shadowColor : t.backgroundColor)),\(t.bold ? -1 : 0),\(t.italic ? -1 : 0),\(t.underline ? -1 : 0),0,100,100,0,0,\(t.backgroundColor.a > 0 ? 3 : 1),\(outline),\(t.shadowColor.a > 0 ? 2 : 0),2,20,20,\(Int(canvas.height * 0.08)),1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text

        """
        for seg in segs {
            var body = seg.text.replacingOccurrences(of: "\n", with: "\\N")
            if !seg.words.isEmpty, !seg.text.contains("\n"), TextTokenizer.tokens(seg.text).count == seg.words.count {
                body = seg.words.enumerated().map { j, w in
                    let end = j + 1 < seg.words.count ? seg.words[j + 1].start : w.end
                    return "{\\k\(max(0, Int(((end - w.start) * 100).rounded())))}" + w.text
                }.joined(separator: " ")
                if let first = seg.words.first, first.start > seg.start + 0.005 {
                    body = "{\\k\(Int(((first.start - seg.start) * 100).rounded()))}" + body
                }
            }
            s += "Dialogue: 0,\(clock(seg.start, msSep: ".", centis: true)),\(clock(seg.end, msSep: ".", centis: true)),Default,,0,0,0,,\(body)\n"
        }
        return s
    }

    // MARK: LRC

    static func parseLRC(_ text: String) -> [CaptionSegment] {
        var stamped: [(Double, String, [(String, Double)])] = []
        let stamp = try! NSRegularExpression(pattern: #"\[(\d+:\d+(?:[.:]\d+)?)\]"#)
        for line in text.components(separatedBy: "\n") {
            let ns = line as NSString
            let ms = stamp.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard let last = ms.last else { continue }
            let body = ns.substring(from: last.range.location + last.range.length)
            // enhanced LRC: <mm:ss.xx>word
            var words: [(String, Double)] = []
            if body.contains("<") {
                let wr = try! NSRegularExpression(pattern: #"<(\d+:\d+(?:\.\d+)?)>([^<]*)"#)
                let bns = body as NSString
                for m in wr.matches(in: body, range: NSRange(location: 0, length: bns.length)) {
                    if let t = parseClock(bns.substring(with: m.range(at: 1))) {
                        for tok in TextTokenizer.tokens(bns.substring(with: m.range(at: 2))) { words.append((tok, t)) }
                    }
                }
            }
            let clean = stripTags(body).trimmingCharacters(in: .whitespaces)
            for m in ms {
                let tag = ns.substring(with: m.range(at: 1))
                let parts = tag.split(separator: ":")
                // [mm:ss:xx] variant (centiseconds after a colon)
                let normalized = parts.count == 3 ? "\(parts[0]):\(parts[1]).\(parts[2])" : tag
                if let t = parseClock(normalized) { stamped.append((t, clean, words)) }
            }
        }
        stamped.sort { $0.0 < $1.0 }
        var out: [CaptionSegment] = []
        for (i, (t, s, w)) in stamped.enumerated() where !s.isEmpty {
            let end = i + 1 < stamped.count ? stamped[i + 1].0 : t + 4
            let words = w.enumerated().map { j, x in (text: x.0, start: x.1, end: j + 1 < w.count ? w[j + 1].1 : end) }
            out.append(CaptionSegment(text: s, start: t, end: max(end, t + 0.1), words: words))
        }
        return out
    }

    static func lrc(_ segs: [CaptionSegment]) -> String {
        func tag(_ t: Double) -> String {
            let cs = Int((max(0, t) * 100).rounded())
            return String(format: "%02d:%02d.%02d", cs / 6000, (cs / 100) % 60, cs % 100)
        }
        return segs.map { s in
            var body = s.text.replacingOccurrences(of: "\n", with: " ")
            if !s.words.isEmpty, TextTokenizer.tokens(body).count == s.words.count {
                body = s.words.map { "<\(tag($0.start))>\($0.text)" }.joined(separator: " ")
            }
            return "[\(tag(s.start))]\(body)"
        }.joined(separator: "\n") + "\n"
    }
}
