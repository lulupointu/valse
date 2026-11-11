import Testing
import Foundation
import ValseCore
@testable import ValseEngine

/// FLAKY-PIPE: helper processes' stdout / stderr must come back complete, every time, also with many runs at once.
/// (A `readabilityHandler` + `readDataToEndOfFile` after exit lost the last chunk in ~1/1280 concurrent runs.)
@Suite("ProcessPipes") struct ProcessPipesTests {
    /// Runs `body(i)` for i in 0..<n, at most `width` at once.
    static func concurrently<T: Sendable>(_ n: Int, width: Int = 16, _ body: @escaping @Sendable (Int) async throws -> T) async throws -> [T] {
        try await withThrowingTaskGroup(of: (Int, T).self) { g in
            var out = [T?](repeating: nil, count: n), next = 0
            func add() { let i = next; next += 1; g.addTask { let r = try await body(i); return (i, r) } }
            while next < min(width, n) { add() }
            while let (i, r) = try await g.next() {
                out[i] = r
                if next < n { add() }
            }
            return out.map { $0! }
        }
    }

    /// A fake tool: `/bin/sh -c <script>` (args after the script are $0, $1 …).
    static let sh = URL(fileURLWithPath: "/bin/sh")

    /// 40 KB on stdout and 20 KB on stderr (several pipe buffers each), interleaved, then exit 3.
    static let script = """
    i=0; while [ $i -lt 500 ]; do echo "out line $i $1 ................................................................"; \
    [ $((i % 2)) -eq 0 ] && echo "err line $i $1 ..............................................................." >&2; i=$((i+1)); done; \
    printf 'last-out %s' "$1"; printf 'last-err %s' "$1" >&2; exit 3
    """

    static func expected(_ tag: String) -> (out: String, err: String) {
        var o = "", e = ""
        for i in 0..<500 {
            o += "out line \(i) \(tag) ................................................................\n"
            if i % 2 == 0 { e += "err line \(i) \(tag) ...............................................................\n" }
        }
        return (o + "last-out \(tag)", e + "last-err \(tag)")
    }

    @Test func everyByteOfBothStreamsUnderConcurrency() async throws {
        let n = 256
        let bad = try await Self.concurrently(n) { i -> String? in
            let tag = "run\(i)"
            let r = try await ProcessPipes.run(Self.sh, ["-c", Self.script, "fake", tag], stdout: .all, stderr: .all)
            let x = Self.expected(tag)
            if r.status != 3 || r.uncaughtSignal { return "\(tag): status \(r.status)" }
            if String(decoding: r.stdout, as: UTF8.self) != x.out { return "\(tag): stdout \(r.stdout.count) bytes, expected \(x.out.utf8.count)" }
            if String(decoding: r.stderr, as: UTF8.self) != x.err { return "\(tag): stderr \(r.stderr.count) bytes, expected \(x.err.utf8.count)" }
            return nil
        }
        let failures = bad.compactMap { $0 }
        #expect(failures.isEmpty, "\(failures.count)/\(n) incomplete: \(failures.prefix(5))")
    }

    /// Chunks reach `onChunk` in order, all of them before `run` returns; `keep: false` keeps nothing.
    @Test func chunksArriveInOrderBeforeReturn() async throws {
        final class Box: @unchecked Sendable { let l = NSLock(); var d = Data(); func add(_ x: Data) { l.withLock { d.append(x) } } }
        let bad = try await Self.concurrently(64) { i -> String? in
            let box = Box()
            let r = try await ProcessPipes.run(Self.sh, ["-c", Self.script, "fake", "c\(i)"], stdout: .init(keep: false) { box.add($0) })
            let got = box.l.withLock { box.d }
            if !r.stdout.isEmpty || !r.stderr.isEmpty { return "c\(i): kept data" }
            return String(decoding: got, as: UTF8.self) == Self.expected("c\(i)").out ? nil : "c\(i): \(got.count) bytes"
        }
        #expect(bad.compactMap { $0 }.isEmpty, "\(bad.compactMap { $0 }.prefix(5))")
    }

    /// FFmpegSidecar.transcode's error text is ffmpeg's WHOLE stderr (it was collected by a readabilityHandler).
    @Test func transcodeErrorTextIsComplete() async throws {
        let n = 128
        let bad = try await Self.concurrently(n) { i -> String? in
            let tag = "t\(i)"
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("pipes-\(UUID().uuidString).mov")
            do {
                try await FFmpegSidecar.transcode(ffmpeg: Self.sh, ["-c", Self.script, "fake-ffmpeg", tag], output: output,
                                                  duration: Time(seconds: 1), progress: nil)
                return "\(tag): no error"
            } catch FFmpegSidecar.SidecarError.failed(let text) {
                return text == Self.expected(tag).err ? nil : "\(tag): \(text.utf8.count) bytes"
            }
        }
        let failures = bad.compactMap { $0 }
        #expect(failures.isEmpty, "\(failures.count)/\(n) incomplete: \(failures.prefix(5))")
    }

    @Test func signalIsReported() async throws {
        let r = try await ProcessPipes.run(Self.sh, ["-c", "echo hi; kill -9 $$"], stdout: .all)
        #expect(r.uncaughtSignal)
        #expect(r.status == SIGKILL)
        #expect(String(decoding: r.stdout, as: UTF8.self) == "hi\n")
    }

    @Test func launchFailureThrows() async {
        await #expect(throws: (any Error).self) {
            _ = try await ProcessPipes.run(URL(fileURLWithPath: "/nonexistent/valse-tool"), [], stdout: .all)
        }
    }

    /// Cancelling the caller terminates the tool; `run` returns once it ended (`yes` never ends by itself). The tool is
    /// one process: `/bin/sh -c '…; exec sleep 60'` reported its exit at once on macOS 26 while `sleep` (another pid)
    /// kept stdout open, so EOF came only 60 s later — a helper's own children holding the pipe delay `run` too.
    @Test func cancelTerminatesTheTool() async throws {
        final class Started: @unchecked Sendable {
            let l = NSLock(); var c: CheckedContinuation<Void, Never>?; var done = false
            func fire() { let w: CheckedContinuation<Void, Never>? = l.withLock { done = true; defer { c = nil }; return c }; w?.resume() }
            func wait() async { await withCheckedContinuation { k in if l.withLock({ if done { return true }; c = k; return false }) { k.resume() } } }
        }
        let started = Started()
        let task = Task {
            try await ProcessPipes.run(URL(fileURLWithPath: "/usr/bin/yes"), [], stdout: .init(keep: false) { _ in started.fire() })
        }
        await started.wait()
        task.cancel()
        let r = try await task.value
        #expect(r.uncaughtSignal)
        #expect(r.status == SIGTERM)
    }
}
