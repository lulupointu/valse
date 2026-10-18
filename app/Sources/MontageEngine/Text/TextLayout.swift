import CoreText
import CoreGraphics
import Foundation
import MontageCore

/// One grapheme cluster laid out by Core Text (shaping, bidi, fallback fonts, kerning all applied).
/// Local space: origin at the cluster's baseline-left, y down. `transform` maps it into the layout / scene space
/// (pen position, curve / path rotation, template layer placement).
struct LaidCluster: @unchecked Sendable {
    let font: CTFont
    let glyphs: [CGGlyph]
    /// Glyph positions relative to the cluster origin (y down).
    let offsets: [CGPoint]
    let advance: CGFloat
    let ascent: CGFloat
    let descent: CGFloat
    /// Ink bounds in local space.
    let ink: CGRect
    var transform: CGAffineTransform
    let utf16: Int
    /// Visible-character index (unit "character"), -1 for whitespace.
    var charIndex: Int
    var wordIndex: Int
    let lineIndex: Int
    var style: TextRunStyle
    let isWhitespace: Bool
    let isColorGlyph: Bool
    let underlinePosition: CGFloat
    let underlineThickness: CGFloat

    /// Typographic box in local space.
    var box: CGRect { CGRect(x: 0, y: -ascent, width: advance, height: ascent + descent) }
    var center: CGPoint { CGPoint(x: advance / 2, y: (descent - ascent) / 2).applying(transform) }
}

struct LaidLine { var rect: CGRect; var baseline: CGFloat }
struct LaidWord { var rect: CGRect; var clusters: [Int] }

/// Result of laying out one `TextContent` at a pixel font size. Coordinates in pixels, y down, origin at the text
/// box top-left (before curve/path, which then move clusters).
struct TextLayoutResult: @unchecked Sendable {
    var clusters: [LaidCluster]
    var lines: [LaidLine]
    var words: [LaidWord]
    /// Union of the typographic boxes (and ink) of every cluster, after transforms.
    var bounds: CGRect
    let fontPx: CGFloat
    var visibleCharCount: Int
    /// The text was bent (curve / path): line backgrounds become one block box.
    var isBent: Bool
}

/// Font resolution with a small thread-safe cache (CTFont is immutable and thread-safe).
enum TextFonts {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: CTFont] = [:]

    static func font(name: String, size: CGFloat, bold: Bool, italic: Bool) -> CTFont {
        let key = "\(name)|\(Int((size * 8).rounded()))|\(bold)|\(italic)"
        if let f = lock.withLock({ cache[key] }) { return f }
        var f: CTFont
        if name.isEmpty {
            f = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)
                ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        } else {
            f = CTFontCreateWithName(name as CFString, size, nil)
            let ps = CTFontCopyPostScriptName(f) as String, fam = CTFontCopyFamilyName(f) as String
            let full = CTFontCopyFullName(f) as String
            if ps.caseInsensitiveCompare(name) != .orderedSame && fam.caseInsensitiveCompare(name) != .orderedSame
                && full.caseInsensitiveCompare(name) != .orderedSame {
                // treat it as a family name
                let d = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: name] as CFDictionary)
                f = CTFontCreateWithFontDescriptor(d, size, nil)
            }
        }
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        if !traits.isEmpty, let t = CTFontCreateCopyWithSymbolicTraits(f, size, nil, traits, traits) { f = t }
        else if italic, let t = CTFontCreateCopyWithSymbolicTraits(f, size, nil, .traitItalic, .traitItalic) { f = t }
        if italic, !CTFontGetSymbolicTraits(f).contains(.traitItalic) {
            // no italic face: synthesize an oblique
            var m = CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)
            f = CTFontCreateCopyWithAttributes(f, size, &m, nil)
        }
        lock.withLock { cache[key] = f; if cache.count > 512 { cache.removeAll() } }
        return f
    }
}

enum TextLayoutEngine {
    static let runKey = NSAttributedString.Key("montage.run")

