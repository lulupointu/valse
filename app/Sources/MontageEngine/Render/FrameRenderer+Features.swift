@preconcurrency import Metal
import CoreVideo
import Foundation
import simd
import MontageCore

/// Optical-flow / ML frame interpolation hook (MontageAI plugs RIFE or VTFrameRateConversion here).
/// Smooth slow-mo with `.opticalFlow` calls it; returning nil (or no provider) falls back to frame blending.
public protocol FrameInterpolating: Sendable {
    /// Encodes the frame at `t` ∈ (0,1) between `a` (t = 0) and `b` (t = 1) into `commandBuffer` and returns it
    /// (straight RGBA, same size as `a`). `makeTexture(w, h)` hands out pooled working-format textures.
    func interpolate(_ a: MTLTexture, _ b: MTLTexture, at t: Double, commandBuffer: MTLCommandBuffer,
                     makeTexture: (Int, Int) -> MTLTexture) -> MTLTexture?
}

public enum FrameInterpolation {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _provider: (any FrameInterpolating)?
    public static var provider: (any FrameInterpolating)? {
        get { lock.withLock { _provider } }
        set { lock.withLock { _provider = newValue } }
    }
}

extension FrameRenderer {
    /// Smooth slow-mo and motion blur (time-domain: they mix source frames), then the AI matte (alpha only).
    /// Chroma key is an ordinary effect (`BuiltinKeying`, first in the stack).
    func applyLayerFeatures(_ l: LayerDescription, to input: MTLTexture, uv cu: ConvertUniforms, media: [MediaID: MediaAsset],
                            sources: any FrameSourceProvider, cmd: MTLCommandBuffer, scratch: FrameScratch,
                            acquire: (Int, Int) -> MTLTexture) -> MTLTexture {
        var cur = input
        let fp = FeaturePipelines.shared

        func mixInto(_ a: MTLTexture, _ b: MTLTexture, _ k: Float) -> MTLTexture {
            let out = acquire(a.width, a.height)
            var kk = k
            fullscreen(fp.blendFrames, target: out, cmd, label: "blend-frames") { enc in
                enc.setFragmentTexture(a, index: 0); enc.setFragmentTexture(b, index: 1)
                enc.setFragmentBytes(&kk, length: 4, index: 0)
            }
            return out
        }

        if case .media = l.source {
            // Smooth slow-mo: blend (or interpolate) towards the next source frame.
            if let w = l.frameBlend, w > 0.002,
               let pb = sources.auxPixelBuffer(for: l.clipID, role: .nextFrame),
               let next = convertAux(pb, width: cur.width, height: cur.height, uv: cu, cmd: cmd, scratch: scratch, acquire: acquire) {
                if l.slowMoMethod == .opticalFlow, let p = FrameInterpolation.provider,
                   let out = p.interpolate(cur, next, at: w, commandBuffer: cmd, makeTexture: acquire) {
                    cur = out
                } else {
                    cur = mixInto(cur, next, Float(w))
                }
            }
            // Motion blur: running weighted average with the previous frames (frame accumulation).
            if let mb = l.motionBlur, mb.amount > 0 {
                let n = mb.clampedSamples
                var total: Float = 1
                for k in 1..<n {
                    guard let pb = sources.auxPixelBuffer(for: l.clipID, role: .previousFrame(k)),
                          let prev = convertAux(pb, width: cur.width, height: cur.height, uv: cu, cmd: cmd, scratch: scratch, acquire: acquire)
                    else { continue }
                    let w = Float(min(max(mb.amount, 0), 1)) * (1 - Float(k - 1) / Float(n))
                    guard w > 0 else { continue }
                    total += w
                    cur = mixInto(cur, prev, w / total)
                }
            }
        }

        // AI matte (video: aux lane Y plane; image: still texture). A body-effects-only matte (FX-002) leaves the layer
        // uncut: prepareLayer applies it to a copy that only feeds the body effects.
        if let m = l.matte, !m.isBodyOnly {
            cur = applyMatte(m, layer: l, to: cur, uv: cu, media: media, sources: sources, cmd: cmd, scratch: scratch, acquire: acquire)
        }
        // Relight (AI2): depth-normal shading, after the matte (alpha untouched)
        if let r = l.relight {
            cur = applyRelight(r, layer: l, to: cur, uv: cu, media: media, sources: sources, cmd: cmd, scratch: scratch, acquire: acquire)
        }
        return cur
    }

