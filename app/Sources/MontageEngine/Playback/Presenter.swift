@preconcurrency import Metal
import QuartzCore
import CoreVideo
import MontageCore

/// Draws a composed BGRA frame into a CAMetalLayer drawable, aspect-fitted with a letterbox colour.
public enum Presenter {
    struct PresentU { var scale: SIMD2<Float>; var offset: SIMD2<Float>; var letterbox: SIMD4<Float> }

    /// Encodes the present pass. `contentAspect` = canvas aspect (width / height).
    /// `contentRect`: where the frame goes, in target pixels (origin top-left; may extend past the target when the
    /// player is zoomed in). nil = aspect-fit to the whole target.
    public static func encode(_ texture: MTLTexture, to target: MTLTexture, contentAspect: Double, letterbox: RGBA,
                              contentRect: CGRect? = nil, commandBuffer cmd: MTLCommandBuffer) {
        let ctx = MetalContext.shared
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: letterbox.r, green: letterbox.g, blue: letterbox.b, alpha: 1)
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { return }
        let tw = Double(target.width), th = Double(max(target.height, 1))
        let ta = tw / th
        var u = PresentU(scale: ta > contentAspect ? SIMD2(Float(contentAspect / ta), 1) : SIMD2(1, Float(ta / contentAspect)),
                         offset: .zero, letterbox: SIMD4(Float(letterbox.r), Float(letterbox.g), Float(letterbox.b), 1))
        if let r = contentRect {
            u.scale = SIMD2(Float(r.width / tw), Float(r.height / th))
            u.offset = SIMD2(Float(r.midX / tw * 2 - 1), Float(1 - r.midY / th * 2))
        }
        enc.setRenderPipelineState(ctx.present)
        enc.setVertexBytes(&u, length: MemoryLayout<PresentU>.stride, index: 0)
        enc.setFragmentTexture(texture, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }
}
