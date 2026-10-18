@preconcurrency import AVFoundation
import Foundation
import MontageCore

/// Background "reversed render" of a media file (CapCut Edit ▸ Reverse), used by `CompositionBuilder` for clips with
/// `reversed == true` in preview AND export (one code path, frame-exact).
///
/// File: `~/Library/Caches/Montage/reversed/<contentHash>.mov` — H.264 (high bitrate, GOP 15, no B-frames: cheap random
/// access) at the source resolution, carrying the source's preferredTransform, plus the audio reversed as 16-bit LPCM
/// (no AAC priming offsets, sample exact). Time mapping: original media time `s` ↔ reversed file time `D − s`
/// (D = media duration), so original frame [p, p+d) is reversed frame [D−p−d, D−p).
///
/// Generation streams backwards in chunks (bounded memory: ≤ ~200 MB of decoded frames whatever the resolution) and
/// interleaves video and audio appends, so it works for long 4K clips on 8 GB machines.
public final class ReverseManager: @unchecked Sendable {
    public static let shared = ReverseManager()

    public let directory: URL
    private let lock = NSLock()
    private var ready: Set<String> = []
    private var pending: [String: JobID] = [:]
    /// Main actor: a reversed render finished (argument = content hash).
    @MainActor public var onReady: ((String) -> Void)?

    init() {
        directory = MontagePaths.cacheDirectory.appendingPathComponent("reversed", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        ready = Set(files.filter { $0.hasSuffix(".mov") && !$0.hasPrefix("tmp-") }.map { String($0.dropLast(4)) })
    }

    public func reversedURL(for a: MediaAsset) -> URL { reversedURL(key: a.contentHash) }
    public func reversedURL(key: String) -> URL { directory.appendingPathComponent("\(key).mov") }

    /// Ready reversed file, if any (synchronous; used while building compositions).
    public func readyURL(for a: MediaAsset) -> URL? { readyURL(key: a.contentHash) }

    /// `key` = content hash of the source (media hash, or "<hash>-matte-<kind>" for mattes).
    public func readyURL(key: String) -> URL? {
        let ok = lock.withLock { ready.contains(key) }
        guard ok else { return nil }
        let url = reversedURL(key: key)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        lock.withLock { _ = ready.remove(key) }
        return nil
    }

    public func pendingJob(for a: MediaAsset) -> JobID? { lock.withLock { pending[a.contentHash] } }

    /// Queues the reversed render (idempotent). Returns the job id, or nil if already available.
    @discardableResult
    public func request(_ a: MediaAsset, subject: String? = nil) async -> JobID? {
        await request(source: a.url, key: a.contentHash, detail: a.name, subject: subject)
    }

    @discardableResult
    public func request(source src: URL, key: String, detail: String = "", subject: String? = nil) async -> JobID? {
        if readyURL(key: key) != nil { return nil }
        if let j = lock.withLock({ pending[key] }) { return j }
        let dst = reversedURL(key: key)
        let id = await JobQueue.shared.enqueue(titleKey: "job.reverse", detail: detail, priority: 1, subject: subject ?? key) { progress in
            try await ReverseManager.generate(source: src, to: dst, progress: progress)
        }
        lock.withLock { pending[key] = id }
        Task {
            let state = await JobQueue.shared.wait(id)
            self.lock.withLock { self.pending[key] = nil }
            if state == .done {
                self.lock.withLock { _ = self.ready.insert(key) }
                await MainActor.run { self.onReady?(key) }
            }
        }
        return id
    }

    /// Waits for (or produces) the reversed file. Used by export so a reversed clip never exports forwards.
    public func ensure(_ a: MediaAsset) async throws -> URL { try await ensure(source: a.url, key: a.contentHash, detail: a.name) }

    public func ensure(source: URL, key: String, detail: String = "") async throws -> URL {
        if let u = readyURL(key: key) { return u }
        guard let id = await request(source: source, key: key, detail: detail) else { return reversedURL(key: key) }
        let state = await JobQueue.shared.wait(id)
        if state == .done { lock.withLock { _ = ready.insert(key) } }   // the request's own bookkeeping may lag
        if let u = readyURL(key: key) { return u }
        if state == .cancelled { throw CancellationError() }
        if case .failed(let why) = state { throw MediaProbeError.unreadable(source, "reverse failed: \(why)") }
        throw MediaProbeError.unreadable(source, "reverse failed")
    }

    public func deleteAll() {
        lock.withLock { ready.removeAll() }
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: Generation

    /// Writes the reversed version of `source` to `dst` (atomic: temp file + rename).
    public static func generate(source: URL, to dst: URL, progress: JobProgress? = nil) async throws {
        let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await asset.load(.duration)
        let vTrack = try await asset.loadTracks(withMediaType: .video).first
        let aTrack = try await asset.loadTracks(withMediaType: .audio).first
        guard vTrack != nil || aTrack != nil else { throw MediaProbeError.unsupported(source) }

        let tmp = dst.deletingLastPathComponent().appendingPathComponent("tmp-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: tmp, fileType: .mov)
        var video: VideoReverser?
        var audio: AudioReverser?
        if let vTrack {
            let (natural, transform, rate) = try await vTrack.load(.naturalSize, .preferredTransform, .nominalFrameRate)
            let w = max(2, Int(natural.width) / 2 * 2), h = max(2, Int(natural.height) / 2 * 2)
            let fps = max(Double(rate), 1)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(4_000_000, Int(Double(w * h) * fps * 0.3)),
                                                  AVVideoMaxKeyFrameIntervalKey: 15,
                                                  AVVideoAllowFrameReorderingKey: false,
                                                  AVVideoExpectedSourceFrameRateKey: fps]])
            input.transform = transform
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
            let frameBytes = Double(w * h) * 1.5
            let chunkFrames = Int(min(120, max(8, 200_000_000 / frameBytes)))
            video = VideoReverser(asset: asset, track: vTrack, duration: duration, input: input, adaptor: adaptor,
                                  chunk: CMTime(seconds: Double(chunkFrames) / fps, preferredTimescale: 600))
        }
        if let aTrack {
            var layout = AudioChannelLayout(); layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audio = AudioReverser(asset: asset, track: aTrack, duration: duration, input: input)
        }
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "Montage", code: 80) }
        writer.startSession(atSourceTime: .zero)

        do {
            // Interleave: append whichever input is ready; refill each stream's reversed chunk lazily.
            while true {
                try Task.checkCancellation()
                var progressed = false
                if let v = video, !v.finished, v.input.isReadyForMoreMediaData {
                    try v.appendNext(); progressed = true
                    progress?.report(v.progress)
                }
                if let a = audio, !a.finished, a.input.isReadyForMoreMediaData {
                    try a.appendNext(); progressed = true
                    if video == nil { progress?.report(a.progress) }
                }
                if (video?.finished ?? true) && (audio?.finished ?? true) { break }
                if !progressed { try await Task.sleep(nanoseconds: 1_000_000) }
            }
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? NSError(domain: "Montage", code: 81) }
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.moveItem(at: tmp, to: dst)
    }
}

