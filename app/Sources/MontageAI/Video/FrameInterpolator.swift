@preconcurrency import Metal
import CoreVideo
import CoreMedia
@preconcurrency import VideoToolbox
import Foundation
import MontageCore
import MontageEngine

/// Optical-flow frame interpolation for smooth slow-mo (AI-018 / SP-005), plugged into the render team's
/// `FrameInterpolation.provider`. Uses VideoToolbox's ML frame-rate conversion (`VTFrameProcessor`, macOS 15.4+,
/// runs on the ANE/GPU) entirely on the GPU: the compositor's rgba16Float textures are blitted into IOSurface
/// 64RGBAHalf pixel buffers (the processor's native format), interpolated inside the same command buffer, and blitted
/// back. No CPU round trip, identical in preview and export. Falls back to frame blending (nil) when unsupported.
@available(macOS 15.4, *)
final class VTFrameInterpolator: FrameInterpolating, @unchecked Sendable {
    private struct Session {
        let processor: VTFrameProcessor
        let width: Int, height: Int
        let pool: CVPixelBufferPool
    }
    let lock = NSLock()
    private var sessions: [Session] = []
    private var cache: CVMetalTextureCache?

    static var isSupported: Bool { VTFrameRateConversionConfiguration.isSupported }

    func interpolate(_ a: MTLTexture, _ b: MTLTexture, at t: Double, commandBuffer cmd: MTLCommandBuffer,
                     makeTexture: (Int, Int) -> MTLTexture) -> MTLTexture? {
        guard a.pixelFormat == .rgba16Float, b.pixelFormat == .rgba16Float, a.width == b.width, a.height == b.height else { return nil }
        return lock.withLock { () -> MTLTexture? in
            guard let s = session(a.width, a.height, device: cmd.device),
                  let pa = buffer(s), let pb = buffer(s), let po = buffer(s),
                  let ta = texture(pa, cmd.device), let tb = texture(pb, cmd.device), let to = texture(po, cmd.device),
                  let blit = cmd.makeBlitCommandEncoder() else { return nil }
            blit.copy(from: a, to: ta); blit.copy(from: b, to: tb)
            blit.endEncoding()
            let fa = VTFrameProcessorFrame(buffer: pa, presentationTimeStamp: .zero)
            let fb = VTFrameProcessorFrame(buffer: pb, presentationTimeStamp: CMTime(value: 1, timescale: 30))
            let fo = VTFrameProcessorFrame(buffer: po, presentationTimeStamp: CMTime(value: Int64((t * 1000).rounded()), timescale: 30_000))
            guard let fa, let fb, let fo,
                  let params = VTFrameRateConversionParameters(sourceFrame: fa, nextFrame: fb, opticalFlow: nil,
                                                               interpolationPhase: [Float(min(max(t, 0.01), 0.99))],
                                                               submissionMode: .sequential, destinationFrames: [fo]) else { return nil }
            s.processor.process(with: cmd, parameters: params)
            let out = makeTexture(a.width, a.height)
            guard let blit2 = cmd.makeBlitCommandEncoder() else { return nil }
            blit2.copy(from: to, to: out)
            blit2.endEncoding()
            // keep the IOSurfaces alive until the GPU is done
            let keep = UncheckedSendable([pa, pb, po] as [CVPixelBuffer])
            cmd.addCompletedHandler { _ in _ = keep }
            return out
        }
    }

    private var warming: Set<String> = []

    /// Ready session for a size. Starting a VideoToolbox session takes ~0.4 s (≈12 s the very first time, while the OS
    /// compiles the model), so it never happens on the render thread: a missing session is created in the
    /// background and this frame falls back to frame blending.
    private func session(_ w: Int, _ h: Int, device: MTLDevice) -> Session? {
        if let i = sessions.firstIndex(where: { $0.width == w && $0.height == h }) { return sessions[i] }
        prewarm(w, h, device: device)
        return nil
    }

    /// Creates the session for a size in the background (no-op if ready or in progress). Caller holds no lock.
    func prewarm(_ w: Int, _ h: Int, device: MTLDevice) {
        let key = "\(w)x\(h)"
        guard !warming.contains(key), !sessions.contains(where: { $0.width == w && $0.height == h }) else { return }
        warming.insert(key)
        if cache == nil { CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let made = Self.makeSession(w, h)
            lock.withLock {
                warming.remove(key)
                guard let made else { return }
                sessions.append(made)
                if sessions.count > 2 { sessions.removeFirst().processor.endSession() }   // bounded memory (preview + export sizes)
            }
        }
    }

