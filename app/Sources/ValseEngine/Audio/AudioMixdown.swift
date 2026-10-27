@preconcurrency import AVFoundation
import Foundation
import ValseCore

/// Offline render of a project's mixed audio through EXACTLY the export path (CompositionBuilder `.export` +
/// AVAssetReaderAudioMixOutput with the same audio mix and taps). Used by audio-only export and by tests.
public enum AudioMixdown {
    /// Streams the mix as 48 kHz stereo Float32 blocks. Returns frames delivered.
    @discardableResult
    public static func stream(_ project: Project, range: TimeRange? = nil, chunk: Int = 8192,
                              _ body: (AudioBlock) throws -> Void) async throws -> Int {
        let built = try await CompositionBuilder.build(project: project, purpose: .export)
        let tracks = try await built.composition.loadTracks(withMediaType: .audio)
        // the read loop blocks in copyNextSampleBuffer: keep it off the cooperative pool (OffPool)
        return try await OffPool.run { ctx in
            let full = TimeRange(start: .zero, duration: project.duration)
            let r = range.flatMap { $0.intersection(full) } ?? full
            let sr = AudioFileIO.sampleRate
            let totalFrames = Int((r.duration.seconds * sr).rounded())
            let out = AudioBuffer(channels: 2, frames: chunk, sampleRate: sr)
            let table = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 2)
            defer { table.deallocate() }
            table[0] = out.pointer(0); table[1] = out.pointer(1)
            var fill = 0, delivered = 0
            func push(_ l: Float, _ rr: Float) throws {
                guard delivered + fill < totalFrames else { return }
                out[0, fill] = l; out[1, fill] = rr; fill += 1
                if fill == chunk { try body(AudioBlock(channels: 2, frames: fill, pointers: table)); delivered += fill; fill = 0 }
            }
            var expected = 0
            if !tracks.isEmpty {
                let reader = try AVAssetReader(asset: built.composition)
                reader.timeRange = r.cmTimeRange
                let o = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: Exporter.mixPCMSettings)
                o.audioMix = built.audioMix
                o.audioTimePitchAlgorithm = .spectral
                reader.add(o)
                guard reader.startReading() else { throw reader.error ?? NSError(domain: "Valse.audio", code: 3) }
                var scratch: [Float] = []
                while let sb = o.copyNextSampleBuffer() {
                    try ctx.checkCancellation()
                    guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
                    let at = Int(((Time(cmTime: CMSampleBufferGetPresentationTimeStamp(sb)) - r.start).seconds * sr).rounded())
                    while expected < at { try push(0, 0); expected += 1 }
                    let len = CMBlockBufferGetDataLength(bb)
                    if scratch.count < len / 4 { scratch = [Float](repeating: 0, count: len / 4) }
                    _ = scratch.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
                    let n = len / 8
                    for i in 0..<n { try push(scratch[2 * i], scratch[2 * i + 1]) }
                    expected += n
                }
                if reader.status == .failed { throw reader.error ?? NSError(domain: "Valse.audio", code: 4) }
            }
            // pad to the exact range length (silent tail / no audio)
            while delivered + fill < totalFrames { try push(0, 0) }
            if fill > 0 { try body(AudioBlock(channels: 2, frames: fill, pointers: table)); delivered += fill }
            return delivered
        }
    }

    /// Whole mix in memory (tests, short projects).
    public static func render(_ project: Project, range: TimeRange? = nil) async throws -> AudioBuffer {
        var l: [Float] = [], r: [Float] = []
        try await stream(project, range: range) { b in
            l.append(contentsOf: UnsafeBufferPointer(start: b[0], count: b.frames))
            r.append(contentsOf: UnsafeBufferPointer(start: b[1], count: b.frames))
        }
        return AudioBuffer([l, r], sampleRate: AudioFileIO.sampleRate)
    }
}

/// Audio-only export (AU-022 / EX-009): WAV 16/24-bit, AAC, FLAC, ALAC.
public struct AudioExportSettings: Sendable, Hashable {
    public var format: AudioFileIO.Format = .aac
    /// AAC bitrate (192 / 256 / 320 kbps). Mixes are rendered at 48 kHz.
    public var bitrateKbps: Int = 256
    public init(format: AudioFileIO.Format = .aac, bitrateKbps: Int = 256) {
        self.format = format; self.bitrateKbps = bitrateKbps
    }
}

public enum AudioExporter {
    public static func export(project: Project, settings: AudioExportSettings = AudioExportSettings(), to url: URL,
                              range: TimeRange? = nil, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard project.duration > .zero else { throw ExportError.emptyProject }
        let w = try AudioFileIO.Writer(url: url, format: settings.format, sampleRate: 48000, channels: 2,
                                       bitrate: settings.bitrateKbps * 1000)
        let total = max(1, (range?.duration ?? project.duration).seconds * 48000)
        var done = 0
        do {
            try await AudioMixdown.stream(project, range: range) { b in
                try w.write(b); done += b.frames; progress?(min(1, Double(done) / total))
            }
        } catch {
            w.close(); try? FileManager.default.removeItem(at: url)
            throw (error is CancellationError) ? ExportError.cancelled : error
        }
        w.close()
        progress?(1)
    }
}

extension Exporter {
    /// Float32 interleaved stereo 48 kHz, used for offline mixdowns.
    static var mixPCMSettings: [String: Any] { [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false] }
}
