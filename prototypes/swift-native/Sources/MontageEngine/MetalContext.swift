import Metal
import CoreVideo

/// Process-wide Metal state shared by the compositor (preview + export), the preview presenter and the timeline.
public final class MetalContext {
    public static let shared = MetalContext()

    public let device: MTLDevice
    public let queue: MTLCommandQueue
    public let library: MTLLibrary
    public let layerPipeline: MTLRenderPipelineState
    public let presentPipeline: MTLRenderPipelineState
    public let timelinePipeline: MTLRenderPipelineState
    public let textureCache: CVMetalTextureCache
    public let shaderCompileMs: Double

    private init() {
        let device = MTLCreateSystemDefaultDevice()!
        self.device = device
        queue = device.makeCommandQueue()!
        let t0 = CFAbsoluteTimeGetCurrent()
        let library = try! device.makeLibrary(source: montageShaderSource, options: nil)
        self.library = library
        shaderCompileMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        func pipeline(_ v: String, _ f: String) -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: v)
            d.fragmentFunction = library.makeFunction(name: f)
            let ca = d.colorAttachments[0]!
            ca.pixelFormat = .bgra8Unorm
            ca.isBlendingEnabled = true
            ca.sourceRGBBlendFactor = .sourceAlpha
            ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
            ca.sourceAlphaBlendFactor = .one
            ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try! device.makeRenderPipelineState(descriptor: d)
        }
        layerPipeline = pipeline("layer_vs", "layer_fs")
        presentPipeline = pipeline("present_vs", "present_fs")
        timelinePipeline = pipeline("tl_vs", "tl_fs")
        var c: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &c)
        textureCache = c!
    }

    /// Zero-copy wrap of an IOSurface-backed CVPixelBuffer plane as an MTLTexture.
    /// The returned CVMetalTexture must be kept alive until the GPU is done with the texture.
    public func texture(_ pb: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> (MTLTexture, CVMetalTexture)? {
        let planar = CVPixelBufferIsPlanar(pb)
        let w = planar ? CVPixelBufferGetWidthOfPlane(pb, plane) : CVPixelBufferGetWidth(pb)
        let h = planar ? CVPixelBufferGetHeightOfPlane(pb, plane) : CVPixelBufferGetHeight(pb)
        var cvTex: CVMetalTexture?
        let r = CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pb, nil, format, w, h, plane, &cvTex)
        guard r == kCVReturnSuccess, let cvTex, let tex = CVMetalTextureGetTexture(cvTex) else { return nil }
        return (tex, cvTex)
    }
}
