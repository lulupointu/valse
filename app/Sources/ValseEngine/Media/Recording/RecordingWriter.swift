@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// Writes captured sample buffers (screen / camera video + microphone audio) to a movie file (MI-015 / MI-017).
///
/// - The writer is configured lazily on the first video frame (its pixel size sets the H.264 output size, even, ≤ 4K
///   long side kept as is), the session starts at that frame; audio arriving before it is dropped.
/// - Pause / resume: samples whose time falls in a paused interval are dropped and later samples are shifted back by
///   the total paused time, so the file plays continuously. Times are in the capture clock (host time for
///   ScreenCaptureKit and AVCaptureSession).
/// - Thread-safe: capture callbacks may arrive on different queues.
public final class RecordingWriter: @unchecked Sendable {
    public enum WriterError: Error, Equatable { case noFrames, failed(String) }

    public let url: URL
    public let recordsAudio: Bool
    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var started = false
    private var finished = false
    private var pausedAt: CMTime?
    private var pausedIntervals: [(CMTime, CMTime)] = []
    private var offset = CMTime.zero
    private var lastVideoPTS = CMTime.invalid
    /// Frames / audio buffers written (tests, UI).
    public private(set) var videoFrames = 0
    public private(set) var audioBuffers = 0

    /// `realTime` (capture): a frame arriving while the encoder is busy is dropped. Offline (tests, imports): wait.
    public let realTime: Bool

    public init(url: URL, recordsAudio: Bool, realTime: Bool = true) {
        self.url = url; self.recordsAudio = recordsAudio; self.realTime = realTime
    }

    private func ready(_ input: AVAssetWriterInput) -> Bool {
        if realTime || input.isReadyForMoreMediaData { return input.isReadyForMoreMediaData }
        for _ in 0..<500 where !input.isReadyForMoreMediaData { usleep(2000) }
        return input.isReadyForMoreMediaData
    }

    /// Duration recorded so far (excluding pauses), seconds.
    public var recordedSeconds: Double {
        lock.withLock { firstPTS.isValid && lastVideoPTS.isValid ? max(0, (lastVideoPTS - firstPTS).seconds) : 0 }
    }
    private var firstPTS = CMTime.invalid

    public var isPaused: Bool { lock.withLock { pausedAt != nil } }

    public func pause(at t: CMTime = CMClockGetTime(CMClockGetHostTimeClock())) {
        lock.withLock { if pausedAt == nil { pausedAt = t } }
    }

    public func resume(at t: CMTime = CMClockGetTime(CMClockGetHostTimeClock())) {
        lock.withLock {
            guard let p = pausedAt else { return }
            pausedIntervals.append((p, t))
            if started { offset = offset + (t - p) }
            pausedAt = nil
        }
    }

    public func appendVideo(_ sb: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !finished, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        guard !isDropped(pts) else { return }
        if !started {
            guard setUp(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb), format: CMSampleBufferGetFormatDescription(sb)) else { return }
            writer?.startSession(atSourceTime: pts)
            firstPTS = pts
            started = true
            // pauses before the first frame don't shift anything
            offset = .zero
        }
        guard let input = videoInput, ready(input), let out = retimed(sb) else { return }
        let t = CMSampleBufferGetPresentationTimeStamp(out)
        if lastVideoPTS.isValid, t <= lastVideoPTS { return }   // monotonic
        if input.append(out) { videoFrames += 1; lastVideoPTS = t }
    }

    public func appendAudio(_ sb: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !finished, started, recordsAudio, let input = audioInput else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        guard !isDropped(pts), pts >= firstPTS, ready(input), let out = retimed(sb) else { return }
        if input.append(out) { audioBuffers += 1 }
    }

    /// Closes the file. Throws `.noFrames` (and deletes the file) when nothing was captured.
    public func finish() async throws -> URL {
        let w: AVAssetWriter? = lock.withLock {
            finished = true
            videoInput?.markAsFinished(); audioInput?.markAsFinished()
            return started ? writer : nil
        }
        guard let w else {
            writer?.cancelWriting(); try? FileManager.default.removeItem(at: url)
            throw WriterError.noFrames
        }
        let box = UncheckedWriter(w)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in box.writer.finishWriting { c.resume() } }
        if w.status != .completed { throw WriterError.failed(w.error?.localizedDescription ?? "status \(w.status.rawValue)") }
        return url
    }

    /// Cancels and deletes the partial file.
    public func cancel() {
        lock.withLock { finished = true; writer?.cancelWriting() }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Private (lock held)

    private func isDropped(_ t: CMTime) -> Bool {
        if let p = pausedAt, t >= p { return true }
        return pausedIntervals.contains { t >= $0.0 && t < $0.1 }
    }

    /// Output size: even dimensions (H.264 needs them).
    static func outputSize(width: Int, height: Int) -> (Int, Int) { (max(2, width / 2 * 2), max(2, height / 2 * 2)) }

    private func setUp(width: Int, height: Int, format: CMFormatDescription?) -> Bool {
        do {
            try? FileManager.default.removeItem(at: url)
            let w = try AVAssetWriter(outputURL: url, fileType: .mov)
            let (ow, oh) = Self.outputSize(width: width, height: height)
            let bitrate = max(4_000_000, Int(Double(ow * oh) * 30 * 0.15))
            let v = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: ow, AVVideoHeightKey: oh,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate, AVVideoMaxKeyFrameIntervalKey: 60,
                                                  AVVideoAllowFrameReorderingKey: false],
            ])
            v.expectsMediaDataInRealTime = true
            guard w.canAdd(v) else { return false }
            w.add(v)
            if recordsAudio {
                var layout = AudioChannelLayout(); layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
                let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 160_000, AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)])
                a.expectsMediaDataInRealTime = true
                if w.canAdd(a) { w.add(a); audioInput = a }
            }
            guard w.startWriting() else { return false }
            writer = w; videoInput = v
            return true
        } catch {
            EngineLog.error("recording writer: \(error)")
            return false
        }
    }

    private func retimed(_ sb: CMSampleBuffer) -> CMSampleBuffer? {
        guard offset != .zero else { return sb }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: max(count, 1))
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for i in timing.indices {
            if timing[i].presentationTimeStamp.isValid { timing[i].presentationTimeStamp = timing[i].presentationTimeStamp - offset }
            if timing[i].decodeTimeStamp.isValid { timing[i].decodeTimeStamp = timing[i].decodeTimeStamp - offset }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: count,
                                              sampleTimingArray: &timing, sampleBufferOut: &out)
        return out
    }
}

private struct UncheckedWriter: @unchecked Sendable { let writer: AVAssetWriter; init(_ w: AVAssetWriter) { writer = w } }
