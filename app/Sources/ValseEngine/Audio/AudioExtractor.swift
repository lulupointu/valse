@preconcurrency import AVFoundation
import Foundation
import ValseCore

/// "Extract audio" from a video FILE (AU-003): the first audio track → .m4a (AAC passthrough when possible, else
/// re-encoded at 256 kbps).
public enum AudioExtractor {
    public enum Failure: Error { case noAudio, exportFailed(String) }

    public static func extract(from source: URL, to dst: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { throw Failure.noAudio }
        try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dst)
        // decode → AAC: works for every codec AVFoundation reads (passthrough would fail on e.g. PCM-in-MOV)
        let w = try AudioFileIO.Writer(url: dst, format: .aac, sampleRate: AudioFileIO.sampleRate, channels: 2, bitrate: 256_000)
        do {
            try await AudioFileIO.stream(source) { try w.write($0) }
        } catch {
            w.close(); try? FileManager.default.removeItem(at: dst); throw error
        }
        w.close()
    }
}
