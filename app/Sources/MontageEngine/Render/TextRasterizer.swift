@preconcurrency import Metal
import CoreText
import CoreGraphics
import ImageIO
import Foundation
import MontageCore
import MontageEffects

/// Text engine entry point (ARCHITECTURE §4 / W7). Rasterizes text clips (and emoji stickers) with Core Text glyph outlines
/// into premultiplied textures at output resolution:
/// - **static** (rest pose): one Core Graphics image per (content, pixel size), LRU-cached → zero per-frame cost;
/// - **dynamic** (per-glyph In/Out/Loop animations, karaoke word states, text templates): every item is rasterized once
///   into an atlas (cached the same way) and the GPU recomposes the glyph quads each frame with one instanced draw.
/// Rasterization follows the layer's displayed scale (√2 buckets) so zoomed text stays sharp.
public final class TextRasterizer: @unchecked Sendable {
    public struct Result { public let texture: MTLTexture; public let canvasSize: Size2 }

    private struct Key: Hashable { let content: TextContent; let px: Int; let canvasW: Int; let duration: Int }
    private final class Entry<V> { let value: V; let bytes: Int; init(_ v: V, _ b: Int) { value = v; bytes = b } }

    /// Small thread-safe LRU with an entry and a byte budget.
    private final class LRU<V>: @unchecked Sendable {
        private let lock = NSLock()
        private var map: [Key: Entry<V>] = [:]
        private var order: [Key] = []
        private var bytes = 0
        let capacity: Int, budget: Int
        init(capacity: Int, budget: Int) { self.capacity = capacity; self.budget = budget }
        func get(_ k: Key) -> V? {
            lock.withLock {
                guard let e = map[k] else { return nil }
                if let i = order.lastIndex(of: k), i != order.count - 1 { order.remove(at: i); order.append(k) }
                return e.value
            }
        }
        func put(_ k: Key, _ v: V, bytes b: Int) {
            lock.withLock {
                if let old = map[k] { bytes -= old.bytes; order.removeAll { $0 == k } }
                map[k] = Entry(v, b); order.append(k); bytes += b
                while order.count > capacity || (bytes > budget && order.count > 1) {
                    let victim = order.removeFirst()
                    if let e = map.removeValue(forKey: victim) { bytes -= e.bytes }
                }
            }
        }
        func removeAll() { lock.withLock { map.removeAll(); order.removeAll(); bytes = 0 } }
    }

    private struct StaticImage { let texture: MTLTexture; let size: CGSize }
    private final class Dynamic: @unchecked Sendable {
        let scene: TextScene; let atlas: TextAtlas
        init(scene: TextScene, atlas: TextAtlas) { self.scene = scene; self.atlas = atlas }
    }

    private let statics = LRU<StaticImage>(capacity: 128, budget: 256 << 20)
    private let dynamics = LRU<Dynamic>(capacity: 64, budget: 256 << 20)
    private let scenes = LRU<TextScene>(capacity: 128, budget: .max)
    private let statsLock = NSLock()
    private var _rasterizations = 0

    public init() { _ = FontCatalog.ensureLoaded }  // registers imported fonts before anything renders

    /// Number of CPU rasterizations so far (tests: animated playback must not re-rasterize per frame).
    public var rasterizationCount: Int { statsLock.withLock { _rasterizations } }
    public func purge() { statics.removeAll(); dynamics.removeAll(); scenes.removeAll() }

    // MARK: Public API

    /// Rest-pose texture of a text (no animation). `canvasHeight` in canvas pixels; `outputScale` = output px per canvas px.
    public func texture(for t: TextContent, canvasHeight: Double, outputScale: Double) -> Result? {
        staticResult(t, fontPx: CGFloat(t.fontSize * canvasHeight * outputScale), canvasWidthPx: CGFloat(canvasHeight * 16 / 9 * outputScale),
                     duration: 0, pxPerCanvas: outputScale)
    }

