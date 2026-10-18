import AVFoundation
import VideoToolbox

/// Export via AVAssetReader (composition rendered by the same MetalCompositor) → AVAssetWriter
/// with hardware H.264 (VideoToolbox) + AAC.
public enum Exporter {
    public static func export(project: BuiltProject, range: CMTimeRange, to url: URL,
                              bitrate: Int = 12_000_000) async throws {
        try? FileManager.default.removeItem(at: url)
        let reader = try AVAssetReader(asset: project.composition)
        reader.timeRange = range
        let vTracks = try await project.composition.loadTracks(withMediaType: .video)
        let vOut = AVAssetReaderVideoCompositionOutput(videoTracks: vTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true])
        vOut.videoComposition = project.videoComposition
        vOut.alwaysCopiesSampleData = false
        reader.add(vOut)

        let aTracks = try await project.composition.loadTracks(withMediaType: .audio)
        var aOut: AVAssetReaderAudioMixOutput?
        if !aTracks.isEmpty {
            let o = AVAssetReaderAudioMixOutput(audioTracks: aTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false])
            o.alwaysCopiesSampleData = false
            reader.add(o); aOut = o
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 1920, AVVideoHeightKey: 1080,
            AVVideoEncoderSpecificationKey: [
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 60],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]])
        vIn.expectsMediaDataInRealTime = false
        writer.add(vIn)
        var aIn: AVAssetWriterInput?
        if aOut != nil {
            var layout = AudioChannelLayout(); layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 160_000,
                AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)])
            i.expectsMediaDataInRealTime = false
            writer.add(i); aIn = i
        }

        guard reader.startReading() else { throw reader.error ?? NSError(domain: "Montage", code: 20) }
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "Montage", code: 21) }
        writer.startSession(atSourceTime: range.start)

        await withTaskGroup(of: Void.self) { g in
            g.addTask { await pump(vOut, vIn, label: "export.video") }
            if let aOut, let aIn { g.addTask { await pump(aOut, aIn, label: "export.audio") } }
        }
        if reader.status == .failed { writer.cancelWriting(); throw reader.error! }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? NSError(domain: "Montage", code: 22) }
    }

    private static func pump(_ out: AVAssetReaderOutput, _ input: AVAssetWriterInput, label: String) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let q = DispatchQueue(label: label)
            var done = false
            input.requestMediaDataWhenReady(on: q) {
                while input.isReadyForMoreMediaData && !done {
                    if let sb = out.copyNextSampleBuffer() {
                        if !input.append(sb) { done = true }
                    } else { done = true }
                    if done { input.markAsFinished(); cont.resume() }
                }
            }
        }
    }
}
