import Foundation

/// Canvas-aware caption layout (CapCut parity, owner bug report on 9:16 footage). `TextContent.fontSize` is a fraction
/// of the canvas *height*, so a fixed caption size is ~1.8× too big on a vertical canvas: captions are sized from the
/// frame's short side instead, placed in the lower third above the platform UI (Reels / TikTok / Shorts caption and
/// buttons), and segmented so a caption is at most two lines inside the safe width. The renderer enforces the same safe
/// width (wrap, then auto-shrink as a last resort — `TextSceneBuilder`), so even edited or old captions never leave the frame.
public enum CaptionLayout {
    /// Fraction of the canvas width a caption line may use (centred: ≈ 7 % margin each side).
    public static let safeWidth = 0.86
    /// CapCut: "One piece of caption can be divided into at most two lines".
    public static let maxLines = 2
    /// Smallest scale the renderer's auto-shrink may apply to a caption that still doesn't fit.
    public static let minFitScale = 0.35
    /// Average advance of a bold sans-serif glyph incl. spaces, em (line-length estimate before layout).
    public static let averageGlyphEm = 0.56

    static func isPortrait(_ c: Size2) -> Bool { c.height > 0 && c.width / c.height < 0.85 }

    /// Default caption font size (fraction of canvas height): 5.5 % of the height on landscape / square canvases
    /// (unchanged look), 6 % of the width on portrait canvases (≈ 65 px on 1080×1920).
    public static func fontSize(canvas: Size2) -> Double {
        guard canvas.width > 0, canvas.height > 0 else { return 0.055 }
        return canvas.width >= canvas.height ? 0.055 : 0.06 * canvas.width / canvas.height
    }

    /// Default caption centre (`Transform.position`, fraction of the canvas from its centre). Portrait: 70 % of the height,
    /// i.e. lower third but above the bottom ~25 % that Reels / TikTok / Shorts cover with their caption and buttons.
    public static func position(canvas: Size2) -> Vec2 {
        guard canvas.height > 0 else { return Vec2(0, 0.36) }
        if isPortrait(canvas) { return Vec2(0, 0.2) }
        if canvas.width / canvas.height < 1.2 { return Vec2(0, 0.3) }
        return Vec2(0, 0.36)
    }

    /// Characters per caption line that fit the safe width at `fontSize` (default: the canvas default), clamped to
    /// 12…40 (CapCut-like readability: ≤ ~40 characters per line).
    public static func maxCharsPerLine(canvas: Size2, fontSize: Double? = nil) -> Int {
        guard canvas.width > 0, canvas.height > 0 else { return 28 }
        let em = (fontSize ?? Self.fontSize(canvas: canvas)) * canvas.height
        guard em > 0 else { return 28 }
        let n = Int((safeWidth * canvas.width / (averageGlyphEm * em)).rounded(.down))
        return min(max(n, 12), 40)
    }
}