    /// Texture of a text layer at one frame: static when nothing moves, else the GPU-composed glyphs (pool texture from
    /// `acquire`, valid for this command buffer only). Both are premultiplied.
    public func layerTexture(_ t: TextContent, canvas: Size2, outputScale: Double, layerScale: Vec2 = .one,
                             animations: [ActiveAnimation] = [], localTime: Time = .zero, duration: Time = .zero,
                             commandBuffer cmd: MTLCommandBuffer?, acquire: (Int, Int) -> MTLTexture) -> Result? {
        let bucket = Self.scaleBucket(layerScale, fontPx: t.fontSize * canvas.height * outputScale)
        let k = outputScale * bucket
        let fontPx = CGFloat(t.fontSize * canvas.height * k)
        let canvasW = CGFloat(canvas.width * k)
        let glyphAnims: [(spec: GlyphAnimationSpec, phase: AnimationPhaseKind, progress: Double)] = animations.compactMap { a in
            guard let spec = Registries.animations[a.typeID]?.glyph else { return nil }
            let phase: AnimationPhaseKind = a.phase == .in ? .in : (a.phase == .out ? .out : .combo)
            return (spec, phase, a.progress)
        }
        let isDynamic = t.template != nil || !glyphAnims.isEmpty || (t.karaoke != nil && !t.string.isEmpty)
        guard isDynamic, let cmd else {
            return staticResult(t, fontPx: fontPx, canvasWidthPx: canvasW, duration: duration.seconds, pxPerCanvas: k)
        }
        let input = TextFrameInput(anims: glyphAnims, localTime: localTime.seconds, duration: duration.seconds)
        guard let dyn = dynamic(t, fontPx: fontPx, canvasWidthPx: canvasW, duration: duration.seconds) else {
            return staticResult(t, fontPx: fontPx, canvasWidthPx: canvasW, duration: duration.seconds, pxPerCanvas: k)
        }
        let scene = dyn.scene
        // symmetric margin around the rest bounds so the layer centre (and thus placement) never moves
        // Integer margin in multiples of 8 around the same 16-px-padded box as the static image: cells stay pixel
        // aligned and the compositor never resamples, so the rest pose matches the static image exactly (no pop).
        let m = (TextAnimator.margin(scene, input) / 8).rounded(.up) * 8
        let rb = Self.padded(scene.bounds).insetBy(dx: -m, dy: -m)
        let w = Int(rb.width), h = Int(rb.height)
        guard w > 0, h > 0, w <= 8192, h <= 8192 else { return nil }
        let origin = rb.origin
        let inst = TextAnimator.instances(scene, dyn.atlas, input, origin: origin)
        let target = acquire(w, h)
        TextGPU.compose(inst, atlas: dyn.atlas.texture, into: target, cmd)
        return Result(texture: target, canvasSize: Size2(Double(w) / k, Double(h) / k))
    }

    /// Size of the text layer in canvas pixels at rest (incl. outlines / shadows / glows) — what placement and the
    /// canvas selection box use. Cheap (layout only, cached).
    public func measure(_ t: TextContent, canvasSize: Size2) -> Size2 {
        let s = scene(t, fontPx: CGFloat(t.fontSize * canvasSize.height), canvasWidthPx: CGFloat(canvasSize.width), duration: 0)
        let b = Self.padded(s.bounds)
        return Size2(Double(b.width), Double(b.height))
    }

