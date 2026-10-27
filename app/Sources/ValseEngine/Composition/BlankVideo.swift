@preconcurrency import AVFoundation
import CoreVideo
import Foundation
import ValseCore

/// A black 64×64 H.264 file (`seconds` long, 1 fps, every frame a key frame) used as the composition's base track
/// (generated once into the cache). The base track tiles it, unscaled, over the project (`CompositionBuilder.addBase`).
enum BlankVideo {
    static let seconds = 60
    private static let task = Task<URL, any Error> { try await generate() }

    static func url() async throws -> URL { try await task.value }

    private static func generate() async throws -> URL {
        let dir = ValsePaths.cacheDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("blank-v2-\(seconds)s.mp4")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let tmp = dir.appendingPathComponent("blank-\(UUID().uuidString).mp4")
        try await SyntheticMedia.writeVideo(to: tmp, size: CGSize(width: 64, height: 64), seconds: Double(seconds), fps: 1,
                                            codec: .h264, audioHz: nil) { _, _ in (0, 0, 0) }
        if !FileManager.default.fileExists(atPath: url.path) { try FileManager.default.moveItem(at: tmp, to: url) }
        else { try? FileManager.default.removeItem(at: tmp) }
        return url
    }
}
