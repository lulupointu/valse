@preconcurrency import Metal
import CoreVideo
import Foundation
import simd
import MontageCore
import MontageEffects

/// Supplies decoded frames for media layers (by clip). The compositor backs this with AVFoundation source frames;
/// live re-render (paused edits) backs it with the last decoded frames.
public protocol FrameSourceProvider {
    func pixelBuffer(for clipID: ClipID) -> CVPixelBuffer?
    /// Secondary decoded frames of a layer (matte, next frame for smooth slow-mo, previous frames for motion blur).
    func auxPixelBuffer(for clipID: ClipID, role: AuxRole) -> CVPixelBuffer?
}

extension FrameSourceProvider {
    public func auxPixelBuffer(for clipID: ClipID, role: AuxRole) -> CVPixelBuffer? { nil }
}

/// Extra composition lanes decoded in sync with a clip's main lane (same time remap, shifted source).
public enum AuxRole: Hashable, Sendable {
    /// The source frame after the one shown (smooth slow-mo frame blending / interpolation).
    case nextFrame
    /// The k-th source frame before the one shown (motion blur accumulation), k ≥ 1.
    case previousFrame(Int)
    /// AI matte video (`MatteStore`), aligned with the media.
    case matte
    /// Relight: depth matte video (`MatteStore` kind "depth", near = white) and the person matte for People/Background.
    case depth
    case relightMask
}

public struct DictionarySourceProvider: FrameSourceProvider {
    public var buffers: [ClipID: CVPixelBuffer]
    public var aux: [ClipID: [AuxRole: CVPixelBuffer]]
    public init(_ buffers: [ClipID: CVPixelBuffer], aux: [ClipID: [AuxRole: CVPixelBuffer]] = [:]) { self.buffers = buffers; self.aux = aux }
    public func pixelBuffer(for clipID: ClipID) -> CVPixelBuffer? { buffers[clipID] }
    public func auxPixelBuffer(for clipID: ClipID, role: AuxRole) -> CVPixelBuffer? { aux[clipID]?[role] }
}

/// Renders a `FrameDescription` with Metal. THE compositor: preview (AVPlayer + MontageCompositor), live re-render,
/// export (AVAssetReader + MontageCompositor) and thumbnails all end up here, so output is identical everywhere.
///
/// Pipeline per frame (all intermediate textures rgba16Float, pooled):
/// 1. per layer: source → straight RGBA texture at displayed resolution (YUV/BGRA convert, crop, flip, rotation)
///    → effect stack (ping-pong passes, one Metal library per effect);
/// 2. placement onto the premultiplied accumulation texture (cleared to the background) with transform, opacity,
///    mask and blend mode (programmable blending via framebuffer fetch);
/// 3. transitions render both sides to canvas-size textures, then the transition shader, then premultiplied-over;
/// 4. adjustment layers process the accumulation so far and mix by opacity;
/// 5. output pass to the 8-bit target.
public final class FrameRenderer: @unchecked Sendable {
    public static let shared = FrameRenderer()

    let ctx = MetalContext.shared
    let overPremul: MTLRenderPipelineState
    public let text = TextRasterizer()
    public let images = ImageTextureCache()
    /// Plain text layers draw their glyphs straight onto the accumulation target (`directText`); tests turn it off to
    /// compare with the layer-texture path.
    var allowsDirectText = true
    /// Frame textures are reused within the frame once dead (`FrameScratch.recycle`); tests turn it off to compare.
    var allowsTextureRecycling = true
    /// Pool textures the last encoded frame used (tests / diagnostics).
    private(set) var lastFrameTextureCount = 0

    init() {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = ctx.library.makeFunction(name: "fullscreen_vs")
        d.fragmentFunction = ctx.library.makeFunction(name: "convert_rgba_fs")
        let ca = d.colorAttachments[0]!
        ca.pixelFormat = MetalContext.workingFormat
        ca.isBlendingEnabled = true
        ca.sourceRGBBlendFactor = .one; ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
        ca.sourceAlphaBlendFactor = .one; ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        overPremul = try! ctx.device.makeRenderPipelineState(descriptor: d)
    }

    /// Per-frame scratch state.
    final class FrameScratch: @unchecked Sendable {
        /// Pool textures acquired by this frame (returned to the pool when its command buffer completes).
        var textures: [MTLTexture] = []
        var retained: [Any] = []
        /// Frame textures whose last use is already encoded: later passes of the same frame reuse them instead of
        /// taking more from the pool (Metal's hazard tracking orders the new writes after the earlier reads). Keeps a
        /// frame's working set to a few full-size half-float textures however many layers / effect passes it has.
        private var spare: [Int: [MTLTexture]] = [:]
        private var owned = Set<ObjectIdentifier>()
        private var spareIDs = Set<ObjectIdentifier>()

        let recycles: Bool
        init(recycles: Bool = true) { self.recycles = recycles }

        private static func key(_ w: Int, _ h: Int) -> Int { w << 20 | h }

        func acquire(_ w: Int, _ h: Int, pool: TexturePool) -> MTLTexture {
            if var list = spare[Self.key(w, h)], let t = list.popLast() {
                spare[Self.key(w, h)] = list
                spareIDs.remove(ObjectIdentifier(t))
                return t
            }
            let t = pool.acquire(w, h)
            textures.append(t); owned.insert(ObjectIdentifier(t))
            return t
        }

        /// Marks a texture this frame acquired as dead for the rest of the frame (no-op for anything else).
        func recycle(_ t: MTLTexture?) {
            guard recycles, let t else { return }
            let id = ObjectIdentifier(t)
            guard owned.contains(id), spareIDs.insert(id).inserted else { return }
            spare[Self.key(t.width, t.height), default: []].append(t)
        }
    }

    private enum Placement {
        case layer(MTLTexture, PlaceUniforms)
        case premultipliedFullscreen(MTLTexture)
        /// Text glyphs drawn straight onto the accumulation target (no layer texture, no convert pass).
        case glyphs(TextRasterizer.GlyphDraw, TextGPU.PlaceUniforms)
    }

