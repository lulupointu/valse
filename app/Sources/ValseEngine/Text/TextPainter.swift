import CoreGraphics
import CoreText
import Foundation
import ValseCore
import ValseEffects

/// Core Graphics painting of scene items. The context's CTM maps scene space (pixels, y down) to the device; every item
/// concatenates its own transform. Glyphs are drawn from their outlines, so strokes (inside the fill), multi-layer
/// outlines, gradient / texture fills, glows and 3D shadows are all exact vector operations.
enum TextPainter {
    // MARK: Glyph outlines (cached)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var paths: [String: CGPath] = [:]

    static func glyphPath(_ font: CTFont, _ g: CGGlyph) -> CGPath? {
        let key = "\(CTFontCopyPostScriptName(font))|\(CTFontGetSize(font))|\(CTFontGetMatrix(font).c)|\(g)"
        if let p = lock.withLock({ paths[key] }) { return p }
        var flip = CGAffineTransform(scaleX: 1, y: -1)
        guard let p = CTFontCreatePathForGlyph(font, g, &flip) else { return nil }
        lock.withLock { paths[key] = p; if paths.count > 8192 { paths.removeAll() } }
        return p
    }

    /// Outline of a cluster in its local space (nil for colour glyphs / empty).
    static func clusterPath(_ c: LaidCluster) -> CGPath? {
        if c.isColorGlyph { return nil }
        let m = CGMutablePath()
        for (g, o) in zip(c.glyphs, c.offsets) {
            if let p = glyphPath(c.font, g) { m.addPath(p, transform: CGAffineTransform(translationX: o.x, y: o.y)) }
        }
        return m.isEmpty ? nil : m
    }

