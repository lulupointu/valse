@preconcurrency import AVFoundation
@preconcurrency import Metal
import CoreVideo
import Foundation
import MontageCore

/// Live, thread-safe render state shared by the player and the compositor.
/// - `project`: latest project. Property edits (opacity, transform, effects…) update it WITHOUT rebuilding the
///   AVComposition, so the next composed frame — or an immediate re-render when paused — reflects them.
/// - `trackMap`: clip → composition track, from the last composition build.
/// - recent decoded sources, so a paused frame can be re-rendered instantly without decoding.
public final class RenderState: @unchecked Sendable {
    private let lock = NSLock()
    private var _project: Project
    private var _media: [MediaID: MediaAsset]
    private var _trackMap: [ClipID: CMPersistentTrackID]
    private var recent: [(time: Time, sources: [ClipID: CVPixelBuffer])] = []
    /// Output frames composed (stats).
    public private(set) var framesComposed = 0
    /// When false the compositor does not keep decoded frames (export).
    let keepsRecentSources: Bool

    public init(project: Project, trackMap: [ClipID: CMPersistentTrackID] = [:], keepsRecentSources: Bool = true) {
        _project = project
        _media = Dictionary(uniqueKeysWithValues: project.media.map { ($0.id, $0) })
        _trackMap = trackMap
        self.keepsRecentSources = keepsRecentSources
    }

    public var project: Project { lock.withLock { _project } }

    public func update(project: Project) {
        let media = Dictionary(uniqueKeysWithValues: project.media.map { ($0.id, $0) })
        lock.withLock { _project = project; _media = media }
    }

    public func update(trackMap: [ClipID: CMPersistentTrackID]) { lock.withLock { _trackMap = trackMap } }

    func snapshot() -> (Project, [MediaID: MediaAsset], [ClipID: CMPersistentTrackID]) {
        lock.withLock { (_project, _media, _trackMap) }
    }

    func remember(time: Time, sources: [ClipID: CVPixelBuffer]) {
        lock.withLock {
            framesComposed += 1
            guard keepsRecentSources else { return }
            recent.append((time, sources))
            if recent.count > 12 { recent.removeFirst(recent.count - 12) }
        }
    }

    /// Decoded sources of the composed frame closest to `time`.
    public func sources(near time: Time) -> [ClipID: CVPixelBuffer]? {
        lock.withLock { recent.min { abs(($0.time - time).ticks) < abs(($1.time - time).ticks) }?.sources }
    }

    public func clearRecent() { lock.withLock { recent.removeAll() } }
}

/// One instruction spanning the whole composition; it only carries the shared `RenderState`.
/// The frame content is evaluated per request from the project (FrameEvaluator), not baked into instructions.
public final class MontageInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    public let timeRange: CMTimeRange
    public let enablePostProcessing = false
    public let containsTweening = true
    public let requiredSourceTrackIDs: [NSValue]?
    public let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    public let state: RenderState

    public init(timeRange: CMTimeRange, trackIDs: [CMPersistentTrackID], state: RenderState) {
        self.timeRange = timeRange
        self.requiredSourceTrackIDs = trackIDs.isEmpty ? nil : trackIDs.map { NSNumber(value: $0) }
        self.state = state
    }
}

/// Custom AVVideoCompositing backed by `FrameRenderer`. Used by AVPlayer (preview), AVAssetReader (export) and
/// AVAssetImageGenerator (thumbnails / render tests). Source frames arrive IOSurface-backed from VideoToolbox and are
/// sampled zero-copy. HDR / wide-gamut sources are delivered untouched (`supportsHDRSourceFrames`): the renderer
/// converts them into the project colour space itself, so preview (proxies) and export (originals) match.
/// SDR projects render into 8-bit BGRA; HDR projects use `MontageHDRCompositor` (rgba16Float buffers).
public class MontageCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let renderQueue = DispatchQueue(label: "montage.compositor", qos: .userInteractive)
    private let inflight = DispatchSemaphore(value: 3)

    public var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                                      kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                                      kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                                                      kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
                                                      kCVPixelFormatType_32BGRA],
         kCVPixelBufferMetalCompatibilityKey as String: true,
         kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable]()]
    }

    public var supportsHDRSourceFrames: Bool { true }
    public var supportsWideColorSourceFrames: Bool { true }

    /// Output pixel format of composed frames.
    class var outputPixelFormat: OSType { kCVPixelFormatType_32BGRA }

    public var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: Self.outputPixelFormat,
         kCVPixelBufferMetalCompatibilityKey as String: true,
         kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable]()]
    }

    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        let req = UncheckedSendable(request)
        renderQueue.async { [self] in autoreleasepool { render(req.value) } }
    }

    public func cancelAllPendingVideoCompositionRequests() {
        renderQueue.sync {}
    }

    private func render(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instr = request.videoCompositionInstruction as? MontageInstruction,
              let out = request.renderContext.newPixelBuffer(),
              let (outTex, outCV) = MetalContext.shared.texture(
                  out, plane: 0, format: CVPixelBufferGetPixelFormatType(out) == kCVPixelFormatType_64RGBAHalf ? .rgba16Float : .bgra8Unorm),
              let cmd = MetalContext.shared.queue.makeCommandBuffer() else {
            request.finish(with: NSError(domain: "Montage", code: 1, userInfo: [NSLocalizedDescriptionKey: "compositor setup failed"]))
            return
        }
        let (project, media, trackMap) = instr.state.snapshot()
        let t = Time(cmTime: request.compositionTime)
        let frame = FrameEvaluator.evaluate(project, at: t)
        var buffers: [ClipID: CVPixelBuffer] = [:]
        for l in frame.mediaLayers {
            if let tid = trackMap[l.clipID], let pb = request.sourceFrame(byTrackID: tid) { buffers[l.clipID] = pb }
        }
        FrameRenderer.shared.encode(frame, media: media, sources: DictionarySourceProvider(buffers), output: outTex, commandBuffer: cmd)
        inflight.wait()
        let state = instr.state
        let box = UncheckedSendable((request, out, outCV, buffers))
        cmd.addCompletedHandler { [inflight] cb in
            let (request, out, _, buffers) = box.value
            state.remember(time: t, sources: buffers)
            if let err = cb.error { request.finish(with: err) } else { request.finish(withComposedVideoFrame: out) }
            inflight.signal()
        }
        cmd.commit()
    }
}

/// HDR projects (Rec.2020 HLG/PQ): composes into 16-bit half-float RGBA buffers so 10-bit export keeps precision.
public final class MontageHDRCompositor: MontageCompositor, @unchecked Sendable {
    override class var outputPixelFormat: OSType { kCVPixelFormatType_64RGBAHalf }
}

/// Wraps a non-Sendable value to cross a concurrency boundary when the caller guarantees exclusive use.
public struct UncheckedSendable<T>: @unchecked Sendable {
    public let value: T
    public init(_ value: T) { self.value = value }
}

extension Time {
    public init(cmTime t: CMTime) {
        if !t.isValid || t.isIndefinite { self = .zero; return }
        if t.timescale == Int32(Time.ticksPerSecond) { self.init(ticks: t.value); return }
        let v = Double(t.value) * Double(Time.ticksPerSecond) / Double(t.timescale)
        self.init(ticks: Int64(v.rounded()))
    }
    public var cmTime: CMTime { CMTime(value: ticks, timescale: CMTimeScale(Time.ticksPerSecond)) }
}

extension TimeRange {
    public var cmTimeRange: CMTimeRange { CMTimeRange(start: start.cmTime, duration: duration.cmTime) }
}
