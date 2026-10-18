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
        var textures: [MTLTexture] = []
        var retained: [Any] = []
    }

    private enum Placement {
        case layer(MTLTexture, PlaceUniforms)
        case premultipliedFullscreen(MTLTexture)
    }

    /// Encodes the frame into `cmd`, writing `output` (bgra8Unorm, any size; canvas is scaled to fit exactly).
    public func encode(_ frame: FrameDescription, media: [MediaID: MediaAsset], sources: any FrameSourceProvider,
                       output: MTLTexture, commandBuffer cmd: MTLCommandBuffer) {
        let scratch = FrameScratch()
        let outW = output.width, outH = output.height
        let canvas = frame.canvasSize
        let outScale = Double(outH) / max(canvas.height, 1)
        var frame = frame
        frame.background = ColorMath.color(frame.background, in: frame.colorSpace)

        func acquire(_ w: Int, _ h: Int) -> MTLTexture {
            let t = ctx.pool.acquire(w, h); scratch.textures.append(t); return t
        }

        var acc = acquire(outW, outH)
        clear(acc, to: frame.background, cmd)
        var placements: [Placement] = []

        func flush() {
            guard !placements.isEmpty else { return }
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = acc
            rp.colorAttachments[0].loadAction = .load
            rp.colorAttachments[0].storeAction = .store
            guard let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { return }
            enc.label = "place"
            for p in placements {
                switch p {
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
            placements.removeAll()
        }

        for item in frame.items {
            switch item {
            case .layer(let l):
                if let p = prepareLayer(l, canvas: canvas, outW: outW, outH: outH, outScale: outScale, media: media,
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
                placements.append(.premultipliedFullscreen(out))
            case .adjustment(_, let effects, let opacity, let local):
                guard !effects.isEmpty, opacity > 0 else { continue }
                flush()
                let straight = acquire(outW, outH)
                fullscreen(ctx.unpremultiply, target: straight, cmd, label: "unpremultiply") { $0.setFragmentTexture(acc, index: 0) }
                let processed = applyEffects(effects, to: straight, time: local, cmd: cmd, acquire: acquire)
                let premul = acquire(outW, outH)
                fullscreen(ctx.premultiply, target: premul, cmd, label: "premultiply") { $0.setFragmentTexture(processed, index: 0) }
                let mixed = acquire(outW, outH)
                var k = Float(min(max(opacity, 0), 1))
                fullscreen(ctx.mix, target: mixed, cmd, label: "adjust-mix") { enc in
                    enc.setFragmentTexture(acc, index: 0)
                    enc.setFragmentTexture(premul, index: 1)
                    enc.setFragmentBytes(&k, length: 4, index: 0)
                }
                acc = mixed
            }
        }
        flush()

        var bg = SIMD4<Float>(Float(frame.background.r), Float(frame.background.g), Float(frame.background.b), 1)
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
        let pool = ctx.pool
        cmd.addCompletedHandler { _ in
            for t in scratch.textures { pool.release(t) }
            scratch.retained.removeAll()
        }
    }

    // MARK: Layers

    /// Builds the layer's straight-RGBA texture (with effects) and its placement uniforms.
    private func prepareLayer(_ l0: LayerDescription, canvas: Size2, outW: Int, outH: Int, outScale: Double,
                              media: [MediaID: MediaAsset], sources: any FrameSourceProvider, cmd: MTLCommandBuffer,
                              scratch: FrameScratch, acquire: (Int, Int) -> MTLTexture,
                              space: ProjectColorSpace = .sdr709) -> (MTLTexture, PlaceUniforms)? {
        var l = l0
        // animations (registry) → transform/opacity
        if !l.animations.isEmpty {
            var st = AnimatedLayerState(transform: l.transform, opacity: l.opacity)
            for a in l.animations { Registries.animations[a.typeID]?.apply(a.progress, &st) }
            l.transform = st.transform; l.opacity = st.opacity
        }
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
                yuv = (y, c, fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, Self.isBT709(pb))
            case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
                guard let (y, yc) = ctx.texture(pb, plane: 0, format: .r16Unorm),
                      let (c, cc) = ctx.texture(pb, plane: 1, format: .rg16Unorm) else { return nil }
                scratch.retained += [yc, cc, pb]
                yuv = (y, c, fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, Self.isBT709(pb))
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
            guard let r = text.texture(for: content, canvasHeight: canvas.height, outputScale: outScale) else { return nil }
            rgbaSource = r.texture; unpremultiply = true
            sourceSizeOverride = r.canvasSize
        case .sticker(let id):
            guard let r = text.sticker(id, canvasSide: l.sourceSize.height, outputScale: outScale) else { return nil }
            rgbaSource = r.texture; unpremultiply = true
            sourceSizeOverride = r.canvasSize
        case .solid:
            break
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
        } else {
            srcW = min(dispW, 64); srcH = min(dispH, 64)
        }
        let tw = Self.quantize(srcW), th = Self.quantize(srcH)

        var layerTex = acquire(tw, th)
        var cu = ConvertUniforms(uvXform: Self.uvTransform(crop: l.crop, flipH: l.transform.flipH, flipV: l.transform.flipV,
                                                            rotation: rotation, stabilize: stabilizationCorrection(l, media: media)),
                                 fullRange: 0, matrix709: 1, unpremultiply: unpremultiply ? 1 : 0, pad: 0)
        cu.inTF = Float(srcTF.code); cu.outTF = Float(space.transfer.code)
        cu.gamut = srcWide == space.isWideGamut ? 0 : (space.isWideGamut ? 1 : 2)
        if let (y, c, full, bt709) = yuv {
            cu.fullRange = full ? 1 : 0; cu.matrix709 = matrix2020 ? 2 : (bt709 ? 1 : 0)
            fullscreen(ctx.convertYUV, target: layerTex, cmd, label: "convert-yuv") { enc in
                enc.setFragmentTexture(y, index: 0); enc.setFragmentTexture(c, index: 1)
                enc.setFragmentBytes(&cu, length: MemoryLayout<ConvertUniforms>.stride, index: 0)
            }
        } else if let t = rgbaSource {
            fullscreen(ctx.convertRGBA, target: layerTex, cmd, label: "convert-rgba") { enc in
                enc.setFragmentTexture(t, index: 0)
                enc.setFragmentBytes(&cu, length: MemoryLayout<ConvertUniforms>.stride, index: 0)
            }
        } else if case .solid(let color0) = l.source {
            let color = ColorMath.color(color0, in: space)
            var c4 = SIMD4<Float>(Float(color.r), Float(color.g), Float(color.b), Float(color.a))
            fullscreen(ctx.solid, target: layerTex, cmd, label: "solid") { $0.setFragmentBytes(&c4, length: 16, index: 0) }
        }

        // W6 per-layer features on the straight source (before the effect stack, like CapCut's cutout/speed tools).
        layerTex = applyLayerFeatures(l, to: layerTex, uv: cu, media: media, sources: sources, cmd: cmd,
                                      scratch: scratch, acquire: acquire)

        if !l.effects.isEmpty {
            layerTex = applyEffects(l.effects, to: layerTex, time: l.localTime, cmd: cmd, acquire: acquire)
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
        if let m = l.mask {
            u.maskShape = Int32(MaskShape.allCases.firstIndex(of: m.shape)!)
            u.maskInvert = m.inverted ? 1 : 0
            u.maskCenter = SIMD2(Float(m.center.x), Float(m.center.y))
            u.maskSize = SIMD2(Float(m.size.x), Float(m.size.y))
            u.maskRotation = Float(m.rotation * .pi / 180)
            u.maskFeather = Float(m.feather)
            u.maskRoundness = Float(m.roundness)
        }
        return (layerTex, u)
    }

    func applyEffects(_ effects: [ResolvedEffect], to input: MTLTexture, time: Time, cmd: MTLCommandBuffer,
                              acquire: (Int, Int) -> MTLTexture) -> MTLTexture {
        var cur = input
        for e in effects {
            guard let d = Registries.effects[e.typeID], let pipe = EffectPipelines.shared.effect(d) else { continue }
            // Extra inputs (3D LUTs…): skip the effect if a resource is missing (e.g. LUT file deleted).
            let extra = d.inputs.map { EffectInputs.texture(for: $0) }
            if extra.contains(where: { $0 == nil }) { continue }
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
                cur = out
            }
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

    static func isBT709(_ pb: CVPixelBuffer) -> Bool {
        if let m = CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, nil) {
            return !CFEqual(m, kCVImageBufferYCbCrMatrix_ITU_R_601_4)
        }
        return CVPixelBufferGetHeight(pb) >= 720
    }

    /// Target-uv → source-uv: flip (display space) → crop → stabilization (shift + zoom, display space) →
    /// display→raw orientation.
    static func uvTransform(crop: CropRect, flipH: Bool, flipV: Bool, rotation: Int,
                            stabilize: (dx: Double, dy: Double, zoom: Double)? = nil) -> simd_float3x2 {
        var m = Affine.identity
        if flipH { m = Affine(a: -1, b: 0, c: 0, d: 1, tx: 1, ty: 0).then(m) }
        if flipV { m = Affine(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 1).then(m) }
        var k = Affine(a: 1 - crop.left - crop.right, b: 0, c: 0, d: 1 - crop.top - crop.bottom, tx: crop.left, ty: crop.top)
        k = m.then(k)
        if let st = stabilize {
            // u' = (u − ½)/zoom + ½ − d   (d = correction, normalized display units)
            let z = 1 / max(st.zoom, 1)
            k = k.then(Affine(a: z, b: 0, c: 0, d: z, tx: 0.5 - 0.5 * z - st.dx, ty: 0.5 - 0.5 * z - st.dy))
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
    var pad: Float
    var inTF: Float = 0
    var outTF: Float = 0
    var gamut: Float = 0
    var pad2: Float = 0
    static let identity = ConvertUniforms(uvXform: Affine.identity.matrix, fullRange: 0, matrix709: 1, unpremultiply: 0, pad: 0)
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
}