    /// Multiplies the layer alpha by its AI matte (+ matting blend). Returns `cur` when the matte is not ready.
    func applyMatte(_ m: ClipMatte, layer l: LayerDescription, to input: MTLTexture, uv cu: ConvertUniforms, media: [MediaID: MediaAsset],
                    sources: any FrameSourceProvider, cmd: MTLCommandBuffer, scratch: FrameScratch,
                    acquire: (Int, Int) -> MTLTexture) -> MTLTexture {
        var cur = input
        let fp = FeaturePipelines.shared
        var matteTex: MTLTexture?
        var isVideo: Float = 0, fullRange: Float = 1
        var xform = cu.uvXform
        switch l.source {
        case .media:
            if let pb = sources.auxPixelBuffer(for: l.clipID, role: .matte) {
                let fmt = CVPixelBufferGetPixelFormatType(pb)
                let planar = CVPixelBufferIsPlanar(pb)
                let yFormat: MTLPixelFormat
                switch fmt {
                case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: yFormat = .r16Unorm
                case kCVPixelFormatType_32BGRA: yFormat = .bgra8Unorm
                default: yFormat = .r8Unorm
                }
                if let (t, tc) = ctx.texture(pb, plane: planar ? 0 : 0, format: yFormat) {
                    scratch.retained += [tc, pb]
                    matteTex = t
                    isVideo = planar ? 1 : 0
                    fullRange = (fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange || !planar) ? 1 : 0
                }
            }
        case .image(let id):
            if let a = media[id] {
                matteTex = MatteStore.shared.stillTexture(media: a, kind: m.kind, device: ctx.device)
                xform = Self.uvTransform(crop: l.crop, flipH: l.transform.flipH, flipV: l.transform.flipV, rotation: 0,
                                         aspect: a.pixelSize.width / max(a.pixelSize.height, 1))
            }
        default: break
        }
        if let mt = matteTex {
            let out = acquire(cur.width, cur.height)
            var u = MatteUniforms(uvXform: xform, fullRange: fullRange, expand: Float(m.expand), feather: Float(m.feather),
                                  invert: m.inverted ? 1 : 0, isVideo: isVideo)
            let src = cur
            fullscreen(fp.matte, target: out, cmd, label: "matte") { enc in
                enc.setFragmentTexture(src, index: 0); enc.setFragmentTexture(mt, index: 1)
                enc.setFragmentBytes(&u, length: MemoryLayout<MatteUniforms>.stride, index: 0)
            }
            cur = out
            // Matting blend (CK-008): edge-aware matte smoothing + colour decontamination of the cut-out edge.
            if let b = m.edgeBlend, b > 0.001 {
                let refined = acquire(cur.width, cur.height)
                let matted = cur
                var mu = MattingUniforms(texel: SIMD2(1 / Float(cur.width), 1 / Float(cur.height)) * max(1, Float(cur.height) / 720),
                                         smooth: Float(min(b, 1)), decontaminate: Float(min(b, 1)))
                fullscreen(FinishPipelines.shared.mattingBlend, target: refined, cmd, label: "matting-blend") { enc in
                    enc.setFragmentTexture(matted, index: 0)
                    enc.setFragmentBytes(&mu, length: MemoryLayout<MattingUniforms>.stride, index: 0)
                }
                cur = refined
            }
        }
        return cur
    }

    /// Converts an aux-lane decoded frame exactly like the layer's own source (same size, same uv transform).
    func convertAux(_ pb: CVPixelBuffer, width: Int, height: Int, uv cu0: ConvertUniforms, cmd: MTLCommandBuffer,
                    scratch: FrameScratch, acquire: (Int, Int) -> MTLTexture) -> MTLTexture? {
        var cu = cu0
        let out = acquire(width, height)
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        switch fmt {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            let ten = fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange || fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            guard let (y, yc) = ctx.texture(pb, plane: 0, format: ten ? .r16Unorm : .r8Unorm),
                  let (c, cc) = ctx.texture(pb, plane: 1, format: ten ? .rg16Unorm : .rg8Unorm) else { return nil }
            scratch.retained += [yc, cc, pb]
            cu.fullRange = (fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange) ? 1 : (ten ? 2 : 0)
            // same source as the layer: keep its BT.2020 matrix (HDR footage), else Rec.709 (aux files are ours,
            // VideoToolbox-encoded 709; the untagged video composition leaves the decoder's BT.601 guess on small frames)
            cu.matrix709 = cu0.matrix709 > 1.5 ? 2 : 1
            cu.unpremultiply = 0
            fullscreen(ctx.convertYUV, target: out, cmd, label: "convert-aux") { enc in
                enc.setFragmentTexture(y, index: 0); enc.setFragmentTexture(c, index: 1)
                enc.setFragmentBytes(&cu, length: MemoryLayout<ConvertUniforms>.stride, index: 0)
            }
        case kCVPixelFormatType_32BGRA:
            guard let (t, tc) = ctx.texture(pb, plane: 0, format: .bgra8Unorm) else { return nil }
            scratch.retained += [tc, pb]
            cu.unpremultiply = 0
            fullscreen(ctx.convertRGBA, target: out, cmd, label: "convert-aux") { enc in
                enc.setFragmentTexture(t, index: 0)
                enc.setFragmentBytes(&cu, length: MemoryLayout<ConvertUniforms>.stride, index: 0)
            }
        default:
            return nil
        }
        return out
    }

    /// Stabilization correction for this frame (nil when off or not analysed yet).
    func stabilizationCorrection(_ l: LayerDescription, media: [MediaID: MediaAsset]) -> StabilizeCorrection? {
        guard let st = l.stabilization, case .media(let id, let t) = l.source, let a = media[id],
              let track = StabilizationStore.shared.track(media: a, level: st.level) else { return nil }
        let c = track.correction(at: t)
        return StabilizeCorrection(dx: c.dx, dy: c.dy, zoom: track.zoom, roll: track.rotation(at: t), aspect: track.aspect ?? 16.0 / 9)
    }
}
