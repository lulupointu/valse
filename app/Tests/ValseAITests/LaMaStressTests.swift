import Testing
import Foundation
import CoreGraphics
import CoreML
@testable import ValseAI
import ValseCore
import ValseEngine

/// FLAKY-LAMA: f4_ai_remove_long aborted in MPSGraph (`MPSGraphTensorData.mm:223: failed assertion 'shape.count = 0 !=
/// strides.count = 4'`) at LaMa's first prediction. Cause: Core ML's on-disk GPU-program cache
/// (`~/Library/Caches/<process>/com.apple.e5rt.e5bundlecache`) is shared by every process of the same name and written
/// in place during a load; a process loading while another writes it reads a half-written `model_0.mpsgraph`.
/// Opt-in probes: `VALSE_LAMA_BENCH=<n>` (mean prediction time per compute-unit setting), `VALSE_LAMA_STRESS=<n>`
/// (n back-to-back predictions from 3 threads under CPU load: 450 passed before the fix, ruling out an in-process race).
@Suite(.serialized) struct LaMaStressTests {
    static let bench = Int(ProcessInfo.processInfo.environment["VALSE_LAMA_BENCH"] ?? "") ?? 0
    static let stress = Int(ProcessInfo.processInfo.environment["VALSE_LAMA_STRESS"] ?? "") ?? 0

    static func frame(_ i: Int) -> (CGImage, CGImage) {
        let img = ObjectRemovalTests.scene(640, 360)
        let x = 0.3 + 0.01 * Double(i % 20)
        let m = ObjectRemover.mask([RemovalStroke(points: [Vec2(x, 0.5), Vec2(x + 0.15, 0.5)], radius: 0.08)], width: 640, height: 360)
        return (img, m)
    }

    /// Regression: another process (re)writing the cached GPU program of this model while we load it. The writer
    /// (a perl child) holds the load lock, truncates `model_0.mpsgraph` as an in-progress write leaves it, then restores
    /// it. The load must wait for it: without `CoreMLLoadLock` the warm-up prediction aborts the test process with the
    /// assertion above (reproduced). Uses a private copy of LaMa (unique cache key: no other run reads that entry).
    @Test func loadWaitsForAnotherProcessWritingTheGPUProgramCache() async throws {
        try await HeavyWorkGate.run {
            guard LaMaInpainter.isAvailable else { print("skip: LaMa model not installed"); return }
            try await OffPool.run { _ in try Self.cacheWriterRace() }
        }
    }

    static func cacheWriterRace() throws {
        let fm = FileManager.default
        let shared = ValsePaths.cacheDirectory.appendingPathComponent("models/LaMa.mlmodelc")
        try CoreMLLoadLock.withLock(CoreMLLoadLock.url(for: shared)) { try LaMaInpainter.install(shared) }   // first use: unzip + compile
        let src = shared.resolvingSymlinksInPath()
        let dir = fm.temporaryDirectory.appendingPathComponent("lama-race-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let copy = dir.appendingPathComponent("LaMa.mlmodelc")
        try fm.copyItem(at: src, to: copy)
        let mil = copy.appendingPathComponent("model.mil")
        let text = try String(contentsOf: mil, encoding: .utf8) + "\n// race \(UUID().uuidString)\n"
        try fm.removeItem(at: mil)
        try text.write(to: mil, atomically: true, encoding: .utf8)

        let start = Date()
        _ = try LaMaInpainter(compiled: copy)   // builds this copy's cache entry
        let made = gpuPrograms(since: start)
        guard made.count == 1, let graph = made.first else {
            print("skip: cache entry not identified (\(made.count) new; cache layout changed or another run compiled at the same time)")
            return
        }
        let keyDir = (0..<6).reduce(graph) { u, _ in u.deletingLastPathComponent() }
        defer { try? fm.removeItem(at: keyDir) }
        let backup = dir.appendingPathComponent("model_0.backup")
        try fm.copyItem(at: graph, to: backup)
        let size = { (u: URL) in (try? fm.attributesOfItem(atPath: u.path)[.size] as? Int) ?? -1 }

        let writer = Process()
        writer.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        writer.arguments = ["-e", """
            use Fcntl qw(:flock); use File::Copy; $| = 1;
            open(my $l, ">>", $ARGV[0]) or die "lock: $!"; flock($l, LOCK_EX) or die "flock: $!";
            truncate($ARGV[1], 0) or die "truncate: $!"; print "writing\\n";
            select(undef, undef, undef, 1.5); copy($ARGV[2], $ARGV[1]) or die "copy: $!"; print "written\\n";
            """, CoreMLLoadLock.url(for: copy).path, graph.path, backup.path]
        let out = Pipe()
        writer.standardOutput = out
        try writer.run()
        defer { writer.waitUntilExit() }
        var said = ""
        while !said.contains("writing") {
            let d = out.fileHandleForReading.availableData
            guard !d.isEmpty else { break }
            said += String(decoding: d, as: UTF8.self)
        }
        try #require(said.contains("writing"), "writer did not start: \(said)")
        #expect(size(graph) == 0)

        let l = try LaMaInpainter(compiled: copy)   // waits for the writer; reads the complete program
        #expect(size(graph) == size(backup), "loaded while the cached program was being written")
        let (a, m) = frame(0)
        _ = try l.inpaint(a, mask: m)
        writer.waitUntilExit()
        #expect(writer.terminationStatus == 0)
    }

    /// `main_mps_graph.mpsgraphpackage/model_0.mpsgraph` files written since `start` in this process's Core ML caches.
    static func gpuPrograms(since start: Date) -> [URL] {
        let fm = FileManager.default
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        var out: [URL] = []
        for app in (try? fm.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil)) ?? [] {
            let root = app.appendingPathComponent("com.apple.e5rt.e5bundlecache")
            guard fm.fileExists(atPath: root.path) else { continue }
            let e = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
            while let f = e?.nextObject() as? URL {
                guard f.lastPathComponent == "model_0.mpsgraph", f.deletingLastPathComponent().lastPathComponent == "main_mps_graph.mpsgraphpackage",
                      let d = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, d >= start else { continue }
                out.append(f)
            }
        }
        return out
    }

