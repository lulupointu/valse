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
    /// Adjust ▸ Mask blend (original vs adjusted through a shape mask).
    let maskMix: MTLRenderPipelineState
    let unpremultiply: MTLRenderPipelineState
    let premultiply: MTLRenderPipelineState
    let outputBGRA: MTLRenderPipelineState
    /// HDR compositor output (rgba16Float pixel buffers).
    let outputHalf: MTLRenderPipelineState
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
        maskMix = pipe("fullscreen_vs", "mask_mix_fs", w)
        unpremultiply = pipe("fullscreen_vs", "unpremultiply_fs", w)
        premultiply = pipe("fullscreen_vs", "premultiply_fs", w)
        outputBGRA = pipe("fullscreen_vs", "output_fs", .bgra8Unorm)
        outputHalf = pipe("fullscreen_vs", "output_half_fs", .rgba16Float)
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
    /// Drops CVMetalTextures nothing references any more (memory pressure).
    public func flushCVTextures() { CVMetalTextureCacheFlush(textureCache, 0) }

    public func flushCaches() {
        CVMetalTextureCacheFlush(textureCache, 0)
        pool.purge()
    }
}

/// Recycles intermediate textures by (width, height, format). Textures are handed back when the command buffer
/// that used them completes, so steady-state rendering allocates nothing. Idle textures are capped by bytes
/// (`idleBudget`, from `MemoryBudget.texturePoolIdleBytes`), not by count per size: a frame with 50 same-sized text
/// layers reuses 50 textures, while rarely used sizes age out (least recently released first).
public final class TexturePool: @unchecked Sendable {
    private struct Key: Hashable { let w: Int; let h: Int; let f: UInt }
    private struct Idle { let texture: MTLTexture; let bytes: Int; let tick: UInt64 }
    private let device: MTLDevice
    private let lock = NSLock()
    /// Per key, in release order (oldest first).
    private var free: [Key: [Idle]] = [:]
    private var tick: UInt64 = 0
    private var _idleBytes = 0
    private var _allocations = 0
    private var _idleBudget: Int

    init(device: MTLDevice, idleBudget: Int = MemoryBudget.texturePoolIdleBytes) {
        self.device = device; _idleBudget = idleBudget
    }

    /// Max bytes of idle (pooled, unused) textures; lowering it trims immediately.
    public var idleBudget: Int {
        get { lock.withLock { _idleBudget } }
        set { lock.withLock { _idleBudget = max(0, newValue); trimLocked(to: _idleBudget) } }
    }
    public var idleBytes: Int { lock.withLock { _idleBytes } }
    /// Textures created so far (tests: steady-state rendering must not allocate).
    public var allocations: Int { lock.withLock { _allocations } }

    public func acquire(_ w: Int, _ h: Int, _ format: MTLPixelFormat = MetalContext.workingFormat) -> MTLTexture {
        let key = Key(w: max(w, 1), h: max(h, 1), f: format.rawValue)
        let reused: MTLTexture? = lock.withLock {
            guard let i = free[key]?.popLast() else { return nil }
            _idleBytes -= i.bytes
            return i.texture
        }
        if let t = reused { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: key.w, height: key.h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        lock.withLock { _allocations += 1 }
        return device.makeTexture(descriptor: d)!
    }

    public func release(_ t: MTLTexture) {
        let key = Key(w: t.width, h: t.height, f: t.pixelFormat.rawValue)
        let bytes = max(t.allocatedSize, t.width * t.height * 4)
        lock.withLock {
            guard bytes <= _idleBudget else { return }
            tick &+= 1
            free[key, default: []].append(Idle(texture: t, bytes: bytes, tick: tick))
            _idleBytes += bytes
            trimLocked(to: _idleBudget)
        }
    }

    /// Drops idle textures (oldest first) until at most `bytes` stay pooled.
    public func trim(to bytes: Int) { lock.withLock { trimLocked(to: bytes) } }

    private func trimLocked(to budget: Int) {
        while _idleBytes > budget {
            guard let (k, _) = free.min(by: { ($0.value.first?.tick ?? .max) < ($1.value.first?.tick ?? .max) }),
                  var list = free[k], !list.isEmpty else { _idleBytes = 0; free.removeAll(); return }
            _idleBytes -= list.removeFirst().bytes
            free[k] = list.isEmpty ? nil : list
        }
    }

    public func purge() { lock.withLock { free.removeAll(); _idleBytes = 0 } }
}
