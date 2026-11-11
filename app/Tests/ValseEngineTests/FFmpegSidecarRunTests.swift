import Foundation
import Testing
@testable import ValseEngine
import ValseCore

/// `FFmpegSidecar.run` returns a tool's COMPLETE stdout, whatever the scheduling. It used to collect stdout with a
/// `readabilityHandler` and, after the process exited, remove the handler and `readDataToEndOfFile()`: a handler call
/// still in flight (its `availableData` already read, its append not yet done — likely when the machine is loaded)
/// appended after `run` had returned, so `run` returned an empty / truncated stdout. For ffprobe that is invalid JSON:
/// `MediaProbe` then fell back to AVFoundation's "Cannot Open" and a perfectly readable MKV failed to import
/// (ImportTests.ffmpegFallbackForMKV flake, FLAKY-ENG). Many concurrent runs make the bad interleaving frequent.
@Suite struct FFmpegSidecarRunTests {
    @Test func runReturnsTheWholeOutputUnderConcurrency() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/bin/cat") else { return }
        // 64 concurrent tools writing a known 3 KB payload (ffprobe's JSON size: written and exiting at once, the
        // racy case), 10 rounds.
        let payload = String(repeating: "0123456789abcdef", count: 192)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("valse-sidecar-run-\(UUID().uuidString).txt")
        try payload.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        var bad: [String] = []
        for _ in 0..<10 {
            let results = await withTaskGroup(of: (Int, Int32).self) { g in
                for _ in 0..<64 {
                    g.addTask {
                        let r = try? await FFmpegSidecar.run(URL(fileURLWithPath: "/bin/cat"), [file.path])
                        return (r?.0.count ?? -1, r?.1 ?? -1)
                    }
                }
                var out: [(Int, Int32)] = []
                for await r in g { out.append(r) }
                return out
            }
            bad += results.filter { $0.0 != payload.utf8.count || $0.1 != 0 }.map { "\($0.0) bytes, status \($0.1)" }
        }
        #expect(bad.isEmpty, "incomplete stdout: \(bad.prefix(5))")
    }
}
