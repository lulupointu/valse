@preconcurrency import Metal
import CoreGraphics
import Foundation
import simd
import MontageCore
import MontageEffects

/// Every scene item rasterized once into its own cell of one texture. At rest, a cell drawn at its `rect` reproduces the
/// static image pixel for pixel (cells are integer-aligned), so animations start and end without a pop.
final class TextAtlas: @unchecked Sendable {
    let texture: MTLTexture
    /// Normalized (x, y, w, h) per item; nil if the item has no cell.
    let uv: [SIMD4<Float>?]
    /// Integer-aligned scene rect of each item's cell.
    let cells: [CGRect]
    let bytes: Int

    init(texture: MTLTexture, uv: [SIMD4<Float>?], cells: [CGRect]) {
        self.texture = texture; self.uv = uv; self.cells = cells; bytes = texture.width * texture.height * 4
    }

    static func build(_ scene: TextScene) -> TextAtlas? {
        let n = scene.items.count
        guard n > 0 else { return nil }
        var cells = scene.items.map { $0.rect.integral }
        // variants share their base cell size
        for (i, it) in scene.items.enumerated() {
            if let b = it.variantOf, b >= 0, b < n { let u = cells[b].union(cells[i]); cells[b] = u; cells[i] = u }
        }
        let gutter: CGFloat = 2
        let area = cells.reduce(CGFloat(0)) { $0 + ($1.width + gutter) * ($1.height + gutter) }
        let maxW = cells.map(\.width).max() ?? 1
        let W = Int(min(4096, max(maxW + gutter * 2, (area.squareRoot() * 1.15).rounded(.up))))
        // shelf packing, tallest first
        let order = (0..<n).sorted { cells[$0].height > cells[$1].height }
        var origins = [CGPoint](repeating: .zero, count: n)
        var x = gutter, y = gutter, shelf: CGFloat = 0
        for i in order {
            let c = cells[i]
            if x + c.width + gutter > CGFloat(W) { x = gutter; y += shelf + gutter; shelf = 0 }
            origins[i] = CGPoint(x: x, y: y)
            x += c.width + gutter; shelf = max(shelf, c.height)
        }
        let H = Int((y + shelf + gutter).rounded(.up))
        guard W > 0, H > 0, H <= 8192, W * H <= 24_000_000 else { return nil }
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(H)); ctx.scaleBy(x: 1, y: -1)
        var uv = [SIMD4<Float>?](repeating: nil, count: n)
        for i in 0..<n {
            let c = cells[i], o = origins[i]
            ctx.saveGState()
            ctx.clip(to: CGRect(origin: o, size: c.size))
            ctx.translateBy(x: o.x - c.minX, y: o.y - c.minY)
            TextPainter.draw(scene.items[i], scene: scene, in: ctx)
            ctx.restoreGState()
            uv[i] = SIMD4(Float(o.x) / Float(W), Float(o.y) / Float(H), Float(c.width) / Float(W), Float(c.height) / Float(H))
        }
        guard let tex = TextGPU.upload(ctx, W, H) else { return nil }
        return TextAtlas(texture: tex, uv: uv, cells: cells)
    }
}

/// Per-frame animation input of a text layer.
struct TextFrameInput {
    /// Clip-level glyph animations (In / Out / Loop) with their progress.
    var anims: [(spec: GlyphAnimationSpec, phase: AnimationPhaseKind, progress: Double)]
    var localTime: Double
    var duration: Double
}

/// Matches `GlyphInst` in `TextGPU.shader`.
struct GlyphInstance {
    var p0: SIMD2<Float>, p1: SIMD2<Float>, p2: SIMD2<Float>, p3: SIMD2<Float>
    var uvA: SIMD4<Float>
    var uvB: SIMD4<Float>
    var mixB: Float
    var opacity: Float
    var pad: SIMD2<Float> = .zero
}

enum TextAnimator {
    struct UnitState { var m: CGAffineTransform = .identity; var opacity: Double = 1; var highlight: Double = 0 }

