import Testing
import Foundation
import ValseCore
import ValseEngine
@testable import ValseUI
import ValseTestSupport

/// "Stop export" really stops the job (the cancel used to stop only the outer task, the export ran to the end) and
/// removes its partial files; "Pack project" reports progress and can be cancelled without leaving a package behind.
@MainActor @Suite(.serialized) struct ExportStopAndPackTests {
    init() { EngineResources.register(); UIResources.register() }

    func tempDir(_ tag: String) throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func stopCancelsARunningExportAndDeletesItsFiles() async throws {
        var p = TestProject(canvas: Size2(640, 360))
        try await p.addVideo(.movingBox(.blue, .white), seconds: 20, audioHz: 440)
        let folder = try tempDir("stop")
        defer { try? FileManager.default.removeItem(at: folder) }
        var spec = ExportJobSpec(project: p.project, title: "Long", folder: folder)
        var s = ExportSettings(); s.resolution = .p1080; spec.video = s
        let queue = ExportQueue()
        let job = queue.enqueue(spec)
        let queued = queue.enqueue(spec)   // waits behind the first one
        #expect(queued.state == .queued)
        while job.state != .running { try await Task.sleep(for: .milliseconds(5)) }
        queue.cancel(queued)
        #expect(queued.state == .cancelled)
        queue.cancel(job)
        await queue.wait(job)
        #expect(job.state == .cancelled)
        #expect(job.written.isEmpty)
        #expect(job.progress < 1)
        for o in job.outputs { #expect(!FileManager.default.fileExists(atPath: o.url.path)) }
        #expect(queue.active.isEmpty)
    }

    @Test func packProgressReportsAndCancels() async throws {
        let queue = JobQueue(maxConcurrent: 1)
        let model = PackProgress()
        let out = URL(fileURLWithPath: "/tmp/x.valse")
        let done = await model.run(name: "A", queue: queue) { report in report(0.5); report(1); return out }
        #expect(done == .packed(out))
        #expect(model.current == nil)

        let runner = Task { @MainActor in
            await model.run(name: "B", queue: queue) { report in
                report(0.25)
                let end = Date().addingTimeInterval(20)
                while Date() < end { try Task.checkCancellation(); Thread.sleep(forTimeInterval: 0.005) }
                return out
            }
        }
        var spins = 0
        while model.current?.id == nil, spins < 1000 { spins += 1; try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.current?.id != nil)
        model.cancel()
        #expect(model.current?.cancelling == true)
        #expect(await runner.value == .cancelled)
        #expect(model.current == nil)
    }

    @Test func cancelledPackLeavesNothingBehind() async throws {
        var p = TestProject(canvas: Size2(320, 180))
        try await p.addVideo(.movingBox(.red, .white), seconds: 1, audioHz: nil)
        let out = try tempDir("pack")
        defer { try? FileManager.default.removeItem(at: out) }
        let project = p.project
        let t = Task.detached { () -> Bool in
            while !Task.isCancelled { await Task.yield() }
            return (try? ProjectPacker.pack(project, from: nil, into: out, zip: false)) != nil
        }
        t.cancel()
        #expect(await t.value == false)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []
        #expect(left.isEmpty)
        // not cancelled: packs, and the media is inside the package
        let ok = try ProjectPacker.pack(project, from: nil, into: out, zip: false)
        #expect(FileManager.default.fileExists(atPath: ok.path))
    }
}