    /// Encodes the frame into `cmd`, writing `output` (bgra8Unorm, any size; canvas is scaled to fit exactly).
    public func encode(_ frame: FrameDescription, media: [MediaID: MediaAsset], sources: any FrameSourceProvider,
                       output: MTLTexture, commandBuffer cmd: MTLCommandBuffer) {
        let scratch = FrameScratch(recycles: allowsTextureRecycling)
        let outW = output.width, outH = output.height
        let canvas = frame.canvasSize
        let outScale = Double(outH) / max(canvas.height, 1)
        var frame = frame
        frame.background = ColorMath.color(frame.background, in: frame.colorSpace)

        let pool = ctx.pool
        func acquire(_ w: Int, _ h: Int) -> MTLTexture { scratch.acquire(w, h, pool: pool) }

        /// Composites `items` (bottom → top) onto a fresh premultiplied target cleared to `clearColor`.
        func compose(_ items: [RenderItem], clearTo clearColor: RGBA) -> MTLTexture {
            var acc = acquire(outW, outH)
            clear(acc, to: clearColor, cmd)
            var placements: [Placement] = []

            func flush() {
                guard !placements.isEmpty else { return }
                let rp = MTLRenderPassDescriptor()
                rp.colorAttachments[0].texture = acc
                rp.colorAttachments[0].loadAction = .load
                rp.colorAttachments[0].storeAction = .store
                guard let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { return }
                enc.label = "place"
                // every text layer's glyph instances above the inline limit share one buffer per pass
                let stride = MemoryLayout<GlyphInstance>.stride
                var glyphBytes = 0
                for case .glyphs(let g, _) in placements where g.instances.count * stride > 4096 { glyphBytes += g.instances.count * stride }
                let glyphBuffer = glyphBytes > 0 ? ctx.device.makeBuffer(length: glyphBytes, options: .storageModeShared) : nil
                var glyphOffset = 0
                for p in placements {
                    switch p {
                    case .glyphs(let g, let u):
                        let bytes = g.instances.count * stride
                        if bytes > 4096, let buf = glyphBuffer {
                            g.instances.withUnsafeBytes { (buf.contents() + glyphOffset).copyMemory(from: $0.baseAddress!, byteCount: bytes) }
                            TextGPU.place(g.instances, atlas: g.atlas, uniforms: u, buffer: buf, offset: glyphOffset, enc)
                            glyphOffset += bytes
                        } else if bytes <= 4096 {
                            TextGPU.place(g.instances, atlas: g.atlas, uniforms: u, buffer: nil, offset: 0, enc)
                        }
                        continue
                    case .layer(let tex, var u):
                        enc.setRenderPipelineState(ctx.place)
                        enc.setVertexBytes(&u, length: MemoryLayout<PlaceUniforms>.stride, index: 0)
                        enc.setFragmentBytes(&u, length: MemoryLayout<PlaceUniforms>.stride, index: 0)
                        enc.setFragmentTexture(tex, index: 0)
                    case .premultipliedFullscreen(let tex):
                        var cu = ConvertUniforms.identity
                        enc.setRenderPipelineState(overPremul)
                        enc.setFragmentBytes(&cu, length: MemoryLayout<ConvertUniforms>.stride, index: 0)
                        enc.setFragmentTexture(tex, index: 0)
                    }
                    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                }
                enc.endEncoding()
                for p in placements {
                    switch p {
                    case .layer(let t, _), .premultipliedFullscreen(let t): scratch.recycle(t)
                    case .glyphs: break
                    }
                }
                placements.removeAll()
            }

            for item in items {
                switch item {
                case .layer(let l):
                    if let direct = directText(l, canvas: canvas, outW: outW, outH: outH, outScale: outScale, space: frame.colorSpace) {
                        placements += direct
                    } else if let p = prepareLayer(l, canvas: canvas, outW: outW, outH: outH, outScale: outScale, media: media,
                                            sources: sources, cmd: cmd, scratch: scratch, acquire: acquire, space: frame.colorSpace) {
                        placements.append(.layer(p.0, p.1))
                    }
                case .transition(let a, let b, let typeID, let progress, let params):
                    guard let desc = Registries.transitions[typeID], let pipe = EffectPipelines.shared.transition(desc) else {
                        // Unknown transition: hard cut at the midpoint.
                        let l = progress < 0.5 ? a : b
                        if let p = prepareLayer(l, canvas: canvas, outW: outW, outH: outH, outScale: outScale, media: media,
                                                sources: sources, cmd: cmd, scratch: scratch, acquire: acquire, space: frame.colorSpace) {
                            placements.append(.layer(p.0, p.1))
                        }
                        continue
                    }
                    let ta = acquire(outW, outH), tb = acquire(outW, outH)
                    for (l, t) in [(a, ta), (b, tb)] {
                        clear(t, to: .clear, cmd)
                        if let p = prepareLayer(l, canvas: canvas, outW: outW, outH: outH, outScale: outScale, media: media,
                                                sources: sources, cmd: cmd, scratch: scratch, acquire: acquire, space: frame.colorSpace) {
                            placeSingle(p.0, p.1, onto: t, cmd)
                            scratch.recycle(p.0)
                        }
                    }
                    let out = acquire(outW, outH)
                    var fx = FXContextU(time: Float(b.localTime.seconds), size: SIMD2(Float(outW), Float(outH)), pass: 0,
                                        aspect: Float(outW) / Float(max(outH, 1)))
                    var params = desc.packParams(params)
                    var pr = Float(progress)
                    fullscreen(pipe, target: out, cmd, label: typeID) { enc in
                        enc.setFragmentTexture(ta, index: 0)
                        enc.setFragmentTexture(tb, index: 1)
                        enc.setFragmentBytes(&params, length: params.count * 4, index: 0)
                        enc.setFragmentBytes(&fx, length: MemoryLayout<FXContextU>.stride, index: 1)
                        enc.setFragmentBytes(&pr, length: 4, index: 2)
                    }
                    scratch.recycle(ta); scratch.recycle(tb)
                    placements.append(.premultipliedFullscreen(out))
                case .adjustment(_, let effects, let opacity, let local, let mask):
                    guard !effects.isEmpty, opacity > 0 else { continue }
                    flush()
                    let straight = acquire(outW, outH)
                    fullscreen(ctx.unpremultiply, target: straight, cmd, label: "unpremultiply") { $0.setFragmentTexture(acc, index: 0) }
                    let processed = applyEffects(effects, to: straight, time: local, cmd: cmd, acquire: acquire, recycle: scratch.recycle)
                    var premul = acquire(outW, outH)
                    fullscreen(ctx.premultiply, target: premul, cmd, label: "premultiply") { $0.setFragmentTexture(processed, index: 0) }
                    // Effect mask (FX-005 / MK-006): the layer's effects apply inside its mask only (canvas space).
                    if let mask {
                        let unmasked = premul
                        premul = maskedMix(pre: acc, post: unmasked, mask: mask, aspect: canvas.width / max(canvas.height, 1),
                                           cmd: cmd, acquire: acquire)
                        if premul !== unmasked { scratch.recycle(unmasked) }
                    }
                    let mixed = acquire(outW, outH)
                    var k = Float(min(max(opacity, 0), 1))
                    fullscreen(ctx.mix, target: mixed, cmd, label: "adjust-mix") { enc in
                        enc.setFragmentTexture(acc, index: 0)
                        enc.setFragmentTexture(premul, index: 1)
                        enc.setFragmentBytes(&k, length: 4, index: 0)
                    }
                    for t in [straight, processed, premul, acc] { scratch.recycle(t) }
                    acc = mixed
                case .nested(let container, let inner):
                    // compound clip: composite the nested items on transparent, then place the result as one layer
                    let composite = compose(inner, clearTo: .clear)
                    let straight = acquire(outW, outH)
                    fullscreen(ctx.unpremultiply, target: straight, cmd, label: "nested-unpremultiply") { $0.setFragmentTexture(composite, index: 0) }
                    if let p = prepareLayer(container, canvas: canvas, outW: outW, outH: outH, outScale: outScale, media: media,
                                            sources: sources, cmd: cmd, scratch: scratch, acquire: acquire, space: frame.colorSpace,
                                            nested: straight) {
                        placements.append(.layer(p.0, p.1))
                    }
                    scratch.recycle(composite); scratch.recycle(straight)
                }
            }
            flush()
            return acc
        }

        let acc = compose(frame.items, clearTo: frame.background)

        // w = 0 only for a fully transparent background (alpha export): the output pass then keeps alpha.
        var bg = SIMD4<Float>(Float(frame.background.r), Float(frame.background.g), Float(frame.background.b), frame.background.a <= 0 ? 0 : 1)
        let finalAcc = acc
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = output
        rp.colorAttachments[0].loadAction = .dontCare
        rp.colorAttachments[0].storeAction = .store
        if let enc = cmd.makeRenderCommandEncoder(descriptor: rp) {
            enc.label = "output"
            enc.setRenderPipelineState(output.pixelFormat == .rgba16Float ? ctx.outputHalf : ctx.outputBGRA)
            enc.setFragmentTexture(finalAcc, index: 0)
            enc.setFragmentBytes(&bg, length: 16, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.endEncoding()
        }
        lastFrameTextureCount = scratch.textures.count
        cmd.addCompletedHandler { _ in
            for t in scratch.textures { pool.release(t) }
            scratch.retained.removeAll()
        }
    }

    // MARK: Layers

    /// Layer-level animations (registry) applied: transform, opacity, reveal crop, blur passes.
    private func animated(_ l0: LayerDescription, canvas: Size2) -> LayerDescription {
        var l = l0
        if !l.animations.isEmpty {
            var st = AnimatedLayerState(transform: l.transform, opacity: l.opacity)
            for a in l.animations { Registries.animations[a.typeID]?.apply(a.progress, &st) }
            l.transform = st.transform; l.opacity = st.opacity
            if !st.reveal.isIdentity { l.crop = l.crop.revealing(st.reveal) }
            if st.blur > 1e-4 { l.effects += Self.animationBlur(st.blur, layer: l, canvas: canvas) }
        }
        return l
    }

    /// Fast path for plain text layers (captions): their glyph quads go straight onto the accumulation target with the
    /// layer's placement folded into the vertex shader — no per-layer texture, compose pass or convert pass, so N
    /// captions cost N instanced draws in the shared placement pass. nil = not eligible (effects, mask, blend mode,
    /// crop/flip, HDR working space…): use `prepareLayer`. Empty = eligible but nothing to draw.
    private func directText(_ l0: LayerDescription, canvas: Size2, outW: Int, outH: Int, outScale: Double,
                            space: ProjectColorSpace) -> [Placement]? {
        guard allowsDirectText, case .text(let content) = l0.source, space == .sdr709, l0.effects.isEmpty, l0.mask == nil, l0.matte == nil,
              l0.blendMode == .normal else { return nil }
        let l = animated(l0, canvas: canvas)
        guard l.effects.isEmpty, l.crop.isIdentity, !l.transform.flipH, !l.transform.flipV else { return nil }
        guard l.opacity > 0.001 else { return [] }
        let draw: TextRasterizer.GlyphDraw
        switch text.layerContent(content, canvas: canvas, outputScale: outScale, layerScale: l.transform.scale,
                                 animations: l.animations, localTime: l.localTime, duration: l.duration) {
        case .none: return []
        case .glyphs(let g): draw = g
        case .texture(let r):
            let full = SIMD4<Float>(0, 0, 1, 1)
            let w = Float(r.texture.width), h = Float(r.texture.height)
            draw = .init(instances: [GlyphInstance(p0: SIMD2(0, 0), p1: SIMD2(w, 0), p2: SIMD2(0, h), p3: SIMD2(w, h),
                                                   uvA: full, uvB: full, mixB: 0, opacity: 1)],
                         atlas: r.texture, width: r.texture.width, height: r.texture.height, canvasSize: r.canvasSize)
        }
        let geo = l.geometry(canvasSize: canvas, sourceSizeOverride: draw.canvasSize)
        guard abs(geo.halfSize.x) * 2 * outScale >= 0.5, abs(geo.halfSize.y) * 2 * outScale >= 0.5 else { return [] }
        let c = geo.corners.map { c -> SIMD2<Float> in
            SIMD2(Float(c.x * outScale / Double(outW) * 2 - 1), Float(1 - c.y * outScale / Double(outH) * 2))
        }
        let u = TextGPU.PlaceUniforms(c0: c[0], ex: c[1] - c[0], ey: c[2] - c[0], exy: c[3] - c[1] - c[2] + c[0],
                                      invSize: SIMD2(1 / Float(draw.width), 1 / Float(draw.height)),
                                      opacity: Float(min(max(l.opacity, 0), 1)))
        return [.glyphs(draw, u)]
    }

    /// Builds the layer's straight-RGBA texture (with effects) and its placement uniforms.
    private func prepareLayer(_ l0: LayerDescription, canvas: Size2, outW: Int, outH: Int, outScale: Double,
                              media: [MediaID: MediaAsset], sources: any FrameSourceProvider, cmd: MTLCommandBuffer,
                              scratch: FrameScratch, acquire: (Int, Int) -> MTLTexture,
                              space: ProjectColorSpace = .sdr709, nested: MTLTexture? = nil) -> (MTLTexture, PlaceUniforms)? {
        var l = animated(l0, canvas: canvas)
        guard l.opacity > 0.001 else { return nil }

        // Source size in canvas pixels for text/stickers comes from rasterization.
        var sourceSizeOverride: Size2?
        var rgbaSource: MTLTexture?
        var unpremultiply = false
        var rotation = 0
        var yuv: (MTLTexture, MTLTexture, Bool, Bool)?  // y, cbcr, fullRange, bt709
        // Source colour (transfer + primaries); stills, text and stickers are SDR Rec.709.
        var srcTF = TransferFunction.sdr, srcWide = false, matrix2020 = false

        switch l.source {
        case .media(let id, _):
            guard let pb = sources.pixelBuffer(for: l.clipID) else { return nil }
            rotation = media[id]?.sourceRotation ?? 0
            (srcTF, srcWide, matrix2020) = Self.colorInfo(pb, asset: media[id])
            let fmt = CVPixelBufferGetPixelFormatType(pb)
            switch fmt {
            case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
                guard let (y, yc) = ctx.texture(pb, plane: 0, format: .r8Unorm),
                      let (c, cc) = ctx.texture(pb, plane: 1, format: .rg8Unorm) else { return nil }
                scratch.retained += [yc, cc, pb]
                yuv = (y, c, fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, Self.isBT709(pb, asset: media[id]))
            case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
                guard let (y, yc) = ctx.texture(pb, plane: 0, format: .r16Unorm),
                      let (c, cc) = ctx.texture(pb, plane: 1, format: .rg16Unorm) else { return nil }
                scratch.retained += [yc, cc, pb]
                yuv = (y, c, fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, Self.isBT709(pb, asset: media[id]))
            case kCVPixelFormatType_32BGRA:
                guard let (t, tc) = ctx.texture(pb, plane: 0, format: .bgra8Unorm) else { return nil }
                scratch.retained += [tc, pb]
                rgbaSource = t
            default:
                EngineLog.error("unsupported pixel format \(fmt)")
                return nil
            }
        case .image(let id):
            guard let asset = media[id], let t = images.texture(for: asset) else { return nil }
            rgbaSource = t; unpremultiply = true
        case .text(let content):
            // text engine (W7): static image, or per-glyph / karaoke / template composition for this frame
            guard let r = text.layerTexture(content, canvas: canvas, outputScale: outScale, layerScale: l.transform.scale,
                                            animations: l.animations, localTime: l.localTime, duration: l.duration,
                                            commandBuffer: cmd, acquire: acquire) else { return nil }
            rgbaSource = r.texture; unpremultiply = true
            sourceSizeOverride = r.canvasSize
        case .sticker(let id):
            guard let r = text.sticker(id, canvasSide: l.sourceSize.height, outputScale: outScale, time: l.localTime.seconds,
                                      style: l.shapeStyle) else { return nil }
            rgbaSource = r.texture; unpremultiply = true
            sourceSizeOverride = r.canvasSize
        case .solid:
            // compound clip container: the nested composite is the source, already in the working colour space
            if let n = nested { rgbaSource = n; srcTF = space.transfer; srcWide = space.isWideGamut }
        }

        let geo = l.geometry(canvasSize: canvas, sourceSizeOverride: sourceSizeOverride)
        // Layer texture resolution: displayed size in output pixels, capped by source resolution.
        let dispW = abs(geo.halfSize.x) * 2 * outScale, dispH = abs(geo.halfSize.y) * 2 * outScale
        guard dispW >= 0.5, dispH >= 0.5 else { return nil }
        var srcW = dispW, srcH = dispH
        let cropW = 1 - l.crop.left - l.crop.right, cropH = 1 - l.crop.top - l.crop.bottom
        if let (y, _, _, _) = yuv {
            let (w, h) = rotation % 180 == 0 ? (Double(y.width), Double(y.height)) : (Double(y.height), Double(y.width))
            srcW = min(dispW, w * cropW); srcH = min(dispH, h * cropH)
        } else if let t = rgbaSource {
            let (w, h) = rotation % 180 == 0 ? (Double(t.width), Double(t.height)) : (Double(t.height), Double(t.width))
            srcW = min(dispW, w * cropW); srcH = min(dispH, h * cropH)
        } else if l.effects.isEmpty && l.mask?.shape.isRaster != true {
            srcW = min(dispW, 64); srcH = min(dispH, 64)   // flat colour: tiny texture, stretched
        } else {
            srcW = dispW; srcH = dispH                      // generated content (canvas styles): full resolution
        }
        let tw = Self.quantize(srcW), th = Self.quantize(srcH)

        var layerTex = acquire(tw, th)
        var cu = ConvertUniforms(uvXform: Self.uvTransform(crop: l.crop, flipH: l.transform.flipH, flipV: l.transform.flipV,
                                                            rotation: rotation, stabilize: stabilizationCorrection(l, media: media)),
                                 fullRange: 0, matrix709: 1, unpremultiply: unpremultiply ? 1 : 0)
        cu.inTF = Float(srcTF.code); cu.outTF = Float(space.transfer.code)
        cu.gamut = srcWide == space.isWideGamut ? 0 : (space.isWideGamut ? 1 : 2)
        cu.inWide = srcWide ? 1 : 0; cu.outWide = space.isWideGamut ? 1 : 0
        if let h = l.hdrConversion, srcTF != space.transfer { cu.toneMode = h.shaderMode; cu.peakNits = Float(h.peakNits) }
        if let (y, c, full, bt709) = yuv {
            cu.fullRange = full ? 1 : (y.pixelFormat == .r16Unorm ? 2 : 0); cu.matrix709 = matrix2020 ? 2 : (bt709 ? 1 : 0)
            fullscreen(ctx.convertYUV, target: layerTex, cmd, label: "convert-yuv") { enc in
                enc.setFragmentTexture(y, index: 0); enc.setFragmentTexture(c, index: 1)
                enc.setFragmentBytes(&cu, length: MemoryLayout<ConvertUniforms>.stride, index: 0)
            }
        } else if let t = rgbaSource {
            fullscreen(ctx.convertRGBA, target: layerTex, cmd, label: "convert-rgba") { enc in
                enc.setFragmentTexture(t, index: 0)
                enc.setFragmentBytes(&cu, length: MemoryLayout<ConvertUniforms>.stride, index: 0)
            }
            scratch.recycle(t)   // per-frame text composition target (no-op for media / cached textures)
        } else if case .solid(let color0) = l.source {
            let color = ColorMath.color(color0, in: space)
            var c4 = SIMD4<Float>(Float(color.r), Float(color.g), Float(color.b), Float(color.a))
            fullscreen(ctx.solid, target: layerTex, cmd, label: "solid") { $0.setFragmentBytes(&c4, length: 16, index: 0) }
        }

        // W6 per-layer features on the straight source (before the effect stack, like CapCut's cutout/speed tools).
        layerTex = applyLayerFeatures(l, to: layerTex, uv: cu, media: media, sources: sources, cmd: cmd,
                                      scratch: scratch, acquire: acquire)

        // FX-002: body effects on an un-cut layer render on its person matte and go back over the whole layer.
        if let m = l.matte, m.isBodyOnly, l.effects.contains(where: Self.isBodyEffect) {
            layerTex = applyBodyEffects(m, layer: l, to: layerTex, uv: cu, media: media, sources: sources, cmd: cmd,
                                        scratch: scratch, acquire: acquire)
            l.effects.removeAll(where: Self.isBodyEffect)
        }

        if !l.effects.isEmpty {
            let isAdjust: (ResolvedEffect) -> Bool = { Registries.effects[$0.typeID]?.category == .adjustment }
            if l.adjustMask != nil || l.skinProtect, l.effects.contains(where: isAdjust) {
                // Adjust ▸ Mask: the Adjust-tab grading applies inside the mask only; other effects follow on the result.
                // Skin tone protection (CL-010) holds the grading back on skin tones.
                let pre = layerTex
                var post = applyEffects(l.effects.filter(isAdjust), to: pre, time: l.localTime, cmd: cmd, acquire: acquire, recycle: scratch.recycle)
                if l.skinProtect {
                    let graded = post
                    post = skinProtect(pre: pre, post: graded, cmd: cmd, acquire: acquire)
                    if post !== graded && graded !== pre { scratch.recycle(graded) }
                }
                if let am = l.adjustMask {
                    layerTex = maskedMix(pre: pre, post: post, mask: am, aspect: abs(geo.halfSize.x) / max(abs(geo.halfSize.y), 1e-6),
                                         cmd: cmd, acquire: acquire)
                } else { layerTex = post }
                if layerTex !== pre { scratch.recycle(pre) }
                if layerTex !== post && post !== pre { scratch.recycle(post) }
                let rest = l.effects.filter { !isAdjust($0) }
                if !rest.isEmpty {
                    let before = layerTex
                    layerTex = applyEffects(rest, to: layerTex, time: l.localTime, cmd: cmd, acquire: acquire, recycle: scratch.recycle)
                    if layerTex !== before { scratch.recycle(before) }
                }
            } else {
                let before = layerTex
                layerTex = applyEffects(l.effects, to: layerTex, time: l.localTime, cmd: cmd, acquire: acquire, recycle: scratch.recycle)
                if layerTex !== before { scratch.recycle(before) }
            }
        }

        // Placement uniforms (canvas px → output px → NDC).
        let corners = geo.corners.map { c -> SIMD2<Float> in
            SIMD2(Float(c.x * outScale / Double(outW) * 2 - 1), Float(1 - c.y * outScale / Double(outH) * 2))
        }
        var u = PlaceUniforms(c0: corners[0], c1: corners[1], c2: corners[2], c3: corners[3],
                              opacity: Float(min(max(l.opacity, 0), 1)), blend: Int32(l.blendMode.shaderIndex),
                              maskShape: -1, maskInvert: 0, maskCenter: .zero, maskSize: .one, maskRotation: 0,
                              maskFeather: 0, maskRoundness: 0,
                              layerAspect: Float(abs(geo.halfSize.x) / max(abs(geo.halfSize.y), 1e-6)))
        if geo.hasTilt {
            let pc = geo.projectedCorners
            u.cornerW = SIMD4(Float(pc[0].w), Float(pc[1].w), Float(pc[2].w), Float(pc[3].w))
        }
        if let m = l.mask, !l.extraMasks.isEmpty {
            // Multiple masks (MK-005): union of every mask's coverage, then one alpha pass (placement sees no mask).
            let aspect = abs(geo.halfSize.x) / max(abs(geo.halfSize.y), 1e-6)
            if let cov = maskUnion([m] + l.extraMasks, width: layerTex.width, height: layerTex.height, aspect: aspect,
                                   cmd: cmd, acquire: acquire, recycle: scratch.recycle) {
                let out = acquire(layerTex.width, layerTex.height)
                let src = layerTex
                var inv: Float = 0
                fullscreen(FeaturePipelines.shared.alphaMask, target: out, cmd, label: "mask-union") { enc in
                    enc.setFragmentTexture(src, index: 0); enc.setFragmentTexture(cov, index: 1)
                    enc.setFragmentBytes(&inv, length: 4, index: 0)
                }
                scratch.recycle(src); scratch.recycle(cov)
                layerTex = out
            }
        } else if let m = l.mask {
            if m.shape.isRaster {
                // Text / Pen: multiply the layer alpha by the rasterized coverage; the placement shader sees no mask.
                if let mt = RasterMasks.shared.texture(m, width: layerTex.width, height: layerTex.height) {
                    let out = acquire(layerTex.width, layerTex.height)
                    let src = layerTex
                    var inv: Float = m.inverted ? 1 : 0
                    fullscreen(FeaturePipelines.shared.alphaMask, target: out, cmd, label: "mask-raster") { enc in
                        enc.setFragmentTexture(src, index: 0); enc.setFragmentTexture(mt, index: 1)
                        enc.setFragmentBytes(&inv, length: 4, index: 0)
                    }
                    scratch.recycle(src)
                    layerTex = out
                }
            } else {
                Self.setMask(m, &u)
            }
        }
        return (layerTex, u)
    }

    /// Fixed instance ids of the blur passes animations add (stable `FrameDescription` hashes).
    static let animationBlurIDs: [EffectInstanceID] = (1...6).map {
        EffectInstanceID(UUID(uuidString: String(format: "00000000-0000-0000-0000-0000000AB%03d", $0))!)
    }

    /// Animation blur (gaussian sigma in canvas heights, up to ≈ 0.03) as stacked `montage.effect.blur` passes
    /// (radius 1 ≈ sigma of 1 % of the layer texture height; variances add, ≤ 1.2 per pass to avoid tap gaps).
    static func animationBlur(_ amount: Double, layer l: LayerDescription, canvas: Size2) -> [ResolvedEffect] {
        let layerH = l.fitsCanvas ? min(canvas.height, canvas.width * l.sourceSize.height / max(l.sourceSize.width, 1))
            * abs(l.transform.scale.y)
            : (l.sourceSize.height > 0 ? l.sourceSize.height : canvas.height * 0.15) * abs(l.transform.scale.y)  // text: measured later
        var r = amount * canvas.height / max(0.01 * max(layerH, 1), 1e-6)
        var out: [ResolvedEffect] = []
        for id in animationBlurIDs where r > 0.01 {
            let k = min(r, 1.2)
            out.append(ResolvedEffect(instanceID: id, typeID: CanvasBackground.blurEffectID, params: ["radius": .scalar(k)]))
            r = (r * r - k * k).squareRoot()   // gaussian variances add
        }
        return out
    }

    /// Union coverage (red channel) of several masks in layer uv space: each mask's coverage (analytic shapes through
    /// the core `mask_mix` pass between black and white, text / pen rasterized) max-combined.
    func maskUnion(_ masks: [Mask], width: Int, height: Int, aspect: Double, cmd: MTLCommandBuffer,
                   acquire: (Int, Int) -> MTLTexture, recycle: (MTLTexture) -> Void) -> MTLTexture? {
        let fp = FinishPipelines.shared
        var acc: MTLTexture?
        for m in masks {
            var cov: MTLTexture
            var inv: Float = 0
            if m.shape.isRaster {
                guard let mt = RasterMasks.shared.texture(m, width: width, height: height) else { continue }
                cov = mt; inv = m.inverted ? 1 : 0
            } else {
                cov = acquire(width, height)
                var mu = PlaceUniforms(c0: .zero, c1: .zero, c2: .zero, c3: .zero, opacity: 1, blend: 0, maskShape: -1, maskInvert: 0,
                                       maskCenter: .zero, maskSize: .one, maskRotation: 0, maskFeather: 0, maskRoundness: 0,
                                       layerAspect: Float(aspect))
                Self.setMask(m, &mu)
                fullscreen(ctx.maskMix, target: cov, cmd, label: "mask-coverage") { enc in
                    enc.setFragmentTexture(fp.black, index: 0); enc.setFragmentTexture(fp.white, index: 1)
                    enc.setFragmentBytes(&mu, length: MemoryLayout<PlaceUniforms>.stride, index: 0)
                }
            }
            let out = acquire(width, height)
            let prev = acc ?? fp.black
            fullscreen(fp.maskUnion, target: out, cmd, label: "mask-union-step") { enc in
                enc.setFragmentTexture(prev, index: 0); enc.setFragmentTexture(cov, index: 1)
                enc.setFragmentBytes(&inv, length: 4, index: 0)
            }
            if !m.shape.isRaster { recycle(cov) }
            if let a = acc { recycle(a) }
            acc = out
        }
        return acc
    }

    /// Skin tone protection (CL-010): `post` (graded) pulled back to `pre` on skin-coloured pixels.
    func skinProtect(pre: MTLTexture, post: MTLTexture, cmd: MTLCommandBuffer, acquire: (Int, Int) -> MTLTexture) -> MTLTexture {
        let out = acquire(post.width, post.height)
        var k: Float = 0.9
        fullscreen(FinishPipelines.shared.skinProtect, target: out, cmd, label: "skin-protect") { enc in
            enc.setFragmentTexture(pre, index: 0); enc.setFragmentTexture(post, index: 1)
            enc.setFragmentBytes(&k, length: 4, index: 0)
        }
        return out
    }

    /// `pre` inside `mask`'s complement, `post` inside it (shape masks analytically, text / pen masks rasterized);
    /// `aspect` = width / height of the mask's space. Used by Adjust ▸ Mask and adjustment-layer effect masks.
    func maskedMix(pre: MTLTexture, post: MTLTexture, mask m: Mask, aspect: Double, cmd: MTLCommandBuffer,
                   acquire: (Int, Int) -> MTLTexture) -> MTLTexture {
        let out = acquire(pre.width, pre.height)
        if m.shape.isRaster {
            guard let mt = RasterMasks.shared.texture(m, width: pre.width, height: pre.height) else { return post }
            var inv: Float = m.inverted ? 1 : 0
            fullscreen(FeaturePipelines.shared.maskTexMix, target: out, cmd, label: "mask-mix-raster") { enc in
                enc.setFragmentTexture(pre, index: 0); enc.setFragmentTexture(post, index: 1); enc.setFragmentTexture(mt, index: 2)
                enc.setFragmentBytes(&inv, length: 4, index: 0)
            }
        } else {
            var mu = PlaceUniforms(c0: .zero, c1: .zero, c2: .zero, c3: .zero, opacity: 1, blend: 0, maskShape: -1, maskInvert: 0,
                                   maskCenter: .zero, maskSize: .one, maskRotation: 0, maskFeather: 0, maskRoundness: 0,
                                   layerAspect: Float(aspect))
            Self.setMask(m, &mu)
            fullscreen(ctx.maskMix, target: out, cmd, label: "mask-mix") { enc in
                enc.setFragmentTexture(pre, index: 0); enc.setFragmentTexture(post, index: 1)
                enc.setFragmentBytes(&mu, length: MemoryLayout<PlaceUniforms>.stride, index: 0)
            }
        }
        return out
    }

    /// Fills the shape-mask fields of `PlaceU` (shared by layer placement and Adjust ▸ Mask).
    static func setMask(_ m: Mask, _ u: inout PlaceUniforms) {
        u.maskShape = Int32(MaskShape.allCases.firstIndex(of: m.shape)!)
        u.maskInvert = m.inverted ? 1 : 0
        u.maskCenter = SIMD2(Float(m.center.x), Float(m.center.y))
        u.maskSize = SIMD2(Float(m.size.x), Float(m.size.y))
        u.maskRotation = Float(m.rotation * .pi / 180)
        u.maskFeather = Float(m.feather)
        u.maskRoundness = Float(m.roundness)
    }

    /// `recycle` (frame renderer) receives each intermediate pass texture once nothing later in the chain reads it;
    /// `input` itself is never recycled.
    func applyEffects(_ effects: [ResolvedEffect], to input: MTLTexture, time: Time, cmd: MTLCommandBuffer,
                      acquire: (Int, Int) -> MTLTexture, recycle: ((MTLTexture) -> Void)? = nil,
                      backdrop: MTLTexture? = nil) -> MTLTexture {
        let chainInput = input
        var cur = input
        for e in effects {
            guard let d = Registries.effects[e.typeID], let pipe = EffectPipelines.shared.effect(d) else { continue }
            // Extra inputs (3D LUTs…): skip the effect if a resource is missing (e.g. LUT file deleted).
            let input = cur
            let extra = d.inputs.map { i -> MTLTexture? in
                switch i {
                case .original: return input
                case .backdrop: return backdrop ?? chainInput
                default: return EffectInputs.texture(for: i)
                }
            }
            if extra.contains(where: { $0 == nil }) { continue }
            let keepsInput = d.inputs.contains(.original)
            var params = d.packParams(e.params)
            for pass in 0..<max(d.passes, 1) {
                let out = acquire(cur.width, cur.height)
                var fx = FXContextU(time: Float(time.seconds), size: SIMD2(Float(cur.width), Float(cur.height)),
                                    pass: Int32(pass), aspect: Float(cur.width) / Float(max(cur.height, 1)))
                let src = cur
                fullscreen(pipe, target: out, cmd, label: e.typeID) { enc in
                    enc.setFragmentTexture(src, index: 0)
                    for (i, t) in extra.enumerated() { enc.setFragmentTexture(t, index: 1 + i) }
                    enc.setFragmentBytes(&params, length: params.count * 4, index: 0)
                    enc.setFragmentBytes(&fx, length: MemoryLayout<FXContextU>.stride, index: 1)
                }
                if src !== chainInput && !(keepsInput && src === input) { recycle?(src) }
                cur = out
            }
            if keepsInput && input !== chainInput && input !== cur { recycle?(input) }
        }
        return cur
    }

    // MARK: Encoding helpers

    private func clear(_ t: MTLTexture, to c: RGBA, _ cmd: MTLCommandBuffer) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = t
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: c.r * c.a, green: c.g * c.a, blue: c.b * c.a, alpha: c.a)
        rp.colorAttachments[0].storeAction = .store
        cmd.makeRenderCommandEncoder(descriptor: rp)?.endEncoding()
    }

    private func placeSingle(_ tex: MTLTexture, _ u0: PlaceUniforms, onto target: MTLTexture, _ cmd: MTLCommandBuffer) {
        var u = u0
        u.blend = 0
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .load
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.setRenderPipelineState(ctx.place)
        enc.setVertexBytes(&u, length: MemoryLayout<PlaceUniforms>.stride, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<PlaceUniforms>.stride, index: 0)
        enc.setFragmentTexture(tex, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }

    func fullscreen(_ pipe: MTLRenderPipelineState, target: MTLTexture, _ cmd: MTLCommandBuffer, label: String,
                            _ setup: (MTLRenderCommandEncoder) -> Void) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .dontCare
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.label = label
        enc.setRenderPipelineState(pipe)
        setup(enc)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }

    static func quantize(_ v: Double) -> Int {
        let n = max(1, Int(v.rounded(.up)))
        return n <= 64 ? n : min(8192, (n + 15) / 16 * 16)
    }

    /// Transfer / primaries / matrix of a decoded frame. The asset's probed tags win: AVFoundation stamps source
    /// frames with the video composition's colour tags without converting them, and proxies are untagged but carry
    /// the original's code values. Buffer attachments are only used when there is no asset; untagged = SDR Rec.709.
    static func colorInfo(_ pb: CVPixelBuffer, asset: MediaAsset?) -> (TransferFunction, Bool, Bool) {
        if let asset {
            return (asset.transfer, asset.isWideGamut, asset.yCbCrMatrix == "ITU_R_2020")
        }
        var tf = TransferFunction.sdr, wide = false, m2020 = false
        if let t = CVBufferCopyAttachment(pb, kCVImageBufferTransferFunctionKey, nil) {
            if CFEqual(t, kCVImageBufferTransferFunction_ITU_R_2100_HLG) { tf = .hlg }
            else if CFEqual(t, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ) { tf = .pq }
            else { tf = .sdr }
        }
        if let p = CVBufferCopyAttachment(pb, kCVImageBufferColorPrimariesKey, nil) {
            wide = CFEqual(p, kCVImageBufferColorPrimaries_ITU_R_2020)
        }
        if let m = CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, nil) {
            m2020 = CFEqual(m, kCVImageBufferYCbCrMatrix_ITU_R_2020)
        }
        return (tf, wide, m2020)
    }

    /// YCbCr matrix of a source frame: the asset's probed tag wins, an untagged asset is Rec.709 (the video
    /// composition is untagged since C1, so the decoder's guess — BT.601 below 720p — reaches the frame; before, the
    /// composition stamped 709 on every source and our VideoToolbox-encoded synthetic / exported files are 709).
    static func isBT709(_ pb: CVPixelBuffer, asset: MediaAsset?) -> Bool {
        guard let asset else { return isBT709(pb) }
        return asset.yCbCrMatrix != "ITU_R_601_4"
    }

    static func isBT709(_ pb: CVPixelBuffer) -> Bool {
        if let m = CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, nil) {
            return !CFEqual(m, kCVImageBufferYCbCrMatrix_ITU_R_601_4)
        }
        return CVPixelBufferGetHeight(pb) >= 720
    }

    /// Target-uv → source-uv: flip (display space) → crop → stabilization (shift + zoom, display space) →
    /// display→raw orientation.
    static func uvTransform(crop: CropRect, flipH: Bool, flipV: Bool, rotation: Int,
                            stabilize: StabilizeCorrection? = nil) -> simd_float3x2 {
        var m = Affine.identity
        if flipH { m = Affine(a: -1, b: 0, c: 0, d: 1, tx: 1, ty: 0).then(m) }
        if flipV { m = Affine(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 1).then(m) }
        var k = Affine(a: 1 - crop.left - crop.right, b: 0, c: 0, d: 1 - crop.top - crop.bottom, tx: crop.left, ty: crop.top)
        k = m.then(k)
        if let st = stabilize {
            // u' = R(−roll)·(u − ½)/zoom + ½ − d   (d = correction, normalized display units; the roll is applied in
            // square pixels: x scaled by the frame aspect)
            let z = 1 / max(st.zoom, 1), ar = max(st.aspect, 0.01)
            let ca = cos(-st.roll) * z, sa = sin(-st.roll) * z
            let (a, b, c, d) = (ca, sa * ar, -sa / ar, ca)
            k = k.then(Affine(a: a, b: b, c: c, d: d, tx: 0.5 - 0.5 * (a + c) - st.dx, ty: 0.5 - 0.5 * (b + d) - st.dy))
        }
        let r: Affine
        switch ((rotation % 360) + 360) % 360 {
        case 90: r = Affine(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1)     // raw = (y, 1-x)
        case 180: r = Affine(a: -1, b: 0, c: 0, d: -1, tx: 1, ty: 1)
        case 270: r = Affine(a: 0, b: 1, c: -1, d: 0, tx: 1, ty: 0)    // raw = (1-y, x)
        default: r = .identity
        }
        return k.then(r).matrix
    }
}