/// Streams video frames of a track in reverse: decodes [chunkStart, chunkEnd) forwards, then hands frames out last→first.
private final class VideoReverser {
    let asset: AVAsset, track: AVAssetTrack, duration: CMTime
    let input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor
    let chunk: CMTime
    private var chunkEnd: CMTime
    /// Smallest PTS already emitted (exclusive upper bound of the next chunk's frames).
    private var upper: CMTime
    private var buffered: [(pts: CMTime, pb: CVPixelBuffer)] = []
    private(set) var finished = false

    init(asset: AVAsset, track: AVAssetTrack, duration: CMTime, input: AVAssetWriterInput,
         adaptor: AVAssetWriterInputPixelBufferAdaptor, chunk: CMTime) {
        self.asset = asset; self.track = track; self.duration = duration; self.input = input; self.adaptor = adaptor
        self.chunk = chunk; chunkEnd = duration; upper = duration
    }

    var progress: Double { 1 - max(0, chunkEnd.seconds) / max(duration.seconds, 0.001) }

    func appendNext() throws {
        if buffered.isEmpty { try refill() }
        guard let f = buffered.popLast() else { finish(); return }
        // original frame [pts, upper) → reversed [D − upper, D − pts)
        let out = CMTimeSubtract(duration, upper)
        upper = f.pts
        if !adaptor.append(f.pb, withPresentationTime: out) { throw NSError(domain: "Montage", code: 82) }
        if buffered.isEmpty && chunkEnd <= .zero { finish() }
    }

    private func finish() { if !finished { finished = true; input.markAsFinished() } }

