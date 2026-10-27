import Testing
import Foundation
@testable import ValseCore

/// Shared model-cache installs (compiled CoreML models, unzipped packages): parallel UI-test apps / test processes
/// install the same item at once. AtomicInstall must never leave a half-written or missing destination.
@Suite struct AtomicInstallTests {
    func scratch() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("atomic-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// A "compiled model" folder with a payload file.
    func built(in dir: URL, _ payload: String) throws -> URL {
        let b = dir.appendingPathComponent("built-\(UUID().uuidString).mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        try Data(payload.utf8).write(to: b.appendingPathComponent("weights.bin"))
        return b
    }

    @Test func concurrentInstallsAllSucceedAndLeaveOneCompleteCopy() async throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let dst = dir.appendingPathComponent("models/Model.mlmodelc", isDirectory: true)
        let sources = try (0..<16).map { try built(in: dir, "payload-\($0)") }
        let results = await withTaskGroup(of: Bool.self) { g in
            for s in sources { g.addTask { (try? AtomicInstall.place(s, at: dst)) == dst } }
            return await g.reduce(into: [Bool]()) { $0.append($1) }
        }
        #expect(results.allSatisfy { $0 }, "every racing installer sees success")
        let payload = try String(contentsOf: dst.appendingPathComponent("weights.bin"), encoding: .utf8)
        #expect(payload.hasPrefix("payload-"))
        let left = try FileManager.default.contentsOfDirectory(atPath: dst.deletingLastPathComponent().path)
        #expect(left == ["Model.mlmodelc"], "no staged leftovers: \(left)")
    }

    @Test func existingValidDestinationIsKept() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let dst = dir.appendingPathComponent("Model.mlmodelc", isDirectory: true)
        try AtomicInstall.place(try built(in: dir, "first"), at: dst)
        try AtomicInstall.place(try built(in: dir, "second"), at: dst)
        #expect(try String(contentsOf: dst.appendingPathComponent("weights.bin"), encoding: .utf8) == "first")
    }

    @Test func replaceSwapsAStaleCopyWithoutBreakingAnOpenReader() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let dst = dir.appendingPathComponent("Model.mlmodelc", isDirectory: true)
        try AtomicInstall.place(try built(in: dir, "old"), at: dst)
        let reader = try FileHandle(forReadingFrom: dst.appendingPathComponent("weights.bin"))   // another process loading it
        try AtomicInstall.place(try built(in: dir, "new"), at: dst, replace: true)
        #expect(String(decoding: try reader.readToEnd() ?? Data(), as: UTF8.self) == "old")
        #expect(try String(contentsOf: dst.appendingPathComponent("weights.bin"), encoding: .utf8) == "new")
    }
}
