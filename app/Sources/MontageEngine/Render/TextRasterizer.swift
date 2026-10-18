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
    private final class Entry<V> {
        let value: V; let bytes: Int; var used: UInt64
        init(_ v: V, _ b: Int, _ u: UInt64) { value = v; bytes = b; used = u }
    }

    /// Small thread-safe LRU with an entry and a byte budget. A hit only bumps a counter (O(1): 50 captions look up
    /// their atlas every frame); eviction scans for the oldest entry, which only happens on inserts over budget.
    private final class LRU<V>: @unchecked Sendable {
        private let lock = NSLock()
        private var map: [Key: Entry<V>] = [:]
        private var tick: UInt64 = 0
        private var bytes = 0
        let capacity: Int
        private(set) var budget: Int
        init(capacity: Int, budget: Int) { self.capacity = capacity; self.budget = budget }
        func get(_ k: Key) -> V? {
            lock.withLock {
                guard let e = map[k] else { return nil }
                tick &+= 1; e.used = tick
                return e.value
            }
        }
        func put(_ k: Key, _ v: V, bytes b: Int) {
            lock.withLock {
                if let old = map[k] { bytes -= old.bytes }
                tick &+= 1
                map[k] = Entry(v, b, tick); bytes += b
                evictLocked()
            }
        }
        /// Changes the byte budget (memory pressure / 8 GB policy) and evicts down to it.
        func setBudget(_ b: Int) { lock.withLock { budget = b; evictLocked() } }
        private func evictLocked() {
            while map.count > capacity || (bytes > budget && map.count > 1) {
                guard let victim = map.min(by: { $0.value.used < $1.value.used })?.key else { break }
                if let e = map.removeValue(forKey: victim) { bytes -= e.bytes }
            }
        }
        var totalBytes: Int { lock.withLock { bytes } }
        func removeAll() { lock.withLock { map.removeAll(); bytes = 0 } }
    }

    private struct StaticImage { let texture: MTLTexture; let size: CGSize }
    private final class Dynamic: @unchecked Sendable {
        let scene: TextScene; let atlas: TextAtlas
        init(scene: TextScene, atlas: TextAtlas) { self.scene = scene; self.atlas = atlas }
    }

    private let statics = LRU<StaticImage>(capacity: 128, budget: MemoryBudget.textCacheBytes)
    private let dynamics = LRU<Dynamic>(capacity: 64, budget: MemoryBudget.textCacheBytes)
    private let scenes = LRU<TextScene>(capacity: 128, budget: .max)
    private let statsLock = NSLock()
    private var _rasterizations = 0

    public init() { _ = FontCatalog.ensureLoaded }  // registers imported fonts before anything renders

    /// Number of CPU rasterizations so far (tests: animated playback must not re-rasterize per frame).
    public var rasterizationCount: Int { statsLock.withLock { _rasterizations } }
    public func purge() { statics.removeAll(); dynamics.removeAll(); scenes.removeAll() }
    /// Bytes held by rasterized text (static images + glyph atlases).
    public var cacheBytes: Int { statics.totalBytes + dynamics.totalBytes }
    /// Shrinks both texture caches to `fraction` of their normal budget (memory pressure; 1 restores).
    public func setBudgetFraction(_ fraction: Double) {
        let b = Int(Double(MemoryBudget.textCacheBytes) * min(max(fraction, 0), 1))
        statics.setBudget(b); dynamics.setBudget(b)
    }

    // MARK: Public API

    /// Rest-pose texture of a text (no animation). `canvasHeight` in canvas pixels; `outputScale` = output px per canvas px.
    public func texture(for t: TextContent, canvasHeight: Double, outputScale: Double) -> Result? {
        staticResult(t, fontPx: CGFloat(t.fontSize * canvasHeight * outputScale), canvasWidthPx: CGFloat(canvasHeight * 16 / 9 * outputScale),
                     duration: 0, pxPerCanvas: outputScale)
    }

    /// Glyph quads of a text layer at one frame, ready to draw: `instances` (target pixel space, `width`×`height`)
    /// sample `atlas` (premultiplied). A static text is one quad over its cached image.
    struct GlyphDraw {
        let instances: [GlyphInstance]
        let atlas: MTLTexture
        let width: Int, height: Int
        let canvasSize: Size2
    }

    /// Texture of a text layer at one frame: static when nothing moves, else the GPU-composed glyphs (pool texture from
    /// `acquire`, valid for this command buffer only). Both are premultiplied.
    public func layerTexture(_ t: TextContent, canvas: Size2, outputScale: Double, layerScale: Vec2 = .one,
                             animations: [ActiveAnimation] = [], localTime: Time = .zero, duration: Time = .zero,
                             commandBuffer cmd: MTLCommandBuffer?, acquire: (Int, Int) -> MTLTexture) -> Result? {
        guard let cmd else {
            let k = outputScale * Self.scaleBucket(layerScale, fontPx: t.fontSize * canvas.height * outputScale)
            return staticResult(t, fontPx: CGFloat(t.fontSize * canvas.height * k), canvasWidthPx: CGFloat(canvas.width * k),
                                duration: duration.seconds, pxPerCanvas: k)
        }
        switch layerContent(t, canvas: canvas, outputScale: outputScale, layerScale: layerScale, animations: animations,
                            localTime: localTime, duration: duration) {
        case .none: return nil
        case .texture(let r): return r
        case .glyphs(let g):
            let target = acquire(g.width, g.height)
            TextGPU.compose(g.instances, atlas: g.atlas, into: target, cmd)
            return Result(texture: target, canvasSize: g.canvasSize)
        }
    }

    enum LayerContent { case none, texture(Result), glyphs(GlyphDraw) }

    /// What a text layer draws at one frame, without encoding anything: the static image, or the animated glyph quads
    /// (cached atlas; only the per-glyph transforms are computed per frame — layout and rasterization are cached).
    func layerContent(_ t: TextContent, canvas: Size2, outputScale: Double, layerScale: Vec2,
                      animations: [ActiveAnimation], localTime: Time, duration: Time) -> LayerContent {
        let bucket = Self.scaleBucket(layerScale, fontPx: t.fontSize * canvas.height * outputScale)
        let k = outputScale * bucket
        let fontPx = CGFloat(t.fontSize * canvas.height * k)
        let canvasW = CGFloat(canvas.width * k)
        func still() -> LayerContent {
            staticResult(t, fontPx: fontPx, canvasWidthPx: canvasW, duration: duration.seconds, pxPerCanvas: k).map { .texture($0) } ?? .none
        }
        let glyphAnims: [(spec: GlyphAnimationSpec, phase: AnimationPhaseKind, progress: Double)] = animations.compactMap { a in
            guard let spec = Registries.animations[a.typeID]?.glyph else { return nil }
            let phase: AnimationPhaseKind = a.phase == .in ? .in : (a.phase == .out ? .out : .combo)
            return (spec, phase, a.progress)
        }
        let isDynamic = t.template != nil || !glyphAnims.isEmpty || (t.karaoke != nil && !t.string.isEmpty)
        guard isDynamic else { return still() }
        let input = TextFrameInput(anims: glyphAnims, localTime: localTime.seconds, duration: duration.seconds)
        guard let dyn = dynamic(t, fontPx: fontPx, canvasWidthPx: canvasW, duration: duration.seconds) else { return still() }
        let scene = dyn.scene
        // symmetric margin around the rest bounds so the layer centre (and thus placement) never moves
        // Integer margin in multiples of 8 around the same 16-px-padded box as the static image: cells stay pixel
        // aligned and the compositor never resamples, so the rest pose matches the static image exactly (no pop).
        let m = (TextAnimator.margin(scene, input) / 8).rounded(.up) * 8
        let rb = Self.padded(scene.bounds).insetBy(dx: -m, dy: -m)
        let w = Int(rb.width), h = Int(rb.height)
        guard w > 0, h > 0, w <= 8192, h <= 8192 else { return .none }
        let inst = TextAnimator.instances(scene, dyn.atlas, input, origin: rb.origin)
        return .glyphs(GlyphDraw(instances: inst, atlas: dyn.atlas.texture, width: w, height: h,
                                 canvasSize: Size2(Double(w) / k, Double(h) / k)))
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

    public func sticker(_ id: String, canvasSide: Double, outputScale: Double, time: Double = 0, style: ShapeStickerStyle? = nil) -> Result? {
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
        case .vector(let base):
            let px = max(8, Int((canvasSide * outputScale).rounded(.up)))
            let layers = style.map { VectorLayer.styled(base, $0) } ?? base
            let key = "\(id)@\(px)" + (style.map { "#\($0.hashValue)" } ?? "")
            if let t = vectorLock.withLock({ vectorCache[key] }) { return Result(texture: t, canvasSize: Size2(canvasSide, canvasSide)) }
            guard let tex = VectorStickerRenderer.texture(layers, px: px) else { return nil }
            vectorLock.withLock {
                vectorCache[key] = tex; vectorOrder.append(key)
                if vectorOrder.count > 64 { vectorCache[vectorOrder.removeFirst()] = nil }
            }
            return Result(texture: tex, canvasSize: Size2(canvasSide, canvasSide))
        case .lottie(let name, let bundle):
            // W5: animated sticker frame at clip time (cached per Lottie frame; side quantized to 32 px, ≤ 1024)
            guard let url = bundle().url(forResource: name, withExtension: nil) else { return nil }
            let side = min(1024, max(32, (Int((canvasSide * outputScale).rounded(.up)) + 31) / 32 * 32))
            guard let tex = LottieLibrary.shared.texture(url, seconds: time, side: side) else { return nil }
            return Result(texture: tex, canvasSize: Size2(canvasSide, canvasSide))
        case .user(let uid):
            // ST-003: imported sticker frame at clip time, aspect-fitted in the side × side box
            let lib = UserStickerLibrary.shared
            let side = min(2048, max(32, (Int((canvasSide * outputScale).rounded(.up)) + 31) / 32 * 32))
            guard let tex = lib.texture(uid, seconds: time, side: side) else { return nil }
            return Result(texture: tex, canvasSize: lib.size(uid, side: canvasSide))
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

    /// Frames of a per-glyph text animation painted with Core Graphics (inspector tiles, tests): the same scene, atlas
    /// and per-unit transforms as the GPU compose pass, so a tile shows exactly what the clip will do. One image per
    /// value of `progresses` (In/Out: 0…1 progress; Loop: cycle phase), all with the same size (rest bounds + margin).
    public static func animationFrames(_ t: TextContent, fontPx: Double, animationID: String, progresses: [Double],
                                       canvasWidthPx: Double = 1920, maxMarginEm: Double = 1) -> [CGImage] {
        guard let d = Registries.animations[animationID], let spec = d.glyph, fontPx >= 1 else { return [] }
        let scene = TextSceneBuilder.build(t, fontPx: CGFloat(fontPx), canvasWidthPx: CGFloat(canvasWidthPx), duration: 3, dynamic: true)
        guard let atlas = TextAtlas.build(scene, keepImage: true), let atlasImage = atlas.image else { return [] }
        let probe = TextFrameInput(anims: [(spec, d.phase, 0)], localTime: 0, duration: 3)
        let em = scene.blocks.map(\.em).max() ?? CGFloat(fontPx)
        let m = min(TextAnimator.margin(scene, probe), CGFloat(maxMarginEm) * em).rounded(.up)
        let rb = padded(scene.bounds).insetBy(dx: -m, dy: -m)
        let w = Int(rb.width), h = Int(rb.height)
        guard w > 0, h > 0, w <= 4096, h <= 4096 else { return [] }
        let AW = CGFloat(atlasImage.width), AH = CGFloat(atlasImage.height)
        var crops: [SIMD4<Float>: CGImage] = [:]
        func crop(_ uv: SIMD4<Float>) -> CGImage? {
            if let c = crops[uv] { return c }
            let r = CGRect(x: CGFloat(uv.x) * AW, y: CGFloat(uv.y) * AH, width: CGFloat(uv.z) * AW, height: CGFloat(uv.w) * AH).integral
            let c = atlasImage.cropping(to: r)
            crops[uv] = c
            return c
        }
        var out: [CGImage] = []
        for p in progresses {
            let input = TextFrameInput(anims: [(spec, d.phase, p)], localTime: 0, duration: 3)
            let inst = TextAnimator.instances(scene, atlas, input, origin: rb.origin)
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { continue }
            ctx.interpolationQuality = .high
            ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)  // y down, like the scene
            for g in inst {
                let p0 = CGPoint(x: CGFloat(g.p0.x), y: CGFloat(g.p0.y))
                let T = CGAffineTransform(a: CGFloat(g.p1.x - g.p0.x), b: CGFloat(g.p1.y - g.p0.y),
                                          c: CGFloat(g.p2.x - g.p0.x), d: CGFloat(g.p2.y - g.p0.y), tx: p0.x, ty: p0.y)
                let layers: [(SIMD4<Float>, Float)] = g.mixB > 0 ? [(g.uvA, 1 - g.mixB), (g.uvB, g.mixB)] : [(g.uvA, Float(1))]
                for (uv, a) in layers where a > 0.002 {
                    guard let img = crop(uv) else { continue }
                    ctx.saveGState()
                    ctx.concatenate(T)
                    ctx.translateBy(x: 0, y: 1); ctx.scaleBy(x: 1, y: -1)  // CGImage draws bottom-up
                    ctx.setAlpha(CGFloat(g.opacity * a))
                    ctx.draw(img, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                    ctx.restoreGState()
                }
            }
            if let img = ctx.makeImage() { out.append(img) }
        }
        return out
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
        return Key(content: t, px: Int((px * 4).rounded()), canvasW: t.boxWidth == nil && !TextSceneBuilder.isFittedCaption(t) ? 0 : Int(w.rounded()), duration: dk)
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
    private var bytes = 0
    private let capacity = 32
    private var _byteBudget = MemoryBudget.imageCacheBytes
    /// Max bytes of cached image textures (a 4096² still is 64 MB); lowering it evicts least recently used.
    public var byteBudget: Int {
        get { lock.withLock { _byteBudget } }
        set { lock.withLock { _byteBudget = newValue; evictLocked() } }
    }

    public func texture(for asset: MediaAsset) -> MTLTexture? {
        let key = asset.contentHash.isEmpty ? asset.url.path : asset.contentHash
        if let t = lock.withLock({ () -> MTLTexture? in
            guard let t = cache[key] else { return nil }
            if let i = order.lastIndex(of: key), i != order.count - 1 { order.remove(at: i); order.append(key) }
            return t
        }) { return t }
        guard let t = ImageTextureCache.load(url: asset.url, maxSide: 4096) else { return nil }
        lock.withLock {
            if let old = cache[key] { bytes -= old.width * old.height * 4; order.removeAll { $0 == key } }
            cache[key] = t; order.append(key); bytes += t.width * t.height * 4
            evictLocked()
        }
        return t
    }

    /// Keeps the newest texture even when it alone exceeds the budget (it is on screen).
    private func evictLocked() {
        while order.count > 1 && (order.count > capacity || bytes > _byteBudget) {
            if let t = cache.removeValue(forKey: order.removeFirst()) { bytes -= t.width * t.height * 4 }
        }
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