    private func refill() throws {
        while buffered.isEmpty && chunkEnd > .zero {
            let start = CMTimeMaximum(.zero, CMTimeSubtract(chunkEnd, chunk))
            let reader = try AVAssetReader(asset: asset)
            // read a little past the start so the frame straddling `start` is included
            reader.timeRange = CMTimeRange(start: start, end: chunkEnd)
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()])
            out.alwaysCopiesSampleData = false
            reader.add(out)
            guard reader.startReading() else { throw reader.error ?? NSError(domain: "Montage", code: 83) }
            var frames: [(CMTime, CVPixelBuffer)] = []
            while let sb = out.copyNextSampleBuffer() {
                guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
                let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                // keep frames strictly below what we already emitted, and not belonging to the previous chunk
                if pts < upper && (pts >= start || start == .zero) { frames.append((pts, pb)) }
            }
            if reader.status == .failed { throw reader.error ?? NSError(domain: "Montage", code: 84) }
            frames.sort { $0.0 < $1.0 }
            // frames before `start` (only when start == 0) are kept; drop duplicates
            var seen = Set<Int64>()
            buffered = frames.filter { seen.insert(CMTimeConvertScale($0.0, timescale: 90000, method: .roundHalfAwayFromZero).value).inserted }
                .map { (pts: $0.0, pb: $0.1) }
            chunkEnd = start
        }
    }
}

/// Streams 48 kHz stereo 16-bit PCM in reverse, chunk by chunk.
private final class AudioReverser {
    let asset: AVAsset, track: AVAssetTrack, duration: CMTime
    let input: AVAssetWriterInput
    private let chunkSamples: Int64 = 48000 * 2
    private let totalSamples: Int64
    private var chunkEnd: Int64
    private(set) var finished = false

    init(asset: AVAsset, track: AVAssetTrack, duration: CMTime, input: AVAssetWriterInput) {
        self.asset = asset; self.track = track; self.duration = duration; self.input = input
        totalSamples = Int64((duration.seconds * 48000).rounded())
        chunkEnd = totalSamples
    }

    var progress: Double { 1 - Double(chunkEnd) / Double(max(totalSamples, 1)) }

    func appendNext() throws {
        guard chunkEnd > 0 else { finish(); return }
        let start = max(0, chunkEnd - chunkSamples)
        let count = Int(chunkEnd - start)
        var pcm = [Int16](repeating: 0, count: count * 2)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(value: start, timescale: 48000), end: CMTime(value: chunkEnd, timescale: 48000))
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false])
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? NSError(domain: "Montage", code: 85) }
        while let sb = out.copyNextSampleBuffer() {
            let pts = CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sb), timescale: 48000, method: .roundHalfAwayFromZero).value
            let n = CMSampleBufferGetNumSamples(sb)
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            var tmp = [Int16](repeating: 0, count: n * 2)
            tmp.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: min($0.count, CMBlockBufferGetDataLength(block)), destination: $0.baseAddress!) }
            for i in 0..<n {
                let k = pts + Int64(i) - start
                guard k >= 0, k < Int64(count) else { continue }
                pcm[Int(k) * 2] = tmp[i * 2]; pcm[Int(k) * 2 + 1] = tmp[i * 2 + 1]
            }
        }
        // reverse frames (keep L/R)
        var rev = [Int16](repeating: 0, count: count * 2)
        for i in 0..<count { rev[i * 2] = pcm[(count - 1 - i) * 2]; rev[i * 2 + 1] = pcm[(count - 1 - i) * 2 + 1] }
        let outStart = totalSamples - chunkEnd
        guard let sb = Self.sampleBuffer(rev, start: outStart, count: count) else { throw NSError(domain: "Montage", code: 86) }
        if !input.append(sb) { throw NSError(domain: "Montage", code: 87) }
        chunkEnd = start
        if chunkEnd <= 0 { finish() }
    }

    private func finish() { if !finished { finished = true; input.markAsFinished() } }

    static func sampleBuffer(_ samples: [Int16], start: Int64, count: Int) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                               mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
                                               mBitsPerChannel: 16, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
        var block: CMBlockBuffer?
        let bytes = count * 4
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block)
        guard let block, let fmt else { return nil }
        samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: fmt,
                                                             sampleCount: count, presentationTimeStamp: CMTime(value: start, timescale: 48000),
                                                             packetDescriptions: nil, sampleBufferOut: &sb)
        return sb
    }
}
