import Foundation

/// Rich-text editing on `TextContent`: string replacement that keeps per-range styles attached to their characters,
/// and range style application (TX-004). Offsets are UTF-16 (NSTextView / Core Text units).
extension TextContent {
    public var utf16Count: Int { string.utf16.count }

    /// Replaces the whole string, shifting / trimming runs so styled characters keep their style (common-prefix/suffix diff,
    /// which is exactly what typing, pasting or deleting a selection produces).
    public mutating func setString(_ new: String) {
        let old = Array(string.utf16), nw = Array(new.utf16)
        guard old != nw else { return }
        var p = 0
        while p < old.count, p < nw.count, old[p] == nw[p] { p += 1 }
        var s = 0
        while s < old.count - p, s < nw.count - p, old[old.count - 1 - s] == nw[nw.count - 1 - s] { s += 1 }
        // old[p ..< old.count - s] was replaced by nw[p ..< nw.count - s]
        let removedEnd = old.count - s, inserted = nw.count - s - p
        let delta = inserted - (removedEnd - p)
        var out: [TextRun] = []
        for r in runs {
            var a = r.range.location, b = r.range.end
            func map(_ x: Int, isEnd: Bool) -> Int {
                if x <= p { return x }
                if x >= removedEnd { return x + delta }
                // inside the replaced span: collapse to its start (deleted) — an end extends over inserted text
                return isEnd ? p + inserted : p
            }
            // typing right after a styled run extends it (like a text editor's typing attributes)
            let extendsAtEnd = b == p && removedEnd == p && inserted > 0
            a = map(a, isEnd: false); b = extendsAtEnd ? b + inserted : map(b, isEnd: true)
            if b > a { out.append(TextRun(TextRange(a, b - a), r.style)) }
        }
        string = new
        runs = Self.normalized(out, length: nw.count)
    }

    /// Applies `style` (merged over existing overrides) to `range`. A zero-length or full range with no runs edits the
    /// clip-wide style instead when `wholeIfEmpty` (CapCut: no selection = whole text).
    public mutating func applyStyle(_ style: TextRunStyle, to range: TextRange) {
        let len = utf16Count
        let r = TextRange(max(0, min(range.location, len)), max(0, min(range.end, len) - max(0, min(range.location, len))))
        guard r.length > 0 else { return }
        if r.location == 0 && r.length == len {
            // whole text: write the base style and drop overridden fields from runs
            if let c = style.color { color = c }
            if let f = style.fontName { fontName = f }
            if let b = style.bold { bold = b }
            if let i = style.italic { italic = i }
            if let u = style.underline { underline = u }
            if let s = style.strokeColor { strokeColor = s }
            runs = runs.map { run in
                var st = run.style
                if style.color != nil { st.color = nil }
                if style.fontName != nil { st.fontName = nil }
                if style.bold != nil { st.bold = nil }
                if style.italic != nil { st.italic = nil }
                if style.underline != nil { st.underline = nil }
                if style.strokeColor != nil { st.strokeColor = nil }
                if let k = style.sizeScale { st.sizeScale = k == 1 ? nil : k }
                if style.backgroundColor != nil { st.backgroundColor = style.backgroundColor }
                return TextRun(run.range, st)
            }
            if style.sizeScale != nil || style.backgroundColor != nil, runs.isEmpty {
                runs = [TextRun(r, TextRunStyle(sizeScale: style.sizeScale, backgroundColor: style.backgroundColor))]
            }
            runs = Self.normalized(runs, length: len)
            return
        }
        // split existing runs at the range edges, merge style inside, add new runs for unstyled gaps
        var out: [TextRun] = []
        var cursor = r.location
        for run in runs.sorted(by: { $0.range.location < $1.range.location }) {
            let a = run.range.location, b = run.range.end
            if b <= r.location || a >= r.end { out.append(run); continue }
            if a < r.location { out.append(TextRun(TextRange(a, r.location - a), run.style)) }
            let ia = max(a, r.location), ib = min(b, r.end)
            if ia > cursor { out.append(TextRun(TextRange(cursor, ia - cursor), style)) }
            out.append(TextRun(TextRange(ia, ib - ia), run.style.merged(with: style)))
            cursor = ib
            if b > r.end { out.append(TextRun(TextRange(r.end, b - r.end), run.style)) }
        }
        if cursor < r.end { out.append(TextRun(TextRange(cursor, r.end - cursor), style)) }
        runs = Self.normalized(out, length: len)
    }

    /// Style shared by every character of `range` (nil fields = mixed, CapCut "multiple values").
    public func commonStyle(in range: TextRange) -> TextRunStyle {
        let len = utf16Count
        guard range.length > 0, len > 0 else { return runStyle(at: max(0, min(range.location, len - 1))) }
        let start = max(0, range.location), end = min(range.end, len)
        var cuts: Set<Int> = [start, end]
        for r in runs { cuts.insert(min(max(r.range.location, start), end)); cuts.insert(min(max(r.range.end, start), end)) }
        let pts = cuts.sorted()
        var acc: TextRunStyle?
        for (a, b) in zip(pts, pts.dropFirst()) where b > a {
            let s = runStyle(at: a)
            guard let x = acc else { acc = s; continue }
            acc = TextRunStyle(color: x.color == s.color ? x.color : nil, fontName: x.fontName == s.fontName ? x.fontName : nil,
                               sizeScale: x.sizeScale == s.sizeScale ? x.sizeScale : nil, bold: x.bold == s.bold ? x.bold : nil,
                               italic: x.italic == s.italic ? x.italic : nil, underline: x.underline == s.underline ? x.underline : nil,
                               strokeColor: x.strokeColor == s.strokeColor ? x.strokeColor : nil,
                               backgroundColor: x.backgroundColor == s.backgroundColor ? x.backgroundColor : nil)
        }
        return acc ?? baseRunStyle
    }

    /// Sorted, clamped, non-empty, adjacent equal runs merged, empty styles dropped.
    public static func normalized(_ runs: [TextRun], length: Int) -> [TextRun] {
        var out: [TextRun] = []
        for r in runs.sorted(by: { $0.range.location < $1.range.location }) {
            let a = max(0, min(r.range.location, length)), b = max(a, min(r.range.end, length))
            guard b > a, !r.style.isEmpty else { continue }
            if let last = out.last, last.range.end >= a {
                if last.style == r.style { out[out.count - 1].range = TextRange(last.range.location, max(last.range.end, b) - last.range.location); continue }
                if last.range.end > a { // overlap: later wins from a
                    out[out.count - 1].range.length = a - last.range.location
                    if out[out.count - 1].range.length <= 0 { out.removeLast() }
                }
            }
            out.append(TextRun(TextRange(a, b - a), r.style))
        }
        return out
    }
}
