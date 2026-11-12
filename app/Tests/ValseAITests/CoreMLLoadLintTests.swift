import Testing
import Foundation

/// FLAKY-LAMA: every Core ML model Valse compiles / loads goes through `CoreMLModels` (cross-process `CoreMLLoadLock`
/// around compile, load and first prediction): Core ML's program cache is shared by all Valse processes and written in
/// place during a load, so a raw load racing another process's aborted the app in MPSGraph. Source lint over app/Sources.
struct CoreMLLoadLintTests {
    static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources")

    @Test func coreMLModelsLoadOnlyThroughTheLockedHelper() throws {
        var files: [URL] = []
        if let e = FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil) {
            for case let u as URL in e where u.pathExtension == "swift" { files.append(u) }
        }
        #expect(files.count > 200, "sources not found at \(Self.sources.path)")
        let raw = ["MLModel(contentsOf", "MLModel.compileModel", "MLModel.load(", "MLModel.compileModel(", ".compileModel(at:"]
        var hits: [String] = []
        for f in files where f.lastPathComponent != "CoreMLLoadLock.swift" {
            let lines = try String(contentsOf: f, encoding: .utf8).components(separatedBy: "\n")
            for (i, l) in lines.enumerated() where raw.contains(where: l.contains) {
                hits.append("\(f.lastPathComponent):\(i + 1)")
            }
        }
        #expect(hits.isEmpty, "load / compile Core ML models with CoreMLModels.load / CoreMLModels.compile (CoreMLLoadLock): \(hits)")
    }
}
