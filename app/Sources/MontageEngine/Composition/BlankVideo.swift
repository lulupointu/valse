@preconcurrency import AVFoundation
import CoreVideo
import Foundation
import MontageCore

/// A 1-second black 64×64 H.264 file used as the composition's base track (generated once into the cache).
enum BlankVideo {
    private static let task = Task<URL, any Error> { try await generate() }

    static func url() async throws -> URL { try await task.value }

    private static func generate() async throws -> URL {
        let dir = MontagePaths.cacheDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("blank-v1.mp4")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let tmp = dir.appendingPathComponent("blank-\(UUID().uuidString).mp4")
        try await SyntheticMedia.writeVideo(to: tmp, size: CGSize(width: 64, height: 64), seconds: 1, fps: 30,
                                            codec: .h264, audioHz: nil) { _, _ in (0, 0, 0) }
        if !FileManager.default.fileExists(atPath: url.path) { try FileManager.default.moveItem(at: tmp, to: url) }
        return url
    }
}
