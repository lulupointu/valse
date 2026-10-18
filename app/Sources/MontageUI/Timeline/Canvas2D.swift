import AppKit
@preconcurrency import Metal
import CoreText
import MontageCore
import MontageEngine

/// Immediate-mode 2D display list for custom GPU-drawn views (timeline, future curve editors, waveforms…).
/// Coordinates in points, origin top-left. Rendered by `Canvas2DRenderer` with instanced Metal draws: rects (rounded,
/// optional border), images (CGImage → cached texture) and text labels (Core Text → cached alpha textures).
/// Consecutive items that share a texture are merged into one draw call; plain rects never break a batch.
struct Canvas2D {
    struct Inst { var rect: SIMD4<Float>; var color: SIMD4<Float>; var uv: SIMD4<Float>; var misc: SIMD4<Float> }
    enum Tex: Equatable { case none, image(ObjectIdentifier), label(String) }
    var items: [(Inst, Tex)] = []
    var images: [ObjectIdentifier: CGImage] = [:]
    var clip: CGRect?

    /// Empties the list but keeps its storage (views reuse one `Canvas2D` across frames: no per-frame allocation).
    mutating func reset() {
        items.removeAll(keepingCapacity: true)
        images.removeAll(keepingCapacity: true)
        clip = nil
    }

    mutating func rect(_ r: CGRect, _ c: RGBA, radius: CGFloat = 0, border: CGFloat = 0) {
        guard let r = clipped(r) else { return }
        items.append((Inst(rect: v4(r), color: c.simd, uv: .zero, misc: SIMD4(0, Float(radius), Float(border), 0)), .none))
    }

    mutating func image(_ img: CGImage, in r: CGRect, alpha: Double = 1, radius: CGFloat = 0, fill: Bool = true) {
        // aspect-fill crop of the image into r
        let ia = Double(img.width) / Double(max(img.height, 1)), ra = Double(r.width) / Double(max(r.height, 1))
        var uv = SIMD4<Float>(0, 0, 1, 1)
        if fill {
            if ia > ra { let w = Float(ra / ia); uv = SIMD4((1 - w) / 2, 0, (1 + w) / 2, 1) }
            else { let h = Float(ia / ra); uv = SIMD4(0, (1 - h) / 2, 1, (1 + h) / 2) }
        }
        var rr = r
        if let c = clip {
            let i = r.intersection(c)
            guard !i.isNull, i.width > 0 else { return }
            // shrink uv proportionally
            let du = uv.z - uv.x, dv = uv.w - uv.y
            let x0 = Float((i.minX - r.minX) / r.width), x1 = Float((i.maxX - r.minX) / r.width)
            let y0 = Float((i.minY - r.minY) / r.height), y1 = Float((i.maxY - r.minY) / r.height)
            uv = SIMD4(uv.x + du * x0, uv.y + dv * y0, uv.x + du * x1, uv.y + dv * y1)
            rr = i
        }
        let id = ObjectIdentifier(img)
        images[id] = img
        items.append((Inst(rect: v4(rr), color: SIMD4(1, 1, 1, Float(alpha)), uv: uv, misc: SIMD4(1, Float(radius), 0, 0)), .image(id)))
    }

    /// Text label; `maxWidth` clips (no ellipsis to keep it cheap).
    mutating func text(_ s: String, at p: CGPoint, size: CGFloat = 10.5, weight: NSFont.Weight = .medium, color: RGBA = .white,
                       maxWidth: CGFloat? = nil, mono: Bool = false) {
        guard !s.isEmpty else { return }
        let key = "\(mono ? "m" : "s")\(Int(size * 10))\(Int(weight.rawValue * 100))|\(s)"
        guard let m = LabelCache.shared.metrics(key, s, size: size, weight: weight, mono: mono) else { return }
        var w = m.width, uMax: Float = 1
        if let maxWidth, w > maxWidth { uMax = Float(maxWidth / w); w = maxWidth }
        guard w > 1 else { return }
        var r = CGRect(x: p.x, y: p.y, width: w, height: m.height)
        var uv = SIMD4<Float>(0, 0, uMax, 1)
        if let c = clip {
            let i = r.intersection(c)
            guard !i.isNull, i.width > 1 else { return }
            let x0 = Float((i.minX - r.minX) / r.width) * uMax, x1 = Float((i.maxX - r.minX) / r.width) * uMax
            uv = SIMD4(x0, 0, x1, 1); r = i
        }
        items.append((Inst(rect: v4(r), color: color.simd, uv: uv, misc: SIMD4(2, 0, 0, 0)), .label(key)))
    }

