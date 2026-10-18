@preconcurrency import AVFoundation
import Foundation
import MontageCore

/// Decoding / encoding helpers for the audio pipeline (offline render stage, analysis, recording, tests).
public enum AudioFileIO {
    public static let sampleRate: Double = 48000

    /// Streams the first audio track of `url` as Float32 non-interleaved blocks (`channels`, resampled to `sampleRate`).
    /// The stream starts at media time 0 (leading gaps are filled with silence) unless `range` is given.
    /// Returns the number of frames delivered.
    @discardableResult
    public static func stream(_ url: URL, sampleRate: Double = AudioFileIO.sampleRate, channels: Int = 2,
                              range: TimeRange? = nil, chunk: Int = 8192,
                              _ body: (AudioBlock) throws -> Void) async throws -> Int {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return 0 }
        let reader = try AVAssetReader(asset: asset)
        if let range { reader.timeRange = range.cmTimeRange }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
        out.alwaysCopiesSampleData = false
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? NSError(domain: "Montage.audio", code: 1) }
        defer { if reader.status == .reading { reader.cancelReading() } }

        let pending = AudioBuffer(channels: channels, frames: chunk, sampleRate: sampleRate)
        let table = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: channels)
        defer { table.deallocate() }
        var fill = 0, total = 0
        func flush(_ n: Int) throws {
            guard n > 0 else { return }
            for c in 0..<channels { table[c] = pending.pointer(c) }
            try body(AudioBlock(channels: channels, frames: n, pointers: table))
            total += n
        }
        func push(_ value: (Int) -> Float) throws {
            for c in 0..<channels { pending[c, fill] = value(c) }
            fill += 1
            if fill == chunk { try flush(fill); fill = 0 }
        }
        let origin = range?.start ?? .zero
        var expected = 0
        var scratch: [Float] = []
        while let sb = out.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let pts = Time(cmTime: CMSampleBufferGetPresentationTimeStamp(sb))
            let at = Int(((pts - origin).seconds * sampleRate).rounded())
            while expected < at { try push { _ in 0 }; expected += 1 }   // leading / gap silence
            let len = CMBlockBufferGetDataLength(bb)
            let count = len / 4
            if scratch.count < count { scratch = [Float](repeating: 0, count: count) }
            _ = scratch.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
            let frames = count / channels
            for i in 0..<frames { try push { scratch[i * channels + $0] } }
            expected += frames
        }
        if reader.status == .failed { throw reader.error ?? NSError(domain: "Montage.audio", code: 2) }
        try flush(fill)
        return total
    }

    /// Whole file (or range) in memory. For analysis of bounded material and tests.
    public static func read(_ url: URL, sampleRate: Double = AudioFileIO.sampleRate, channels: Int = 2, range: TimeRange? = nil) async throws -> AudioBuffer {
        var parts: [[Float]] = Array(repeating: [], count: channels)
        try await stream(url, sampleRate: sampleRate, channels: channels, range: range) { b in
            for c in 0..<channels { parts[c].append(contentsOf: UnsafeBufferPointer(start: b[c], count: b.frames)) }
        }
        return AudioBuffer(parts, sampleRate: sampleRate)
    }

    public enum Format: String, Sendable, CaseIterable {
        /// Apple Lossless in CAF (render cache, lossless & compact).
        case alac
        case wav16, wav24
        case aac
        case flac
        public var fileExtension: String {
            switch self { case .alac: "caf"; case .wav16, .wav24: "wav"; case .aac: "m4a"; case .flac: "flac" }
        }
        func settings(sampleRate: Double, channels: Int, bitrate: Int) -> [String: Any] {
            switch self {
            case .alac: return [AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels, AVEncoderBitDepthHintKey: 24]
            case .wav16, .wav24:
                return [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
                        AVLinearPCMBitDepthKey: self == .wav16 ? 16 : 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
            case .aac: return [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: bitrate]
            case .flac: return [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels, AVEncoderBitDepthHintKey: 24]
            }
        }
    }

    /// Streaming writer of Float32 blocks into an audio file.
    public final class Writer {
        var file: AVAudioFile!
        let format: AVAudioFormat
        let buffer: AVAudioPCMBuffer
        public let channels: Int
        public private(set) var framesWritten = 0

        public init(url: URL, format: Format = .alac, sampleRate: Double = AudioFileIO.sampleRate, channels: Int = 2,
                    bitrate: Int = 256_000, capacity: Int = 8192) throws {
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            self.channels = channels
            file = try AVAudioFile(forWriting: url, settings: format.settings(sampleRate: sampleRate, channels: channels, bitrate: bitrate),
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
            self.format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channels), interleaved: false)!
            buffer = AVAudioPCMBuffer(pcmFormat: self.format, frameCapacity: AVAudioFrameCount(capacity))!
        }

        public func write(_ b: AudioBlock, offset: Int = 0, count: Int? = nil) throws {
            var o = offset
            let end = offset + (count ?? (b.frames - offset))
            while o < end {
                let n = min(Int(buffer.frameCapacity), end - o)
                for c in 0..<channels {
                    let src = b[min(c, b.channels - 1)] + o
                    buffer.floatChannelData![c].update(from: src, count: n)
                }
                buffer.frameLength = AVAudioFrameCount(n)
                try file.write(from: buffer)
                o += n; framesWritten += n
            }
        }

        public func writeSilence(_ frames: Int) throws {
            var left = frames
            while left > 0 {
                let n = min(Int(buffer.frameCapacity), left)
                for c in 0..<channels { buffer.floatChannelData![c].update(repeating: 0, count: n) }
                buffer.frameLength = AVAudioFrameCount(n)
                try file.write(from: buffer)
                left -= n; framesWritten += n
            }
        }

        /// AVAudioFile finalizes on deinit; call to make that explicit.
        public func close() { if #available(macOS 15, *) { file?.close() }; file = nil }
    }

    /// Writes a whole buffer to a file.
    public static func write(_ buffer: AudioBuffer, to url: URL, format: Format = .wav16) throws {
        let w = try Writer(url: url, format: format, sampleRate: buffer.sampleRate, channels: buffer.channels)
        try w.write(buffer.block)
        w.close()
    }
}
