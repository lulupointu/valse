@preconcurrency import AVFoundation
import VideoToolbox
import Foundation
import MontageCore

public enum ExportError: Error, Sendable, Equatable {
    case emptyProject
    case cancelled
    case failed(String)
    /// Preflight: media files that can't be found (names).
    case missingMedia([String])
    /// Preflight: not enough free space (needed bytes).
    case notEnoughSpace(Int64)
    /// The selected output needs a tool that isn't installed (e.g. MP3 without the FFmpeg sidecar).
    case encoderUnavailable(String)
    public var messageKey: String {
        switch self {
        case .emptyProject: return "export.error.empty"
        case .cancelled: return "export.error.cancelled"
        case .failed: return "export.error.failed"
        case .missingMedia: return "export.error.missingMedia"
        case .notEnoughSpace: return "export.error.space"
        case .encoderUnavailable: return "export.error.encoder"
        }
    }
}

/// Per-file extras for a video export.
public struct ExportOptions: Sendable {
    /// Title metadata (CapCut "Title").
    public var title: String?
    /// Cover JPEG embedded as artwork metadata (poster/thumbnail in Finder, players).
    public var artworkJPEG: Data?
    /// Timeline time of the cover frame (used by `ExportSettings.prependCover`).
    public var coverTime: Time = .zero
    public init(title: String? = nil, artworkJPEG: Data? = nil, coverTime: Time = .zero) {
        self.title = title; self.artworkJPEG = artworkJPEG; self.coverTime = coverTime
    }
}

/// Renders a project to a file: AVAssetReader (composition rendered by the same MontageCompositor as the preview,
/// from ORIGINAL media at full resolution) → AVAssetWriter (VideoToolbox hardware H.264/HEVC, ProRes, AAC).
/// Samples are re-timed so the file always starts at 0 (range exports). Cancel by cancelling the calling Task.
public enum Exporter {
    public static func export(project: Project, settings: ExportSettings, to url: URL, range: TimeRange? = nil,
                              options: ExportOptions = ExportOptions(),
                              progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard project.duration > .zero else { throw ExportError.emptyProject }
        let sourceSpace = project.settings.colorSpace
        var project = prepare(project, for: settings)
        // EX-018 AI ultra HD: super-resolve small sources first (first part of the progress bar).
        var progressVar = progress
        if settings.aiUltraHD, let sr = ExportHooks.superResolve,
           !ExportHooks.clipsNeedingUpscale(project, settings: settings, range: range).isEmpty {
            let outer = progress
            project = try await sr(project, settings, range) { outer?(0.4 * $0) }
            progressVar = outer.map { o in { @Sendable p in o(0.4 + 0.6 * p) } }
        }
        let progress = progressVar
        try Task.checkCancellation()
        let blurSamples = settings.motionBlur.samples
        let space = project.settings.colorSpace
        var settings = settings
        settings.codec = settings.effectiveCodec(for: sourceSpace)
        // HEVC with alpha is 8-bit SDR only; HDR alpha needs ProRes 4444.
        let alpha = settings.effectiveAlpha && !(space.isHDR && settings.codec == .hevc)
        let bitDepth = settings.effectiveBitDepth(for: sourceSpace)
        let tenBitHEVC = settings.codec == .hevc && bitDepth == 10
        let (w, h) = settings.outputSize(canvas: project.settings.canvasSize)
        // EX-025: the composition runs at `blurSamples` × the output rate; the video pump averages each group.
        let renderRate = blurSamples > 1
            ? FrameRate(settings.frameRate.numerator * Int32(blurSamples), settings.frameRate.denominator) : settings.frameRate
        let built = try await CompositionBuilder.build(project: project, purpose: .export,
                                                       renderSize: CGSize(width: w, height: h), frameRate: renderRate,
                                                       highPrecision: tenBitHEVC)
        let fullRange = TimeRange(start: .zero, duration: project.duration)
        let exportRange = range.flatMap { $0.intersection(fullRange) } ?? fullRange
        guard exportRange.duration > .zero else { throw ExportError.emptyProject }

        // Pixel format handed to the writer: 10-bit 4:2:0 for HEVC Main10, 16-bit RGBA for HDR ProRes, else 8-bit BGRA
        // (alpha travels in BGRA).
        let readFormat: OSType
        if tenBitHEVC && !alpha { readFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange }
        else if space.isHDR && settings.codec.isProRes { readFormat = kCVPixelFormatType_64RGBAHalf }
        else if space.isHDR { readFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange }
        else {
            #if arch(x86_64)
            // x86_64 (Intel / Rosetta): VideoToolbox's HEVC encoder converts BGRA input to FULL-range 4:2:0 there
            // (ffprobe: yuvj420p, measured under Rosetta), so 8-bit HEVC gets video-range 4:2:0 from the reader, like
            // Apple Silicon's output (yuv420p). Alpha still needs BGRA.
            readFormat = settings.codec == .hevc && !alpha ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_32BGRA
            #else
            readFormat = kCVPixelFormatType_32BGRA
            #endif
        }
        let vTracks = try await built.composition.loadTracks(withMediaType: .video)
        func videoOutput() -> AVAssetReaderVideoCompositionOutput {
            let o = AVAssetReaderVideoCompositionOutput(videoTracks: vTracks, videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: readFormat,
                kCVPixelBufferMetalCompatibilityKey as String: true])
            o.videoComposition = built.videoComposition
            o.alwaysCopiesSampleData = false
            return o
        }

