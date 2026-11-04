import CoreGraphics
import Foundation
import ValseCore

/// Neon tube painter (TX-NEON), reusable for any outline: glyphs (filled tube = the glyph shape) and shapes such as
/// bubble borders (stroked tube: pass `stroked: true`, the path is turned into a tube of `thickness` × 3).
///
/// Look, back to front: faint wide light spill → soft halo → tight glow (all in the tube colour, cast from the tube
/// silhouette with Core Graphics shadows, the silhouette itself cleared) | near-white core tinted toward the colour →
/// tight inner glow from the edge → thin coloured tube edge. All sizes scale with `em` (pixels per em), so a 4K
/// export is as sharp as the preview; the context's CTM must map path space to device pixels without scaling
/// (scene space), like every other text item.
enum NeonPainter {
    /// Neon parameters in pixels.
    struct Params {
        var color: RGBA
        var intensity: CGFloat
        var glow: CGFloat
        var thickness: CGFloat
        /// Flicker brightness 0…1 (1 = fully lit).
        var level: CGFloat

        init(_ s: TextNeonStyle, em: CGFloat, level: Double = 1) {
            color = s.color
            intensity = CGFloat(min(max(s.intensity, 0), 1))
            glow = max(CGFloat(s.glowSize) * em, 0.5)
            thickness = max(CGFloat(s.thickness) * em, 0.5)
            self.level = CGFloat(min(max(level, 0), 1))
        }
    }

    /// Paints a whole neon tube along `path` at clip-local time `time` (flicker of `style.flicker`, unit = glyph /
    /// segment index for per-unit flicker). `stroked`: the path is a line / outline (bubble border) rather than a
    /// filled shape (glyph).
    static func draw(_ path: CGPath, style: TextNeonStyle, em: CGFloat, time: Double, unit: Int = 0, stroked: Bool = false,
                     in ctx: CGContext) {
        let level = TextNeonStyle.flickerLevel(style.flicker, t: time, unit: unit)
        let p = Params(style, em: em, level: level)
        let shape = stroked ? tube(path, p) : path
        drawHalo(shape, p, in: ctx)
        drawTube(shape, p, in: ctx)
    }

    /// How far the light reaches outside the tube silhouette, px (matches `TextNeonStyle.extentEm`).
    static func reach(_ p: Params) -> CGFloat { p.glow * 3.2 + p.thickness * 2 }

    /// Silhouette of a stroked tube (the outline `path` becomes a filled shape).
    static func tube(_ path: CGPath, _ p: Params) -> CGPath {
        path.copy(strokingWithWidth: p.thickness * 3, lineCap: .round, lineJoin: .round, miterLimit: 4)
    }

    /// Outward light (spill, halo, tight glow) cast by the filled tube silhouette `shape`; the silhouette itself is
    /// left empty (the tube is painted over it by `drawTube`).
    static func drawHalo(_ shape: CGPath, _ p: Params, in ctx: CGContext) {
        let I = p.intensity * p.level
        guard I > 0.004 else { return }
        ctx.saveGState()
        ctx.setFillColor(TextPainter.cg(p.color)); ctx.setStrokeColor(TextPainter.cg(p.color))
        ctx.setLineJoin(.round)
        // Only the light is wanted, not the shape casting it: the shape is drawn far away (outside the clip) and its
        // shadow offset brings the light back under the tube. Shadow offsets live in device space, so the user-space
        // shift is mapped through the CTM (item transforms may rotate / scale).
        let box = shape.boundingBoxOfPath
        let far = box.width + box.height + p.glow * 8 + 4096
        let dev = CGSize(width: far, height: 0).applying(ctx.userSpaceToDeviceSpaceTransform)
        ctx.clip(to: box.insetBy(dx: -reach(p), dy: -reach(p)))   // the far-away shape itself never shows
        ctx.translateBy(x: far, y: 0)
        // A Gaussian of a thin stroke is faint: each light layer is cast from the tube grown by `grow` (so the light has a
        // body), and repeated `n` times (alpha accumulates) for a dense, saturated glow.
        func cast(_ blur: CGFloat, _ alpha: CGFloat, grow: CGFloat, n: Int = 1) {
            guard alpha > 0.002 else { return }
            ctx.setShadow(offset: CGSize(width: -dev.width, height: -dev.height), blur: blur,
                          color: TextPainter.cg(p.color, alpha: Double(min(alpha, 1))))
            for _ in 0..<n {
                ctx.addPath(shape); ctx.fillPath()
                if grow > 0 { ctx.addPath(shape); ctx.setLineWidth(grow * 2); ctx.strokePath() }
            }
        }
        cast(p.glow * 2.2, 0.35 * I, grow: p.glow * 0.4)                       // light spill on the surroundings
        cast(p.glow, 0.95 * I, grow: p.glow * 0.2)                              // soft halo
        cast(p.glow * 0.4, 0.9 * I, grow: p.thickness * 1.5, n: 2)              // halo body
        cast(max(p.thickness * 2, 2), 1.0 * I, grow: p.thickness * 0.5, n: 2)   // tight glow hugging the tube
        ctx.restoreGState()
    }

    /// The glass tube itself: near-white core, inner glow from the edge, thin coloured edge. Unlit (`level` 0) it is a
    /// dim tinted glass tube.
    static func drawTube(_ shape0: CGPath, _ p: Params, in ctx: CGContext) {
        // glyph outlines often overlap (variable fonts): merge them so the edge line has no inner seams (macOS 14+)
        var shape = shape0
        if #available(macOS 14, *) { shape = shape0.normalized() }
        let lit = p.level
        let col = p.color
        let unlit = col.mix(RGBA(0.35, 0.35, 0.38), 0.65)
        // core: white-hot, tinted toward the tube colour (more when dimmer)
        let hot = RGBA.white.mix(col, Double(0.1 + 0.25 * (1 - p.intensity)))
        let core = unlit.mix(hot, Double(lit))
        let edgeCol = unlit.mix(col, Double(lit))
        ctx.saveGState()
        ctx.setLineJoin(.round)
        // tube edge: a coloured ring just outside the outline (the tube is the glyph grown by `thickness`, so thin
        // fonts still get a real tube)
        ctx.addPath(shape)
        ctx.setStrokeColor(TextPainter.cg(edgeCol)); ctx.setLineWidth(p.thickness * 2)
        ctx.strokePath()
        // core: the glyph (slightly grown) in near-white
        ctx.setFillColor(TextPainter.cg(core)); ctx.setStrokeColor(TextPainter.cg(core))
        ctx.addPath(shape); ctx.fillPath()
        ctx.addPath(shape); ctx.setLineWidth(p.thickness * 0.6); ctx.strokePath()
        // inner glow: colour bleeding in from the edge = a blurred line on the outline, clipped to the glyph (non-zero
        // winding, so overlapping contours stay solid)
        ctx.addPath(shape); ctx.clip()
        ctx.setShadow(offset: .zero, blur: p.thickness * 1.1, color: TextPainter.cg(edgeCol, alpha: Double(0.4 + 0.3 * lit)))
        ctx.setStrokeColor(TextPainter.cg(edgeCol, alpha: 0.35)); ctx.setLineWidth(p.thickness * 0.5)
        ctx.addPath(shape); ctx.strokePath()
        ctx.restoreGState()
    }
}
