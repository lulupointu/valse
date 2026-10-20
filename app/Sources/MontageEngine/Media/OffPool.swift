@preconcurrency import AVFoundation
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

    /// Holds the body for the GCD block; emptied before the caller resumes (`withoutActuallyEscaping` traps if the
    /// closure is still referenced when it returns — the dispatch block itself is released only later).
    private final class Slot<V>: @unchecked Sendable {
        var value: V?
        init(_ v: V) { value = v }
    }

    /// One blocking `copyNextSampleBuffer()` on a GCD thread, for read loops that `await` between samples (ML
    /// inference, writer back-pressure …). Costs one thread hop per sample; pure loops use `run` around the whole loop.
    public static func next(_ out: AVAssetReaderOutput, qos: DispatchQoS.QoSClass = .userInitiated) async -> CMSampleBuffer? {
        let o = UncheckedSendable(out)
        let r: UncheckedSendable<CMSampleBuffer?> = await withCheckedContinuation { c in
            DispatchQueue.global(qos: qos).async { c.resume(returning: UncheckedSendable(o.value.copyNextSampleBuffer())) }
        }
        return r.value
    }

    public static func run<T: Sendable>(qos: DispatchQoS.QoSClass = .userInitiated,
                                        _ body: (Context) throws -> T) async throws -> T {
        try await withoutActuallyEscaping(body) { body in
            // the caller is suspended until the GCD block resumes it, so `body` (and what it captures) is never shared
            let slot = Slot(body)
            let ctx = Context()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
                    DispatchQueue.global(qos: qos).async {
                        let r = { () -> Result<T, Error> in
                            let f = slot.value!
                            slot.value = nil
                            return Result { try f(ctx) }
                        }()
                        c.resume(with: r)
                    }
                }
            } onCancel: { ctx.cancel() }
        }
    }
}
