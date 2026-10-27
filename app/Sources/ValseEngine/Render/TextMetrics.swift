import CoreText
import Foundation
import ValseCore
import ValseEffects

/// Canvas-pixel size of text / sticker layers without rasterizing (player handles, hit-testing, inline editing).
/// Backed by the text engine's layout (`TextRasterizer.textBox` / `measure`, cached), so handles always hug what is
/// rendered — curves, paths, vertical text, runs, templates included.
public enum TextMetrics {
    /// Font used for `t` at `fontPx` (shared with the inline text editor; same resolution as the renderer).
    public static func font(_ t: TextContent, fontPx: Double) -> CTFont {
        TextFonts.font(name: t.fontName, size: CGFloat(fontPx), bold: t.bold, italic: t.italic)
    }

    /// Padding between the layer box and the glyphs, in the same units as `fontPx` (the box hugs the glyphs).
    public static func padding(_ t: TextContent, fontPx: Double) -> Double { 0 }

    /// Size of the text box (glyphs, no effect padding) in canvas pixels. The layer is centred on it.
    public static func size(of t: TextContent, canvasHeight: Double, canvasWidth: Double? = nil) -> Size2 {
        guard t.fontSize * canvasHeight >= 1 else { return .zero }
        var c = t
        if c.string.isEmpty && c.template == nil { c.string = " " }
        let box = FrameRenderer.shared.text.textBox(c, canvasSize: Size2(canvasWidth ?? canvasHeight * 16 / 9, canvasHeight))
        return Size2(ceil(box.size.width), ceil(box.size.height))
    }

    /// Canvas-pixel size of a sticker layer whose nominal side is `side` (see `FrameEvaluator.layer`).
    public static func stickerSize(_ id: String, side: Double) -> Size2 {
        guard let d = Registries.stickers[id] else { return Size2(side, side) }
        switch d.source {
        case .emoji(let e):
            var t = TextContent(string: e)
            t.fontSize = 0.8
            return FrameRenderer.shared.text.measure(t, canvasSize: Size2(side * 16 / 9, side))
        case .image, .vector, .lottie:
            return Size2(side, side)
        case .user(let uid):
            return UserStickerLibrary.shared.size(uid, side: side)
        }
    }
}
