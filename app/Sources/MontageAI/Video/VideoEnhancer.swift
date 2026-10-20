@preconcurrency import AVFoundation
@preconcurrency import VideoToolbox
import CoreVideo
import Foundation
import MontageCore
import MontageEngine

/// Renders a processed copy of a video (Reduce image noise / Remove flickers / Enhance quality, see
/// Core `VideoEnhancement`): one streaming pass reader → per-frame processing → HEVC writer (+ audio passthrough), so
/// memory stays at a few frames whatever the length. Output: `Caches/Montage/enhanced/<hash>-<key>.mov`, same
/// timestamps, orientation and audio as the original.
///
/// - Remove flickers: a first pass measures each frame's mean luma (64 px decode); `Deflicker.gains` maps it onto a
///   smoothed curve; the gain is applied to Y (around black) and Cb/Cr (around neutral), i.e. a multiplicative exposure fix.
/// - Reduce image noise: motion-adaptive recursive temporal filter on the 4:2:0 planes (static areas average over
///   frames, moving pixels pass through), strength per level. (VideoToolbox's VTTemporalNoiseFilter is used instead
///   when the Mac supports it.)
/// - Enhance quality: VideoToolbox low-latency ML super resolution ×2 over tiles (`TiledScaler`, twice above ×2) + GPU
///   resize, no model download; ~×0.9 real time for an iPhone 1080p HLG clip → 4K (the full ×4 scaler took ×50).
public enum VideoEnhancer {
    public static var directory: URL { MontagePaths.cacheDirectory.appendingPathComponent("enhanced", isDirectory: true) }

    public static func outputURL(_ a: MediaAsset, _ e: VideoEnhancement) -> URL {
        // "-c2": colour-tagged outputs (earlier HDR results were untagged → washed out; never reuse them)
        directory.appendingPathComponent("\(a.contentHash)-\(e.key)-c2.mov")
    }

    /// Whether super resolution applies to this media: tiled low-latency ×2 scaler (`TiledScaler`, sources up to
    /// 1920×1080, the fast path) or, where that scaler is missing, VideoToolbox's full ML scaler (×4, same limits).
    public static func canUpscale(_ a: MediaAsset) -> Bool {
        let (w, h) = rawSize(a)
        return tiledSupports(w, h) || fullScalerSupports(w, h)
    }

    static func tiledSupports(_ w: Int, _ h: Int) -> Bool {
        guard #available(macOS 26.0, *), VTLowLatencySuperResolutionScalerConfiguration.isSupported,
              !VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(frameWidth: 960, frameHeight: 540).isEmpty
        else { return false }
        return max(w, h) <= 1920 && min(w, h) <= 1080 && min(w, h) >= 96
    }

    static func fullScalerSupports(_ w: Int, _ h: Int) -> Bool {
        guard #available(macOS 26.0, *), VTSuperResolutionScalerConfiguration.isSupported,
              VTSuperResolutionScalerConfiguration.supportedScaleFactors.contains(4) else { return false }
        return max(w, h) <= 1920 && min(w, h) <= 1080 && w >= 64 && h >= 64
    }

    /// Output size of an upscale: HD = ×2, UHD = up to 3840 px on the long side (×4 max); even dimensions.
    public static func upscaledSize(_ target: UpscaleTarget, width w: Int, height h: Int) -> (Int, Int) {
        let k: Double = target == .hd ? 2 : min(4, max(2, 3840 / Double(max(w, h))))
        return (Int((Double(w) * k / 2).rounded()) * 2, Int((Double(h) * k / 2).rounded()) * 2)
    }

    static func rawSize(_ a: MediaAsset) -> (Int, Int) {
        let w = Int(a.pixelSize.width), h = Int(a.pixelSize.height)
        return a.sourceRotation % 180 == 0 ? (w, h) : (h, w)
    }

