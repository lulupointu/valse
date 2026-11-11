import Foundation

/// Runs a helper process (ffmpeg, whisper-cli, llama-completion …) and reads its stdout / stderr completely.
///
/// FLAKY-PIPE: never collect a pipe with a `readabilityHandler` and then `readabilityHandler = nil` +
/// `readDataToEndOfFile()` after the termination handler fired: a handler call still in flight can append its chunk
/// after the caller already returned, so the output came back empty or cut (FFmpegSidecar.run: 0-byte ffprobe stdout in
/// 1/1280 concurrent runs, FLAKY-ENG). Here each pipe has ONE reader that reads to end of file on an OffPool thread
/// (never the cooperative pool, never GCD), and only then is the exit status awaited: every byte the tool wrote is in
/// the result (EOF comes when the tool, and anything it spawned, closed the pipe — at its exit at the latest).
public enum ProcessPipes {
    /// What to do with one output stream of the process.
    public struct Capture: Sendable {
        /// Keep every byte in the result (false: only `onChunk` sees them, e.g. long progress streams).
        public var keep: Bool
        /// Called on the reader thread with each chunk, in order (progress parsing); never after `run` returned.
        public var onChunk: (@Sendable (Data) -> Void)?
        public init(keep: Bool = true, onChunk: (@Sendable (Data) -> Void)? = nil) { self.keep = keep; self.onChunk = onChunk }
        public static let all = Capture()
    }

    public struct Result: Sendable {
        public var stdout: Data
        public var stderr: Data
        public var status: Int32
        /// Ended by a signal (`status` is then the signal number).
        public var uncaughtSignal: Bool
    }

    /// Launches `executable` with `arguments` (stdin = /dev/null; a stream with no capture goes to /dev/null), reads the
    /// captured streams to EOF, then waits for the exit. Cancelling the calling task terminates the process (the result
    /// is still returned once it ended: check `Task.isCancelled`). Throws only when the process cannot be launched.
    public static func run(_ executable: URL, _ arguments: [String], stdout: Capture? = nil, stderr: Capture? = nil,
                           environment: [String: String]? = nil) async throws -> Result {
        let p = Process()
        p.executableURL = executable
        p.arguments = arguments
        if let environment { p.environment = environment }
        p.standardInput = FileHandle.nullDevice
        let outPipe = stdout.map { _ in Pipe() }, errPipe = stderr.map { _ in Pipe() }
        p.standardOutput = outPipe ?? FileHandle.nullDevice
        p.standardError = errPipe ?? FileHandle.nullDevice
        let exit = ExitBox()
        p.terminationHandler = { exit.set($0.terminationStatus, signal: $0.terminationReason == .uncaughtSignal) }
        try p.run()
        let proc = UncheckedSendable(p)
        return await withTaskCancellationHandler {
            async let out = drain(outPipe, stdout)
            async let err = drain(errPipe, stderr)
            let (o, e) = await (out, err)
            let (status, signal) = await exit.wait()
            return Result(stdout: o, stderr: e, status: status, uncaughtSignal: signal)
        } onCancel: { if proc.value.isRunning { proc.value.terminate() } }
    }

    /// Reads `pipe` to EOF on an OffPool thread (one reader), then closes it.
    private static func drain(_ pipe: Pipe?, _ capture: Capture?) async -> Data {
        guard let pipe, let capture else { return Data() }
        let h = UncheckedSendable(pipe.fileHandleForReading)
        // the body never throws, and ignores cancellation on purpose: the tool is terminated instead, then read to EOF
        let data = (try? await OffPool.run { _ -> Data in
            var all = Data()
            while true {
                guard let chunk = try? h.value.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
                capture.onChunk?(chunk)
                if capture.keep { all.append(chunk) }
            }
            return all
        }) ?? Data()
        try? h.value.close()
        return data
    }

    /// The exit status, set once by the termination handler (any thread), awaited after the reads.
    private final class ExitBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (Int32, Bool)?
        private var waiter: CheckedContinuation<(Int32, Bool), Never>?
        func set(_ status: Int32, signal: Bool) {
            let w: CheckedContinuation<(Int32, Bool), Never>? = lock.withLock {
                value = (status, signal)
                defer { waiter = nil }
                return waiter
            }
            w?.resume(returning: (status, signal))
        }
        func wait() async -> (Int32, Bool) {
            await withCheckedContinuation { (c: CheckedContinuation<(Int32, Bool), Never>) in
                let v: (Int32, Bool)? = lock.withLock { if value == nil { waiter = c }; return value }
                if let v { c.resume(returning: v) }
            }
        }
    }
}