    /// Rest box of the glyphs alone (no effect padding) relative to the layer centre, canvas pixels (inline editor).
    public func textBox(_ t: TextContent, canvasSize: Size2) -> (center: Vec2, size: Size2) {
        let s = scene(t, fontPx: CGFloat(t.fontSize * canvasSize.height), canvasWidthPx: CGFloat(canvasSize.width), duration: 0)
        let b = s.bounds.integral, tb = s.textBounds
        return (Vec2(Double(tb.midX - b.midX), Double(tb.midY - b.midY)), Size2(Double(tb.width), Double(tb.height)))
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
        case .vector(let layers):
            let px = max(8, Int((canvasSide * outputScale).rounded(.up)))
            let key = "\(id)@\(px)"
            if let t = vectorLock.withLock({ vectorCache[key] }) { return Result(texture: t, canvasSize: Size2(canvasSide, canvasSide)) }
            guard let tex = VectorStickerRenderer.texture(layers, px: px) else { return nil }
            vectorLock.withLock {
                vectorCache[key] = tex; vectorOrder.append(key)
                if vectorOrder.count > 64 { vectorCache[vectorOrder.removeFirst()] = nil }
            }
            return Result(texture: tex, canvasSize: Size2(canvasSide, canvasSide))
        }
    }

    // Vector sticker textures (W4), keyed by id + pixel size.
    private let vectorLock = NSLock()
    private var vectorCache: [String: MTLTexture] = [:]
    private var vectorOrder: [String] = []

    /// Rest-pose CGImage of a text at `fontPx` (asset tiles, previews, tests). Not cached.
    public static func image(_ t: TextContent, fontPx: Double, canvasWidthPx: Double = 1920, duration: Double = 3) -> CGImage? {
        let s = TextSceneBuilder.build(t, fontPx: CGFloat(fontPx), canvasWidthPx: CGFloat(canvasWidthPx), duration: duration, dynamic: false)
        return render(s)?.image
    }

    // MARK: Internals

    static func scaleBucket(_ s: Vec2, fontPx: Double) -> Double {
        let m = max(abs(s.x), abs(s.y))
        guard m > 1.05 else { return 1 }
        let b = pow(2, (log2(m) * 2).rounded(.up) / 2)
        return min(b, 4, max(1, 1200 / max(fontPx, 1)))
    }

    private func key(_ t: TextContent, _ px: CGFloat, _ w: CGFloat, _ d: Double) -> Key {
        // duration only matters for templates / evenly spread karaoke words
        let dk = (t.template != nil || t.karaoke != nil) ? Int((d * 100).rounded()) : 0
        return Key(content: t, px: Int((px * 4).rounded()), canvasW: t.boxWidth == nil ? 0 : Int(w.rounded()), duration: dk)
    }

    private func scene(_ t: TextContent, fontPx: CGFloat, canvasWidthPx: CGFloat, duration: Double) -> TextScene {
        let k = key(t, fontPx, canvasWidthPx, duration)
        if let s = scenes.get(k) { return s }
        let s = TextSceneBuilder.build(t, fontPx: fontPx, canvasWidthPx: canvasWidthPx, duration: duration, dynamic: false)
        scenes.put(k, s, bytes: 0)
        return s
    }

    private func staticResult(_ t: TextContent, fontPx: CGFloat, canvasWidthPx: CGFloat, duration: Double, pxPerCanvas: Double) -> Result? {
        guard fontPx >= 1, !(t.string.isEmpty && t.template == nil) else { return nil }
        let k = key(t, fontPx, canvasWidthPx, duration)
        if let s = statics.get(k) {
            return Result(texture: s.texture, canvasSize: Size2(Double(s.size.width) / pxPerCanvas, Double(s.size.height) / pxPerCanvas))
        }
        let sc = scene(t, fontPx: fontPx, canvasWidthPx: canvasWidthPx, duration: duration)
        guard let r = Self.render(sc), let tex = TextGPU.upload(r.ctx, r.w, r.h) else { return nil }
        statsLock.withLock { _rasterizations += 1 }
        statics.put(k, StaticImage(texture: tex, size: CGSize(width: r.w, height: r.h)), bytes: r.w * r.h * 4)
        return Result(texture: tex, canvasSize: Size2(Double(r.w) / pxPerCanvas, Double(r.h) / pxPerCanvas))
    }

    private func dynamic(_ t: TextContent, fontPx: CGFloat, canvasWidthPx: CGFloat, duration: Double) -> Dynamic? {
        guard fontPx >= 1 else { return nil }
        let k = key(t, fontPx, canvasWidthPx, duration)
        if let d = dynamics.get(k) { return d }
        let sc = TextSceneBuilder.build(t, fontPx: fontPx, canvasWidthPx: canvasWidthPx, duration: duration, dynamic: true)
        guard let atlas = TextAtlas.build(sc) else { return nil }
        statsLock.withLock { _rasterizations += 1 }
        let d = Dynamic(scene: sc, atlas: atlas)
        dynamics.put(k, d, bytes: atlas.bytes)
        return d
    }

    /// Integral bounds grown to multiples of 16 px (the compositor's layer-texture quantum, so it draws text 1:1).
    static func padded(_ r: CGRect) -> CGRect {
        let b = r.integral
        func grow(_ v: CGFloat) -> (CGFloat, CGFloat) {
            let n = Int(v)
            let target = n <= 64 ? n : (n + 15) / 16 * 16
            let extra = CGFloat(target - n)
            return ((extra / 2).rounded(.down), extra - (extra / 2).rounded(.down))
        }
        let (l, rr) = grow(b.width), (t, bt) = grow(b.height)
        return CGRect(x: b.minX - l, y: b.minY - t, width: b.width + l + rr, height: b.height + t + bt)
    }

    /// Paints a scene's rest pose into a bitmap sized to its (padded) bounds.
    static func render(_ s: TextScene) -> (ctx: CGContext, w: Int, h: Int, image: CGImage?)? {
        let b = padded(s.bounds)
        let w = Int(b.width), h = Int(b.height)
        guard w > 0, h > 0, w <= 16384, h <= 16384 else { return nil }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -b.minX, y: -b.minY)
        TextPainter.drawStatic(s, in: ctx)
        return (ctx, w, h, ctx.makeImage())
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
