import Foundation

/// Blocking AVFoundation work (an `AVAssetReader` `copyNextSampleBuffer` loop, …) must not run on Swift's cooperative
/// pool. AVFoundation needs pool threads of its own to finish a read, so once every pool thread (about one per core) is
/// blocked in `copyNextSampleBuffer` the process deadlocks at 0 % CPU (seen with ~10 parallel media tests). `run` does
/// the blocking part on a GCD thread while the calling task is suspended; `Context.checkCancellation()` reports the
/// caller's cancellation (`Task.checkCancellation` does not work off the task).
public enum OffPool {
    public final class Context: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        fileprivate func cancel() { lock.withLock { cancelled = true } }
        public var isCancelled: Bool { lock.withLock { cancelled } }
        public func checkCancellation() throws { if isCancelled { throw CancellationError() } }
    }

    private struct Unchecked<V>: @unchecked Sendable { let value: V }

    public static func run<T: Sendable>(qos: DispatchQoS.QoSClass = .userInitiated,
                                        _ body: (Context) throws -> T) async throws -> T {
        try await withoutActuallyEscaping(body) { body in
            // the caller is suspended until the GCD block resumes it, so `body` (and what it captures) is never shared
            let work = Unchecked(value: body)
            let ctx = Context()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
                    DispatchQueue.global(qos: qos).async { c.resume(with: Result { try work.value(ctx) }) }
                }
            } onCancel: { ctx.cancel() }
        }
    }
}