    static func transform(_ s: GlyphState, pivot: CGPoint, em: CGFloat) -> CGAffineTransform {
        CGAffineTransform(translationX: -pivot.x, y: -pivot.y)
            .concatenating(CGAffineTransform(scaleX: CGFloat(s.scale.x), y: CGFloat(s.scale.y)))
            .concatenating(CGAffineTransform(rotationAngle: CGFloat(s.rotation * .pi / 180)))
            .concatenating(CGAffineTransform(translationX: pivot.x + CGFloat(s.offset.x) * em, y: pivot.y + CGFloat(s.offset.y) * em))
    }

    /// Animation list of one block at `t` (template layer timing + the clip's own animations). nil = block hidden.
    static func blockAnims(_ b: TextScene.Block, _ input: TextFrameInput) -> [(spec: GlyphAnimationSpec, phase: AnimationPhaseKind, progress: Double)]? {
        var out = input.anims
        guard let L = b.layer else { return out }
        let t = input.localTime, D = max(input.duration, 0.001)
        let s0 = L.start * D, e0 = max(L.end * D, s0 + 0.001)
        guard t >= s0, t <= e0 + 1e-6 else { return nil }
        if let a = L.inAnim, let spec = Registries.animations[a.id]?.glyph {
            let d = min(a.duration, (e0 - s0) * 0.5)
            out.append((spec, .in, d > 0 ? min(max((t - s0) / d, 0), 1) : 1))
        }
        if let a = L.outAnim, let spec = Registries.animations[a.id]?.glyph {
            let d = min(a.duration, (e0 - s0) * 0.5)
            if t > e0 - d { out.append((spec, .out, min(max((t - (e0 - d)) / max(d, 1e-6), 0), 1))) }
        }
        if let a = L.loopAnim, let spec = Registries.animations[a.id]?.glyph {
            let x = (t - s0) / max(a.period, 0.05)
            out.append((spec, .combo, x - floor(x)))
        }
        return out
    }

    /// Karaoke state of word `w` at time `t` (seconds, clip-local).
    static func karaoke(_ k: KaraokeStyle, words: [(start: Double, end: Double, keyword: Bool)], w: Int, t: Double)
        -> (state: GlyphState, boxOpacity: Double) {
        guard w >= 0, w < words.count else { return (GlyphState(), 0) }
        let wt = words[w]
        var s = GlyphState()
        let active = t >= wt.start && t < max(wt.end, wt.start + 0.05)
        let spoken = t >= wt.start
        let since = t - wt.start
        func ease(_ x: Double) -> Double { let c = min(max(x, 0), 1); return 1 - (1 - c) * (1 - c) }
        let pop = ease(since / 0.12)
        var box = 0.0
        switch k.mode {
        case .highlightWord:
            if active { s.highlight = pop; box = pop; let sc = 1 + (k.highlightScale - 1) * pop; s.scale = s.scale * Vec2(sc, sc) }
            else if !spoken { s.opacity = k.unspokenOpacity }
        case .fillSpoken:
            if spoken { s.highlight = pop; box = active ? pop : 0 } else { s.opacity = k.unspokenOpacity }
            if active { let sc = 1 + (k.highlightScale - 1) * pop; s.scale = s.scale * Vec2(sc, sc) }
        case .reveal:
            if !spoken { s.opacity = 0 } else {
                let p = min(since / 0.22, 1)
                let back = 1 + 2.7 * pow(p - 1, 3) + 1.7 * pow(p - 1, 2)
                let sc = max(0.01, back) * (active ? k.highlightScale : 1)
                s.scale = s.scale * Vec2(sc, sc); s.opacity = min(p * 3, 1)
                if active { s.highlight = 1; box = 1 }
            }
        case .singleWord:
            // current word = last word that started (stays until the next one)
            let cur = words.lastIndex { t >= $0.start } ?? 0
            if w != cur { s.opacity = 0 } else { s.highlight = 1; box = 1 }
        }
        if k.bounce > 0, spoken, since < 0.3 { s.offset.y -= k.bounce * sin(min(since / 0.3, 1) * .pi) }
        return (s, box)
    }

