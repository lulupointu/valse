@preconcurrency import AVFoundation
import Foundation
import ValseCore

/// Export audio at the mix rate (BUG-SPLIT-AUDIO-FLAKE): an audio stream that is not at 48 kHz (iPhone / camera AAC at
/// 44.1 kHz) is decoded once at its own rate, resampled by `StreamResampler` and cached as a 48 kHz ALAC file that
/// the export composition reads in place of the original. Left to AVAssetReaderAudioMixOutput, the 44.1 → 48 kHz
/// conversion sometimes restarted at an AAC packet boundary and left ~0.3 ms of silence in the export (a click, at a
/// different place on each export of the same project: see `StreamResampler`). The file keeps the media timeline:
/// sample 0 = media time 0, same length.
///
/// ~/Library/Caches/Valse/audio/conform-<content hash>[~variant]-s<stream>-v1.caf (cache category `audio`: purged /
/// size-limited by CacheManager). Also read by the reversed render (ReverseManager). Preview keeps reading the original:
/// AVPlayer decodes at the file's rate and converts to the device rate after the mix, and measured no dropout in 40
/// plays while the pre-fix reader showed it in 9 % of reads under the same load (PreviewResampleProbeTests,
/// BUG-AUDIO-RESAMPLE-ALL).
public actor AudioConform {
    public static let shared = AudioConform()
    static let version = 1

    let directory: URL
    private var inflight: [String: Task<URL, Error>] = [:]

    init(directory: URL = ValsePaths.cacheDirectory.appendingPathComponent("audio", isDirectory: true)) {
        self.directory = directory
    }

    /// `source` itself when its stream `streamIndex` is already at `AudioFileIO.sampleRate` (or has no audio), else the
    /// conformed copy (rendered on first use; concurrent calls share one render).
    public func conformed(_ source: URL, asset: MediaAsset, streamIndex: Int?) async throws -> URL {
        var key = asset.contentHash.isEmpty ? Self.hash(source.standardizedFileURL.path) : asset.contentHash
        if source.standardizedFileURL != asset.url.standardizedFileURL { key += "~" + Self.hash(source.lastPathComponent) }
        return try await conformed(source, key: key, streamIndex: streamIndex)
    }

    /// Same, cached under `key` (the source's content hash, or any key that changes with its content).
    public func conformed(_ source: URL, key contentKey: String, streamIndex: Int?) async throws -> URL {
        let index = streamIndex ?? 0
        let file = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks = try await file.loadTracks(withMediaType: .audio)
        guard let track = tracks.indices.contains(index) ? tracks[index] : tracks.first,
              let rate = try await AudioFileIO.nativeSampleRate(track),
              abs(rate - AudioFileIO.sampleRate) > 0.01 else { return source }
        let key = "conform-\(contentKey.isEmpty ? Self.hash(source.standardizedFileURL.path) : contentKey)-s\(index)-v\(Self.version)"
        let dst = directory.appendingPathComponent("\(key).caf")
        if let size = try? FileManager.default.attributesOfItem(atPath: dst.path)[.size] as? Int, size > 0 { return dst }
        if let t = inflight[key] { return try await t.value }
        let dir = directory
        let t = Task.detached(priority: .userInitiated) { () throws -> URL in
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let tmp = dir.appendingPathComponent("tmp-\(UUID().uuidString).caf")
            do {
                let w = try AudioFileIO.Writer(url: tmp, format: .alac, sampleRate: AudioFileIO.sampleRate, channels: 2)
                try await AudioFileIO.stream(source, trackIndex: index) { try w.write($0) }
                w.close()
                try? FileManager.default.removeItem(at: dst)
                try FileManager.default.moveItem(at: tmp, to: dst)
            } catch {
                try? FileManager.default.removeItem(at: tmp)
                throw error
            }
            return dst
        }
        inflight[key] = t
        defer { inflight[key] = nil }
        return try await t.value
    }

    static func hash(_ s: String) -> String {
        String(s.utf8.reduce(UInt64(0xcbf29ce484222325)) { ($0 ^ UInt64($1)) &* 0x100000001b3 }, radix: 16)
    }
}
