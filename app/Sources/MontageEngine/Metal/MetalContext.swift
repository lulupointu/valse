@preconcurrency import Metal
import CoreVideo
import Foundation

/// Process-wide Metal state shared by the compositor (preview, export, thumbnails) and the preview presenter.
/// Thread-safe: Metal device/queue/pipeline objects are immutable and documented as thread-safe.
public final class MetalContext: @unchecked Sendable {
    public static let shared = MetalContext()

    public let device: MTLDevice
    public let queue: MTLCommandQueue
    public let textureCache: CVMetalTextureCache
    public let pool: TexturePool
    /// Working format of layer and accumulation textures.
    public static let workingFormat: MTLPixelFormat = .rgba16Float

    let library: MTLLibrary
    let convertYUV: MTLRenderPipelineState
    let convertRGBA: MTLRenderPipelineState
    let solid: MTLRenderPipelineState
    let place: MTLRenderPipelineState
    let mix: MTLRenderPipelineState
    let unpremultiply: MTLRenderPipelineState
    let premultiply: MTLRenderPipelineState
    let outputBGRA: MTLRenderPipelineState
    public let present: MTLRenderPipelineState
    let fullscreenVS: MTLFunction

    private init() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("Metal is required")
        }
        self.device = device
        self.queue = queue
        queue.label = "montage.render"
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: CoreShaders.source, options: nil)
        } catch {
            fatalError("Core shaders failed to compile: \(error)")
        }
        self.library = library
        fullscreenVS = library.makeFunction(name: "fullscreen_vs")!
        func pipe(_ vs: String, _ fs: String, _ fmt: MTLPixelFormat, blend: Bool = false) -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vs)
            d.fragmentFunction = library.makeFunction(name: fs)
            d.colorAttachments[0].pixelFormat = fmt
            if blend {
                d.colorAttachments[0].isBlendingEnabled = true
                d.colorAttachments[0].sourceRGBBlendFactor = .one
                d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                d.colorAttachments[0].sourceAlphaBlendFactor = .one
                d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            do { return try device.makeRenderPipelineState(descriptor: d) } catch { fatalError("pipeline \(fs): \(error)") }
        }
        let w = MetalContext.workingFormat
        convertYUV = pipe("fullscreen_vs", "convert_yuv_fs", w)
        convertRGBA = pipe("fullscreen_vs", "convert_rgba_fs", w)
        solid = pipe("fullscreen_vs", "solid_fs", w)
        place = pipe("place_vs", "place_fs", w)
        mix = pipe("fullscreen_vs", "mix_fs", w)
        unpremultiply = pipe("fullscreen_vs", "unpremultiply_fs", w)
        premultiply = pipe("fullscreen_vs", "premultiply_fs", w)
        outputBGRA = pipe("fullscreen_vs", "output_fs", .bgra8Unorm)
        present = pipe("present_vs", "present_fs", .bgra8Unorm)
        var c: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &c)
        textureCache = c!
        pool = TexturePool(device: device)
    }

    /// Zero-copy wrap of an IOSurface-backed CVPixelBuffer plane. Keep the returned CVMetalTexture alive until the GPU
    /// finished with the texture.
    public func texture(_ pb: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> (MTLTexture, CVMetalTexture)? {
        let planar = CVPixelBufferIsPlanar(pb)
        let w = planar ? CVPixelBufferGetWidthOfPlane(pb, plane) : CVPixelBufferGetWidth(pb)
        let h = planar ? CVPixelBufferGetHeightOfPlane(pb, plane) : CVPixelBufferGetHeight(pb)
        var cvTex: CVMetalTexture?
        let r = CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pb, nil, format, w, h, plane, &cvTex)
        guard r == kCVReturnSuccess, let cvTex, let tex = CVMetalTextureGetTexture(cvTex) else { return nil }
        return (tex, cvTex)
    }

    /// Releases cached CVMetalTextures (call under memory pressure).
    public func flushCaches() {
        CVMetalTextureCacheFlush(textureCache, 0)
        pool.purge()
    }
}

/// Recycles intermediate textures by (width, height, format). Textures are handed back when the command buffer
/// that used them completes, so steady-state rendering allocates nothing.
public final class TexturePool: @unchecked Sendable {
    private struct Key: Hashable { let w: Int; let h: Int; let f: UInt }
    private let device: MTLDevice
    private let lock = NSLock()
    private var free: [Key: [MTLTexture]] = [:]
    /// Max idle textures kept per key.
    private let maxPerKey = 6

    init(device: MTLDevice) { self.device = device }

    public func acquire(_ w: Int, _ h: Int, _ format: MTLPixelFormat = MetalContext.workingFormat) -> MTLTexture {
        let key = Key(w: max(w, 1), h: max(h, 1), f: format.rawValue)
        if let t = lock.withLock({ free[key]?.popLast() }) { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: key.w, height: key.h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)!
    }

    public func release(_ t: MTLTexture) {
        let key = Key(w: t.width, h: t.height, f: t.pixelFormat.rawValue)
        lock.withLock {
            var list = free[key] ?? []
            if list.count < maxPerKey { list.append(t) }
            free[key] = list
        }
    }

    public func purge() { lock.withLock { free.removeAll() } }
}
