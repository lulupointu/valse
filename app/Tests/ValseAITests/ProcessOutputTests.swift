import Testing
import Foundation
@testable import ValseAI
import ValseEngine

/// FLAKY-PIPE: the llama reply (stdout) and whisper-cli's stderr (progress + the error text that classifies a
/// failure) must be read completely, also with many runs at once; fake tools (`/bin/sh -c`), no models needed.
@Suite("ProcessOutput") struct ProcessOutputTests {
    static let sh = URL(fileURLWithPath: "/bin/sh")

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

    /// A fake llama-completion: an empty think block, ~30 KB of reply, the end marker.
    static let llamaScript = """
    printf '<think>\\n\\n</think>\\n'; i=0; while [ $i -lt 400 ]; do echo "word $i of reply $1 ........................................"; \
    i=$((i+1)); done; printf 'end %s [end of text]\\n' "$1"
    """

    static func expectedReply(_ tag: String) -> String {
        var s = ""
        for i in 0..<400 { s += "word \(i) of reply \(tag) ........................................\n" }
        return s + "end \(tag)"
    }

    @Test func llamaReplyIsCompleteUnderConcurrency() async throws {
        let n = 256
        let bad = try await Self.concurrently(n) { i -> String? in
            let tag = "r\(i)"
            let reply = try await LlamaRuntime.respond(cli: Self.sh, ["-c", Self.llamaScript, "fake-llama", tag])
            return reply == Self.expectedReply(tag) ? nil : "\(tag): \(reply.utf8.count) bytes"
        }
        let failures = bad.compactMap { $0 }
        #expect(failures.isEmpty, "\(failures.count)/\(n) incomplete: \(failures.prefix(5))")
    }

    @Test func llamaNonZeroExitThrows() async {
        await #expect(throws: AIToolError.self) {
            _ = try await LlamaRuntime.respond(cli: Self.sh, ["-c", "echo partial; exit 2"])
        }
    }

    /// A fake whisper-cli: progress lines on stderr, then a model-load error written last, without a final newline
    /// (classification reads the stderr tail), exit 1.
    static let whisperFailScript = """
    i=0; while [ $i -lt 200 ]; do echo "whisper_print_progress_callback: progress = $((i / 2))% ......................................" >&2; \
    i=$((i+1)); done; echo "whisper_print_progress_callback: progress = 100%" >&2; \
    printf 'whisper_init_from_file: failed to load model' >&2; exit 1
    """

    final class MaxBox: @unchecked Sendable {
        private let l = NSLock(); private var v = -1.0
        func set(_ x: Double) { l.withLock { v = max(v, x) } }
        var value: Double { l.withLock { v } }
    }

    /// The error text arriving last still classifies the failure, and every progress line was seen before `run`
    /// returned (100 % reported).
    @Test func whisperStderrIsCompleteUnderConcurrency() async throws {
        let n = 256
        let bad = try await Self.concurrently(n) { i -> String? in
            let box = MaxBox()
            do {
                try await WhisperEngine.run(Self.sh, ["-c", Self.whisperFailScript], progress: { box.set($0) })
                return "w\(i): no error"
            } catch let f as SpeechFailure {
                if f != .speechModelDamaged { return "w\(i): \(f)" }
            }
            return box.value == 1 ? nil : "w\(i): progress \(box.value)"
        }
        let failures = bad.compactMap { $0 }
        #expect(failures.isEmpty, "\(failures.count)/\(n) wrong: \(failures.prefix(5))")
    }

    @Test func whisperSuccessReportsFullProgress() async throws {
        let box = MaxBox()
        try await WhisperEngine.run(Self.sh, ["-c", "echo 'progress = 50%' >&2; echo 'progress = 100%' >&2"], progress: { box.set($0) })
        #expect(box.value == 1)
    }

    @Test func whisperLaunchFailureIsAppIncomplete() async {
        await #expect(throws: SpeechFailure.appIncomplete) {
            try await WhisperEngine.run(URL(fileURLWithPath: "/nonexistent/whisper-cli"), [], progress: nil)
        }
    }
}