    /// GPU instances of a scene at a frame, relative to `origin` (top-left of the target, scene space).
    static func instances(_ scene: TextScene, _ atlas: TextAtlas, _ input: TextFrameInput, origin: CGPoint) -> [GlyphInstance] {
        var out: [GlyphInstance] = []
        out.reserveCapacity(scene.items.count)
        let perBlock = scene.blocks.map { Self.blockAnims($0, input) }
        // highlight variant of each base item
        var variant = [Int?](repeating: nil, count: scene.items.count)
        for (i, it) in scene.items.enumerated() { if let b = it.variantOf, b >= 0 { variant[b] = i } }
        for (i, it) in scene.items.enumerated() {
            guard it.variantOf == nil, let uvA = atlas.uv[i] else { continue }
            let b = scene.blocks[it.block]
            guard let anims = perBlock[it.block] else { continue }
            var m = CGAffineTransform.identity
            var opacity = 1.0, highlight = 0.0
            let em = b.em
            // karaoke (word level)
            if let k = b.karaoke, !b.wordTimes.isEmpty {
                if it.word >= 0 {
                    let (s, box) = karaoke(k, words: b.wordTimes, w: it.word, t: input.localTime)
                    var st = s
                    if k.mode == .singleWord, it.word < b.wordPivots.count {
                        st.offset = st.offset + Vec2(Double((b.center.x - b.wordPivots[it.word].x) / em), Double((b.center.y - b.wordPivots[it.word].y) / em))
                    }
                    let pivot = it.word < b.wordPivots.count ? b.wordPivots[it.word] : b.center
                    m = m.concatenating(transform(st, pivot: pivot, em: em))
                    if case .wordBox = it.kind { opacity *= box * st.opacity } else { opacity *= st.opacity; highlight = st.highlight }
                }
            }
            for a in anims {
                let unit: GlyphUnitInfo
                let pivot: CGPoint
                switch a.spec.unit {
                case .character where it.char >= 0:
                    unit = GlyphUnitInfo(index: it.char, count: b.layout.visibleCharCount, random: glyphRandom(it.char, seed: 11))
                    pivot = it.char < b.charPivots.count ? b.charPivots[it.char] : b.center
                case .word where it.word >= 0:
                    unit = GlyphUnitInfo(index: it.word, count: b.layout.words.count, random: glyphRandom(it.word, seed: 17))
                    pivot = it.word < b.wordPivots.count ? b.wordPivots[it.word] : b.center
                case .line where it.line >= 0 || it.char >= 0:
                    let li = it.line >= 0 ? it.line : lineOf(it, b)
                    unit = GlyphUnitInfo(index: li, count: max(b.layout.lines.count, 1), random: glyphRandom(li, seed: 23))
                    pivot = li < b.linePivots.count ? b.linePivots[li] : b.center
                default:
                    unit = GlyphUnitInfo(index: 0, count: 1, random: 0.5)
                    pivot = b.center
                }
                let s = a.spec.state(progress: a.progress, phase: a.phase, unit: unit)
                if !s.isIdentity {
                    m = m.concatenating(transform(s, pivot: pivot, em: em))
                    opacity *= s.opacity
                    highlight = max(highlight, s.highlight)
                }
            }
            guard opacity > 0.002 else { continue }
            let r = atlas.cells[i]
            func p(_ x: CGFloat, _ y: CGFloat) -> SIMD2<Float> {
                let q = CGPoint(x: x, y: y).applying(m)
                return SIMD2(Float(q.x - origin.x), Float(q.y - origin.y))
            }
            let uvB = variant[i].flatMap { atlas.uv[$0] } ?? uvA
            out.append(GlyphInstance(p0: p(r.minX, r.minY), p1: p(r.maxX, r.minY), p2: p(r.minX, r.maxY), p3: p(r.maxX, r.maxY),
                                     uvA: uvA, uvB: uvB, mixB: variant[i] == nil ? 0 : Float(highlight), opacity: Float(min(opacity, 1))))
        }
        return out
    }

    static func lineOf(_ it: TextScene.Item, _ b: TextScene.Block) -> Int {
        guard it.char >= 0 else { return 0 }
        return b.layout.clusters.first { $0.charIndex == it.char }?.lineIndex ?? 0
    }