/// Per-frame stabilization correction handed to `uvTransform` (normalized shift, roll in radians, crop zoom).
struct StabilizeCorrection {
    var dx: Double, dy: Double, zoom: Double, roll: Double = 0, aspect: Double = 16.0 / 9
}

/// 2D affine map p' = (a·x + c·y + tx, b·x + d·y + ty).
struct Affine {
    var a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double
    static let identity = Affine(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)
    func apply(_ x: Double, _ y: Double) -> (Double, Double) { (a * x + c * y + tx, b * x + d * y + ty) }
    /// self first, then `o`.
    func then(_ o: Affine) -> Affine {
        Affine(a: o.a * a + o.c * b, b: o.b * a + o.d * b, c: o.a * c + o.c * d, d: o.b * c + o.d * d,
               tx: o.a * tx + o.c * ty + o.tx, ty: o.b * tx + o.d * ty + o.ty)
    }
    var matrix: simd_float3x2 {
        simd_float3x2(SIMD2(Float(a), Float(b)), SIMD2(Float(c), Float(d)), SIMD2(Float(tx), Float(ty)))
    }
}

/// Matches `ConvertU` in CoreShaders.
struct ConvertUniforms {
    var uvXform: simd_float3x2
    var fullRange: Float
    var matrix709: Float
    var unpremultiply: Float
    /// Source / output use BT.2020 primaries (luminance weights of the HLG OOTF).
    var inWide: Float = 0
    var inTF: Float = 0
    var outTF: Float = 0
    var gamut: Float = 0
    var outWide: Float = 0
    /// CL-014: 0 = default conversion, 1 = BT.2390 EETF (HDR → SDR) / highlight expansion (SDR → HDR).
    var toneMode: Float = 0
    /// CL-014: source mastering peak (HDR → SDR) or target highlight peak (SDR → HDR), nits.
    var peakNits: Float = 1000
    static let identity = ConvertUniforms(uvXform: Affine.identity.matrix, fullRange: 0, matrix709: 1, unpremultiply: 0)
}

/// Matches `PlaceU` in CoreShaders.
struct PlaceUniforms {
    var c0: SIMD2<Float>, c1: SIMD2<Float>, c2: SIMD2<Float>, c3: SIMD2<Float>
    var opacity: Float
    var blend: Int32
    var maskShape: Int32
    var maskInvert: Float
    var maskCenter: SIMD2<Float>
    var maskSize: SIMD2<Float>
    var maskRotation: Float
    var maskFeather: Float
    var maskRoundness: Float
    var layerAspect: Float
    /// Perspective divisor per corner (TL, TR, BL, BR) for tilted layers (CV-018).
    var cornerW: SIMD4<Float> = SIMD4(1, 1, 1, 1)
}