    @Test func benchComputeUnits() async throws {
        guard Self.bench > 0 else { print("skip: set VALSE_LAMA_BENCH=<n>"); return }
        guard LaMaInpainter.isAvailable else { print("skip: LaMa model not installed"); return }
        let units: [(String, MLComputeUnits)] = [("all", .all), ("cpuAndGPU", .cpuAndGPU), ("cpuAndNeuralEngine", .cpuAndNeuralEngine), ("cpuOnly", .cpuOnly)]
        for (name, u) in units {
            let clock = ContinuousClock()
            let t0 = clock.now
            let l = try LaMaInpainter(computeUnits: u)
            let load = clock.now - t0
            let t1 = clock.now
            for i in 0..<Self.bench { let (a, m) = Self.frame(i); _ = try autoreleasepool { try l.inpaint(a, mask: m) } }
            print("metric lama_\(name) load=\(load) per_frame=\((clock.now - t1) / Self.bench)")
        }
    }

    @Test func stressSharedInpainterUnderLoad() async throws {
        guard Self.stress > 0 else { print("skip: set VALSE_LAMA_STRESS=<n>"); return }
        guard LaMaInpainter.isAvailable else { print("skip: LaMa model not installed"); return }
        let stop = UncheckedFlag()
        for _ in 0..<ProcessInfo.processInfo.activeProcessorCount {
            Thread.detachNewThread { var x = 0.0; while !stop.value { for i in 0..<100_000 { x += sin(Double(i)) } }; _ = x }
        }
        defer { stop.value = true }
        let l = try await OffPool.run { _ in try LaMaInpainter.acquire() }
        defer { LaMaInpainter.release() }
        let done = UncheckedCounter()
        await withTaskGroup(of: Void.self) { g in
            for t in 0..<3 {
                g.addTask {
                    _ = try? await OffPool.run { _ in
                        for i in 0..<Self.stress {
                            let (a, m) = Self.frame(i + t)
                            _ = try? autoreleasepool { try l.inpaint(a, mask: m) }
                            done.add()
                        }
                    }
                }
            }
        }
        print("metric lama_stress predictions=\(done.value)")
        #expect(done.value == 3 * Self.stress)
    }
}

/// CoreMLLoadLock excludes holders in other processes and other threads, and waits for them.
@Suite struct CoreMLLoadLockTests {
    @Test func waitsForAHolderInAnotherProcess() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loadlock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let lock = CoreMLLoadLock.url(for: dir.appendingPathComponent("M.mlmodelc"))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await OffPool.run { _ in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            p.arguments = ["-e", "use Fcntl qw(:flock); $| = 1; open(my $l, '>>', $ARGV[0]) or die; flock($l, LOCK_EX) or die; print \"held\\n\"; <STDIN>; print \"released\\n\";", lock.path]
            let out = Pipe(), inp = Pipe()
            p.standardOutput = out; p.standardInput = inp
            try p.run()
            let first = String(decoding: out.fileHandleForReading.availableData, as: UTF8.self)
            try #require(first.contains("held"))
            let order = UncheckedLog()
            let t = Thread {
                Thread.sleep(forTimeInterval: 0.3)   // the holder keeps it a while: the waiter must not get in meanwhile
                order.add("release"); inp.fileHandleForWriting.write(Data("go\n".utf8))
            }
            t.start()
            try CoreMLLoadLock.withLock(lock) { order.add("acquired") }
            p.waitUntilExit()
            #expect(order.items == ["release", "acquired"])
        }
    }

    @Test func cancelledWaitThrows() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loadlock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let lock = CoreMLLoadLock.url(for: dir.appendingPathComponent("M.mlmodelc"))
        try CoreMLLoadLock.withLock(lock) {
            // a second descriptor of this process conflicts too (flock is per open file)
            #expect(throws: CancellationError.self) { try CoreMLLoadLock.withLock(lock, cancelled: { true }) { } }
        }
        var ran = false
        try CoreMLLoadLock.withLock(lock) { ran = true }
        #expect(ran)
    }
}

final class UncheckedFlag: @unchecked Sendable { var value = false }
final class UncheckedCounter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func add() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}
final class UncheckedLog: @unchecked Sendable {
    private let lock = NSLock(); private var log: [String] = []
    func add(_ s: String) { lock.withLock { log.append(s) } }
    var items: [String] { lock.withLock { log } }
}
