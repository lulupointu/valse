@preconcurrency import AVFoundation
import Testing
import Foundation
import MontageCore
import MontageEngine
@testable import MontageAI
import MontageTestSupport

/// B1: every AVAssetReader read loop of MontageEngine / MontageAI runs its blocking `copyNextSampleBuffer` calls off
/// Swift's cooperative pool (`OffPool.run` / `OffPool.next`). Before, ~10 overlapping loops on the pool (≈ one thread
/// per core) deadlocked the process at 0 % CPU: AVFoundation needs pool threads itself to deliver the samples. This
/// runs several of each loop at once (≈ 5 × the core count); a GCD watchdog aborts with a message instead of hanging.
@Suite struct BlockingReadStressTests {
    final class Done: @unchecked Sendable {
        private let lock = NSLock(); private var v = false
        func set() { lock.withLock { v = true } }
        var isSet: Bool { lock.withLock { v } }
    }

    @Test func manyConcurrentReadLoopsFinish() async throws {
        let url = try await TestMedia.video(.movingBox(.blue, .white), seconds: 4, size: CGSize(width: 320, height: 180), audioHz: 440)
        let asset = try await MediaProbe.probe(url)
        var tp = TestProject()
        try await tp.addMedia(url)
        let project = tp.project
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("montage-b1-stress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        @Sendable func out(_ ext: String) -> URL { tmp.appendingPathComponent("\(UUID().uuidString).\(ext)") }

        typealias Job = @Sendable () async throws -> Void
        let kinds: [(String, Job)] = [
            ("frameGrabber", { _ = try await FrameGrabber.image(of: asset, at: Time(2)) }),
            ("stabilizer", { _ = try await StabilizationStore.analyze(url) }),
            ("gif", { var s = GIFSettings(); s.fps = 5; try await GIFExporter.export(project: project, settings: s, to: out("gif"), range: TimeRange(start: .zero, duration: Time(1))) }),
            ("exportCover", { var s = ExportSettings(); s.resolution = .p480; s.prependCover = true
                try await Exporter.export(project: project, settings: s, to: out("mp4"), range: TimeRange(start: Time(1), duration: Time(0.5)),
                                          options: ExportOptions(coverTime: Time(2))) }),
            ("reverse", { try await ReverseManager.generate(source: url, to: out("mov")) }),
            ("sceneCuts", { _ = try await SceneDetector.cuts(url) }),
            ("levels", { _ = try await ActivityAnalyzer.levels(url: url) }),
            ("motion", { _ = try await ActivityAnalyzer.motion(url: url) }),
            ("meanLuma", { let av = AVURLAsset(url: url)
                let t = try #require(try await av.loadTracks(withMediaType: .video).first)
                _ = try await VideoEnhancer.meanLuma(av, track: t) { _ in } }),
            ("isolatorDecode", { let u = try await VoiceIsolator.decode(url) { _ in }; try? FileManager.default.removeItem(at: u) }),
            ("wav16k", { let u = try await AudioExtractor.wav16k(url, range: nil); try? FileManager.default.removeItem(at: u) }),
            ("stemWAV", { try await StemSeparator.writeWAV(url, to: out("wav")) }),
        ]
        let perKind = max(2, ProcessInfo.processInfo.activeProcessorCount * 5 / kinds.count)
        let done = Done()
        defer { done.set() }
        let total = perKind * kinds.count
        // a Thread of its own: with the pool deadlocked GCD's global queues get no new worker either (seen: no watchdog
        // fired after 16 min on the pre-fix code)
        Thread.detachNewThread {
            let deadline = Date().addingTimeInterval(300)
            while !done.isSet, Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
            if !done.isSet { fatalError("B1 stress: \(total) concurrent read loops did not finish in 300 s (cooperative pool deadlock)") }
        }
        var finished: [String: Int] = [:]
        try await withThrowingTaskGroup(of: String.self) { g in
            for (name, job) in kinds { for _ in 0..<perKind { g.addTask { try await job(); return name } } }
            for try await name in g { finished[name, default: 0] += 1 }
        }
        for (name, _) in kinds { #expect(finished[name] == perKind, "\(name)") }
    }
}
