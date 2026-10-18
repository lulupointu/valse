import CoreText
import Foundation
import MontageCore
import MontageEffects

/// Canvas-pixel size of text / sticker layers without rasterizing (player handles, hit-testing, inline editing).
/// Mirrors the layout of `TextRasterizer.render` (same font, frame-setter fit and padding); keep both in sync.
public enum TextMetrics {
    private struct Key: Hashable { let content: TextContent; let height: Int }
    nonisolated(unsafe) private static var cache: [Key: Size2] = [:]
    private static let lock = NSLock()

    /// Font used for `t` at `fontPx` (shared with the inline text editor).
    public static func font(_ t: TextContent, fontPx: Double) -> CTFont {
        var font = t.fontName.isEmpty
            ? CTFontCreateUIFontForLanguage(.system, fontPx, nil) ?? CTFontCreateWithName("Helvetica" as CFString, fontPx, nil)
            : CTFontCreateWithName(t.fontName as CFString, fontPx, nil)
        var traits: CTFontSymbolicTraits = []
        if t.bold { traits.insert(.traitBold) }
        if t.italic { traits.insert(.traitItalic) }
        if !traits.isEmpty, let f = CTFontCreateCopyWithSymbolicTraits(font, fontPx, nil, traits, traits) { font = f }
        return font
    }

    /// Padding around the glyph box, in the same units as `fontPx`.
    public static func padding(_ t: TextContent, fontPx: Double) -> Double {
        ceil(max(t.strokeWidth * fontPx, 0) + fontPx * 0.15 + (t.shadowColor.a > 0 ? fontPx * 0.12 : 0))
    }

    /// Size of the rasterized text box in canvas pixels for a canvas of height `canvasHeight`.
    public static func size(of t: TextContent, canvasHeight: Double) -> Size2 {
        let key = Key(content: t, height: Int(canvasHeight.rounded()))
        if let s = lock.withLock({ cache[key] }) { return s }
        let fontPx = t.fontSize * canvasHeight
        guard fontPx >= 1 else { return .zero }
        let string = t.string.isEmpty ? " " : t.string
        var spacing = CGFloat(t.lineSpacing * fontPx)
        let para: CTParagraphStyle = withUnsafeBytes(of: &spacing) { sp in
            let settings = [CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size,
                                                    value: sp.baseAddress!)]
            return CTParagraphStyleCreate(settings, settings.count)
        }
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font(t, fontPx: fontPx),
            NSAttributedString.Key(kCTKernAttributeName as String): t.letterSpacing * fontPx,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): para,
        ]
        let fs = CTFramesetterCreateWithAttributedString(NSAttributedString(string: string, attributes: attrs))
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRange(location: 0, length: 0), nil,
                                                               CGSize(width: 100_000, height: 100_000), nil)
        let pad = padding(t, fontPx: fontPx)
        let s = Size2(ceil(fit.width) + 2 * pad, ceil(fit.height) + 2 * pad)
        lock.withLock {
            if cache.count > 256 { cache.removeAll() }
            cache[key] = s
        }
        return s
    }

    /// Canvas-pixel size of a sticker layer whose nominal side is `side` (see `FrameEvaluator.layer`).
    public static func stickerSize(_ id: String, side: Double) -> Size2 {
        guard let d = Registries.stickers[id] else { return Size2(side, side) }
        switch d.source {
        case .emoji(let e):
            var t = TextContent(string: e)
            t.fontSize = 0.8
            return size(of: t, canvasHeight: side)
        case .image:
            return Size2(side, side)
        }
    }
}