    /// Render margin (scene px) needed around the rest bounds for the active animations.
    static func margin(_ scene: TextScene, _ input: TextFrameInput) -> CGFloat {
        var extent: Double = 0.1
        for b in scene.blocks {
            for a in blockAnims(b, input) ?? [] { extent = max(extent, a.spec.extent) }
            if let k = b.karaoke { extent = max(extent, (max(k.highlightScale, k.keywordScale) - 1) * 2 + k.bounce + 0.2) }
        }
        let em = scene.blocks.map(\.em).max() ?? 10
        if scene.blocks.contains(where: { $0.karaoke?.mode == .singleWord }) { return max(CGFloat(extent) * em, scene.bounds.width / 2) }
        return CGFloat(extent) * em
    }
}

/// Metal side of the text engine: atlas upload and the instanced glyph compose pass.
enum TextGPU {
    static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct GlyphInst { float2 p[4]; float4 uvA; float4 uvB; float mixB; float opacity; float2 pad; };
    struct VOut { float4 pos [[position]]; float2 uvA; float2 uvB; float mixB; float opacity; };
    vertex VOut glyph_vs(uint vid [[vertex_id]], uint iid [[instance_id]], constant GlyphInst* inst [[buffer(0)]],
                         constant float2& target [[buffer(1)]]) {
        GlyphInst g = inst[iid];
        float2 p = g.p[vid];
        float2 c = float2(float(vid & 1), float(vid >> 1));
        VOut o;
        o.pos = float4(p.x / target.x * 2 - 1, 1 - p.y / target.y * 2, 0, 1);
        o.uvA = g.uvA.xy + c * g.uvA.zw;
        o.uvB = g.uvB.xy + c * g.uvB.zw;
        o.mixB = g.mixB; o.opacity = g.opacity;
        return o;
    }
    fragment float4 glyph_fs(VOut in [[stage_in]], texture2d<float> atlas [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_zero);
        float4 a = atlas.sample(s, in.uvA);
        float4 b = in.mixB > 0.0 ? atlas.sample(s, in.uvB) : a;
        return mix(a, b, in.mixB) * in.opacity;
    }
    """

    private static let lock = NSLock()
    nonisolated(unsafe) private static var pipelineCache: MTLRenderPipelineState?

    static var pipeline: MTLRenderPipelineState? {
        lock.withLock {
            if let p = pipelineCache { return p }
            let dev = MetalContext.shared.device
            do {
                let lib = try dev.makeLibrary(source: shader, options: nil)
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = lib.makeFunction(name: "glyph_vs")
                d.fragmentFunction = lib.makeFunction(name: "glyph_fs")
                let ca = d.colorAttachments[0]!
                ca.pixelFormat = MetalContext.workingFormat
                ca.isBlendingEnabled = true
                ca.sourceRGBBlendFactor = .one; ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
                ca.sourceAlphaBlendFactor = .one; ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                pipelineCache = try dev.makeRenderPipelineState(descriptor: d)
            } catch {
                EngineLog.error("text pipeline: \(error)")
            }
            return pipelineCache
        }
    }

    static func upload(_ ctx: CGContext, _ w: Int, _ h: Int) -> MTLTexture? {
        guard let data = ctx.data else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = .shaderRead
        guard let tex = MetalContext.shared.device.makeTexture(descriptor: d) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: ctx.bytesPerRow)
        return tex
    }

    /// Draws `instances` from `atlas` into `target` (cleared, premultiplied).
    static func compose(_ instances: [GlyphInstance], atlas: MTLTexture, into target: MTLTexture, _ cmd: MTLCommandBuffer) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.label = "text-glyphs"
        if !instances.isEmpty, let pipe = pipeline {
            enc.setRenderPipelineState(pipe)
            var size = SIMD2<Float>(Float(target.width), Float(target.height))
            let bytes = instances.count * MemoryLayout<GlyphInstance>.stride
            if bytes <= 4096 {
                instances.withUnsafeBytes { enc.setVertexBytes($0.baseAddress!, length: bytes, index: 0) }
            } else if let buf = MetalContext.shared.device.makeBuffer(bytes: instances, length: bytes, options: .storageModeShared) {
                enc.setVertexBuffer(buf, offset: 0, index: 0)
            }
            enc.setVertexBytes(&size, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            enc.setFragmentTexture(atlas, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instances.count)
        }
        enc.endEncoding()
    }
}
