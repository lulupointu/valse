import Testing
import Foundation
import MontageCore
import MontageEngine
import MontageTestSupport

/// FLAKY-UI2: `SyntheticMedia.writeVideo` allocates frames from its own pixel-buffer pool (the writer-owned
/// `adaptor.pixelBufferPool` was torn down under the frame loop when the encoder failed on a loaded machine: SIGSEGV in
/// CVPixelBufferPool::createPixelBuffer building the demo media). Concurrent writes still produce complete files.
@Suite struct SyntheticMediaPoolTests {
    @Test func concurrentWritesProduceCompleteFiles() async throws {
        let dir = MontagePaths.cacheDirectory.appendingPathComponent("synthetic-pool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let urls = (0..<4).map { dir.appendingPathComponent("v\($0).mp4") }
        try await withThrowingTaskGroup(of: Void.self) { g in
            for (i, u) in urls.enumerated() {
                g.addTask {
                    try await SyntheticMedia.writeVideo(to: u, size: CGSize(width: 320, height: 180), seconds: 1, fps: 30,
                                                        pattern: .solid(RGBA(Double(i) / 4, 0.5, 0.25)), audioHz: i % 2 == 0 ? 440 : nil)
                }
            }
            try await g.waitForAll()
        }
        for u in urls {
            let info = try await MediaInfo.probe(u)
            #expect(info.width == 320 && info.height == 180)
            #expect(abs(info.duration - 1) < 0.1, "\(info)")
            if let n = info.frameCount { #expect(n == 30, "\(info)") }
        }
    }
}
