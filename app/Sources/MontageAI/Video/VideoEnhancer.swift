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
/// - Enhance quality (HD): VideoToolbox low-latency ML super resolution ×2 (sources ≤ 960 px, no model download).
public enum VideoEnhancer {
    public static var directory: URL { MontagePaths.cacheDirectory.appendingPathComponent("enhanced", isDirectory: true) }

    public static func outputURL(_ a: MediaAsset, _ e: VideoEnhancement) -> URL {
        directory.appendingPathComponent("\(a.contentHash)-\(e.key).mov")
    }

    /// Whether ×2 super resolution applies to this media (low-latency scaler limits).
    public static func canUpscale(_ a: MediaAsset) -> Bool {
        guard #available(macOS 26.0, *), VTLowLatencySuperResolutionScalerConfiguration.isSupported else { return false }
        let (w, h) = rawSize(a)
        return !VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(frameWidth: w, frameHeight: h).isEmpty
    }

    static func rawSize(_ a: MediaAsset) -> (Int, Int) {
        let w = Int(a.pixelSize.width), h = Int(a.pixelSize.height)
        return a.sourceRotation % 180 == 0 ? (w, h) : (h, w)
    }

    @discardableResult
    public static func process(_ a: MediaAsset, _ e: VideoEnhancement, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
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
        let (ow, oh) = upscale ? (w * 2, h * 2) : (w, h)
        let tmp = out.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let writer = try AVAssetWriter(outputURL: tmp, fileType: .mov)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: ow, AVVideoHeightKey: oh,
            AVVideoCompressionPropertiesKey: [AVVideoQualityKey: 0.8]])
        vIn.transform = transform
        vIn.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
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
            while let sb = aOut.value.copyNextSampleBuffer() {
                while !aIn.value.isReadyForMoreMediaData { try Task.checkCancellation(); try await Task.sleep(nanoseconds: 2_000_000) }
                aIn.value.append(sb)
            }
            aIn.value.markAsFinished()
        } : nil
        defer { audioTask?.cancel() }

        var denoiser = e.denoise.map { TemporalDenoiser(level: $0) }
        var scale: ((CVPixelBuffer, CMTime) async throws -> CVPixelBuffer)?
        var endScaler: (() -> Void)?
        var newBuffer: () -> CVPixelBuffer? = { makeBuffer(w, h) }
        if upscale, #available(macOS 26.0, *) {
            let sc = try Scaler(width: w, height: h)
            scale = { try await sc.scale($0, pts: $1) }; endScaler = { sc.end() }
            newBuffer = { sc.sourceBuffer() }
        }
        var frame = 0
        do {
            while let sb = vOut.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let src = CMSampleBufferGetImageBuffer(sb) else { continue }
                let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                guard let work = newBuffer() else { throw AIToolError.noInput }
                copy420(src, to: work, gain: frame < gains.count ? gains[frame] : 1)
                denoiser?.apply(work)
                var outBuf = work
                if let scale { outBuf = try await scale(work, pts) }
                while !vIn.isReadyForMoreMediaData { try Task.checkCancellation(); try await Task.sleep(nanoseconds: 2_000_000) }
                if !adaptor.append(outBuf, withPresentationTime: pts) { throw writer.error ?? AIToolError.noInput }
                frame += 1
                progress?(split + (1 - split) * min(1, pts.seconds / max(duration, 0.001)))
            }
            vIn.markAsFinished()
            try await audioTask?.value
        } catch {
            reader.cancelReading(); writer.cancelWriting(); throw error
        }
        endScaler?()
        if reader.status == .failed { writer.cancelWriting(); throw reader.error ?? AIToolError.noInput }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? AIToolError.noInput }
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.moveItem(at: tmp, to: out)
        progress?(1)
        return out
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
        while let sb = o.copyNextSampleBuffer() {
            try Task.checkCancellation()
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

    /// VideoToolbox low-latency ×2 super resolution.
    @available(macOS 26.0, *)
    final class Scaler: @unchecked Sendable {
        let processor = VTFrameProcessor()
        let ow: Int, oh: Int
        let srcPool: CVPixelBufferPool, dstPool: CVPixelBufferPool
        init(width: Int, height: Int) throws {
            let cfg = VTLowLatencySuperResolutionScalerConfiguration(frameWidth: width, frameHeight: height, scaleFactor: 2)
            try processor.startSession(configuration: cfg)
            ow = width * 2; oh = height * 2
            var a: CVPixelBufferPool?, b: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, cfg.sourcePixelBufferAttributes as CFDictionary, &a)
            CVPixelBufferPoolCreate(nil, nil, cfg.destinationPixelBufferAttributes as CFDictionary, &b)
            guard let a, let b else { throw AIToolError.noInput }
            srcPool = a; dstPool = b
        }
        func sourceBuffer() -> CVPixelBuffer? { var pb: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, srcPool, &pb); return pb }
        func scale(_ src: CVPixelBuffer, pts: CMTime) async throws -> CVPixelBuffer {
            var dstOut: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, dstPool, &dstOut)
            guard let dst = dstOut,
                  let fs = VTFrameProcessorFrame(buffer: src, presentationTimeStamp: pts),
                  let fd = VTFrameProcessorFrame(buffer: dst, presentationTimeStamp: pts) else { throw AIToolError.noInput }
            let params = VTLowLatencySuperResolutionScalerParameters(sourceFrame: fs, destinationFrame: fd)
            let box = UncheckedSendable(params)
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                processor.process(parameters: box.value) { _, err in if let err { c.resume(throwing: err) } else { c.resume() } }
            }
            return dst
        }
        func end() { processor.endSession() }
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