    @discardableResult
    public static func process(_ a: MediaAsset, _ e: VideoEnhancement, progress: (@Sendable (Double) -> Void)? = nil,
                               stats: (@Sendable (Stats) -> Void)? = nil) async throws -> URL {
        let out = outputURL(a, e)
        if FileManager.default.fileExists(atPath: out.path) { progress?(1); return out }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let av = AVURLAsset(url: a.url)
        guard let vt = try await av.loadTracks(withMediaType: .video).first else { throw AIToolError.noInput }
        let duration = try await av.load(.duration).seconds
        let fps = Double(try await vt.load(.nominalFrameRate))
        let transform = try await vt.load(.preferredTransform)
        let natural = try await vt.load(.naturalSize)
        let (w, h) = (Int(natural.width) / 2 * 2, Int(natural.height) / 2 * 2)
        let wantsAnalysis = e.deflicker != nil
        let split = wantsAnalysis ? 0.25 : 0.0
        // 1. flicker analysis
        var gains: [Double] = []
        if let mode = e.deflicker {
            let means = try await meanLuma(av, track: vt) { progress?($0 * split) }
            gains = Deflicker.gains(meanLuma: means, fps: max(fps, 1), mode: mode, level: e.deflickerLevel)
        }
        // 2. processing pass
        let upscale = e.upscale != nil && canUpscale(a)
        let (ow, oh) = upscale ? upscaledSize(e.upscale!, width: w, height: h) : (w, h)
        // tiled low-latency ×2 (twice for > ×2) + GPU resize; the full ×4 scaler only where the fast one is missing
        let useFull = upscale && !tiledSupports(w, h)
        let tmp = out.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let writer = try AVAssetWriter(outputURL: tmp, fileType: .mov)
        // keep the source's colour tags (iPhone HLG / Dolby Vision footage): untagged output was read back as BT.709
        // and the enhanced copy looked grey and washed out (AI QA, project 1018). HDR stays HEVC Main10.
        let color = try await Self.colorProperties(vt)
        var compression: [String: Any] = [AVVideoQualityKey: 0.8]
        let hdr = (color?[AVVideoTransferFunctionKey] as? String).map(Self.hdrTransfers.contains) ?? false
        if hdr {
            // constant-quality isn't accepted with Main10 here (kVTParameterErr): average bit rate instead
            compression = [AVVideoProfileLevelKey: "HEVC_Main10_AutoLevel", AVVideoAverageBitRateKey: max(4_000_000, ow * oh * 6)]
        }
        var videoSettings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: ow, AVVideoHeightKey: oh,
                                            AVVideoCompressionPropertiesKey: compression]
        if let color { videoSettings[AVVideoColorPropertiesKey] = color }
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vIn.transform = transform
        vIn.expectsMediaDataInRealTime = false
        // Main10 needs 10-bit input: HDR frames are widened (VTPixelTransferSession) right before encoding
        let outFormat = hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let widen = hdr ? try TenBitWidener(width: ow, height: oh, color: color ?? [:]) : nil
        defer { widen?.end() }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: outFormat,
            kCVPixelBufferWidthKey as String: ow, kCVPixelBufferHeightKey as String: oh,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()])
        writer.add(vIn)
        // audio passthrough
        let at = try await av.loadTracks(withMediaType: .audio).first
        var aIn: AVAssetWriterInput?
        if let at {
            let hint = try await at.load(.formatDescriptions).first
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
            i.expectsMediaDataInRealTime = false
            writer.add(i); aIn = i
        }
        let reader = try AVAssetReader(asset: av)
        let vOut = AVAssetReaderTrackOutput(track: vt, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()])
        vOut.alwaysCopiesSampleData = false
        reader.add(vOut)
        var aOut: AVAssetReaderTrackOutput?
        if let at { let o = AVAssetReaderTrackOutput(track: at, outputSettings: nil); reader.add(o); aOut = o }
        guard reader.startReading(), writer.startWriting() else { throw reader.error ?? writer.error ?? AIToolError.noInput }
        writer.startSession(atSourceTime: .zero)

        let audioTask: Task<Void, Error>? = (aIn != nil && aOut != nil) ? Task.detached { [aIn = UncheckedSendable(aIn!), aOut = UncheckedSendable(aOut!)] in
            while let sb = await OffPool.next(aOut.value) {
                while !aIn.value.isReadyForMoreMediaData { try Task.checkCancellation(); try await Task.sleep(nanoseconds: 2_000_000) }
                aIn.value.append(sb)
            }
            aIn.value.markAsFinished()
        } : nil
        defer { audioTask?.cancel() }

        var denoiser = e.denoise.map { TemporalDenoiser(level: $0) }
        var scale: ((CVPixelBuffer, CMTime) async throws -> CVPixelBuffer)?
        var endScaler: (() -> Void)?
        if upscale, useFull, #available(macOS 26.0, *) {
            let sc = try await FullScaler(width: w, height: h, outWidth: ow, outHeight: oh)
            scale = { try await sc.scale($0, pts: $1) }; endScaler = { sc.end() }
        } else if upscale, #available(macOS 26.0, *) {
            let k = Double(max(ow, oh)) / Double(max(w, h))
            let sc = try TiledScaler(width: w, height: h, passes: SuperResolutionTiles.passes(for: k), outWidth: ow, outHeight: oh)
            scale = { try await sc.scale($0, pts: $1) }; endScaler = { sc.end() }
        }
        defer { endScaler?() }
        var frame = 0
        var st = Stats(width: ow, height: oh)
        let clock = ContinuousClock(), start = clock.now
        func lap(_ t: inout Double, _ since: ContinuousClock.Instant) { t += Self.seconds(clock.now - since) }
        do {
            while true {
                var t0 = clock.now
                guard let sb = await OffPool.next(vOut) else { break }
                lap(&st.decode, t0)
                try Task.checkCancellation()
                guard let src = CMSampleBufferGetImageBuffer(sb) else { continue }
                let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                t0 = clock.now
                var outBuf = src
                let gain = frame < gains.count ? gains[frame] : 1
                // pixels are only rewritten for denoise / deflicker (or an odd-sized decoded frame); the tiled scaler
                // reads the decoded frame directly
                if scale == nil || denoiser != nil || gain != 1 || CVPixelBufferGetWidth(src) != w || CVPixelBufferGetHeight(src) != h {
                    guard let work = makeBuffer(w, h) else { throw AIToolError.noInput }
                    copy420(src, to: work, gain: gain)
                    denoiser?.apply(work)
                    outBuf = work
                }
                lap(&st.filter, t0); t0 = clock.now
                if let scale { outBuf = try await scale(outBuf, pts) }
                lap(&st.scale, t0); t0 = clock.now
                while !vIn.isReadyForMoreMediaData { try Task.checkCancellation(); try await Task.sleep(nanoseconds: 2_000_000) }
                lap(&st.encodeWait, t0); t0 = clock.now
                if let widen { outBuf = try widen.convert(outBuf) }
                if !adaptor.append(outBuf, withPresentationTime: pts) { throw writer.error ?? AIToolError.noInput }
                lap(&st.encode, t0)
                frame += 1
                progress?(split + (1 - split) * min(1, pts.seconds / max(duration, 0.001)))
            }
            vIn.markAsFinished()
            try await audioTask?.value
        } catch {
            reader.cancelReading(); writer.cancelWriting(); throw error
        }
        if reader.status == .failed { writer.cancelWriting(); throw reader.error ?? AIToolError.noInput }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? AIToolError.noInput }
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.moveItem(at: tmp, to: out)
        st.frames = frame; st.total = Self.seconds(clock.now - start); st.duration = duration
        stats?(st)
        if ProcessInfo.processInfo.environment["MONTAGE_ENHANCE_LOG"] != nil { print("enhance \(e.key): \(st)") }
        progress?(1)
        return out
    }

    static func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }

    /// Where the time of a `process` pass went (seconds, summed over frames): the AI QA timing log
    /// (`MONTAGE_ENHANCE_LOG=1` prints it).
    public struct Stats: Sendable, CustomStringConvertible {
        public var width = 0, height = 0, frames = 0
        public var duration = 0.0, total = 0.0, decode = 0.0, filter = 0.0, scale = 0.0, encodeWait = 0.0, encode = 0.0
        init(width: Int, height: Int) { self.width = width; self.height = height }
        /// Processing time ÷ media duration.
        public var realTimeFactor: Double { total / max(duration, 0.001) }
        public var description: String {
            String(format: "%dx%d %d frames in %.2fs (×%.2f RT): decode %.2f filter %.2f scale %.2f encode-wait %.2f encode %.2f",
                   width, height, frames, total, realTimeFactor, decode, filter, scale, encodeWait, encode)
        }
    }

    static let hdrTransfers: Set<String> = [AVVideoTransferFunction_ITU_R_2100_HLG, AVVideoTransferFunction_SMPTE_ST_2084_PQ]

    /// Colour primaries / transfer / matrix of a video track as `AVVideoColorPropertiesKey` settings (nil = untagged).
    static func colorProperties(_ track: AVAssetTrack) async throws -> [String: Any]? {
        guard let fd = try await track.load(.formatDescriptions).first else { return nil }
        func ext(_ k: CFString) -> String? { CMFormatDescriptionGetExtension(fd, extensionKey: k) as? String }
        guard let p = ext(kCMFormatDescriptionExtension_ColorPrimaries), let t = ext(kCMFormatDescriptionExtension_TransferFunction),
              let m = ext(kCMFormatDescriptionExtension_YCbCrMatrix) else { return nil }
        return [AVVideoColorPrimariesKey: p, AVVideoTransferFunctionKey: t, AVVideoYCbCrMatrixKey: m]
    }

    // MARK: Flicker analysis

    static func meanLuma(_ av: AVURLAsset, track: AVAssetTrack, progress: (Double) -> Void) async throws -> [Double] {
        let duration = try await av.load(.duration).seconds
        let reader = try AVAssetReader(asset: av)
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 36])
        o.alwaysCopiesSampleData = false
        reader.add(o)
        guard reader.startReading() else { throw reader.error ?? AIToolError.noInput }
        var means: [Double] = []
        // blocking read loop: off the cooperative pool (OffPool)
        try await OffPool.run { ctx in
            while let sb = o.copyNextSampleBuffer() {
                try ctx.checkCancellation()
                guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
                CVPixelBufferLockBaseAddress(pb, .readOnly)
                let pw = CVPixelBufferGetWidthOfPlane(pb, 0), ph = CVPixelBufferGetHeightOfPlane(pb, 0), bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
                var acc = 0
                if let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)?.assumingMemoryBound(to: UInt8.self) {
                    for y in 0..<ph { let row = base + y * bpr; for x in 0..<pw { acc += Int(row[x]) } }
                }
                CVPixelBufferUnlockBaseAddress(pb, .readOnly)
                means.append(max(1, Double(acc) / Double(max(pw * ph, 1)) - 16))
                progress(min(1, CMSampleBufferGetPresentationTimeStamp(sb).seconds / max(duration, 0.001)))
            }
        }
        return means
    }

    // MARK: Buffers

    static func makeBuffer(_ w: Int, _ h: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary, &pb)
        return pb
    }

    /// Copies a 4:2:0 video-range buffer (cropping to even `dst` size) applying an exposure gain.
    static func copy420(_ src: CVPixelBuffer, to dst: CVPixelBuffer, gain: Double) {
        CVPixelBufferLockBaseAddress(src, .readOnly); CVPixelBufferLockBaseAddress(dst, [])
        defer { CVPixelBufferUnlockBaseAddress(src, .readOnly); CVPixelBufferUnlockBaseAddress(dst, []) }
        let g = Float(gain)
        let lutY: [UInt8] = (0..<256).map { v in UInt8(min(max((Float(v) - 16) * g + 16, 0), 255).rounded()) }
        let lutC: [UInt8] = (0..<256).map { v in UInt8(min(max((Float(v) - 128) * g + 128, 0), 255).rounded()) }
        for plane in 0..<2 {
            guard let s = CVPixelBufferGetBaseAddressOfPlane(src, plane)?.assumingMemoryBound(to: UInt8.self),
                  let d = CVPixelBufferGetBaseAddressOfPlane(dst, plane)?.assumingMemoryBound(to: UInt8.self) else { continue }
            let sb = CVPixelBufferGetBytesPerRowOfPlane(src, plane), db = CVPixelBufferGetBytesPerRowOfPlane(dst, plane)
            let rows = min(CVPixelBufferGetHeightOfPlane(src, plane), CVPixelBufferGetHeightOfPlane(dst, plane))
            let bytes = min(CVPixelBufferGetWidthOfPlane(src, plane), CVPixelBufferGetWidthOfPlane(dst, plane)) * (plane == 0 ? 1 : 2)
            if gain == 1 {
                for y in 0..<rows { memcpy(d + y * db, s + y * sb, bytes) }
            } else {
                let lut = plane == 0 ? lutY : lutC
                lut.withUnsafeBufferPointer { l in
                    for y in 0..<rows { let rs = s + y * sb, rd = d + y * db; for x in 0..<bytes { rd[x] = l[Int(rs[x])] } }
                }
            }
        }
    }

    /// Motion-adaptive recursive temporal filter: out = prev + (cur − prev)·w, w = 1 − α·exp(−(d/σ)²).
    /// The tolerance σ follows the measured noise level (robust estimate from horizontal Y differences), × a level factor.
    struct TemporalDenoiser {
        let alpha: Float, k: Float
        var prev: [[UInt8]] = []
        var weights: [UInt8] = []   // lookup by |d| (0…255) → w·255
        var noise: Float?
        init(level: EnhanceLevel) {
            switch level {
            case .weak: alpha = 0.6; k = 2
            case .normal: alpha = 0.8; k = 3
            case .strong: alpha = 0.9; k = 4
            }
        }

        /// Median |Y(x+1) − Y(x)| / (0.6745·√2) on a subsample (σ of white noise in 8-bit units).
        static func estimateNoise(_ pb: CVPixelBuffer) -> Float {
            guard let p = CVPixelBufferGetBaseAddressOfPlane(pb, 0)?.assumingMemoryBound(to: UInt8.self) else { return 2 }
            let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
            var hist = [Int](repeating: 0, count: 256), n = 0
            for y in stride(from: 0, to: h, by: 4) { let r = p + y * bpr; for x in stride(from: 0, to: w - 1, by: 2) { hist[abs(Int(r[x + 1]) - Int(r[x]))] += 1; n += 1 } }
            var acc = 0
            for (i, c) in hist.enumerated() { acc += c; if acc * 2 >= n { return max(1, Float(i) / 0.954) } }
            return 2
        }

        mutating func apply(_ pb: CVPixelBuffer) {
            CVPixelBufferLockBaseAddress(pb, [])
            defer { CVPixelBufferUnlockBaseAddress(pb, []) }
            let est = Self.estimateNoise(pb)
            let n = noise.map { $0 * 0.9 + est * 0.1 } ?? est
            if noise == nil || abs(n - noise!) > 0.25 || weights.isEmpty {
                let sigma = max(3, k * n)
                weights = (0..<256).map { d in
                    let x = Float(d) / sigma
                    return UInt8(min(255, ((1 - alpha * exp(-x * x)) * 255).rounded()))
                }
            }
            noise = n
            let first = prev.isEmpty
            for plane in 0..<2 {
                guard let p = CVPixelBufferGetBaseAddressOfPlane(pb, plane)?.assumingMemoryBound(to: UInt8.self) else { continue }
                let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, plane), rows = CVPixelBufferGetHeightOfPlane(pb, plane)
                let bytes = CVPixelBufferGetWidthOfPlane(pb, plane) * (plane == 0 ? 1 : 2)
                if first { prev.append([UInt8](repeating: 0, count: bytes * rows)) }
                prev[plane].withUnsafeMutableBufferPointer { q in
                    weights.withUnsafeBufferPointer { wl in
                        for y in 0..<rows {
                            let row = p + y * bpr, qr = q.baseAddress! + y * bytes
                            if first { memcpy(qr, row, bytes); continue }
                            for x in 0..<bytes {
                                let c = Int(row[x]), o = Int(qr[x])
                                let w = Int(wl[abs(c - o)])
                                let v = UInt8(o + ((c - o) * w + (c >= o ? 127 : -127)) / 255)
                                row[x] = v; qr[x] = v
                            }
                        }
                    }
                }
            }
        }
    }

    /// Fallback where the low-latency scaler is missing: VideoToolbox ML super resolution (×4, temporal: previous
    /// source/output frames are fed back; ~1.5 s per 1080p frame on an M1 Pro), then a
    /// VTPixelTransferSession downscale to the requested output size. Downloads the OS model first if needed.
    @available(macOS 26.0, *)
    final class FullScaler: @unchecked Sendable {
        let processor = VTFrameProcessor()
        let srcPool: CVPixelBufferPool, dstPool: CVPixelBufferPool, outPool: CVPixelBufferPool
        let transfer: VTPixelTransferSession
        var previous: (src: VTFrameProcessorFrame, out: VTFrameProcessorFrame)?

        init(width: Int, height: Int, outWidth: Int, outHeight: Int) async throws {
            guard let cfg = VTSuperResolutionScalerConfiguration(frameWidth: width, frameHeight: height, scaleFactor: 4, inputType: .video,
                                                                 usePrecomputedFlow: false, qualityPrioritization: .normal,
                                                                 revision: VTSuperResolutionScalerConfiguration.defaultRevision)
            else { throw AIToolError.unavailable("super resolution: unsupported size") }
            if cfg.configurationModelStatus != .ready {
                let box = UncheckedSendable(cfg)
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    box.value.downloadConfigurationModel { err in if let err { c.resume(throwing: err) } else { c.resume() } }
                }
            }
            try processor.startSession(configuration: cfg)
            var a: CVPixelBufferPool?, b: CVPixelBufferPool?, o: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, cfg.sourcePixelBufferAttributes as CFDictionary, &a)
            CVPixelBufferPoolCreate(nil, nil, cfg.destinationPixelBufferAttributes as CFDictionary, &b)
            CVPixelBufferPoolCreate(nil, nil, [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                               kCVPixelBufferWidthKey as String: outWidth, kCVPixelBufferHeightKey as String: outHeight,
                                               kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary, &o)
            var t: VTPixelTransferSession?
            VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &t)
            guard let a, let b, let o, let t else { throw AIToolError.noInput }
            srcPool = a; dstPool = b; outPool = o; transfer = t
        }

        func make(_ pool: CVPixelBufferPool) throws -> CVPixelBuffer {
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let pb else { throw AIToolError.noInput }
            return pb
        }

        func scale(_ work: CVPixelBuffer, pts: CMTime) async throws -> CVPixelBuffer {
            let src = try make(srcPool), dst = try make(dstPool), out = try make(outPool)
            guard VTPixelTransferSessionTransferImage(transfer, from: work, to: src) == noErr,
                  let fs = VTFrameProcessorFrame(buffer: src, presentationTimeStamp: pts),
                  let fd = VTFrameProcessorFrame(buffer: dst, presentationTimeStamp: pts),
                  let params = VTSuperResolutionScalerParameters(sourceFrame: fs, previousFrame: previous?.src,
                                                                  previousOutputFrame: previous?.out, opticalFlow: nil,
                                                                  submissionMode: .sequential, destinationFrame: fd)
            else { throw AIToolError.noInput }
            let box = UncheckedSendable(params)
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                processor.process(parameters: box.value) { _, err in if let err { c.resume(throwing: err) } else { c.resume() } }
            }
            previous = (fs, fd)
            guard VTPixelTransferSessionTransferImage(transfer, from: dst, to: out) == noErr else { throw AIToolError.noInput }
            return out
        }

        func end() { processor.endSession(); VTPixelTransferSessionInvalidate(transfer) }
    }
}

