@preconcurrency import Metal
import CoreText
import CoreGraphics
import ImageIO
import Foundation
import MontageCore
import MontageEffects

/// Rasterizes text (and emoji stickers) with Core Text into premultiplied BGRA textures at output resolution,
/// cached by content + scale (LRU). Full shaping, bidi, CJK and colour emoji come from Core Text.
/// Future: SDF glyph atlas for per-glyph animation (see ARCHITECTURE "Text").
public final class TextRasterizer: @unchecked Sendable {
    public struct Result { public let texture: MTLTexture; public let canvasSize: Size2 }
    private struct Key: Hashable { let content: TextContent; let px: Int }
    private let lock = NSLock()
    private var cache: [Key: Result] = [:]
    private var order: [Key] = []
    private let capacity = 64

    /// `canvasHeight` in canvas pixels; `outputScale` = output px per canvas px.
    public func texture(for t: TextContent, canvasHeight: Double, outputScale: Double) -> Result? {
        let fontPx = t.fontSize * canvasHeight * outputScale
        let key = Key(content: t, px: Int((fontPx * 4).rounded()))
        if let r = lock.withLock({ cache[key] }) { return r }
        guard let r = render(t, fontPx: fontPx, outputScale: outputScale) else { return nil }
        lock.withLock {
            cache[key] = r; order.append(key)
            if order.count > capacity { cache[order.removeFirst()] = nil }
        }
        return r
    }

    public func sticker(_ id: String, canvasSide: Double, outputScale: Double) -> Result? {
        guard let d = Registries.stickers[id] else { return nil }
        switch d.source {
        case .emoji(let e):
            var t = TextContent(string: e)
            t.fontSize = 0.8  // relative to "canvas height" = sticker side
            return texture(for: t, canvasHeight: canvasSide, outputScale: outputScale)
        case .image(let name, let bundle):
            guard let url = bundle().url(forResource: name, withExtension: nil),
                  let tex = ImageTextureCache.load(url: url, maxSide: Int(canvasSide * outputScale) + 1) else { return nil }
            return Result(texture: tex, canvasSize: Size2(canvasSide, canvasSide))
        }
    }

    func render(_ t: TextContent, fontPx: Double, outputScale: Double) -> Result? {
        guard fontPx >= 1, !t.string.isEmpty else { return nil }
        var font = t.fontName.isEmpty
            ? CTFontCreateUIFontForLanguage(.system, fontPx, nil) ?? CTFontCreateWithName("Helvetica" as CFString, fontPx, nil)
            : CTFontCreateWithName(t.fontName as CFString, fontPx, nil)
        var traits: CTFontSymbolicTraits = []
        if t.bold { traits.insert(.traitBold) }
        if t.italic { traits.insert(.traitItalic) }
        if !traits.isEmpty, let f = CTFontCreateCopyWithSymbolicTraits(font, fontPx, nil, traits, traits) { font = f }

        var align: CTTextAlignment = t.alignment == .left ? .left : (t.alignment == .right ? .right : .center)
        var spacing = CGFloat(t.lineSpacing * fontPx)
        let para: CTParagraphStyle = withUnsafeBytes(of: &align) { a in
            withUnsafeBytes(of: &spacing) { sp in
                let settings = [
                    CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: a.baseAddress!),
                    CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size, value: sp.baseAddress!),
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
        func cg(_ c: RGBA) -> CGColor { CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a) }
        func key(_ k: CFString) -> NSAttributedString.Key { NSAttributedString.Key(k as String) }
        let attrs: [NSAttributedString.Key: Any] = [
            key(kCTFontAttributeName): font, key(kCTForegroundColorAttributeName): cg(t.color),
            key(kCTParagraphStyleAttributeName): para, key(kCTKernAttributeName): t.letterSpacing * fontPx,
        ]
        let attr = NSAttributedString(string: t.string, attributes: attrs)
        let framesetter = CTFramesetterCreateWithAttributedString(attr)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil,
                                                               CGSize(width: 100_000, height: 100_000), nil)
        let stroke = t.strokeWidth * fontPx
        let pad = ceil(max(stroke, 0) + fontPx * 0.15 + (t.shadowColor.a > 0 ? fontPx * 0.12 : 0))
        let w = Int(ceil(fit.width) + 2 * pad), h = Int(ceil(fit.height) + 2 * pad)
        guard w > 0, h > 0, w < 16384, h < 16384 else { return nil }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        if t.backgroundColor.a > 0 {
            ctx.setFillColor(cg(t.backgroundColor))
            let r = CGRect(x: pad * 0.4, y: pad * 0.4, width: Double(w) - pad * 0.8, height: Double(h) - pad * 0.8)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: fontPx * 0.15, cornerHeight: fontPx * 0.15, transform: nil))
            ctx.fillPath()
        }
        let path = CGPath(rect: CGRect(x: pad, y: pad, width: ceil(fit.width), height: ceil(fit.height)), transform: nil)
        if t.shadowColor.a > 0 {
            ctx.setShadow(offset: CGSize(width: fontPx * 0.05, height: -fontPx * 0.05), blur: fontPx * 0.1, color: cg(t.shadowColor))
        }
        if stroke > 0 {
            var sa = attrs
            sa[key(kCTStrokeColorAttributeName)] = cg(t.strokeColor)
            // CT stroke width is a % of the font size, centred on the outline; fill is drawn on top so double it.
            sa[key(kCTStrokeWidthAttributeName)] = t.strokeWidth * 200
            sa[key(kCTForegroundColorAttributeName)] = cg(t.strokeColor)
            let fs = CTFramesetterCreateWithAttributedString(NSAttributedString(string: t.string, attributes: sa))
            ctx.setLineJoin(.round)
            CTFrameDraw(CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), path, nil), ctx)
        }
        CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil), ctx)
        guard let data = ctx.data else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = .shaderRead
        guard let tex = MetalContext.shared.device.makeTexture(descriptor: d) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: w * 4)
        return Result(texture: tex, canvasSize: Size2(Double(w) / outputScale, Double(h) / outputScale))
    }
}

/// Still images → textures (premultiplied BGRA), downsampled to ≤ 4096 px, cached by content hash (LRU).
public final class ImageTextureCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: MTLTexture] = [:]
    private var order: [String] = []
    private let capacity = 32

    public func texture(for asset: MediaAsset) -> MTLTexture? {
        let key = asset.contentHash.isEmpty ? asset.url.path : asset.contentHash
        if let t = lock.withLock({ cache[key] }) { return t }
        guard let t = ImageTextureCache.load(url: asset.url, maxSide: 4096) else { return nil }
        lock.withLock {
            cache[key] = t; order.append(key)
            if order.count > capacity { cache[order.removeFirst()] = nil }
        }
        return t
    }

    static func load(url: URL, maxSide: Int) -> MTLTexture? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxSide]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let w = img.width, h = img.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = .shaderRead
        guard let tex = MetalContext.shared.device.makeTexture(descriptor: d) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: w * 4)
        return tex
    }
}