    static func cg(_ c: RGBA, alpha: Double? = nil) -> CGColor {
        CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: alpha ?? c.a)
    }

    // MARK: Items

    static func draw(_ item: TextScene.Item, scene: TextScene, in ctx: CGContext) {
        let b = scene.blocks[item.block]
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.concatenate(item.transform)
        switch item.kind {
        case .bubble(let shape, let fill, let stroke, let sw, let rect):
            let p = BubblePaths.path(shape, rect: rect, em: b.em)
            if fill.a > 0 { ctx.addPath(p); ctx.setFillColor(cg(fill)); ctx.fillPath() }
            if let s = stroke, sw > 0 {
                ctx.addPath(p); ctx.setStrokeColor(cg(s)); ctx.setLineWidth(sw); ctx.setLineJoin(.round); ctx.strokePath()
            }
        case .shape(let shape, let color, let rect):
            let p = BubblePaths.path(shape, rect: rect, em: b.em)
            ctx.addPath(p); ctx.setFillColor(cg(color))
            if case .brackets = shape { ctx.setStrokeColor(cg(color)); ctx.setLineWidth(b.em * 0.08); ctx.strokePath() } else { ctx.fillPath() }
        case .background(let rect, let color, let radius), .wordBox(let rect, let color, let radius):
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.setFillColor(cg(color)); ctx.fillPath()
        case .glyphBack(let ci, let v):
            let st = b.style(for: b.layout.clusters[ci], highlight: v == .highlight)
            drawBack(b.painted(b.layout.clusters[ci], highlight: v == .highlight), style: st, em: b.em, itemTransform: item.transform, in: ctx)
        case .glyphFront(let ci, let v):
            let st = b.style(for: b.layout.clusters[ci], highlight: v == .highlight)
            drawFront(b.painted(b.layout.clusters[ci], highlight: v == .highlight), style: st, highlight: v == .highlight, em: b.em, itemTransform: item.transform,
                      gradientRect: b.gradientRect, in: ctx)
        }
    }

    /// Silhouette = fill + outline (what shadows and outer glows are cast from).
    static func silhouette(_ path: CGPath, width: CGFloat, in ctx: CGContext) {
        ctx.addPath(path); ctx.fillPath()
        if width > 0 { ctx.addPath(path); ctx.setLineWidth(width * 2); ctx.setLineJoin(.round); ctx.strokePath() }
    }

    /// Vector `d` in scene space expressed in item-local space.
    static func toLocal(_ d: CGPoint, _ m: CGAffineTransform) -> CGPoint {
        let inv = CGAffineTransform(a: m.a, b: m.b, c: m.c, d: m.d, tx: 0, ty: 0).inverted()
        return d.applying(inv)
    }

    static func drawBack(_ c: LaidCluster, style st: TextContent, em: CGFloat, itemTransform M: CGAffineTransform, in ctx: CGContext) {
        guard let path = clusterPath(c) else {
            if c.isColorGlyph, st.shadowColor.a > 0 { drawColorGlyphShadow(c, st, em, M, ctx) }
            return
        }
        let outer = CGFloat(st.strokeExtentEm) * em
        // shadow
        if st.shadowColor.a > 0 {
            let ang = st.shadow.angle * .pi / 180
            let d = CGPoint(x: cos(ang) * st.shadow.distance * Double(em), y: sin(ang) * st.shadow.distance * Double(em))
            if st.shadow.extrude {
                let steps = max(1, min(64, Int(hypot(d.x, d.y).rounded())))
                ctx.setFillColor(cg(st.shadowColor)); ctx.setStrokeColor(cg(st.shadowColor))
                for k in stride(from: steps, through: 1, by: -1) {
                    let f = CGFloat(k) / CGFloat(steps)
                    let l = toLocal(CGPoint(x: d.x * f, y: d.y * f), M)
                    ctx.saveGState(); ctx.translateBy(x: l.x, y: l.y)
                    silhouette(path, width: outer, in: ctx)
                    ctx.restoreGState()
                }
            } else {
                ctx.saveGState()
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                // CG shadow offsets live in device space (y up)
                ctx.setShadow(offset: CGSize(width: d.x, height: -d.y), blur: CGFloat(st.shadow.blur) * em, color: cg(st.shadowColor))
                ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
                silhouette(path, width: outer, in: ctx)
                ctx.setShadow(offset: .zero, blur: 0, color: nil)
                ctx.setBlendMode(.clear)
                silhouette(path, width: outer, in: ctx)
                ctx.endTransparencyLayer()
                ctx.restoreGState()
            }
        }
        // outer glow
        if let g = st.glow, g.mode != .inner, g.intensity > 0 {
            ctx.saveGState()
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            let alpha = min(1, g.intensity * 1.2)
            ctx.setShadow(offset: .zero, blur: CGFloat(g.radius) * em, color: cg(g.color, alpha: alpha))
            ctx.setFillColor(cg(g.color)); ctx.setStrokeColor(cg(g.color))
            for _ in 0..<(g.intensity > 0.6 ? 2 : 1) { silhouette(path, width: outer, in: ctx) }
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setBlendMode(.clear)
            silhouette(path, width: outer, in: ctx)
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
        // outlines, outermost first
        ctx.setLineJoin(.round)
        for s in st.extraStrokes.sorted(by: { $0.width > $1.width }) where s.width > 0 {
            ctx.addPath(path); ctx.setStrokeColor(cg(s.color)); ctx.setLineWidth(CGFloat(s.width) * em * 2); ctx.strokePath()
        }
        if st.strokeWidth > 0, st.strokePosition == .outside {
            ctx.addPath(path); ctx.setStrokeColor(cg(c.style.strokeColor ?? st.strokeColor))
            ctx.setLineWidth(CGFloat(st.strokeWidth) * em * 2); ctx.strokePath()
        }
    }

    /// Centre / inside primary stroke (TX-005): painted over the fill. Centre straddles the edge (width w), inside is
    /// a 2w line clipped to the glyph so exactly w shows inside the edge.
    static func drawInnerStroke(_ path: CGPath, _ c: LaidCluster, style st: TextContent, em: CGFloat, in ctx: CGContext) {
        guard st.strokeWidth > 0, st.strokePosition != .outside else { return }
        ctx.saveGState()
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(cg(c.style.strokeColor ?? st.strokeColor))
        if st.strokePosition == .inside {
            ctx.addPath(path); ctx.clip()
            ctx.setLineWidth(CGFloat(st.strokeWidth) * em * 2)
        } else {
            ctx.setLineWidth(CGFloat(st.strokeWidth) * em)
        }
        ctx.addPath(path); ctx.strokePath()
        ctx.restoreGState()
    }

    static func drawColorGlyphShadow(_ c: LaidCluster, _ st: TextContent, _ em: CGFloat, _ M: CGAffineTransform, _ ctx: CGContext) {
        let ang = st.shadow.angle * .pi / 180
        let d = CGSize(width: cos(ang) * st.shadow.distance * Double(em), height: -sin(ang) * st.shadow.distance * Double(em))
        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setShadow(offset: d, blur: CGFloat(st.shadow.blur) * em, color: cg(st.shadowColor))
        drawColorGlyphs(c, ctx)
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.setBlendMode(.clear)
        drawColorGlyphs(c, ctx)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    static func drawColorGlyphs(_ c: LaidCluster, _ ctx: CGContext) {
        for (g, o) in zip(c.glyphs, c.offsets) {
            ctx.saveGState()
            ctx.translateBy(x: o.x, y: o.y)
            ctx.scaleBy(x: 1, y: -1)
            var glyph = g
            var p = CGPoint.zero
            CTFontDrawGlyphs(c.font, &glyph, &p, 1, ctx)
            ctx.restoreGState()
        }
    }

    static func drawFront(_ c: LaidCluster, style st: TextContent, highlight: Bool, em: CGFloat, itemTransform M: CGAffineTransform,
                          gradientRect: CGRect, in ctx: CGContext) {
        let color = highlight ? st.color : (c.style.color ?? st.color)
        guard let path = clusterPath(c) else {
            if c.isColorGlyph { drawColorGlyphs(c, ctx) }
            return
        }
        switch st.fill {
        case .some(.gradient(let g)) where !highlight:
            ctx.saveGState()
            ctx.addPath(path); ctx.clip()
            ctx.concatenate(M.inverted())
            drawGradient(g, in: gradientRect, ctx)
            ctx.restoreGState()
        case .some(.texture(let tex)) where !highlight:
            ctx.saveGState()
            ctx.addPath(path); ctx.clip()
            ctx.concatenate(M.inverted())
            TextTextures.draw(tex, in: gradientRect, em: em, base: color, ctx)
            ctx.restoreGState()
        default:
            ctx.addPath(path); ctx.setFillColor(cg(color)); ctx.fillPath()
        }
        drawInnerStroke(path, c, style: st, em: em, in: ctx)
        // inner glow
        if let g = st.glow, g.mode != .outer, g.intensity > 0 {
            ctx.saveGState()
            ctx.addPath(path); ctx.clip()
            let big = CGMutablePath()
            big.addRect(c.box.insetBy(dx: -em * 2, dy: -em * 2))
            big.addPath(path)
            ctx.setShadow(offset: .zero, blur: CGFloat(g.radius) * em, color: cg(g.color, alpha: min(1, g.intensity)))
            ctx.addPath(big); ctx.setFillColor(cg(g.color)); ctx.fillPath(using: .evenOdd)
            ctx.restoreGState()
        }
        if c.style.underline ?? st.underline {
            ctx.setFillColor(cg(color))
            ctx.fill(CGRect(x: 0, y: c.underlinePosition - c.underlineThickness / 2, width: c.advance, height: c.underlineThickness))
        }
    }

    static func drawGradient(_ g: TextGradient, in rect: CGRect, _ ctx: CGContext) {
        let cols = g.colors.isEmpty ? [RGBA.white] : g.colors
        let colors = (cols.count == 1 ? [cols[0], cols[0]] : cols).map { cg($0) } as CFArray
        guard let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: nil) else { return }
        let a = g.angle * .pi / 180
        let dir = CGPoint(x: cos(a), y: sin(a))
        let half = (abs(dir.x) * rect.width + abs(dir.y) * rect.height) / 2
        let c = CGPoint(x: rect.midX, y: rect.midY)
        ctx.drawLinearGradient(grad, start: CGPoint(x: c.x - dir.x * half, y: c.y - dir.y * half),
                               end: CGPoint(x: c.x + dir.x * half, y: c.y + dir.y * half),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    // MARK: Whole scene

    /// Paints every base item at rest into `ctx` (static image).
    static func drawStatic(_ scene: TextScene, in ctx: CGContext) {
        for it in scene.items {
            if case .wordBox = it.kind { continue }
            switch it.kind {
            case .glyphBack(_, .highlight), .glyphFront(_, .highlight): continue
            default: draw(it, scene: scene, in: ctx)
            }
        }
    }
}

/// Procedural fill textures (`TextTexture.id`, see `BuiltinTextStyles.textures`). Drawn in scene space over the text box.
enum TextTextures {
    static func draw(_ t: TextTexture, in rect: CGRect, em: CGFloat, base: RGBA, _ ctx: CGContext) {
        let tile = max(em * CGFloat(t.scale), 2)
        func grad(_ stops: [(Double, UInt32)], angle: Double = 90) {
            let cols = stops.map { TextPainter.cg(RGBA(hex: $0.1)) } as CFArray
            var locs = stops.map { CGFloat($0.0) }
            guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: cols, locations: &locs) else { return }
            let a = angle * .pi / 180
            let dir = CGPoint(x: cos(a), y: sin(a))
            let half = (abs(dir.x) * rect.width + abs(dir.y) * rect.height) / 2
            let c = CGPoint(x: rect.midX, y: rect.midY)
            ctx.drawLinearGradient(g, start: CGPoint(x: c.x - dir.x * half, y: c.y - dir.y * half),
                                   end: CGPoint(x: c.x + dir.x * half, y: c.y + dir.y * half), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        let area = rect.insetBy(dx: -tile, dy: -tile)
        switch t.id {
        case "gold": grad([(0, 0xFFF3B0), (0.42, 0xE8B33A), (0.55, 0xA8741A), (0.78, 0xFFE08A), (1, 0xC68B2C)])
        case "silver": grad([(0, 0xFFFFFF), (0.45, 0xC0C0C0), (0.55, 0x7A7A7A), (0.8, 0xE6E6E6), (1, 0x9E9E9E)])
        case "holo": grad([(0, 0xFFB3F2), (0.25, 0xB3E5FF), (0.5, 0xC9FFB3), (0.75, 0xFFF3B3), (1, 0xFFB3C7)], angle: 30)
        case "stripes":
            ctx.setFillColor(TextPainter.cg(RGBA(hex: 0xFFFFFF))); ctx.fill(area)
            ctx.setStrokeColor(TextPainter.cg(RGBA(hex: 0x2F80FF))); ctx.setLineWidth(tile * 0.18)
            var x = area.minX - area.height
            while x < area.maxX {
                ctx.move(to: CGPoint(x: x, y: area.maxY)); ctx.addLine(to: CGPoint(x: x + area.height, y: area.minY)); x += tile * 0.36
            }
            ctx.strokePath()
        case "dots":
            ctx.setFillColor(TextPainter.cg(RGBA(hex: 0xFFD400))); ctx.fill(area)
            ctx.setFillColor(TextPainter.cg(RGBA(hex: 0xFF3B30)))
            let step = tile * 0.3
            var y = area.minY, row = 0
            while y < area.maxY {
                var x = area.minX + (row % 2 == 0 ? 0 : step / 2)
                while x < area.maxX { ctx.fillEllipse(in: CGRect(x: x, y: y, width: step * 0.45, height: step * 0.45)); x += step }
                y += step / 2; row += 1
            }
        case "checker":
            ctx.setFillColor(TextPainter.cg(.white)); ctx.fill(area)
            ctx.setFillColor(TextPainter.cg(RGBA(hex: 0x111111)))
            let step = tile * 0.22
            var y = area.minY, r = 0
            while y < area.maxY {
                var x = area.minX + (r % 2 == 0 ? 0 : step), k = 0
                while x < area.maxX { if k % 2 == 0 { ctx.fill(CGRect(x: x, y: y, width: step, height: step)) }; x += step * 2; k += 2 }
                y += step; r += 1
            }
        case "marble":
            ctx.setFillColor(TextPainter.cg(RGBA(hex: 0xF4F1EC))); ctx.fill(area)
            ctx.setStrokeColor(TextPainter.cg(RGBA(hex: 0x8C8C8C, alpha: 0.7)))
            for k in 0..<6 {
                ctx.setLineWidth(tile * (0.02 + 0.015 * CGFloat(k % 3)))
                let y0 = area.minY + area.height * CGFloat(k) / 6
                ctx.move(to: CGPoint(x: area.minX, y: y0))
                var x = area.minX
                while x < area.maxX {
                    x += tile * 0.1
                    ctx.addLine(to: CGPoint(x: x, y: y0 + sin(x / tile * 2.3 + CGFloat(k)) * tile * 0.25 + (x - area.minX) * 0.15))
                }
                ctx.strokePath()
            }
        case "sparkle":
            grad([(0, 0x1B1464), (1, 0x6F1E9C)])
            ctx.setFillColor(TextPainter.cg(.white))
            let n = Int(area.width * area.height / (tile * tile) * 18) + 4
            for i in 0..<min(n, 4000) {
                let x = area.minX + CGFloat(glyphRandom(i, seed: 7)) * area.width, y = area.minY + CGFloat(glyphRandom(i, seed: 13)) * area.height
                let s = tile * (0.015 + 0.04 * CGFloat(glyphRandom(i, seed: 3)))
                ctx.fillEllipse(in: CGRect(x: x, y: y, width: s, height: s))
            }
        default:
            ctx.setFillColor(TextPainter.cg(base)); ctx.fill(area)
        }
    }
}

/// Bubble / template shape outlines sized to a rectangle (y down). Radii and sizes in em.
enum BubblePaths {
    static func bounds(_ s: BubbleShape, rect: CGRect, em: CGFloat, strokeWidth: CGFloat) -> CGRect {
        path(s, rect: rect, em: em).boundingBoxOfPath.insetBy(dx: -strokeWidth - 1, dy: -strokeWidth - 1)
    }

    static func path(_ s: BubbleShape, rect r: CGRect, em: CGFloat) -> CGPath {
        let p = CGMutablePath()
        let w = r.width, h = r.height
        switch s {
        case .roundedRect(let radius):
            let rr = min(CGFloat(radius) * em, h / 2, w / 2)
            p.addRoundedRect(in: r, cornerWidth: rr, cornerHeight: rr)
        case .capsule:
            p.addRoundedRect(in: r, cornerWidth: min(h, w) / 2, cornerHeight: min(h, w) / 2)
        case .ellipse:
            p.addEllipse(in: r)
        case .speech(let radius, let tail):
            let rr = min(CGFloat(radius) * em, h / 2, w / 2)
            speech(p, r, rr, tail, em)
        case .thought:
            p.addEllipse(in: r)
            let d1 = h * 0.28, d2 = h * 0.16
            p.addEllipse(in: CGRect(x: r.minX + w * 0.18, y: r.maxY + h * 0.02, width: d1, height: d1))
            p.addEllipse(in: CGRect(x: r.minX + w * 0.1, y: r.maxY + h * 0.32, width: d2, height: d2))
        case .cloud(let bumps):
            let n = max(bumps, 5)
            let c = CGPoint(x: r.midX, y: r.midY), rx = w / 2, ry = h / 2
            let pts = (0..<n).map { i -> CGPoint in
                let a = CGFloat(i) / CGFloat(n) * 2 * .pi
                return CGPoint(x: c.x + rx * cos(a), y: c.y + ry * sin(a))
            }
            p.move(to: pts[0])
            for i in 0..<n {
                let a = pts[i], b = pts[(i + 1) % n]
                let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                let out = CGPoint(x: mid.x - c.x, y: mid.y - c.y)
                let len = max(hypot(out.x, out.y), 1e-6)
                let bulge = hypot(b.x - a.x, b.y - a.y) * 0.55
                p.addQuadCurve(to: b, control: CGPoint(x: mid.x + out.x / len * bulge, y: mid.y + out.y / len * bulge))
            }
            p.closeSubpath()
        case .burst(let spikes, let depth):
            let n = max(spikes, 5) * 2
            let c = CGPoint(x: r.midX, y: r.midY)
            let rx = w / 2 * 1.08, ry = h / 2 * 1.08
            for i in 0..<n {
                let a = CGFloat(i) / CGFloat(n) * 2 * .pi - .pi / 2
                let k = i % 2 == 0 ? 1 + CGFloat(depth) : 1
                let pt = CGPoint(x: c.x + rx * k * cos(a), y: c.y + ry * k * sin(a))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            p.closeSubpath()
        case .banner(let fold):
            let f = h * CGFloat(fold)
            p.addLines(between: [CGPoint(x: r.minX - f, y: r.minY), CGPoint(x: r.maxX + f, y: r.minY), CGPoint(x: r.maxX + f * 0.4, y: r.midY),
                                 CGPoint(x: r.maxX + f, y: r.maxY), CGPoint(x: r.minX - f, y: r.maxY), CGPoint(x: r.minX - f * 0.4, y: r.midY)])
            p.closeSubpath()
        case .tag:
            let k = h * 0.45
            p.addLines(between: [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY),
                                 CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX - k, y: r.midY)])
            p.closeSubpath()
        case .ribbon:
            let f = h * 0.6, drop = h * 0.25
            p.addLines(between: [CGPoint(x: r.minX - f, y: r.minY + drop), CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                                 CGPoint(x: r.maxX + f, y: r.minY + drop), CGPoint(x: r.maxX + f * 0.6, y: r.midY + drop / 2),
                                 CGPoint(x: r.maxX + f, y: r.maxY + drop), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY),
                                 CGPoint(x: r.minX - f, y: r.maxY + drop), CGPoint(x: r.minX - f * 0.6, y: r.midY + drop / 2)])
            p.closeSubpath()
        case .underlineBar(let height):
            let bh = min(CGFloat(height) * em, h)
            p.addRect(CGRect(x: r.minX, y: r.maxY - bh, width: w, height: bh))
        case .brackets:
            let k = min(w, h) * 0.22
            p.addLines(between: [CGPoint(x: r.minX + k, y: r.minY), CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX + k, y: r.maxY)])
            p.move(to: CGPoint(x: r.maxX - k, y: r.minY))
            p.addLines(between: [CGPoint(x: r.maxX - k, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.maxX - k, y: r.maxY)])
        case .hexagon:
            let k = h * 0.45
            p.addLines(between: [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX + k, y: r.midY),
                                 CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX - k, y: r.midY)])
            p.closeSubpath()
        case .arrow:
            let k = h * 0.55
            p.addLines(between: [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY - h * 0.15), CGPoint(x: r.maxX + k, y: r.midY),
                                 CGPoint(x: r.maxX, y: r.maxY + h * 0.15), CGPoint(x: r.minX, y: r.maxY)])
            p.closeSubpath()
        }
        return p
    }

    /// Rounded rectangle with a triangular tail, as one outline (so the stroke has no inner seams).
    static func speech(_ p: CGMutablePath, _ r: CGRect, _ rr: CGFloat, _ tail: BubbleTail, _ em: CGFloat) {
        let tw = min(r.width * 0.18, em * 0.9), tl = min(r.height * 0.6, em * 0.8)
        p.move(to: CGPoint(x: r.minX + rr, y: r.minY))
        if tail == .top {
            p.addLine(to: CGPoint(x: r.midX - tw / 2, y: r.minY)); p.addLine(to: CGPoint(x: r.midX, y: r.minY - tl))
            p.addLine(to: CGPoint(x: r.midX + tw / 2, y: r.minY))
        }
        p.addLine(to: CGPoint(x: r.maxX - rr, y: r.minY))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY + rr), radius: rr)
        if tail == .right {
            p.addLine(to: CGPoint(x: r.maxX, y: r.midY - tw / 2)); p.addLine(to: CGPoint(x: r.maxX + tl, y: r.midY + tw * 0.2))
            p.addLine(to: CGPoint(x: r.maxX, y: r.midY + tw / 2))
        }
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - rr))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX - rr, y: r.maxY), radius: rr)
        switch tail {
        case .bottomRight:
            let x = r.maxX - max(rr, r.width * 0.2)
            p.addLine(to: CGPoint(x: x, y: r.maxY)); p.addLine(to: CGPoint(x: x + tw * 0.3, y: r.maxY + tl))
            p.addLine(to: CGPoint(x: x - tw, y: r.maxY))
        case .bottom:
            p.addLine(to: CGPoint(x: r.midX + tw / 2, y: r.maxY)); p.addLine(to: CGPoint(x: r.midX, y: r.maxY + tl))
            p.addLine(to: CGPoint(x: r.midX - tw / 2, y: r.maxY))
        case .bottomLeft:
            let x = r.minX + max(rr, r.width * 0.2)
            p.addLine(to: CGPoint(x: x + tw, y: r.maxY)); p.addLine(to: CGPoint(x: x - tw * 0.3, y: r.maxY + tl))
            p.addLine(to: CGPoint(x: x, y: r.maxY))
        default: break
        }
        p.addLine(to: CGPoint(x: r.minX + rr, y: r.maxY))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY - rr), radius: rr)
        if tail == .left {
            p.addLine(to: CGPoint(x: r.minX, y: r.midY + tw / 2)); p.addLine(to: CGPoint(x: r.minX - tl, y: r.midY + tw * 0.2))
            p.addLine(to: CGPoint(x: r.minX, y: r.midY - tw / 2))
        }
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + rr))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX + rr, y: r.minY), radius: rr)
        p.closeSubpath()
    }
}
