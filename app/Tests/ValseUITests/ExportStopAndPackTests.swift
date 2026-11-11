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

    // MARK: BUG-PACK-PROGRESS: progress tracks the bytes (copy phase, zip phase), not the file count

    /// A project with one big (48 MB, incompressible) and two small media files outside any package.
    func fakeMedia(_ dir: URL) throws -> Project {
        var block = Data(count: 1 << 20)
        var rng = SystemRandomNumberGenerator()
        block.withUnsafeMutableBytes { raw in for i in stride(from: 0, to: raw.count, by: 8) { raw.storeBytes(of: rng.next() as UInt64, toByteOffset: i, as: UInt64.self) } }
        var big = Data(); for _ in 0..<48 { big.append(block) }
        var p = Project()
        for (name, data) in [("big.mov", big), ("a.png", block.prefix(4096)), ("b.wav", block.prefix(100_000))] {
            let u = dir.appendingPathComponent(name)
            try Data(data).write(to: u)
            p.media.append(MediaAsset(name: name, kind: .video, url: u, duration: 1, pixelSize: Size2(16, 9), frameRate: nil,
                                      hasVideo: true, hasAudio: false, contentHash: name, fileSize: Int64(data.count)))
        }
        p.name = "Packed"
        return p
    }

    final class Reports: @unchecked Sendable {
        let lock = NSLock()
        var values: [Double] = []
        private var onReport: (@Sendable (Double) -> Void)?
        func add(_ v: Double) { let cb = lock.withLock { values.append(v); return onReport }; cb?(v) }
        func setOnReport(_ f: @escaping @Sendable (Double) -> Void) { lock.withLock { onReport = f } }
        var all: [Double] { lock.withLock { values } }
    }

    func expectSmooth(_ r: [Double], _ label: String) {
        #expect(r.last == 1, "\(label): ends at 1")
        #expect(zip(r, r.dropFirst()).allSatisfy { $0 <= $1 }, "\(label): monotonic")
        let jumps = zip([0] + r, r).map { $1 - $0 }
        #expect((jumps.max() ?? 1) < 0.25, "\(label): no big jump \(r)")
    }

    @Test func packProgressIsByteProportionalAcrossCopyAndZip() throws {
        let src = try tempDir("packsrc"), out = try tempDir("packout")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: out) }
        let project = try fakeMedia(src)
        let work = ProjectPacker.plan(project, from: nil, dest: out.appendingPathComponent("Packed.valse"), zip: true, clone: false)
        let zipStart = work.zipStart
        // zip bytes weigh more than copied bytes (deflate is slower than a copy): the zip is the larger phase
        #expect(zipStart > 0.05 && zipStart < 0.5)
        let reports = Reports()
        let url = try ProjectPacker.pack(project, from: nil, into: out, zip: true, clone: false, progress: reports.add)
        #expect(url.pathExtension == "zip")
        #expect(FileManager.default.fileExists(atPath: url.path))
        let r = reports.all
        expectSmooth(r, "zip")
        // byte-level inside the big file: several reports during the copy phase, not one jump per file
        #expect(r.filter { $0 > 0.01 && $0 < zipStart }.count >= 4, "copy phase \(r)")
        // the zip phase reports while ditto runs, including its second half (no stall then jump to 1)
        #expect(r.filter { $0 > zipStart + 0.01 && $0 < 1 }.count >= 2, "zip phase \(r)")
        #expect(r.contains { $0 > zipStart + (1 - zipStart) / 2 && $0 < 1 }, "zip second half \(r)")
        // the staging package was removed, only the archive is left
        #expect((try FileManager.default.contentsOfDirectory(atPath: out.path)) == [url.lastPathComponent])
    }

    @Test func packWithoutZipIsByteProportional() throws {
        let src = try tempDir("packsrc"), out = try tempDir("packout")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: out) }
        let project = try fakeMedia(src)
        let reports = Reports()
        let pkg = try ProjectPacker.pack(project, from: nil, into: out, zip: false, clone: false, progress: reports.add)
        let r = reports.all
        expectSmooth(r, "no zip")
        #expect(r.filter { $0 > 0.01 && $0 < 1 }.count >= 6, "copy reports \(r)")
        // the streamed copies are complete
        #expect(FileCopier.size(pkg.appendingPathComponent("media/big.mov")) == 48 << 20)
        #expect(FileCopier.size(pkg.appendingPathComponent("media/b.wav")) == 100_000)
    }

    @Test func cancelDuringZipRemovesTheArchive() async throws {
        let src = try tempDir("packsrc"), out = try tempDir("packout")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: out) }
        let project = try fakeMedia(src)
        let zipStart = ProjectPacker.plan(project, from: nil, dest: out.appendingPathComponent("Packed.valse"), zip: true, clone: false).zipStart
        let reports = Reports()
        let task = Task.detached { () -> Bool in
            (try? ProjectPacker.pack(project, from: nil, into: out, zip: true, clone: false, progress: reports.add)) != nil
        }
        reports.setOnReport { if $0 > zipStart + 0.01, $0 < 1 { task.cancel() } }
        #expect(await task.value == false)
        #expect(reports.all.contains { $0 > zipStart })
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []).isEmpty)
    }
}
