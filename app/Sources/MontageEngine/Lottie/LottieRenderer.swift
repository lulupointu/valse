@preconcurrency import Metal
import CoreGraphics
import Foundation
import MontageCore

/// Draws `LottieAnimation` frames with Core Graphics (vector, any resolution), uploaded as textures for the compositor.
public enum LottieRenderer {
    /// Frame `f` aspect-fitted into a transparent `width`×`height` image (premultiplied BGRA, sRGB).
    public static func image(_ anim: LottieAnimation, frame f: Double, width: Int, height: Int) -> CGImage? {
        guard let ctx = context(width, height) else { return nil }
        draw(anim, frame: f, in: ctx, width: width, height: height)
        return ctx.makeImage()
    }

    /// Same as `image` but straight into a Metal texture (bgra8, premultiplied).
    public static func texture(_ anim: LottieAnimation, frame f: Double, width: Int, height: Int) -> MTLTexture? {
        guard let ctx = context(width, height), let data = ctx.data else { return nil }
        draw(anim, frame: f, in: ctx, width: width, height: height)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = .shaderRead
        guard let tex = MetalContext.shared.device.makeTexture(descriptor: d) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: data, bytesPerRow: width * 4)
        return tex
    }

    static func context(_ w: Int, _ h: Int) -> CGContext? {
        CGContext(data: nil, width: max(w, 1), height: max(h, 1), bitsPerComponent: 8, bytesPerRow: max(w, 1) * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    public static func draw(_ anim: LottieAnimation, frame f: Double, in ctx: CGContext, width: Int, height: Int) {
        let k = min(Double(width) / anim.width, Double(height) / anim.height)
        ctx.saveGState()
        // y down, origin top-left, composition aspect-fitted and centred
        ctx.translateBy(x: 0, y: CGFloat(height)); ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: (Double(width) - anim.width * k) / 2, y: (Double(height) - anim.height * k) / 2)
        ctx.scaleBy(x: k, y: k)
        ctx.setShouldAntialias(true)
        drawLayers(anim.layers, frame: f, anim: anim, in: ctx, base: .identity)
        ctx.restoreGState()
    }

    static func drawLayers(_ layers: [LottieLayer], frame f: Double, anim: LottieAnimation, in ctx: CGContext,
                           base: CGAffineTransform, depth: Int = 0) {
        let byIndex = Dictionary(layers.compactMap { l in l.index.map { ($0, l) } }, uniquingKeysWith: { a, _ in a })
        func world(_ l: LottieLayer, _ hops: Int = 0) -> CGAffineTransform {
            var m = l.transform.matrix(f)
            if hops < 16, let p = l.parent, let parent = byIndex[p] { m = m.concatenating(world(parent, hops + 1)) }
            return m
        }
        // first layer in the list is on top: draw bottom-up
        for l in layers.reversed() where !l.hidden && f >= l.inPoint && f < l.outPoint {
            let m = world(l).concatenating(base)
            let opacity = l.transform.opacityValue(f)
            guard opacity > 0.001 else { continue }
            ctx.saveGState()
            ctx.setAlpha(opacity)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            switch l.kind {
            case .shape(let shapes):
                let built = build(shapes, frame: f, m: m, opacity: 1, trims: [])
                execute(built.cmds, in: ctx)
            case .solid(let color, let w, let h):
                ctx.addPath(CGPath(rect: CGRect(x: 0, y: 0, width: w, height: h), transform: [m]))
                ctx.setFillColor(color); ctx.fillPath()
            case .precomp(let ref):
                if depth < 8, let inner = anim.assets[ref] {
                    drawLayers(inner, frame: (f - l.startTime) / max(l.stretch, 1e-6), anim: anim, in: ctx, base: m, depth: depth + 1)
                }
            case .null:
                break
            }
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
    }

    // MARK: Shapes

    struct Trim { var start: Double, end: Double, offset: Double }

    enum Cmd {
        case paint(LottieShape, CGPath, opacity: Double, m: CGAffineTransform, frame: Double)
        case group([Cmd])
    }

    /// Geometry and paint commands of a shape list. A paint covers the geometry of every item above it (earlier in the
    /// list, nested groups included); earlier items draw on top, so commands execute in reverse order.
    static func build(_ items: [LottieShape], frame f: Double, m: CGAffineTransform, opacity: Double,
                      trims: [Trim]) -> (cmds: [Cmd], geometry: CGPath) {
        var local: [(Int, Trim)] = []
        for (i, it) in items.enumerated() {
            if case let .trim(s, e, o) = it { local.append((i, Trim(start: s.scalar(f), end: e.scalar(f), offset: o.scalar(f)))) }
        }
        var cmds: [Cmd] = []
        let acc = CGMutablePath()
        for (i, item) in items.enumerated() {
            let applicable = trims + local.filter { $0.0 > i }.map(\.1)
            switch item {
            case .group(let sub, let tr, let hidden):
                guard !hidden else { continue }
                let m2 = (tr?.matrix(f) ?? .identity).concatenating(m)
                let op2 = opacity * (tr?.opacityValue(f) ?? 1)
                let b = build(sub, frame: f, m: m2, opacity: op2, trims: applicable)
                acc.addPath(b.geometry)
                cmds.append(.group(b.cmds))
            case .fill, .stroke, .gradient:
                cmds.append(.paint(item, acc.copy() ?? acc, opacity: opacity, m: m, frame: f))
            case .trim:
                continue
            default:
                guard var p = geometry(item, frame: f) else { continue }
                for t in applicable { p = trimmed(p, t) }
                acc.addPath(p, transform: m)
            }
        }
        return (cmds, acc)
    }

    static func execute(_ cmds: [Cmd], in ctx: CGContext) {
        for c in cmds.reversed() {
            switch c {
            case .group(let sub): execute(sub, in: ctx)
            case .paint(let shape, let path, let opacity, let m, let f): paint(shape, path, opacity: opacity, m: m, frame: f, in: ctx)
            }
        }
    }

    static func color(_ v: [Double], alpha: Double) -> CGColor {
        CGColor(srgbRed: v.count > 0 ? v[0] : 1, green: v.count > 1 ? v[1] : 1, blue: v.count > 2 ? v[2] : 1,
                alpha: min(max((v.count > 3 ? v[3] : 1) * alpha, 0), 1))
    }

    static func paint(_ shape: LottieShape, _ path: CGPath, opacity: Double, m: CGAffineTransform, frame f: Double, in ctx: CGContext) {
        guard !path.isEmpty else { return }
        let scale = sqrt(abs(m.a * m.d - m.b * m.c))
        switch shape {
        case let .fill(c, o, evenOdd):
            ctx.addPath(path)
            ctx.setFillColor(color(c.value(f), alpha: o.scalar(f) / 100 * opacity))
            ctx.fillPath(using: evenOdd ? .evenOdd : .winding)
        case let .stroke(c, o, w, cap, join):
            let width = w.scalar(f) * scale
            guard width > 0 else { return }
            ctx.addPath(path)
            ctx.setLineWidth(width)
            ctx.setLineCap(cap == 1 ? .butt : cap == 3 ? .square : .round)
            ctx.setLineJoin(join == 1 ? .miter : join == 3 ? .bevel : .round)
            ctx.setStrokeColor(color(c.value(f), alpha: o.scalar(f) / 100 * opacity))
            ctx.strokePath()
        case let .gradient(stroke, type, n, colors, start, end, o, w):
            let k = colors.value(f)
            guard n >= 1, k.count >= n * 4 else { return }
            var locs: [CGFloat] = [], cgColors: [CGColor] = []
            let alphaStops = k.count >= n * 4 + 2 ? Array(k[(n * 4)...]) : []
            for i in 0..<n {
                var a = 1.0
                if alphaStops.count >= 2 * n { a = alphaStops[2 * i + 1] }
                locs.append(CGFloat(k[i * 4]))
                cgColors.append(color([k[i * 4 + 1], k[i * 4 + 2], k[i * 4 + 3]], alpha: a * o.scalar(f) / 100 * opacity))
            }
            guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: cgColors as CFArray, locations: locs) else { return }
            ctx.saveGState()
            ctx.addPath(path)
            if stroke {
                ctx.setLineWidth((w?.scalar(f) ?? 2) * scale)
                ctx.replacePathWithStrokedPath()
            }
            ctx.clip()
            let s = start.point(f).applying(m), e = end.point(f).applying(m)
            if type == 2 {
                ctx.drawRadialGradient(g, startCenter: s, startRadius: 0, endCenter: s, endRadius: hypot(e.x - s.x, e.y - s.y),
                                       options: [.drawsAfterEndLocation])
            } else {
                ctx.drawLinearGradient(g, start: s, end: e, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            ctx.restoreGState()
        default:
            break
        }
    }

    static func geometry(_ s: LottieShape, frame f: Double) -> CGPath? {
        switch s {
        case let .rect(p, size, r, _):
            let c = p.point(f), sz = size.point(f)
            let rr = min(r.scalar(f), min(abs(sz.x), abs(sz.y)) / 2)
            let rect = CGRect(x: c.x - sz.x / 2, y: c.y - sz.y / 2, width: sz.x, height: sz.y)
            return rr > 0 ? CGPath(roundedRect: rect, cornerWidth: rr, cornerHeight: rr, transform: nil) : CGPath(rect: rect, transform: nil)
        case let .ellipse(p, size):
            let c = p.point(f), sz = size.point(f)
            return CGPath(ellipseIn: CGRect(x: c.x - sz.x / 2, y: c.y - sz.y / 2, width: sz.x, height: sz.y), transform: nil)
        case let .star(polygon, p, pts, rot, outer, inner):
            let c = p.point(f), n = max(Int(pts.scalar(f).rounded()), 3)
            let ro = outer.scalar(f), ri = inner.scalar(f)
            let a0 = (rot.scalar(f) - 90) * .pi / 180
            let path = CGMutablePath()
            let count = polygon ? n : 2 * n
            for i in 0..<count {
                let a = a0 + Double(i) * 2 * .pi / Double(count)
                let r = polygon || i % 2 == 0 ? ro : ri
                let q = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
                i == 0 ? path.move(to: q) : path.addLine(to: q)
            }
            path.closeSubpath()
            return path
        case let .path(pv):
            let sh = pv.shape(f)
            guard let v0 = sh.v.first else { return nil }
            let path = CGMutablePath()
            path.move(to: v0)
            func tangent(_ a: [CGPoint], _ j: Int) -> CGPoint { j < a.count ? a[j] : .zero }
            for j in 1..<max(sh.v.count, 1) where j < sh.v.count {
                let a = sh.v[j - 1], b = sh.v[j]
                let c1 = CGPoint(x: a.x + tangent(sh.o, j - 1).x, y: a.y + tangent(sh.o, j - 1).y)
                let c2 = CGPoint(x: b.x + tangent(sh.i, j).x, y: b.y + tangent(sh.i, j).y)
                path.addCurve(to: b, control1: c1, control2: c2)
            }
            if sh.closed, sh.v.count > 1 {
                let a = sh.v[sh.v.count - 1]
                let c1 = CGPoint(x: a.x + tangent(sh.o, sh.v.count - 1).x, y: a.y + tangent(sh.o, sh.v.count - 1).y)
                let c2 = CGPoint(x: v0.x + tangent(sh.i, 0).x, y: v0.y + tangent(sh.i, 0).y)
                path.addCurve(to: v0, control1: c1, control2: c2)
                path.closeSubpath()
            }
            return path
        default:
            return nil
        }
    }

    // MARK: Trim paths

    /// Keeps the [start, end] % part of every subpath (offset in degrees = fraction of a turn), as polylines.
    static func trimmed(_ path: CGPath, _ t: Trim) -> CGPath {
        var s = min(t.start, t.end) / 100, e = max(t.start, t.end) / 100
        let off = t.offset / 360
        s += off; e += off
        if e - s >= 1 - 1e-6 { return path }
        if e - s <= 1e-6 { return CGMutablePath() }
        let out = CGMutablePath()
        for poly in polylines(path) {
            var lengths: [Double] = [0]
            for i in 1..<poly.count { lengths.append(lengths[i - 1] + hypot(poly[i].x - poly[i - 1].x, poly[i].y - poly[i - 1].y)) }
            guard let total = lengths.last, total > 0 else { continue }
            func point(at d: Double) -> CGPoint {
                let x = min(max(d, 0), total)
                var i = 1
                while i < lengths.count - 1 && lengths[i] < x { i += 1 }
                let seg = max(lengths[i] - lengths[i - 1], 1e-9)
                let u = (x - lengths[i - 1]) / seg
                return CGPoint(x: poly[i - 1].x + (poly[i].x - poly[i - 1].x) * u, y: poly[i - 1].y + (poly[i].y - poly[i - 1].y) * u)
            }
            func addRange(_ a: Double, _ b: Double) {
                guard b > a else { return }
                out.move(to: point(at: a * total))
                for (i, l) in lengths.enumerated() where l > a * total && l < b * total { out.addLine(to: poly[i]) }
                out.addLine(to: point(at: b * total))
            }
            // ranges may wrap past 1 with the offset
            let s0 = s - floor(s), e0 = s0 + (e - s)
            if e0 <= 1 { addRange(s0, e0) } else { addRange(s0, 1); addRange(0, e0 - 1) }
        }
        return out
    }

    /// Flattens a path into polylines (curves subdivided in 16 steps).
    static func polylines(_ path: CGPath) -> [[CGPoint]] {
        var result: [[CGPoint]] = []
        var cur: [CGPoint] = []
        var start = CGPoint.zero, last = CGPoint.zero
        path.applyWithBlock { el in
            let e = el.pointee
            switch e.type {
            case .moveToPoint:
                if cur.count > 1 { result.append(cur) }
                start = e.points[0]; last = start; cur = [start]
            case .addLineToPoint:
                last = e.points[0]; cur.append(last)
            case .addQuadCurveToPoint:
                let c = e.points[0], p = e.points[1]
                for k in 1...16 {
                    let u = CGFloat(k) / 16, v = 1 - u
                    cur.append(CGPoint(x: v * v * last.x + 2 * v * u * c.x + u * u * p.x, y: v * v * last.y + 2 * v * u * c.y + u * u * p.y))
                }
                last = p
            case .addCurveToPoint:
                let c1 = e.points[0], c2 = e.points[1], p = e.points[2]
                for k in 1...16 {
                    let u = CGFloat(k) / 16, v = 1 - u
                    let x = v * v * v * last.x + 3 * v * v * u * c1.x + 3 * v * u * u * c2.x + u * u * u * p.x
                    let y = v * v * v * last.y + 3 * v * v * u * c1.y + 3 * v * u * u * c2.y + u * u * u * p.y
                    cur.append(CGPoint(x: x, y: y))
                }
                last = p
            case .closeSubpath:
                if last != start { cur.append(start) }
                last = start
            @unknown default: break
            }
        }
        if cur.count > 1 { result.append(cur) }
        return result
    }
}

/// Loaded animations and recently rendered frames (stickers play their Lottie in a loop from the clip start).
public final class LottieLibrary: @unchecked Sendable {
    public static let shared = LottieLibrary()
    private let lock = NSLock()
    private var animations: [URL: LottieAnimation] = [:]
    private var frames: [String: MTLTexture] = [:]
    private var thumbs: [URL: CGImage] = [:]
    private var order: [String] = []

    public func animation(_ url: URL) -> LottieAnimation? {
        if let a = lock.withLock({ animations[url] }) { return a }
        guard let a = try? LottieAnimation(url: url) else { return nil }
        lock.withLock { animations[url] = a }
        return a
    }

    /// Still for library tiles (frame at 40 % of the loop, 144 px), cached.
    public func thumbnail(_ url: URL) -> CGImage? {
        if let t = lock.withLock({ thumbs[url] }) { return t }
        guard let a = animation(url) else { return nil }
        let img = LottieRenderer.image(a, frame: a.inPoint + (a.outPoint - a.inPoint) * 0.4, width: 144, height: 144)
        lock.withLock { thumbs[url] = img }
        return img
    }

    /// Texture of the frame shown `seconds` into the clip, `side` px square. Frames are cached by whole Lottie frame.
    public func texture(_ url: URL, seconds: Double, side: Int) -> MTLTexture? {
        guard let a = animation(url) else { return nil }
        let f = a.frame(at: seconds).rounded(.down)
        let key = "\(url.path)#\(Int(f))@\(side)"
        if let t = lock.withLock({ frames[key] }) { return t }
        guard let tex = LottieRenderer.texture(a, frame: f, width: side, height: side) else { return nil }
        lock.withLock {
            frames[key] = tex; order.append(key)
            if order.count > 48 { frames[order.removeFirst()] = nil }
        }
        return tex
    }
}