    /// Lays out `t` at `fontPx` (pixels). `boxWidthPx` wraps lines (nil = no wrapping, explicit newlines only).
    static func layout(_ t: TextContent, string override: String? = nil, fontPx: CGFloat, boxWidthPx: CGFloat?) -> TextLayoutResult {
        let s = override ?? t.displayString
        let base = t.baseRunStyle
        let runs = override == nil ? TextContent.normalized(t.runs, length: s.utf16.count) : []
        func style(at o: Int) -> TextRunStyle {
            guard let r = runs.first(where: { $0.range.location <= o && o < $0.range.end }) else { return base }
            return base.merged(with: r.style)
        }
        if t.orientation == .vertical {
            return verticalLayout(t, s, fontPx: fontPx, style: style)
        }
        var result = horizontalLayout(t, s, runs: runs, fontPx: fontPx, boxWidthPx: boxWidthPx, style: style)
        if let p = t.path { applyPath(p, to: &result) } else if abs(t.curve) > 0.001 { applyCurve(t.curve, to: &result) }
        finish(&result, s)
        return result
    }

    static func ctFont(_ st: TextRunStyle, _ t: TextContent, _ fontPx: CGFloat) -> CTFont {
        TextFonts.font(name: st.fontName ?? t.fontName, size: fontPx * CGFloat(st.sizeScale ?? 1), bold: st.bold ?? t.bold,
                       italic: st.italic ?? t.italic)
    }

    // MARK: Horizontal