/// Applying / removing enhancements on a clip (one undo step; the processed copy is added to the media list).
public enum VideoEnhanceJob {
    /// Renders the media for `e` (from the original) and returns the edit that points the clip at it.
    public static func run(project p: Project, clipID: ClipID, enhancement e: VideoEnhancement,
                           progress: (@Sendable (Double) -> Void)? = nil) async throws -> any EditCommand {
        guard let original = p.asset(e.original), original.kind == .video else { throw AIToolError.noInput }
        if e.isEmpty {
            return Edit("cmd.enhance") { p in
                guard var c = p.timeline.clip(clipID) else { throw EditError.clipNotFound }
                c.content = .media(e.original); c.enhance = nil
                p.timeline[clip: clipID] = c
            }
        }
        let url = try await VideoEnhancer.process(original, e, progress: progress)
        var processed = try await MediaProbe.probe(url)
        processed.name = original.name
        let asset = processed
        return Edit("cmd.enhance") { p in
            guard var c = p.timeline.clip(clipID) else { throw EditError.clipNotFound }
            let id: MediaID
            if let existing = p.media.first(where: { $0.contentHash == asset.contentHash }) { id = existing.id } else { p.media.append(asset); id = asset.id }
            c.content = .media(id); c.enhance = e
            p.timeline[clip: clipID] = c
        }
    }
}

