import AVFoundation
import Metal
import CoreVideo

/// One layer of the composition (subset of the future per-clip render state:
/// transform, opacity and one colour adjustment).
public struct LayerSpec: Sendable {
    public var trackID: CMPersistentTrackID
    public var center: SIMD2<Float>   // normalized output coords, (0,0) = top-left
    public var scale: Float           // fraction of output size (aspect preserved for 16:9 sources)
    public var opacity: Float
    public var saturation: Float
    public var brightness: Float
    public init(trackID: CMPersistentTrackID, center: SIMD2<Float>, scale: Float, opacity: Float, saturation: Float, brightness: Float) {
        self.trackID = trackID; self.center = center; self.scale = scale
        self.opacity = opacity; self.saturation = saturation; self.brightness = brightness
    }
}

/// Instruction carrying the layer stack for a time range. In the real app each instruction would carry
/// a reference to an immutable render-graph snapshot evaluated (with keyframes) per frame time.
public final class MontageInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    public let timeRange: CMTimeRange
    public let enablePostProcessing = false
    public let containsTweening = true
    public let requiredSourceTrackIDs: [NSValue]?
    public let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    public let layers: [LayerSpec]

    public init(timeRange: CMTimeRange, layers: [LayerSpec]) {
        self.timeRange = timeRange
        self.layers = layers
        self.requiredSourceTrackIDs = layers.map { NSNumber(value: $0.trackID) }
    }
}

private struct LayerUniforms {
    var center: SIMD2<Float>
    var halfSize: SIMD2<Float>
    var opacity: Float
    var saturation: Float
    var brightness: Float
    var fullRange: Float
}

/// Custom AVVideoCompositing backed by Metal. Used by AVPlayer (preview), AVAssetReader (export) and
/// thumbnail generation alike, so preview and export share one renderer. Source frames arrive as
/// IOSurface-backed 4:2:0 YUV straight from VideoToolbox and are sampled without any copy/conversion.
public final class MetalCompositor: NSObject, AVVideoCompositing {
    private let ctx = MetalContext.shared
    private let renderQueue = DispatchQueue(label: "montage.compositor")
    private let inflight = DispatchSemaphore(value: 3)

    /// Rolling GPU+CPU time per composed frame (ms), for diagnostics.
    public static let stats = CompositorStats()

    public var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                                      kCVPixelFormatType_420YpCbCr8BiPlanarFullRange],
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }

    public var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }

    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        renderQueue.async { [self] in
            autoreleasepool { render(request) }
        }
    }

    public func cancelAllPendingVideoCompositionRequests() {
        renderQueue.sync {}  // drain; queued requests finish normally
    }

    private func render(_ request: AVAsynchronousVideoCompositionRequest) {
        let t0 = CACurrentMediaTime()
        guard let instr = request.videoCompositionInstruction as? MontageInstruction,
              let out = request.renderContext.newPixelBuffer(),
              let (outTex, outCV) = ctx.texture(out, plane: 0, format: .bgra8Unorm),
              let cmd = ctx.queue.makeCommandBuffer() else {
            request.finish(with: NSError(domain: "Montage", code: 1))
            return
        }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = outTex
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { request.finish(with: NSError(domain: "Montage", code: 2)); return }
        enc.setRenderPipelineState(ctx.layerPipeline)
        var held: [CVMetalTexture] = [outCV]
        var sources: [CVPixelBuffer] = []
        for layer in instr.layers {
            guard let src = request.sourceFrame(byTrackID: layer.trackID),
                  let (yT, yCV) = ctx.texture(src, plane: 0, format: .r8Unorm),
                  let (cT, cCV) = ctx.texture(src, plane: 1, format: .rg8Unorm) else { continue }
            held.append(yCV); held.append(cCV); sources.append(src)
            let full = CVPixelBufferGetPixelFormatType(src) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            var u = LayerUniforms(center: SIMD2(layer.center.x * 2 - 1, 1 - layer.center.y * 2),
                                  halfSize: SIMD2(layer.scale, layer.scale),
                                  opacity: layer.opacity, saturation: layer.saturation,
                                  brightness: layer.brightness, fullRange: full ? 1 : 0)
            enc.setVertexBytes(&u, length: MemoryLayout<LayerUniforms>.stride, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<LayerUniforms>.stride, index: 0)
            enc.setFragmentTexture(yT, index: 0)
            enc.setFragmentTexture(cT, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        enc.endEncoding()
        inflight.wait()
        cmd.addCompletedHandler { [inflight] _ in
            _ = held; _ = sources
            MetalCompositor.stats.add((CACurrentMediaTime() - t0) * 1000)
            request.finish(withComposedVideoFrame: out)
            inflight.signal()
        }
        cmd.commit()
    }
}

public final class CompositorStats: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Double] = []
    public func add(_ ms: Double) { lock.lock(); samples.append(ms); if samples.count > 4000 { samples.removeFirst(1000) }; lock.unlock() }
    public func reset() { lock.lock(); samples.removeAll(); lock.unlock() }
    public func snapshot() -> [Double] { lock.lock(); defer { lock.unlock() }; return samples }
}
