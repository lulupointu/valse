@preconcurrency import AVFoundation
import VideoToolbox
import Foundation
import MontageCore

public enum ExportError: Error, Sendable {
    case emptyProject
    case cancelled
    case failed(String)
    public var messageKey: String {
        switch self {
        case .emptyProject: return "export.error.empty"
        case .cancelled: return "export.error.cancelled"
        case .failed: return "export.error.failed"
        }
    }
}

/// Renders a project to a file: AVAssetReader (composition rendered by the same MontageCompositor as the preview,
/// from ORIGINAL media at full resolution) → AVAssetWriter (VideoToolbox hardware H.264/HEVC, ProRes, AAC).
/// Cancel by cancelling the calling Task.
public enum Exporter {
    public static func export(project: Project, settings: ExportSettings, to url: URL, range: TimeRange? = nil,
                              progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard project.duration > .zero else { throw ExportError.emptyProject }
        let space = project.settings.colorSpace
        var settings = settings
        settings.codec = settings.effectiveCodec(for: space)
        let (w, h) = settings.outputSize(canvas: project.settings.canvasSize)
        let built = try await CompositionBuilder.build(project: project, purpose: .export,
                                                       renderSize: CGSize(width: w, height: h), frameRate: settings.frameRate)
        let fullRange = TimeRange(start: .zero, duration: project.duration)
        let exportRange = range.flatMap { $0.intersection(fullRange) } ?? fullRange

        try? FileManager.default.removeItem(at: url)
        let reader = try AVAssetReader(asset: built.composition)
        reader.timeRange = exportRange.cmTimeRange
        let vTracks = try await built.composition.loadTracks(withMediaType: .video)
        // HDR: 10-bit 4:2:0 for HEVC Main10, 16-bit RGBA for ProRes; SDR: 8-bit BGRA.
        let readFormat: OSType = !space.isHDR ? kCVPixelFormatType_32BGRA
            : (settings.codec.isProRes ? kCVPixelFormatType_64RGBAHalf : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        let vOut = AVAssetReaderVideoCompositionOutput(videoTracks: vTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: readFormat,
            kCVPixelBufferMetalCompatibilityKey as String: true])
        vOut.videoComposition = built.videoComposition
        vOut.alwaysCopiesSampleData = false
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

        let writer = try AVAssetWriter(outputURL: url, fileType: settings.codec.isProRes ? .mov : .mp4)
        writer.shouldOptimizeForNetworkUse = !settings.codec.isProRes
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings(settings, w: w, h: h, canvas: project.settings.canvasSize, space: space))
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
        writer.startSession(atSourceTime: exportRange.start.cmTime)

        let total = exportRange.duration.seconds
        let start = exportRange.start.seconds
        let io = UncheckedSendable((reader, writer, vOut, vIn, aOut, aIn))
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { g in
                g.addTask {
                    let (_, _, vOut, vIn, _, _) = io.value
                    await pump(vOut, vIn, label: "export.video") { pts in progress?(min(1, max(0, (pts - start) / max(total, 0.001)))) }
                }
                if aOut != nil {
                    g.addTask {
                        let (_, _, _, _, aOut, aIn) = io.value
                        if let aOut, let aIn { await pump(aOut, aIn, label: "export.audio", onSample: nil) }
                    }
                }
            }
        } onCancel: {
            // Only stop the reader here: the pumps then drain and finish; the writer is cancelled below.
            io.value.0.cancelReading()
        }
        if Task.isCancelled {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw ExportError.cancelled
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw ExportError.failed(reader.error?.localizedDescription ?? "read failed")
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw ExportError.failed(writer.error?.localizedDescription ?? "write failed") }
        progress?(1)
    }

    static func videoSettings(_ s: ExportSettings, w: Int, h: Int, canvas: Size2, space: ProjectColorSpace = .sdr709) -> [String: Any] {
        var out: [String: Any] = [AVVideoWidthKey: w, AVVideoHeightKey: h]
        out[AVVideoColorPropertiesKey] = ColorTags(space).properties
        switch s.codec {
        case .h264, .hevc:
            out[AVVideoCodecKey] = s.codec == .h264 ? AVVideoCodecType.h264 : AVVideoCodecType.hevc
            var props: [String: Any] = [AVVideoAverageBitRateKey: s.videoBitrate(canvas: canvas),
                                        AVVideoExpectedSourceFrameRateKey: s.frameRate.fps,
                                        AVVideoMaxKeyFrameIntervalKey: Int(s.frameRate.fps.rounded()) * 2]
            if s.codec == .h264 { props[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
            if s.codec == .hevc && space.isHDR { props[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String }
            out[AVVideoCompressionPropertiesKey] = props
            if s.preferHardware {
                out[AVVideoEncoderSpecificationKey] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true]
            }
        case .proRes422: out[AVVideoCodecKey] = AVVideoCodecType.proRes422
        case .proRes4444: out[AVVideoCodecKey] = AVVideoCodecType.proRes4444
        }
        return out
    }

    private static func pump(_ out: AVAssetReaderOutput, _ input: AVAssetWriterInput, label: String,
                             onSample: (@Sendable (Double) -> Void)?) async {
        let io = UncheckedSendable((out, input))
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let q = DispatchQueue(label: label)
            let state = UncheckedSendable(PumpState())
            io.value.1.requestMediaDataWhenReady(on: q) {
                let (out, input) = io.value
                let st = state.value
                while input.isReadyForMoreMediaData && !st.done {
                    if let sb = out.copyNextSampleBuffer() {
                        onSample?(CMSampleBufferGetPresentationTimeStamp(sb).seconds)
                        if !input.append(sb) { st.done = true }
                    } else { st.done = true }
                    if st.done { input.markAsFinished(); cont.resume() }
                }
            }
        }
    }

    private final class PumpState { var done = false }
}