/// 8-bit 4:2:0 → 10-bit 4:2:0 (same colour space) for HEVC Main10 output of HDR sources. The widened buffers carry the
/// output's colour tags: untagged ones made the HLG encoder fail with kVTParameterErr (-12902).
final class TenBitWidener {
    private let session: VTPixelTransferSession
    private let pool: CVPixelBufferPool
    private let tags: [(CFString, CFString)]
    init(width: Int, height: Int, color: [String: Any]) throws {
        tags = [(kCVImageBufferColorPrimariesKey, AVVideoColorPrimariesKey), (kCVImageBufferTransferFunctionKey, AVVideoTransferFunctionKey),
                (kCVImageBufferYCbCrMatrixKey, AVVideoYCbCrMatrixKey)].compactMap { k, s in (color[s] as? String).map { (k, $0 as CFString) } }
        var s: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &s) == noErr, let s else { throw AIToolError.noInput }
        var p: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                                           kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                                           kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary, &p)
        guard let p else { throw AIToolError.noInput }
        session = s; pool = p
    }
    func convert(_ src: CVPixelBuffer) throws -> CVPixelBuffer {
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let out, VTPixelTransferSessionTransferImage(session, from: src, to: out) == noErr else { throw AIToolError.noInput }
        for (k, v) in tags { CVBufferSetAttachment(out, k, v, .shouldPropagate) }
        return out
    }
    func end() { VTPixelTransferSessionInvalidate(session) }
}