    func measure(_ s: String, size: CGFloat = 10.5, weight: NSFont.Weight = .medium, mono: Bool = false) -> CGFloat {
        let key = "\(mono ? "m" : "s")\(Int(size * 10))\(Int(weight.rawValue * 100))|\(s)"
        return LabelCache.shared.metrics(key, s, size: size, weight: weight, mono: mono)?.width ?? 0
    }

    private func clipped(_ r: CGRect) -> CGRect? {
        guard let c = clip else { return r }
        let i = r.intersection(c)
        return i.isNull || i.width <= 0 || i.height <= 0 ? nil : i
    }
    private func v4(_ r: CGRect) -> SIMD4<Float> { SIMD4(Float(r.minX), Float(r.minY), Float(r.width), Float(r.height)) }
}

/// Core Text label rasterizer cache (alpha textures at 2× scale).
@MainActor
final class LabelCache {
    static let shared = LabelCache()
    struct Entry { let texture: MTLTexture; let width: CGFloat; let height: CGFloat }
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private let capacity = 800
    let scale: CGFloat = 2

    func metrics(_ key: String, _ s: String, size: CGFloat, weight: NSFont.Weight, mono: Bool) -> Entry? {
        if let e = entries[key] { return e }
        let font = mono ? NSFont.monospacedDigitSystemFont(ofSize: size * scale, weight: weight) : NSFont.systemFont(ofSize: size * scale, weight: weight)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor.white]))
        var asc: CGFloat = 0, desc: CGFloat = 0, lead: CGFloat = 0
        let w = CGFloat(CTLineGetTypographicBounds(line, &asc, &desc, &lead))
        let pw = max(1, Int(ceil(w)) + 2), ph = max(1, Int(ceil(asc + desc)) + 2)
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: pw,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = ctx.data else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
        ctx.setShouldAntialias(true)
        ctx.textPosition = CGPoint(x: 1, y: desc + 1)
        CTLineDraw(line, ctx)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: pw, height: ph, mipmapped: false)
        d.usage = .shaderRead
        guard let tex = MetalContext.shared.device.makeTexture(descriptor: d) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, pw, ph), mipmapLevel: 0, withBytes: data, bytesPerRow: pw)
        let e = Entry(texture: tex, width: CGFloat(pw) / scale, height: CGFloat(ph) / scale)
        entries[key] = e; order.append(key)
        if order.count > capacity { entries[order.removeFirst()] = nil }
        return e
    }
}

/// Renders a `Canvas2D` into a target texture.
@MainActor
final class Canvas2DRenderer {
    private let ctx = MetalContext.shared
    private let pipeline: MTLRenderPipelineState
    private let white: MTLTexture
    private var imageTextures: [ObjectIdentifier: (CGImage, MTLTexture)] = [:]
    private var imageOrder: [ObjectIdentifier] = []
    private var buffers: [MTLBuffer] = []
    private var bufIndex = 0
    private let maxInst = 32768

