import Foundation

/// At most `limit` video export passes at once in the process; the others wait (suspended, no thread held, cancellable).
///
/// Each running export holds two GCD threads blocked in `copyNextSampleBuffer` (its video / audio pumps run on
/// `requestMediaDataWhenReady` queues) plus decoder / encoder / compositor work that AVFoundation itself schedules on
/// GCD. GCD stops adding workers at its soft limit (64 threads blocked in synchronous calls): with ~30 exports at once
/// (the parallel unit suite starts every test task together; FLAKY-SYS-UNIT stress: 80 concurrent exports) AVFoundation
/// got no worker to deliver the samples the pumps waited for and the process deadlocked at 0 % CPU — below that, passes
/// starved and exports could trip the stall detector. The app exports one project at a time; this bounds tests and
/// batch tools. `MONTAGE_EXPORT_CONCURRENCY` overrides the limit.
public final class ExportGate: @unchecked Sendable {
    public static let shared = ExportGate(limit: ProcessInfo.processInfo.environment["MONTAGE_EXPORT_CONCURRENCY"].flatMap(Int.init)
                                          ?? max(2, ProcessInfo.processInfo.activeProcessorCount / 2))

    /// Reversed renders (ReverseManager.generate: chunked AVAssetReader decodes + an H.264 writer): same reason —
    /// 120 at once exhausted GCD inside AVFoundation itself (`coremedia.boss.makedataready` workers).
    public static let reverse = ExportGate(limit: shared.limit)

    public let limit: Int
    private let lock = NSLock()
    private var running = 0
    private var waiters: [(id: UUID, resume: (Bool) -> Void)] = []
    private var peak = 0

    public init(limit: Int) { self.limit = max(1, limit) }

    /// Most passes that ran at once (tests).
    public var peakRunning: Int { lock.withLock { peak } }

    public func run<T>(_ body: () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        return try await body()
    }

    func acquire() async throws {
        let id = UUID()
        let granted: Bool = await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                lock.lock()
                if running < limit {
                    running += 1; peak = max(peak, running)
                    lock.unlock(); c.resume(returning: true); return
                }
                // cancelled before waiting (onCancel already ran, found nothing to remove)
                if Task.isCancelled { lock.unlock(); c.resume(returning: false); return }
                waiters.append((id, { c.resume(returning: $0) }))
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let w = waiters.firstIndex { $0.id == id }.map { waiters.remove(at: $0) }
            lock.unlock()
            w?.resume(false)
        }
        // a slot granted at the moment of cancellation is handed back by the caller's `release` (granted == true)
        if !granted { throw CancellationError() }
    }

    func release() {
        lock.lock()
        if waiters.isEmpty {
            running -= 1
            lock.unlock()
        } else {
            let next = waiters.removeFirst()   // the slot passes straight to the next waiter (running unchanged)
            lock.unlock()
            next.resume(true)
        }
    }
}