        // EX-019: the cover frame, read through the same pipeline (same pixel format) before the main pass.
        var coverSample: CMSampleBuffer?
        let frameDur = settings.frameRate.frameDuration
        if settings.prependCover {
            let r = try AVAssetReader(asset: built.composition)
            let t = min(max(options.coverTime, .zero), project.duration - frameDur)
            r.timeRange = TimeRange(start: t, duration: frameDur).cmTimeRange
            let o = videoOutput(); r.add(o)
            // blocking read: off the cooperative pool (OffPool)
            try await OffPool.run { _ in
                if r.startReading() { coverSample = o.copyNextSampleBuffer() }
                r.cancelReading()
            }
        }
        let lead: Time = coverSample == nil ? .zero : frameDur

        // A STALLED pass (no sample read and nothing composed for `stallSeconds`: AVFoundation stopped asking the
        // compositor for frames, seen under heavy machine load — the export then hung forever) is abandoned and the
        // export restarted once; a second stall fails it ("export stalled") instead of hanging.
        var attempt = 0
        while true {
        attempt += 1
        try? FileManager.default.removeItem(at: url)
        let reader = try AVAssetReader(asset: built.composition)
        reader.timeRange = exportRange.cmTimeRange
        let vOut = videoOutput()
        reader.add(vOut)

        var aOut: AVAssetReaderAudioMixOutput?
        let aTracks = try await built.composition.loadTracks(withMediaType: .audio)
        if settings.includeAudio, !aTracks.isEmpty {
            let o = AVAssetReaderAudioMixOutput(audioTracks: aTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false])
            o.audioMix = built.audioMix
            o.audioTimePitchAlgorithm = .spectral
            o.alwaysCopiesSampleData = false
            reader.add(o); aOut = o
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: fileType(for: url, settings: settings))
        writer.shouldOptimizeForNetworkUse = true
        writer.metadata = metadataItems(options)
        // HLG: the footage's ambient viewing environment, so players render the file like its source (C1)
        let ambient = space == .hdrHLG ? await HDRViewingMetadata.shared.ambientViewingEnvironment(for: project) : nil
        var vSettings = videoSettings(settings, w: w, h: h, canvas: project.settings.canvasSize, space: space,
                                      bitDepth: bitDepth, alpha: alpha, ambient: ambient)
        if !writer.canApply(outputSettings: vSettings, forMediaType: .video) {
            // macOS 13 / Intel encoders reject some optional properties (an unsupported one fails canApply, and would
            // throw in AVAssetWriterInput): export without them rather than not at all. 14+/Apple Silicon never get here.
            vSettings = Self.withoutOptionalCompressionKeys(vSettings)
        }
        guard writer.canApply(outputSettings: vSettings, forMediaType: .video) else {
            throw ExportError.failed("unsupported video settings \(settings.codec) \(w)x\(h)")
        }
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
        vIn.expectsMediaDataInRealTime = false
        writer.add(vIn)
        var aIn: AVAssetWriterInput?
        if aOut != nil {
            var layout = AudioChannelLayout(); layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: settings.audioBitrateKbps * 1000,
                AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)])
            i.expectsMediaDataInRealTime = false
            writer.add(i); aIn = i
        }

        guard reader.startReading() else { throw ExportError.failed(reader.error?.localizedDescription ?? "reader") }
        guard writer.startWriting() else { throw ExportError.failed(writer.error?.localizedDescription ?? "writer") }
        writer.startSession(atSourceTime: .zero)

        // file time = composition time − shift
        let shift = (exportRange.start - lead).cmTime
        let total = exportRange.duration.seconds
        let start = exportRange.start.seconds
        let io = UncheckedSendable((reader, writer, vOut, vIn, aOut, aIn, coverSample))
        let stop = ReaderCancel()
        let activity = ExportActivity()
        let monitor = Task.detached { [state = built.state] in
            // stall = for `stallSeconds`: no sample read, no composition requested or composed, and NO compose in
            // progress (work-based: a slow pass on a loaded machine, even one very slow frame, keeps it alive). The
            // pumps are then only asked to stop: the reader is never cancelled while a pump reads (ReaderCancel).
            var last = (activity.samples, state.framesComposed, state.requestsStarted), since = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                let now = (activity.samples, state.framesComposed, state.requestsStarted)
                if now != last || state.composesInFlight > 0 { last = now; since = Date(); continue }
                if Date().timeIntervalSince(since) > Self.stallSeconds { activity.markStalled(); stop.request(); return }
            }
        }
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { g in
                g.addTask {
                    let (_, _, vOut, vIn, _, _, cover) = io.value
                    let first = cover.flatMap { retimed($0, pts: .zero, duration: frameDur.cmTime) }
                    let report: @Sendable (Double) -> Void = { pts in
                        activity.tick()
                        progress?(min(0.999, max(0, (pts - start) / max(total, 0.001))))
                    }
                    if blurSamples > 1 {
                        await pumpMotionBlur(vOut, vIn, shift: shift, prefix: first, frameDuration: frameDur, rangeStart: exportRange.start, lead: lead,
                                             stop: stop, onSample: report)
                    } else {
                        await pump(vOut, vIn, shift: shift, prefix: first, label: "export.video", stop: stop, onSample: report)
                    }
                }
                if aOut != nil {
                    g.addTask {
                        let (_, _, _, _, aOut, aIn, _) = io.value
                        if let aOut, let aIn { await pump(aOut, aIn, shift: shift, prefix: nil, label: "export.audio", stop: stop, onSample: { _ in activity.tick() }) }
                    }
                }
            }
        } onCancel: {
            // Only ask the pumps to stop (never cancelReading under a running copy: ReaderCancel); reader and writer
            // are cancelled below, once nothing reads.
            stop.request()
        }
        stop.finish()
        monitor.cancel()
        if Task.isCancelled {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw ExportError.cancelled
        }
        if activity.stalled {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            Self.noteStallRestart()
            NSLog("Montage export: pass stalled (nothing read or composed for %d s), attempt %d", Int(Self.stallSeconds), attempt)
            // a test never hides a stall behind the restart: it fails (UI tests: UITestDriver fails on stallRestarts)
            if attempt < 2, !MontageProcess.isUnitTest { continue }
            throw ExportError.failed("export stalled")
        }
        if reader.status == .failed || writer.status == .failed {
            let msg = reader.error?.localizedDescription ?? writer.error?.localizedDescription ?? "read failed"
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw ExportError.failed(msg)
        }
        writer.endSession(atSourceTime: (exportRange.duration + lead).cmTime)
        await writer.finishWriting()
        guard writer.status == .completed else { throw ExportError.failed(writer.error?.localizedDescription ?? "write failed") }
        progress?(1)
        return
        }
    }

    /// No sample read and no frame composed for this long = a stalled export pass (hang detector, not a speed budget).
    static let stallSeconds: Double = ProcessInfo.processInfo.environment["MONTAGE_EXPORT_STALL_SECONDS"].flatMap(Double.init) ?? 30
    private static let stallLock = NSLock()
    nonisolated(unsafe) private static var _stallRestarts = 0
    /// Export passes abandoned as stalled since launch (diagnostics / tests).
    public static var stallRestarts: Int { stallLock.withLock { _stallRestarts } }
    static func noteStallRestart() { stallLock.withLock { _stallRestarts += 1 } }

    /// The project as the export renders it: output colour space (smart HDR→SDR), platform aspect, transparent
    /// background for alpha codecs, caption tracks hidden when captions aren't burnt in.
    public static func prepare(_ project: Project, for settings: ExportSettings) -> Project {
        var p = project
        p.settings.colorSpace = settings.outputColorSpace(for: project.settings.colorSpace)
        p.settings.canvasSize = settings.exportCanvas(project.settings.canvasSize)
        if settings.effectiveAlpha { p.settings.backgroundColor = .clear }
        if !settings.burnCaptions {
            for id in CaptionExport.burnableTrackIDs(project) {
                if let i = p.timeline.tracks.firstIndex(where: { $0.id == id }) { p.timeline.tracks[i].isHidden = true }
            }
        }
        return p
    }

    /// The URL's extension wins (callers may pick .mp4/.mov/.m4v); otherwise the settings' container.
    static func fileType(for url: URL, settings: ExportSettings) -> AVFileType {
        switch url.pathExtension.lowercased() {
        case "mp4": return settings.codec.isProRes ? .mov : .mp4
        case "m4v": return settings.codec.isProRes ? .mov : .m4v
        case "mov": return .mov
        default: return settings.effectiveContainer == .mp4 ? .mp4 : .mov
        }
    }

    static func metadataItems(_ o: ExportOptions) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        if let t = o.title, !t.isEmpty {
            let m = AVMutableMetadataItem(); m.keySpace = .common; m.key = AVMetadataKey.commonKeyTitle as NSString; m.value = t as NSString
            m.identifier = .commonIdentifierTitle
            items.append(m)
        }
        if let d = o.artworkJPEG {
            let m = AVMutableMetadataItem(); m.keySpace = .common; m.key = AVMetadataKey.commonKeyArtwork as NSString
            m.identifier = .commonIdentifierArtwork
            m.value = d as NSData; m.dataType = kCMMetadataBaseDataType_JPEG as String
            items.append(m)
        }
        let sw = AVMutableMetadataItem(); sw.keySpace = .common; sw.key = AVMetadataKey.commonKeySoftware as NSString
        sw.identifier = .commonIdentifierSoftware; sw.value = "Montage" as NSString
        items.append(sw)
        return items
    }

    static func proResType(_ c: ExportSettings.Codec) -> AVVideoCodecType {
        switch c {
        case .proRes422Proxy: return .proRes422Proxy
        case .proRes422LT: return .proRes422LT
        case .proRes422HQ: return .proRes422HQ
        case .proRes4444: return .proRes4444
        case .proRes4444XQ: return AVVideoCodecType(rawValue: "ap4x")
        default: return .proRes422
        }
    }

    /// Compression properties the export can live without: HLG ambient viewing environment (VideoToolbox 14+) and the
    /// fast-encode hint (not every hardware encoder accepts it, e.g. Intel Quick Sync).
    static let optionalCompressionKeys = ["AmbientViewingEnvironment", kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String]

    static func withoutOptionalCompressionKeys(_ settings: [String: Any]) -> [String: Any] {
        guard var props = settings[AVVideoCompressionPropertiesKey] as? [String: Any] else { return settings }
        for k in optionalCompressionKeys where props[k] != nil {
            props[k] = nil
            EngineLog.info("export: encoder rejected optional property \(k); exporting without it")
        }
        var out = settings
        out[AVVideoCompressionPropertiesKey] = props
        return out
    }

    static func videoSettings(_ s: ExportSettings, w: Int, h: Int, canvas: Size2, space: ProjectColorSpace = .sdr709,
                              bitDepth: Int = 8, alpha: Bool = false, ambient: Data? = nil) -> [String: Any] {
        var out: [String: Any] = [AVVideoWidthKey: w, AVVideoHeightKey: h]
        out[AVVideoColorPropertiesKey] = ColorTags(space).properties
        switch s.codec {
        case .h264, .hevc:
            let hevcAlpha = s.codec == .hevc && alpha
            out[AVVideoCodecKey] = s.codec == .h264 ? AVVideoCodecType.h264 : (hevcAlpha ? AVVideoCodecType.hevcWithAlpha : AVVideoCodecType.hevc)
            let bitrate = s.videoBitrate(canvas: canvas)
            var props: [String: Any] = [AVVideoAverageBitRateKey: bitrate,
                                        AVVideoExpectedSourceFrameRateKey: s.frameRate.fps,
                                        AVVideoMaxKeyFrameIntervalKey: max(1, Int(s.frameRate.fps.rounded()) * 2),
                                        AVVideoAllowFrameReorderingKey: true]
            if s.codec == .h264 { props[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
            if s.codec == .hevc && !hevcAlpha {
                props[AVVideoProfileLevelKey] = (bitDepth == 10 ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel) as String
            }
            if s.codec == .hevc && space == .hdrPQ {
                // HDR10 static metadata (SMPTE ST 2086 mastering display + CTA-861.3 content light level).
                props[kVTCompressionPropertyKey_MasteringDisplayColorVolume as String] = HDR10Metadata.masteringDisplay()
                props[kVTCompressionPropertyKey_ContentLightLevelInfo as String] = HDR10Metadata.contentLightLevel()
            }
            if s.codec == .hevc && space == .hdrHLG, let ambient {
                // kVTCompressionPropertyKey_AmbientViewingEnvironment (exported by VideoToolbox, not in the SDK headers)
                props["AmbientViewingEnvironment"] = ambient
            }
            if hevcAlpha {
                props[kVTCompressionPropertyKey_TargetQualityForAlpha as String] = 0.9
                props[kVTCompressionPropertyKey_AlphaChannelMode as String] = kVTAlphaChannelMode_StraightAlpha
            }
            if s.rateControl == .cbr {
                // Peak ≈ average over 1 s windows (VideoToolbox data-rate limit): constant-bit-rate-like output.
                props[kVTCompressionPropertyKey_DataRateLimits as String] = [NSNumber(value: Double(bitrate) * 1.1 / 8), NSNumber(value: 1)]
            }
            if s.preferHardware && s.fastEncoding {
                props[kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String] = true   // EX-016
            }
            out[AVVideoCompressionPropertiesKey] = props
            out[AVVideoEncoderSpecificationKey] = [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: s.preferHardware]
        default:
            out[AVVideoCodecKey] = proResType(s.codec)
            if s.codec == .proRes4444 || s.codec == .proRes4444XQ {
                // The output pass writes straight (unpremultiplied) colour; without alpha no alpha plane is coded.
                out[AVVideoCompressionPropertiesKey] = alpha
                    ? [kVTCompressionPropertyKey_AlphaChannelMode as String: kVTAlphaChannelMode_StraightAlpha]
                    : [kVTCompressionPropertyKey_PreserveAlphaChannel as String: false]
            }
        }
        return out
    }

    /// HDR10 static metadata blobs as VideoToolbox wants them (big-endian, ST 2086 / CTA-861.3 units).
    enum HDR10Metadata {
        /// Display P3 D65 mastering display, 1000 cd/m² peak, 0.005 cd/m² black (the common grading monitor setup).
        static func masteringDisplay(peakNits: Double = 1000, minNits: Double = 0.005) -> Data {
            var d = Data()
            func u16(_ v: Double) { var x = UInt16(v.rounded()).bigEndian; d.append(Data(bytes: &x, count: 2)) }
            func u32(_ v: Double) { var x = UInt32(v.rounded()).bigEndian; d.append(Data(bytes: &x, count: 4)) }
            // primaries G, B, R then white point, in 0.00002 units
            for (x, y) in [(0.265, 0.690), (0.150, 0.060), (0.680, 0.320), (0.3127, 0.3290)] { u16(x / 0.00002); u16(y / 0.00002) }
            u32(peakNits * 10000); u32(minNits * 10000)
            return d
        }
        /// MaxCLL / MaxFALL (cd/m²).
        static func contentLightLevel(maxCLL: Int = 1000, maxFALL: Int = 400) -> Data {
            var a = UInt16(maxCLL).bigEndian, b = UInt16(maxFALL).bigEndian
            return Data(bytes: &a, count: 2) + Data(bytes: &b, count: 2)
        }
    }

    static func retimed(_ sb: CMSampleBuffer, pts: CMTime, duration: CMTime? = nil) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return sb }
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        let delta = CMTimeSubtract(pts, CMSampleBufferGetPresentationTimeStamp(sb))
        for i in 0..<count {
            if timing[i].presentationTimeStamp.isValid { timing[i].presentationTimeStamp = CMTimeAdd(timing[i].presentationTimeStamp, delta) }
            if timing[i].decodeTimeStamp.isValid { timing[i].decodeTimeStamp = CMTimeAdd(timing[i].decodeTimeStamp, delta) }
            if let duration { timing[i].duration = duration }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: count,
                                              sampleTimingArray: &timing, sampleBufferOut: &out)
        return out
    }

    private static func pump(_ out: AVAssetReaderOutput, _ input: AVAssetWriterInput, shift: CMTime, prefix: CMSampleBuffer?,
                             label: String, stop: ReaderCancel, onSample: (@Sendable (Double) -> Void)?) async {
        let io = UncheckedSendable((out, input, prefix))
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let q = DispatchQueue(label: label, qos: .userInitiated)
            let state = UncheckedSendable(PumpState())
            io.value.1.requestMediaDataWhenReady(on: q) {
                let (out, input, prefix) = io.value
                let st = state.value
                if let prefix, !st.prefixed, input.isReadyForMoreMediaData {
                    st.prefixed = true
                    if !input.append(prefix) { st.done = true; input.markAsFinished(); cont.resume(); return }
                }
                while input.isReadyForMoreMediaData && !st.done {
                    if stop.requested {
                        st.done = true
                    } else if let sb = out.copyNextSampleBuffer() {
                        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                        onSample?(pts.seconds)
                        let t = CMTimeSubtract(pts, shift)
                        if t < .zero && CMSampleBufferGetNumSamples(sb) <= 1 { continue }
                        let moved = shift == .zero ? sb : (retimed(sb, pts: t) ?? sb)
                        if !input.append(moved) { st.done = true }
                    } else { st.done = true }
                    if st.done { input.markAsFinished(); cont.resume() }
                }
            }
        }
    }

    private final class PumpState { var done = false; var prefixed = false }

    private final class BlurPumpState {
        var done = false, prefixed = false, group = -1
        var head: CMSampleBuffer?
        let acc = FrameAccumulator()
    }

    /// EX-025 video pump: the reader delivers several sub-frames per output frame; each group is averaged
    /// (`FrameAccumulator`, in place in the group's first buffer) and written once at the output frame time.
    private static func pumpMotionBlur(_ out: AVAssetReaderOutput, _ input: AVAssetWriterInput, shift: CMTime, prefix: CMSampleBuffer?,
                                       frameDuration fd: Time, rangeStart: Time, lead: Time, stop: ReaderCancel,
                                       onSample: (@Sendable (Double) -> Void)?) async {
        let io = UncheckedSendable((out, input, prefix))
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let q = DispatchQueue(label: "export.video.motionBlur", qos: .userInitiated)
            let state = UncheckedSendable(BlurPumpState())
            io.value.1.requestMediaDataWhenReady(on: q) {
                let (out, input, prefix) = io.value
                let st = state.value
                func flush() -> Bool {
                    guard let head = st.head, st.group >= 0 else { return true }
                    st.head = nil
                    if let pb = CMSampleBufferGetImageBuffer(head), st.acc.count > 1 { st.acc.write(into: pb) } else { st.acc.reset() }
                    let pts = (Time(ticks: fd.ticks * Int64(st.group)) + lead).cmTime
                    guard let moved = retimed(head, pts: pts, duration: fd.cmTime) else { return true }
                    return input.append(moved)
                }
                if let prefix, !st.prefixed, input.isReadyForMoreMediaData {
                    st.prefixed = true
                    if !input.append(prefix) { st.done = true; input.markAsFinished(); cont.resume(); return }
                }
                while input.isReadyForMoreMediaData && !st.done {
                    if stop.requested {
                        st.done = true
                    } else if let sb = out.copyNextSampleBuffer() {
                        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                        onSample?(pts.seconds)
                        let rel = pts.seconds - rangeStart.seconds
                        if rel < -1e-6 { continue }
                        let g = Int((rel / fd.seconds + 1e-4).rounded(.down))
                        if g != st.group {
                            if !flush() { st.done = true }
                            st.group = g
                            st.head = sb
                        }
                        // unsupported pixel formats aren't accumulated: the group's first sub-frame passes through
                        if let pb = CMSampleBufferGetImageBuffer(sb) { _ = st.acc.add(pb) }
                    } else {
                        if !flush() { st.done = true }
                        st.done = true
                    }
                    if st.done { input.markAsFinished(); cont.resume() }
                }
            }
        }
    }
}