    static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Inst { float4 rect; float4 color; float4 uv; float4 misc; };
    struct VOut { float4 pos [[position]]; float4 color; float2 uv; float2 local; float2 size; float kind [[flat]]; float radius [[flat]]; float border [[flat]]; };
    vertex VOut c2d_vs(uint vid [[vertex_id]], uint iid [[instance_id]], const device Inst* inst [[buffer(0)]],
                       constant float2& vp [[buffer(1)]], constant uint& base [[buffer(2)]]) {
        Inst i = inst[base + iid];
        float2 c = float2(vid & 1, (vid >> 1) & 1);
        float2 p = i.rect.xy + c * i.rect.zw;
        VOut o;
        o.pos = float4(p.x / vp.x * 2.0 - 1.0, 1.0 - p.y / vp.y * 2.0, 0.0, 1.0);
        o.color = i.color; o.uv = mix(i.uv.xy, i.uv.zw, c); o.local = c * i.rect.zw; o.size = i.rect.zw;
        o.kind = i.misc.x; o.radius = i.misc.y; o.border = i.misc.z;
        return o;
    }
    fragment float4 c2d_fs(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float4 col = in.color;
        if (in.kind > 1.5) { col.a *= tex.sample(s, in.uv).r; }
        else if (in.kind > 0.5) { float4 t = tex.sample(s, in.uv); col = float4(t.rgb, t.a * in.color.a); }
        float r = in.radius;
        float2 q = abs(in.local - in.size * 0.5) - (in.size * 0.5 - r);
        float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
        col.a *= saturate(0.5 - d);
        if (in.border > 0.0) { col.a *= saturate(d + in.border + 0.5); }
        return float4(col.rgb * col.a, col.a);
    }
    """

    init() {
        let lib = try! ctx.device.makeLibrary(source: Self.shader, options: nil)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "c2d_vs")
        d.fragmentFunction = lib.makeFunction(name: "c2d_fs")
        let ca = d.colorAttachments[0]!
        ca.pixelFormat = .bgra8Unorm
        ca.isBlendingEnabled = true
        ca.sourceRGBBlendFactor = .one; ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
        ca.sourceAlphaBlendFactor = .one; ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try! ctx.device.makeRenderPipelineState(descriptor: d)
        let wd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 1, height: 1, mipmapped: false)
        white = ctx.device.makeTexture(descriptor: wd)!
        var one: UInt8 = 255
        white.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &one, bytesPerRow: 1)
        buffers = (0..<3).map { _ in ctx.device.makeBuffer(length: maxInst * MemoryLayout<Canvas2D.Inst>.stride, options: .storageModeShared)! }
    }

    func encode(_ canvas: Canvas2D, into target: MTLTexture, scale: CGFloat, clear: RGBA, commandBuffer cmd: MTLCommandBuffer) {
        let buf = buffers[bufIndex]; bufIndex = (bufIndex + 1) % buffers.count
        let n = min(canvas.items.count, maxInst)
        let p = buf.contents().bindMemory(to: Canvas2D.Inst.self, capacity: maxInst)
        for i in 0..<n { p[i] = canvas.items[i].0 }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: clear.r, green: clear.g, blue: clear.b, alpha: 1)
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(buf, offset: 0, index: 0)
        var vp = SIMD2<Float>(Float(CGFloat(target.width) / scale), Float(CGFloat(target.height) / scale))
        enc.setVertexBytes(&vp, length: 8, index: 1)
        var start = 0
        var current: MTLTexture = white
        func flush(_ end: Int) {
            guard end > start else { return }
            var base = UInt32(start)
            enc.setVertexBytes(&base, length: 4, index: 2)
            enc.setFragmentTexture(current, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: end - start)
            start = end
        }
        for i in 0..<n {
            let tex: MTLTexture?
            switch canvas.items[i].1 {
            case .none: tex = nil
            case .image(let id): tex = canvas.images[id].flatMap(texture(for:))
            case .label(let key): tex = LabelCache.shared.cached(key)
            }
            if let tex, tex !== current { flush(i); current = tex }
        }
        flush(n)
        enc.endEncoding()
    }

    private func texture(for img: CGImage) -> MTLTexture? {
        let id = ObjectIdentifier(img)
        if let (_, t) = imageTextures[id] { return t }
        let w = img.width, h = img.height
        guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = c.data else { return nil }
        c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        d.usage = .shaderRead
        guard let t = ctx.device.makeTexture(descriptor: d) else { return nil }
        t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: w * 4)
        imageTextures[id] = (img, t); imageOrder.append(id)
        if imageOrder.count > 600 { imageTextures[imageOrder.removeFirst()] = nil }
        return t
    }
}

extension LabelCache {
    func cached(_ key: String) -> MTLTexture? { entries[key]?.texture }
}
