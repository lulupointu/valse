@preconcurrency import Metal
import CoreGraphics
import CoreText
import CoreImage
import Foundation
import MontageCore

/// Text and Pen masks (W3-7): shapes that the placement shader can't evaluate analytically are drawn on the CPU
/// (CoreGraphics / CoreText) into an r8 coverage texture at the layer texture size, feathered with a Gaussian blur.
/// Geometry matches the shader masks: centre/size in layer units (y down), rotation clockwise, feather 1 ≈ a quarter
/// of the layer height. Results are cached (masks are usually static), so steady playback costs nothing.
public final class RasterMasks: @unchecked Sendable {
    static let shared = RasterMasks()

    private struct Key: Hashable { let mask: Mask; let w: Int; let h: Int }
    private let lock = NSLock()
    private var cache: [Key: MTLTexture] = [:]
    private var order: [Key] = []
    private let ci = CIContext(options: [.useSoftwareRenderer: false])

    /// Coverage texture (1 = inside, before `inverted`) or nil when the mask can't be drawn.
    func texture(_ m: Mask, width w: Int, height h: Int) -> MTLTexture? {
        let key = Key(mask: m, w: w, h: h)
        if let t = lock.withLock({ cache[key] }) { return t }
        guard let pixels = Self.coverage(m, width: w, height: h, ci: ci) else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead]
        guard let t = MetalContext.shared.device.makeTexture(descriptor: d) else { return nil }
        pixels.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w) }
        lock.withLock {
            cache[key] = t; order.append(key)
            if order.count > 8 { cache[order.removeFirst()] = nil }
        }
        return t
    }

    /// 8-bit coverage, row 0 = top of the layer.
    static func coverage(_ m: Mask, width w: Int, height h: Int, ci: CIContext? = nil) -> [UInt8]? {
        guard w > 0, h > 0, let cs = CGColorSpace(name: CGColorSpace.linearGray),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // y-down layer space, origin at the mask centre, rotated clockwise
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: CGFloat((0.5 + m.center.x) * Double(w)), y: CGFloat((0.5 + m.center.y) * Double(h)))
        ctx.rotate(by: CGFloat(m.rotation * .pi / 180))
        let bw = CGFloat(abs(m.size.x) * Double(w)), bh = CGFloat(abs(m.size.y) * Double(h))
        ctx.setFillColor(gray: 1, alpha: 1)
        switch m.shape {
        case .pen:
            let pts = (m.points ?? Mask.defaultPenPoints).map { CGPoint(x: CGFloat($0.x) * bw, y: CGFloat($0.y) * bh) }
            guard pts.count >= 3 else { return nil }
            ctx.addPath(smoothClosedPath(pts)); ctx.fillPath()
        case .brush:
            // painted region: strokes in order, erase strokes paint black (round caps / joins)
            ctx.setLineCap(.round); ctx.setLineJoin(.round)
            for st in m.strokes ?? [] {
                if let region = st.region {
                    // smart brush / tracked shape (CL-012, MK-004): filled contours, holes by even-odd
                    let path = CGMutablePath()
                    for c in region where c.count >= 3 {
                        path.addLines(between: c.map { CGPoint(x: CGFloat($0.x) * bw, y: CGFloat($0.y) * bh) }); path.closeSubpath()
                    }
                    ctx.setFillColor(gray: st.erase ? 0 : 1, alpha: 1)
                    ctx.addPath(path); ctx.fillPath(using: .evenOdd)
                    continue
                }
                guard !st.points.isEmpty else { continue }
                ctx.setStrokeColor(gray: st.erase ? 0 : 1, alpha: 1)
                ctx.setLineWidth(CGFloat(max(st.radius, 0.001) * 2 * Double(h)))
                let pts = st.points.map { CGPoint(x: CGFloat($0.x) * bw, y: CGFloat($0.y) * bh) }
                ctx.move(to: pts[0])
                if pts.count == 1 { ctx.addLine(to: pts[0]) } else { for p in pts.dropFirst() { ctx.addLine(to: p) } }
                ctx.strokePath()
            }
        case .text:
            let s = (m.text?.isEmpty == false ? m.text! : "TEXT")
            drawText(s, in: CGRect(x: -bw / 2, y: -bh / 2, width: bw, height: bh), ctx)
        default:
            return nil
        }
        guard let data = ctx.data else { return nil }
        var out = [UInt8](UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: w * h))
        // the bitmap memory is top-row-first already (CG bitmap contexts store row 0 at the top)
        let sigma = m.feather * 0.25 * Double(h) / 2
        if sigma >= 0.5, let ci, let img = ctx.makeImage() { out = blurred(img, sigma: sigma, w: w, h: h, ci: ci) ?? out }
        return out
    }

    /// Glyphs fitted into `box` (bold system font, centred, keeps the text's aspect).
    static func drawText(_ s: String, in box: CGRect, _ ctx: CGContext) {
        let base: CGFloat = 100
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, base, nil)
        let attr = NSAttributedString(string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                              NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true])
        let line = CTLineCreateWithAttributedString(attr)
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let k = min(box.width / bounds.width, box.height / bounds.height)
        ctx.saveGState()
        // text is drawn y-up: flip locally around the box centre
        ctx.translateBy(x: box.midX, y: box.midY)
        ctx.scaleBy(x: k, y: -k)
        ctx.textPosition = CGPoint(x: -bounds.midX, y: -bounds.midY)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// Closed Catmull-Rom spline through `pts` as cubic Béziers.
    public static func smoothClosedPath(_ pts: [CGPoint]) -> CGPath {
        let p = CGMutablePath(), n = pts.count
        p.move(to: pts[0])
        for i in 0..<n {
            let p0 = pts[(i - 1 + n) % n], p1 = pts[i], p2 = pts[(i + 1) % n], p3 = pts[(i + 2) % n]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            p.addCurve(to: p2, control1: c1, control2: c2)
        }
        p.closeSubpath()
        return p
    }

    private static func blurred(_ img: CGImage, sigma: Double, w: Int, h: Int, ci: CIContext) -> [UInt8]? {
        let input = CIImage(cgImage: img).clampedToExtent()
        guard let f = CIFilter(name: "CIGaussianBlur") else { return nil }
        f.setValue(input, forKey: kCIInputImageKey)
        f.setValue(sigma, forKey: kCIInputRadiusKey)
        guard let outImg = f.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: w, height: h)) else { return nil }
        var out = [UInt8](repeating: 0, count: w * h)
        out.withUnsafeMutableBytes { buf in
            ci.render(outImg, toBitmap: buf.baseAddress!, rowBytes: w, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                      format: .L8, colorSpace: CGColorSpace(name: CGColorSpace.linearGray))
        }
        return out
    }
}
