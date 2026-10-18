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
    private var _auxMap: [ClipID: [AuxRole: CMPersistentTrackID]] = [:]
    private var _cached: [(range: TimeRange, key: String, track: CMPersistentTrackID)] = []
    private var _validCached: [(range: TimeRange, track: CMPersistentTrackID)] = []
    private var _cacheSize: CGSize = .zero
    /// Frames served from the preview render cache (stats/tests).
    public private(set) var cacheHits = 0
    private var recent: [(time: Time, sources: [ClipID: CVPixelBuffer], aux: [ClipID: [AuxRole: CVPixelBuffer]])] = []
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
        // the media dictionary is rebuilt only when the media list changed (not on every property tick)
        let (oldMedia, oldDict) = lock.withLock { (_project.media, _media) }
        let same = oldMedia.count == project.media.count && (oldMedia.isEmpty
            || oldMedia.withUnsafeBufferPointer { a in project.media.withUnsafeBufferPointer { b in a.baseAddress == b.baseAddress } })
        let media = same ? oldDict : Dictionary(project.media.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let (cached, size) = lock.withLock { (_cached, _cacheSize) }
        let valid = Self.validate(cached, project: project, size: size)
        lock.withLock { _project = project; _media = media; _validCached = valid }
    }

    /// Pre-rendered segments of the current composition; only those whose content key still matches the live project
    /// are served (edits invalidate them without a rebuild).
    public func update(cachedSegments: [(range: TimeRange, key: String, track: CMPersistentTrackID)], renderSize: CGSize) {
        let project = lock.withLock { _project }
        let valid = Self.validate(cachedSegments, project: project, size: renderSize)
        lock.withLock { _cached = cachedSegments; _cacheSize = renderSize; _validCached = valid }
    }

    static func validate(_ c: [(range: TimeRange, key: String, track: CMPersistentTrackID)], project: Project, size: CGSize)
    -> [(range: TimeRange, track: CMPersistentTrackID)] {
        c.filter { RenderCache.key(project, range: $0.range, size: size) == $0.key }.map { ($0.range, $0.track) }
    }

    func cachedTrack(at t: Time) -> CMPersistentTrackID? {
        lock.withLock { _validCached.first { $0.range.contains(t) }?.track }
    }

    func noteCacheHit() { lock.withLock { cacheHits += 1 } }

    public func update(trackMap: [ClipID: CMPersistentTrackID]) { lock.withLock { _trackMap = trackMap } }
    public func update(auxMap: [ClipID: [AuxRole: CMPersistentTrackID]]) { lock.withLock { _auxMap = auxMap } }

    func snapshot() -> (Project, [MediaID: MediaAsset], [ClipID: CMPersistentTrackID]) {
        lock.withLock { (_project, _media, _trackMap) }
    }

    var auxMap: [ClipID: [AuxRole: CMPersistentTrackID]] { lock.withLock { _auxMap } }

    func remember(time: Time, sources: [ClipID: CVPixelBuffer], aux: [ClipID: [AuxRole: CVPixelBuffer]] = [:]) {
        lock.withLock {
            framesComposed += 1
            guard keepsRecentSources else { return }
            recent.append((time, sources, aux))
            if recent.count > 12 { recent.removeFirst(recent.count - 12) }
        }
    }

    /// Decoded sources of the composed frame closest to `time`.
    public func sources(near time: Time) -> [ClipID: CVPixelBuffer]? {
        lock.withLock { recent.min { abs(($0.time - time).ticks) < abs(($1.time - time).ticks) }?.sources }
    }

    /// Decoded sources incl. aux lanes (matte / blend frames) of the composed frame closest to `time`.
    public func sourceProvider(near time: Time) -> DictionarySourceProvider? {
        lock.withLock {
            recent.min { abs(($0.time - time).ticks) < abs(($1.time - time).ticks) }.map { DictionarySourceProvider($0.sources, aux: $0.aux) }
        }
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
        let clock0 = CompositorStats.threadClock()
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
        if let tid = instr.state.cachedTrack(at: t), let pb = request.sourceFrame(byTrackID: tid) {
            renderCached(pb, request: request, project: project, out: out, outTex: outTex, outCV: outCV, cmd: cmd, state: instr.state, clock0: clock0)
            return
        }
        let frame = FrameEvaluator.evaluate(project, at: t)
        var buffers: [ClipID: CVPixelBuffer] = [:]
        var aux: [ClipID: [AuxRole: CVPixelBuffer]] = [:]
        let auxMap = instr.state.auxMap
        for l in frame.mediaLayers {
            if let tid = trackMap[l.clipID], let pb = request.sourceFrame(byTrackID: tid) { buffers[l.clipID] = pb }
            for (role, tid) in auxMap[l.clipID] ?? [:] {
                if let pb = request.sourceFrame(byTrackID: tid) { aux[l.clipID, default: [:]][role] = pb }
            }
        }
        FrameRenderer.shared.encode(frame, media: media, sources: DictionarySourceProvider(buffers, aux: aux), output: outTex, commandBuffer: cmd)
        let cpuNs = CompositorStats.threadClock() &- clock0
        inflight.wait()
        let state = instr.state
        let box = UncheckedSendable((request, out, outCV, buffers, aux))
        cmd.addCompletedHandler { [inflight] cb in
            CompositorStats.shared.record(cpuNs: cpuNs, commandBuffer: cb)
            let (request, out, _, buffers, aux) = box.value
            state.remember(time: t, sources: buffers, aux: aux)
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

extension MontageCompositor {
    /// Cached segment frame: drawn as one full-canvas layer through the same renderer (scaling/format conversion only).
    fileprivate func renderCached(_ pb: CVPixelBuffer, request: AVAsynchronousVideoCompositionRequest, project: Project,
                                  out: CVPixelBuffer, outTex: MTLTexture, outCV: CVMetalTexture, cmd: MTLCommandBuffer, state: RenderState,
                                  clock0: UInt64) {
        let canvas = project.settings.canvasSize
        let fake = MediaAsset(name: "render-cache", kind: .video, url: URL(fileURLWithPath: "/dev/null"), duration: .zero,
                              pixelSize: canvas, frameRate: nil, hasVideo: true, hasAudio: false, contentHash: "render-cache")
        let clip = ClipID()
        let layer = LayerDescription(clipID: clip, trackID: TrackID(), source: .media(fake.id, sourceTime: .zero), sourceSize: canvas,
                                     transform: Transform(), opacity: 1, blendMode: .normal, crop: CropRect(), mask: nil,
                                     effects: [], animations: [], localTime: .zero)
        let frame = FrameDescription(time: Time(cmTime: request.compositionTime), canvasSize: canvas,
                                     background: project.settings.backgroundColor, items: [.layer(layer)])
        FrameRenderer.shared.encode(frame, media: [fake.id: fake], sources: DictionarySourceProvider([clip: pb]), output: outTex, commandBuffer: cmd)
        state.noteCacheHit()
        let cpuNs = CompositorStats.threadClock() &- clock0
        let box = UncheckedSendable((request, out, outCV, pb))
        cmd.addCompletedHandler { cb in
            CompositorStats.shared.record(cpuNs: cpuNs, commandBuffer: cb)
            let (request, out, _, _) = box.value
            if let err = cb.error { request.finish(with: err) } else { request.finish(withComposedVideoFrame: out) }
        }
        cmd.commit()
    }
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