    static func horizontalLayout(_ t: TextContent, _ s: String, runs: [TextRun], fontPx: CGFloat, boxWidthPx: CGFloat?,
                                 style: (Int) -> TextRunStyle) -> TextLayoutResult {
        let attr = NSMutableAttributedString(string: s)
        let len = attr.length
        var align: CTTextAlignment = {
            switch t.alignment { case .left: return .left; case .right: return .right; case .center: return .center; case .justify: return .justified }
        }()
        var spacing = CGFloat(t.lineSpacing) * fontPx
        let para: CTParagraphStyle = withUnsafeBytes(of: &align) { a in
            withUnsafeBytes(of: &spacing) { sp in
                let settings = [
                    CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: a.baseAddress!),
                    CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size, value: sp.baseAddress!),
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
        func key(_ k: CFString) -> NSAttributedString.Key { NSAttributedString.Key(k as String) }
        let full = NSRange(location: 0, length: len)
        attr.addAttribute(key(kCTParagraphStyleAttributeName), value: para, range: full)
        attr.addAttribute(key(kCTKernAttributeName), value: CGFloat(t.letterSpacing) * fontPx, range: full)
        // font per style segment (base + runs)
        var cuts: Set<Int> = [0, len]
        for r in runs { cuts.insert(min(r.range.location, len)); cuts.insert(min(r.range.end, len)) }
        let pts = cuts.sorted()
        for (a, b) in zip(pts, pts.dropFirst()) where b > a {
            let st = style(a)
            attr.addAttribute(key(kCTFontAttributeName), value: ctFont(st, t, fontPx), range: NSRange(location: a, length: b - a))
        }
        if len == 0 { attr.addAttribute(key(kCTFontAttributeName), value: ctFont(style(0), t, fontPx), range: full) }

        let framesetter = CTFramesetterCreateWithAttributedString(attr)
        let constraintW = boxWidthPx ?? 1_000_000
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil,
                                                               CGSize(width: constraintW, height: 1_000_000), nil)
        let frameW = boxWidthPx ?? ceil(fit.width) + 1
        let frameH = ceil(fit.height) + 2
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0),
                                             CGPath(rect: CGRect(x: 0, y: 0, width: frameW, height: frameH), transform: nil), nil)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)

        var clusters: [LaidCluster] = []
        var laidLines: [LaidLine] = []
        let clusterStarts = graphemeStarts(s)
        for (li, line) in lines.enumerated() {
            let o = origins[li]
            let baseline = frameH - o.y
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading)) - CGFloat(CTLineGetTrailingWhitespaceWidth(line))
            var lineMinX = CGFloat.greatestFiniteMagnitude, lineMaxX = -CGFloat.greatestFiniteMagnitude
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let n = CTRunGetGlyphCount(run)
                guard n > 0 else { continue }
                var glyphs = [CGGlyph](repeating: 0, count: n), pos = [CGPoint](repeating: .zero, count: n)
                var adv = [CGSize](repeating: .zero, count: n), idx = [CFIndex](repeating: 0, count: n)
                let all = CFRange(location: 0, length: 0)
                CTRunGetGlyphs(run, all, &glyphs); CTRunGetPositions(run, all, &pos)
                CTRunGetAdvances(run, all, &adv); CTRunGetStringIndices(run, all, &idx)
                let attrs = CTRunGetAttributes(run) as NSDictionary
                let font = attrs[kCTFontAttributeName as String].map { $0 as! CTFont } ?? ctFont(style(0), t, fontPx)
                let isColor = CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs)
                let fa = CTFontGetAscent(font), fd = CTFontGetDescent(font)
                let ulPos = -CTFontGetUnderlinePosition(font), ulTh = max(CTFontGetUnderlineThickness(font), fontPx * 0.05)
                // group consecutive glyphs of the same grapheme cluster
                var i = 0
                while i < n {
                    let cl = clusterIndex(idx[i], clusterStarts)
                    var j = i + 1
                    while j < n, clusterIndex(idx[j], clusterStarts) == cl { j += 1 }
                    let g = Array(glyphs[i..<j])
                    let p0 = pos[i]
                    let offs = (i..<j).map { CGPoint(x: pos[$0].x - p0.x, y: -(pos[$0].y - p0.y)) }
                    let advance = (i..<j).reduce(CGFloat(0)) { $0 + adv[$1].width }
                    var rects = [CGRect](repeating: .zero, count: g.count)
                    CTFontGetBoundingRectsForGlyphs(font, .default, g, &rects, g.count)
                    var ink = CGRect.null
                    for (k, r) in rects.enumerated() where !r.isEmpty {
                        ink = ink.union(CGRect(x: offs[k].x + r.minX, y: offs[k].y - r.maxY, width: r.width, height: r.height))
                    }
                    let u16 = clusterStarts[cl]
                    let ch = characterAt(s, utf16: u16)
                    let ws = ch?.isWhitespace ?? true
                    let origin = CGPoint(x: o.x + p0.x, y: baseline - p0.y)
                    clusters.append(LaidCluster(font: font, glyphs: g, offsets: offs, advance: advance, ascent: fa, descent: fd,
                                                ink: ink.isNull ? .zero : ink, transform: CGAffineTransform(translationX: origin.x, y: origin.y),
                                                utf16: u16, charIndex: -1, wordIndex: -1, lineIndex: li, style: style(u16),
                                                isWhitespace: ws, isColorGlyph: isColor, underlinePosition: ulPos,
                                                underlineThickness: ulTh))
                    if !ws { lineMinX = min(lineMinX, origin.x); lineMaxX = max(lineMaxX, origin.x + advance) }
                    i = j
                }
            }
            if lineMinX > lineMaxX { lineMinX = o.x; lineMaxX = o.x + max(width, 0) }
            laidLines.append(LaidLine(rect: CGRect(x: lineMinX, y: baseline - ascent, width: lineMaxX - lineMinX, height: ascent + descent),
                                      baseline: baseline))
        }
        return TextLayoutResult(clusters: clusters, lines: laidLines, words: [], bounds: .null, fontPx: fontPx, visibleCharCount: 0, isBent: false)
    }

    // MARK: Vertical (characters stacked, columns right → left)

    static func verticalLayout(_ t: TextContent, _ s: String, fontPx: CGFloat, style: (Int) -> TextRunStyle) -> TextLayoutResult {
        struct Item { var cluster: LaidCluster; var height: CGFloat }
        var columns: [[Item]] = [[]]
        var u16 = 0
        let gap = CGFloat(t.letterSpacing) * fontPx
        for ch in s {
            let len = ch.utf16.count
            defer { u16 += len }
            if ch == "\n" { columns.append([]); continue }
            let st = style(u16)
            let font = ctFont(st, t, fontPx)
            let attr = NSAttributedString(string: String(ch), attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let line = CTLineCreateWithAttributedString(attr)
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let n = CTRunGetGlyphCount(run)
                guard n > 0 else { continue }
                var glyphs = [CGGlyph](repeating: 0, count: n), pos = [CGPoint](repeating: .zero, count: n)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs); CTRunGetPositions(run, CFRange(location: 0, length: 0), &pos)
                let attrs = CTRunGetAttributes(run) as NSDictionary
                let rf = attrs[kCTFontAttributeName as String].map { $0 as! CTFont } ?? font
                var rects = [CGRect](repeating: .zero, count: n)
                CTFontGetBoundingRectsForGlyphs(rf, .default, glyphs, &rects, n)
                var ink = CGRect.null
                for (k, r) in rects.enumerated() where !r.isEmpty {
                    ink = ink.union(CGRect(x: pos[k].x + r.minX, y: -r.maxY, width: r.width, height: r.height))
                }
                let adv = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                let a = CTFontGetAscent(rf), d = CTFontGetDescent(rf)
                let c = LaidCluster(font: rf, glyphs: glyphs, offsets: pos.map { CGPoint(x: $0.x, y: -$0.y) }, advance: adv, ascent: a,
                                    descent: d, ink: ink.isNull ? .zero : ink, transform: .identity, utf16: u16, charIndex: -1,
                                    wordIndex: -1, lineIndex: columns.count - 1, style: st, isWhitespace: ch.isWhitespace,
                                    isColorGlyph: CTFontGetSymbolicTraits(rf).contains(.traitColorGlyphs),
                                    underlinePosition: -CTFontGetUnderlinePosition(rf), underlineThickness: max(CTFontGetUnderlineThickness(rf), fontPx * 0.05))
                columns[columns.count - 1].append(Item(cluster: c, height: (a + d) * 0.92 + gap))
                break
            }
        }
        let colW = fontPx * 1.15 + CGFloat(t.lineSpacing) * fontPx
        let heights = columns.map { $0.reduce(0) { $0 + $1.height } }
        let maxH = heights.max() ?? 0
        var clusters: [LaidCluster] = []
        var lines: [LaidLine] = []
        for (ci, col) in columns.enumerated() {
            let cx = CGFloat(columns.count - 1 - ci) * colW + colW / 2
            var y: CGFloat
            switch t.alignment {
            case .left, .justify: y = 0
            case .center: y = (maxH - heights[ci]) / 2
            case .right: y = maxH - heights[ci]
            }
            let top = y
            for var it in col {
                let c = it.cluster
                it.cluster.transform = CGAffineTransform(translationX: cx - c.advance / 2, y: y + c.ascent * 0.92)
                clusters.append(it.cluster)
                y += it.height
            }
            lines.append(LaidLine(rect: CGRect(x: cx - colW / 2, y: top, width: colW, height: max(y - top, fontPx)), baseline: top))
        }
        var r = TextLayoutResult(clusters: clusters, lines: lines, words: [], bounds: .null, fontPx: fontPx, visibleCharCount: 0, isBent: false)
        finish(&r, s)
        return r
    }

    // MARK: Curve / path

    /// Bends every line along a circular arc. |curve| = 1 wraps the widest line around ~324°.
    static func applyCurve(_ curve: Double, to r: inout TextLayoutResult) {
        guard let first = r.lines.first else { return }
        let width = r.lines.map(\.rect.width).max() ?? 0
        guard width > 1 else { return }
        let theta = CGFloat(abs(curve)) * 1.8 * .pi
        let R = width / theta
        let cx = (r.lines.map(\.rect.minX).min()! + r.lines.map(\.rect.maxX).max()!) / 2
        let b0 = first.baseline
        let arch = curve > 0
        for i in r.clusters.indices {
            let c = r.clusters[i]
            let origin = CGPoint(x: c.transform.tx, y: c.transform.ty)
            let u = origin.x + c.advance / 2 - cx
            let yb = origin.y
            let phi = u / R
            let pos: CGPoint, rot: CGFloat
            if arch {
                let rad = R - (yb - b0)
                pos = CGPoint(x: cx + rad * sin(phi), y: b0 + R - rad * cos(phi))
                rot = phi
            } else {
                let rad = R + (yb - b0)
                pos = CGPoint(x: cx + rad * sin(phi), y: b0 - R + rad * cos(phi))
                rot = -phi
            }
            r.clusters[i].transform = CGAffineTransform(translationX: -c.advance / 2, y: 0)
                .concatenating(CGAffineTransform(rotationAngle: rot)).concatenating(CGAffineTransform(translationX: pos.x, y: pos.y))
        }
        r.isBent = true
    }

    /// Places glyphs along a path shape, by arc length (TX-010).
    static func applyPath(_ shape: TextPathShape, to r: inout TextLayoutResult) {
        guard let first = r.lines.first else { return }
        let width = r.lines.map(\.rect.width).max() ?? 0
        guard width > 1 else { return }
        let minX = r.lines.map(\.rect.minX).min()!
        let pts = pathPoints(shape, length: width, em: r.fontPx)
        guard pts.count >= 2 else { return }
        var cum: [CGFloat] = [0]
        for i in 1..<pts.count { cum.append(cum[i - 1] + hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)) }
        let total = cum.last!
        func sample(_ d: CGFloat) -> (CGPoint, CGFloat) {
            let x = min(max(d, 0), total)
            var k = 1
            while k < cum.count - 1, cum[k] < x { k += 1 }
            let seg = max(cum[k] - cum[k - 1], 1e-6), f = (x - cum[k - 1]) / seg
            let a = pts[k - 1], b = pts[k]
            return (CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f), atan2(b.y - a.y, b.x - a.x))
        }
        let scale = total / width
        for i in r.clusters.indices {
            let c = r.clusters[i]
            let origin = CGPoint(x: c.transform.tx, y: c.transform.ty)
            let d = (origin.x - minX + c.advance / 2) * scale
            let (p, ang) = sample(d)
            let normalOff = origin.y - first.baseline
            let pos = CGPoint(x: p.x - sin(ang) * normalOff, y: p.y + cos(ang) * normalOff)
            r.clusters[i].transform = CGAffineTransform(translationX: -c.advance / 2, y: 0)
                .concatenating(CGAffineTransform(rotationAngle: ang)).concatenating(CGAffineTransform(translationX: pos.x, y: pos.y))
        }
        r.isBent = true
    }

    /// Polyline of a path shape, y down, roughly `length` long.
    static func pathPoints(_ s: TextPathShape, length: CGFloat, em: CGFloat) -> [CGPoint] {
        let n = 96
        let a = CGFloat(min(max(s.amount, 0), 1))
        switch s.kind {
        case .circle:
            let R = length / (2 * .pi) * 1.02
            // text centred on the top of the circle, running clockwise
            return (0...n).map { i in
                let ang = -3 * CGFloat.pi / 2 + 2 * .pi * CGFloat(i) / CGFloat(n)
                return CGPoint(x: R * cos(ang), y: R * sin(ang))
            }
        case .wave:
            let amp = em * (0.15 + 0.55 * a), cycles = 1 + a
            return (0...n).map { i in
                let x = length * CGFloat(i) / CGFloat(n)
                return CGPoint(x: x, y: -amp * sin(2 * .pi * cycles * x / length))
            }
        case .arch:
            let h = length * (0.1 + 0.35 * a)
            return (0...n).map { i in
                let u = CGFloat(i) / CGFloat(n)
                return CGPoint(x: length * u, y: -4 * h * u * (1 - u))
            }
        case .spiral:
            // ~1.25 turns, radius shrinking to 55 %, scaled so the arc length matches the text
            let turns = 1 + 0.5 * a
            let raw: [CGPoint] = (0...n).map { i in
                let u = CGFloat(i) / CGFloat(n)
                let ang = -.pi + u * 2 * .pi * turns
                let rad = 1 - 0.45 * u
                return CGPoint(x: rad * cos(ang), y: rad * sin(ang))
            }
            var l: CGFloat = 0
            for i in 1..<raw.count { l += hypot(raw[i].x - raw[i - 1].x, raw[i].y - raw[i - 1].y) }
            let k = length / max(l, 1e-6)
            return raw.map { CGPoint(x: $0.x * k, y: $0.y * k) }
        case .custom:
            var raw = s.points.map { CGPoint(x: $0.x, y: $0.y) }
            guard raw.count >= 2 else { return [CGPoint(x: 0, y: 0), CGPoint(x: length, y: 0)] }
            // Chaikin smoothing: sharp corners would make neighbouring glyphs collide
            for _ in 0..<3 where raw.count >= 3 {
                var out = [raw[0]]
                for i in 0..<(raw.count - 1) {
                    let p = raw[i], q = raw[i + 1]
                    out.append(CGPoint(x: p.x * 0.75 + q.x * 0.25, y: p.y * 0.75 + q.y * 0.25))
                    out.append(CGPoint(x: p.x * 0.25 + q.x * 0.75, y: p.y * 0.25 + q.y * 0.75))
                }
                out.append(raw[raw.count - 1])
                raw = out
            }
            var l: CGFloat = 0
            for i in 1..<raw.count { l += hypot(raw[i].x - raw[i - 1].x, raw[i].y - raw[i - 1].y) }
            let k = length / max(l, 1e-6)
            return raw.map { CGPoint(x: $0.x * k, y: $0.y * k) }
        }
    }

    // MARK: Units, words, bounds

    static func finish(_ r: inout TextLayoutResult, _ s: String) {
        // visible char indices in logical order
        let order = r.clusters.indices.sorted { r.clusters[$0].utf16 < r.clusters[$1].utf16 }
        var vis = 0
        for i in order where !r.clusters[i].isWhitespace { r.clusters[i].charIndex = vis; vis += 1 }
        r.visibleCharCount = vis
        let words = TextTokenizer.words(in: s)
        var laid = [LaidWord](repeating: LaidWord(rect: .null, clusters: []), count: words.count)
        for i in r.clusters.indices where !r.clusters[i].isWhitespace {
            let u = r.clusters[i].utf16
            if let w = words.firstIndex(where: { $0.location <= u && u < $0.end }) {
                r.clusters[i].wordIndex = w
                laid[w].clusters.append(i)
                laid[w].rect = laid[w].rect.union(r.clusters[i].box.applying(r.clusters[i].transform))
            }
        }
        r.words = laid.map { $0.rect.isNull ? LaidWord(rect: .zero, clusters: []) : $0 }
        var b = CGRect.null
        for c in r.clusters {
            if !c.isWhitespace { b = b.union(c.box.applying(c.transform)); if !c.ink.isEmpty { b = b.union(c.ink.applying(c.transform)) } }
        }
        if b.isNull { b = r.lines.first.map { CGRect(x: $0.rect.minX, y: $0.rect.minY, width: max($0.rect.width, 1), height: $0.rect.height) } ?? .zero }
        r.bounds = b
        if r.isBent {
            for i in r.lines.indices { r.lines[i].rect = b }
        }
    }

    static func graphemeStarts(_ s: String) -> [Int] {
        var out: [Int] = []
        var o = 0
        for ch in s { out.append(o); o += ch.utf16.count }
        return out.isEmpty ? [0] : out
    }

    static func clusterIndex(_ u16: Int, _ starts: [Int]) -> Int {
        var lo = 0, hi = starts.count - 1
        while lo < hi { let m = (lo + hi + 1) / 2; if starts[m] <= u16 { lo = m } else { hi = m - 1 } }
        return lo
    }

    static func characterAt(_ s: String, utf16 o: Int) -> Character? {
        let u = s.utf16
        guard o < u.count, let i = u.index(u.startIndex, offsetBy: o, limitedBy: u.endIndex),
              let si = i.samePosition(in: s) else { return nil }
        return s[si]
    }
}