    /// Blocks until the session for a size exists (export / tests).
    func prepare(_ w: Int, _ h: Int, device: MTLDevice) {
        // the caller blocks anyway: build the session on this thread instead of waiting for a background queue that heavy
        // concurrent work can starve past the timeout (export / tests then silently fell back to frame blending)
        let key = "\(w)x\(h)"
        let start = lock.withLock { () -> Bool in
            if sessions.contains(where: { $0.width == w && $0.height == h }) || warming.contains(key) { return false }
            if cache == nil { CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) }
            warming.insert(key)
            return true
        }
        if start {
            let made = Self.makeSession(w, h)
            lock.withLock {
                warming.remove(key)
                if let made {
                    sessions.append(made)
                    if sessions.count > 2 { sessions.removeFirst().processor.endSession() }
                }
            }
            return
        }
        for _ in 0..<600 {
            if lock.withLock({ sessions.contains { $0.width == w && $0.height == h } || !warming.contains("\(w)x\(h)") }) { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private static func makeSession(_ w: Int, _ h: Int) -> Session? {
        guard let cfg = VTFrameRateConversionConfiguration(frameWidth: w, frameHeight: h, usePrecomputedFlow: false,
                                                           qualityPrioritization: .normal, revision: .revision1) else { return nil }
        let p = VTFrameProcessor()
        do { try p.startSession(configuration: cfg) } catch { EngineLog.info("VT frame interpolation unavailable: \(error)"); return nil }
        var pool: CVPixelBufferPool?
        let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf,
                                    kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
                                    kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                                    kCVPixelBufferMetalCompatibilityKey as String: true]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        guard let pool else { return nil }
        return Session(processor: p, width: w, height: h, pool: pool)
    }

    private func buffer(_ s: Session) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, s.pool, &pb)
        return pb
    }

    private func texture(_ pb: CVPixelBuffer, _ device: MTLDevice) -> MTLTexture? {
        guard let cache else { return nil }
        var t: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .rgba16Float, CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), 0, &t)
        return t.flatMap(CVMetalTextureGetTexture)
    }
}

/// Engine hooks installed by the app at startup (MontageUI calls `install()` once).
public enum AIEngineHooks {
    public static func install() {
        if #available(macOS 15.4, *), VTFrameInterpolator.isSupported, FrameInterpolation.provider == nil {
            FrameInterpolation.provider = VTFrameInterpolator()
        }
        if ExportHooks.superResolve == nil { ExportHooks.superResolve = ExportSuperResolution.run }   // EX-018
    }

    /// ML voice isolation in the audio engine's rendered stage (`AudioML`). The app installs it at launch; test
    /// processes don't (unless `MONTAGE_AUDIO_ML=1`) so the DSP tests keep exercising the DSP path.
    public static func installAudioML(force: Bool = false) {
        let isApp = Bundle.main.bundlePath.hasSuffix(".app") || ProcessInfo.processInfo.environment["MONTAGE_AUDIO_ML"] == "1"
        if AudioML.musicStems == nil {   // AU-009 (F3): singing voice via HTDemucs (fails with "model missing" until installed)
            AudioML.musicStems = { asset, progress in try await StemSeparator.separateVocals(asset, progress: progress) }
        }
        guard force || isApp, VoiceIsolator.isAvailable, AudioML.voiceStems == nil else { return }
        AudioML.voiceStems = { asset, progress in try await VoiceIsolator.separate(asset, progress: progress) }
        AudioML.usedByPlans = true
    }
    /// Starts the optical-flow session for a frame size ahead of time (store: when a clip turns optical flow on;
    /// `wait` blocks until ready, for export and tests).
    public static func prepareOpticalFlow(width: Int, height: Int, wait: Bool = false) {
        guard #available(macOS 15.4, *), let p = FrameInterpolation.provider as? VTFrameInterpolator,
              let device = MTLCreateSystemDefaultDevice() else { return }
        // layer textures are quantized to 16 px by the renderer
        let width = (width + 15) / 16 * 16, height = (height + 15) / 16 * 16
        if wait { p.prepare(width, height, device: device) } else { p.lock.withLock { p.prewarm(width, height, device: device) } }
    }

    /// Whether optical-flow slow-mo uses ML interpolation on this Mac (else frame blending).
    public static var hasOpticalFlow: Bool { FrameInterpolation.provider != nil }
}
