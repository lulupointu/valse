@preconcurrency import AVFoundation
import Foundation
import Testing
import ValseCore
import ValseEngine
import ValseTestSupport

/// A user's cancel of an export whose read is stuck inside AVFoundation (copyNextSampleBuffer never returning) must not
/// hang: the export is abandoned at once (cancelled, partial file removed) and its reader stays parked — never freed or
/// cancelled while being read — until the copy returns; then it is cancelled and released (DX-C, ReaderCancel).
@Suite struct ExportCancelTests {
    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var copies = 0, isBlocked = false
        func copy() -> Int { lock.withLock { copies += 1; return copies } }
        func markBlocked() { lock.withLock { isBlocked = true } }
        var blocked: Bool { lock.withLock { isBlocked } }
    }

    @Test func userCancelAbandonsAStuckReadAndReleasesItAfterTheCopyReturns() async throws {
        var p = TestProject()
        try await p.addVideo(.movingBox(.red, .white), seconds: 3, audioHz: 440)
        var s = ExportSettings(); s.resolution = .p480
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("valse-cancel-\(UUID().uuidString).\(s.fileExtension)")
        let gate = DispatchSemaphore(value: 0), box = Box()
        // the 5th video read of THIS export blocks (a stuck AVFoundation read) until the test releases it
        Exporter.testWillCopy = { id, label in
            guard id == url.path, label == "export.video", box.copy() == 5 else { return }
            box.markBlocked(); gate.wait()
        }
        defer { Exporter.testWillCopy = nil }
        let project = p.project
        let task = Task { try await Exporter.export(project: project, settings: s, to: url) }
        for _ in 0..<600 where !box.blocked { try await Task.sleep(for: .milliseconds(50)) }   // hang bound 30 s
        try #require(box.blocked, "the injected read never blocked")

        let t0 = Date()
        task.cancel()
        await #expect(throws: ExportError.cancelled) { try await task.value }
        let dt = Date().timeIntervalSince(t0)
        #expect(dt < 1, "cancel took \(dt) s with a stuck read")
        #expect(!FileManager.default.fileExists(atPath: url.path), "partial output left behind")
        #expect(ParkedReaders.shared.isParked(url.path), "the stuck reader must stay parked while it is being read")
        #expect(!ParkedReaders.shared.wasCleanedUp(url.path), "nothing may cancel / release it before its copy returns")

        gate.signal()   // the stuck copy returns
        for _ in 0..<600 where !ParkedReaders.shared.wasCleanedUp(url.path) { try await Task.sleep(for: .milliseconds(50)) }
        #expect(ParkedReaders.shared.wasCleanedUp(url.path), "the abandoned reader was not cancelled after its copy returned")
        #expect(!ParkedReaders.shared.isParked(url.path))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
