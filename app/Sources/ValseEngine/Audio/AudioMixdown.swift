@preconcurrency import AVFoundation
import Foundation
import ValseCore

/// Offline render of a project's mixed audio through EXACTLY the export path (CompositionBuilder `.export` +
/// AVAssetReaderAudioMixOutput with the same audio mix and taps). Used by audio-only export and by tests.
public enum AudioMixdown {
    /// Streams the mix as 48 kHz stereo Float32 blocks. Returns frames delivered.
    @discardableResult
    /// `audioState`: the lanes' shared state (tests read `tapCapture` / `tapObserver` through it).
    public static func stream(_ project: Project, range: TimeRange? = nil, chunk: Int = 8192, audioState: AudioMixState? = nil,
                              _ body: (AudioBlock) throws -> Void) async throws -> Int {
        let built = try await CompositionBuilder.build(project: project, purpose: .export, audioState: audioState, conformsAudio: true)
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
                // read past the range's end (what is past it is dropped by `push`): the stretcher delivers a stretched
                // clip's last ~0.1 s only once it has read beyond them (FLAKY-PB2)
                reader.timeRange = Exporter.audioReadRange(r, composition: built.composition)
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
                    // BUG-ECHO-EXPORT-SILENT: the mix output skips ahead when a lane tap's first callback is slow
                    // (LiveProcessor doc); the gap is padded with silence, log it so a skipped export is visible.
                    if at - expected > 2400 {
                        EngineLog.error(String(format: "audio mixdown: reader output jumped %.3f s at %.3f s (gap padded with silence)",
                                               Double(at - expected) / sr, Double(expected) / sr))
                    }
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
    public static func render(_ project: Project, range: TimeRange? = nil, audioState: AudioMixState? = nil) async throws -> AudioBuffer {
        var l: [Float] = [], r: [Float] = []
        try await stream(project, range: range, audioState: audioState) { b in
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
    /// Media read past an export range's end by the audio reader (the samples there are dropped).
    static let audioReadTail = Time(0.5)

    /// Time range the audio reader of an export / mixdown of `range` reads: the range plus `audioReadTail`, within the
    /// composition (FLAKY-PB2). A reader stopped at the range's end cut the time-pitch stretcher off before it delivered a
    /// stretched clip's last 20-120 ms (spectral: it outputs a block only once it has read past it), so a sped-up or
    /// slowed clip ending the project faded / went silent early in the file, at 0.5× its whole last ~0.12 s. The clip's
    /// tail pad (`CompositionBuilder.packAudio`, silenced by the lane gains) is what the stretcher reads there.
    static func audioReadRange(_ range: TimeRange, composition: AVComposition) -> CMTimeRange {
        let d = composition.duration
        let end = d.isNumeric ? min(range.end + audioReadTail, max(range.end, Time(cmTime: d))) : range.end
        return TimeRange(start: range.start, end: end).cmTimeRange
    }

    /// Float32 interleaved stereo 48 kHz, used for offline mixdowns.
    static var mixPCMSettings: [String: Any] { [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false] }
}
