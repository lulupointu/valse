@preconcurrency import Metal
import CoreGraphics
import Foundation
import MontageCore
import MontageEffects

/// Draws procedural vector stickers (`StickerDescriptor.Source.vector`) with Core Graphics at the exact output
/// pixel size (sharp at any zoom), into premultiplied BGRA — the same format as text and emoji stickers.
public enum VectorStickerRenderer {
    /// Premultiplied BGRA bitmap context with the unit square mapped to `px` (y down).
    public static func image(_ layers: [VectorLayer], px: Int) -> CGImage? {
        guard px > 0, px <= 8192, let ctx = context(px) else { return nil }
        draw(layers, in: ctx, px: px)
        return ctx.makeImage()
    }

    static func context(_ px: Int) -> CGContext? {
        CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: px * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    static func texture(_ layers: [VectorLayer], px: Int) -> MTLTexture? {
        guard px > 0, px <= 8192, let ctx = context(px) else { return nil }
        draw(layers, in: ctx, px: px)
        guard let data = ctx.data else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: px, height: px, mipmapped: false)
        d.usage = .shaderRead
        guard let tex = MetalContext.shared.device.makeTexture(descriptor: d) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, px, px), mipmapLevel: 0, withBytes: data, bytesPerRow: px * 4)
        return tex
    }

    static func draw(_ layers: [VectorLayer], in ctx: CGContext, px: Int) {
        let s = CGFloat(px)
        ctx.translateBy(x: 0, y: s); ctx.scaleBy(x: s, y: -s)   // unit square, y down
        ctx.setLineJoin(.round); ctx.setLineCap(.round)
        for l in layers {
            let r = CGRect(x: l.inset, y: l.inset, width: 1 - 2 * l.inset, height: 1 - 2 * l.inset)
            let (path, strokeOnly) = Self.path(l.shape, in: r, corner: l.cornerRadius)
            ctx.saveGState()
            if l.shadow { ctx.setShadow(offset: CGSize(width: 0, height: 0.012 * s), blur: 0.03 * s, color: CGColor(gray: 0, alpha: 0.45)) }
            if let f = l.fill, !strokeOnly {
                if let b = l.fillBottom {
                    ctx.saveGState()
                    ctx.addPath(path); ctx.clip()
                    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [cg(f), cg(b)] as CFArray, locations: [0, 1])!
                    ctx.drawLinearGradient(g, start: CGPoint(x: 0.5, y: r.minY), end: CGPoint(x: 0.5, y: r.maxY), options: [])
                    ctx.restoreGState()
                } else {
                    ctx.setFillColor(cg(f)); ctx.addPath(path); ctx.fillPath()
                }
            }
            if let st = l.stroke, l.strokeWidth > 0 {
                ctx.setShadow(offset: .zero, blur: 0, color: nil)
                if l.shadow && l.fill == nil { ctx.setShadow(offset: CGSize(width: 0, height: 0.012 * s), blur: 0.03 * s, color: CGColor(gray: 0, alpha: 0.45)) }
                if let d = l.dash { ctx.setLineDash(phase: 0, lengths: d.map { CGFloat($0) }) }
                ctx.setStrokeColor(cg(st)); ctx.setLineWidth(l.strokeWidth); ctx.addPath(path); ctx.strokePath()
            }
            ctx.restoreGState()
        }
    }

    static func cg(_ c: RGBA) -> CGColor { CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a) }

    /// Path of a shape inside `r`; `strokeOnly` shapes (line, ring, chevron, check) ignore fills.
    static func path(_ shape: VectorLayer.Shape, in r: CGRect, corner: Double? = nil) -> (CGPath, Bool) {
        let p = CGMutablePath()
        let c = CGPoint(x: r.midX, y: r.midY), w = r.width, h = r.height
        func poly(_ pts: [CGPoint]) { p.addLines(between: pts); p.closeSubpath() }
        func radial(_ n: Int, outer: CGFloat, inner: CGFloat?, rotate: CGFloat = -.pi / 2) {
            var pts: [CGPoint] = []
            let count = inner == nil ? n : n * 2
            for i in 0..<count {
                let a = rotate + CGFloat(i) * 2 * .pi / CGFloat(count)
                let rad = (inner != nil && i % 2 == 1) ? inner! : outer
                pts.append(CGPoint(x: c.x + cos(a) * rad * w / 2, y: c.y + sin(a) * rad * h / 2))
            }
            poly(pts)
        }
        switch shape {
        case .rect where corner != nil, .roundedRect where corner != nil:
            // ST-008 corner radius (fraction of the shorter side)
            let rr = r.insetBy(dx: 0, dy: h * 0.12)
            let rad = min(max(CGFloat(corner ?? 0), 0), 0.5) * min(rr.width, rr.height)
            if rad < 1e-4 { p.addRect(rr) } else { p.addRoundedRect(in: rr, cornerWidth: rad, cornerHeight: rad) }
        case .path(let pts):
            guard pts.count >= 3 else { p.addEllipse(in: r); break }
            p.addPath(RasterMasks.smoothClosedPath(pts.map { CGPoint(x: r.minX + CGFloat($0.x) * w, y: r.minY + CGFloat($0.y) * h) }))
        case .rect: p.addRect(r.insetBy(dx: 0, dy: h * 0.12))
        case .roundedRect:
            let rr = r.insetBy(dx: 0, dy: h * 0.12)
            p.addRoundedRect(in: rr, cornerWidth: w * 0.16, cornerHeight: w * 0.16)
        case .circle: p.addEllipse(in: r)
        case .triangle: poly([CGPoint(x: c.x, y: r.minY + h * 0.05), CGPoint(x: r.maxX, y: r.maxY - h * 0.08), CGPoint(x: r.minX, y: r.maxY - h * 0.08)])
        case .diamond: poly([CGPoint(x: c.x, y: r.minY), CGPoint(x: r.maxX, y: c.y), CGPoint(x: c.x, y: r.maxY), CGPoint(x: r.minX, y: c.y)])
        case .hexagon: radial(6, outer: 1, inner: nil, rotate: 0)
        case .star(let n): radial(max(n, 3), outer: 1, inner: 0.45)
        case .burst(let n): radial(max(n, 6), outer: 1, inner: 0.78)
        case .sparkle:
            // 4-point star with concave sides
            let k: CGFloat = 0.16
            p.move(to: CGPoint(x: c.x, y: r.minY))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: c.y), control: CGPoint(x: c.x + w * k, y: c.y - h * k))
            p.addQuadCurve(to: CGPoint(x: c.x, y: r.maxY), control: CGPoint(x: c.x + w * k, y: c.y + h * k))
            p.addQuadCurve(to: CGPoint(x: r.minX, y: c.y), control: CGPoint(x: c.x - w * k, y: c.y + h * k))
            p.addQuadCurve(to: CGPoint(x: c.x, y: r.minY), control: CGPoint(x: c.x - w * k, y: c.y - h * k))
            p.closeSubpath()
        case .heart:
            let top = r.minY + h * 0.28
            p.move(to: CGPoint(x: c.x, y: r.maxY - h * 0.04))
            p.addCurve(to: CGPoint(x: r.minX, y: top), control1: CGPoint(x: c.x - w * 0.18, y: r.maxY - h * 0.2), control2: CGPoint(x: r.minX, y: c.y + h * 0.05))
            p.addArc(center: CGPoint(x: r.minX + w * 0.25, y: top), radius: w * 0.25, startAngle: .pi, endAngle: 0, clockwise: false)
            p.addArc(center: CGPoint(x: r.maxX - w * 0.25, y: top), radius: w * 0.25, startAngle: .pi, endAngle: 0, clockwise: false)
            p.addCurve(to: CGPoint(x: c.x, y: r.maxY - h * 0.04), control1: CGPoint(x: r.maxX, y: c.y + h * 0.05), control2: CGPoint(x: c.x + w * 0.18, y: r.maxY - h * 0.2))
            p.closeSubpath()
        case .arrow:
            let t = h * 0.14
            poly([CGPoint(x: r.minX, y: c.y - t), CGPoint(x: r.maxX - w * 0.38, y: c.y - t), CGPoint(x: r.maxX - w * 0.38, y: c.y - h * 0.32),
                  CGPoint(x: r.maxX, y: c.y), CGPoint(x: r.maxX - w * 0.38, y: c.y + h * 0.32), CGPoint(x: r.maxX - w * 0.38, y: c.y + t),
                  CGPoint(x: r.minX, y: c.y + t)])
        case .chevron:
            p.move(to: CGPoint(x: r.minX + w * 0.3, y: r.minY + h * 0.15)); p.addLine(to: CGPoint(x: r.maxX - w * 0.25, y: c.y))
            p.addLine(to: CGPoint(x: r.minX + w * 0.3, y: r.maxY - h * 0.15))
            return (p, true)
        case .line:
            p.move(to: CGPoint(x: r.minX + w * 0.05, y: c.y)); p.addLine(to: CGPoint(x: r.maxX - w * 0.05, y: c.y))
            return (p, true)
        case .ring:
            p.addEllipse(in: r.insetBy(dx: w * 0.06, dy: h * 0.06))
            return (p, true)
        case .check:
            p.move(to: CGPoint(x: r.minX, y: c.y + h * 0.02)); p.addLine(to: CGPoint(x: r.minX + w * 0.36, y: r.maxY - h * 0.12))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY + h * 0.12))
            return (p, true)
        case .plus, .cross:
            let t = w * 0.13
            let plus = CGMutablePath()
            plus.addRoundedRect(in: CGRect(x: c.x - t, y: r.minY, width: 2 * t, height: h), cornerWidth: t * 0.5, cornerHeight: t * 0.5)
            plus.addRoundedRect(in: CGRect(x: r.minX, y: c.y - t, width: w, height: 2 * t), cornerWidth: t * 0.5, cornerHeight: t * 0.5)
            if case .cross = shape {
                var tr = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: .pi / 4).translatedBy(x: -c.x, y: -c.y)
                return (plus.copy(using: &tr) ?? plus, false)
            }
            return (plus, false)
        case .bubble:
            let body = CGRect(x: r.minX, y: r.minY + h * 0.08, width: w, height: h * 0.66)
            let rounded = CGPath(roundedRect: body, cornerWidth: w * 0.22, cornerHeight: h * 0.22, transform: nil)
            let tail = CGMutablePath()
            tail.addLines(between: [CGPoint(x: r.minX + w * 0.22, y: body.maxY - h * 0.04), CGPoint(x: r.minX + w * 0.12, y: r.maxY - h * 0.04),
                                    CGPoint(x: r.minX + w * 0.45, y: body.maxY - h * 0.04)])
            tail.closeSubpath()
            return (rounded.union(tail), false)
        }
        return (p, false)
    }
}
