@preconcurrency import AVFoundation
import Foundation

/// Blocking AVFoundation work (an `AVAssetReader` `copyNextSampleBuffer` loop, …) must not run on Swift's cooperative
/// pool. AVFoundation needs pool threads of its own to finish a read, so once every pool thread (about one per core) is
/// blocked in `copyNextSampleBuffer` the process deadlocks at 0 % CPU (seen with ~10 parallel media tests). `run` does
/// the blocking part on an OffPool thread while the calling task is suspended; `Context.checkCancellation()` reports the
/// caller's cancellation (`Task.checkCancellation` does not work off the task).
///
/// The threads are OffPool's own (`BlockingThreads`), not GCD's: GCD stops adding workers at its soft limit (64 threads
/// blocked in synchronous calls), and AVFoundation / VideoToolbox deliver decoded samples through GCD queues — so ~64
/// blocked reads on GCD deadlocked the process just like the cooperative pool did (FLAKY-SYS-UNIT: 80 reversed renders
/// at once, `sample`: "Dispatch Thread Soft Limit: 64 reached", every worker in copyNextSampleBuffer).
public enum OffPool {
    public final class Context: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        fileprivate func cancel() { lock.withLock { cancelled = true } }
        public var isCancelled: Bool { lock.withLock { cancelled } }
        public func checkCancellation() throws { if isCancelled { throw CancellationError() } }
    }

    /// Holds the body for the thread; emptied before the caller resumes (`withoutActuallyEscaping` traps if the
    /// closure is still referenced when it returns — the work item itself is released only later).
    private final class Slot<V>: @unchecked Sendable {
        var value: V?
        init(_ v: V) { value = v }
    }

    /// One blocking `copyNextSampleBuffer()` on an OffPool thread, for read loops that `await` between samples (ML
    /// inference, writer back-pressure …). Costs one thread hop per sample; pure loops use `run` around the whole loop.
    public static func next(_ out: AVAssetReaderOutput, qos: DispatchQoS.QoSClass = .userInitiated) async -> CMSampleBuffer? {
        let o = UncheckedSendable(out)
        let r: UncheckedSendable<CMSampleBuffer?> = await withCheckedContinuation { c in
            BlockingThreads.shared.async(qos: qos) { c.resume(returning: UncheckedSendable(o.value.copyNextSampleBuffer())) }
        }
        return r.value
    }

    public static func run<T: Sendable>(qos: DispatchQoS.QoSClass = .userInitiated,
                                        _ body: (Context) throws -> T) async throws -> T {
        try await withoutActuallyEscaping(body) { body in
            // the caller is suspended until the thread resumes it, so `body` (and what it captures) is never shared
            let slot = Slot(body)
            let ctx = Context()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
                    BlockingThreads.shared.async(qos: qos) {
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

/// Threads for blocking work, outside both the cooperative pool and GCD's worker pool: an idle thread takes the next
/// item, a new thread starts when none is idle (never a queue: two blocking reads of one AVAssetReader — video and
/// audio pumps — may need each other to progress), idle threads exit after `idleSeconds`.
public final class BlockingThreads: @unchecked Sendable {
    public static let shared = BlockingThreads()

    private let cond = NSCondition()
    /// Work items (a thread's QoS is set when it starts: reused threads keep theirs).
    private var queue: [() -> Void] = []
    private var idle = 0
    private var live = 0
    private var peak = 0
    private let idleSeconds: TimeInterval = 10

    /// Threads alive now / most alive at once (diagnostics, tests).
    public var liveThreads: Int { cond.lock(); defer { cond.unlock() }; return live }
    public var peakThreads: Int { cond.lock(); defer { cond.unlock() }; return peak }

    public func async(qos: DispatchQoS.QoSClass = .userInitiated, _ work: @escaping @Sendable () -> Void) {
        cond.lock()
        queue.append(work)
        let spawn = idle < queue.count
        if spawn { live += 1; peak = max(peak, live) }
        cond.signal()
        cond.unlock()
        if spawn {
            let t = Thread { [self] in loop() }
            t.name = "montage.offpool"
            t.stackSize = 1 << 20
            t.qualityOfService = Self.quality(qos)
            t.start()
        }
    }

    private func loop() {
        cond.lock()
        while true {
            while queue.isEmpty {
                idle += 1
                let woke = cond.wait(until: Date().addingTimeInterval(idleSeconds))
                idle -= 1
                if !woke && queue.isEmpty { live -= 1; cond.unlock(); return }
            }
            let work = queue.removeFirst()
            cond.unlock()
            autoreleasepool { work() }
            cond.lock()
        }
    }

    static func quality(_ q: DispatchQoS.QoSClass) -> QualityOfService {
        switch q {
        case .userInteractive: return .userInteractive
        case .userInitiated: return .userInitiated
        case .utility: return .utility
        case .background: return .background
        default: return .default
        }
    }
}
