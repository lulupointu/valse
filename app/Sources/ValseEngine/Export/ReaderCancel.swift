@preconcurrency import AVFoundation

/// Cancelling an `AVAssetReader` while another thread is inside `copyNextSampleBuffer` is a use-after-free in
/// AVFoundation: `cancelReading` tears down the outputs' decode / offline audio-mix engines under the waiting thread
/// (EXC_BAD_ACCESS in `FigSemaphoreWaitRelative` while `AQMixEngine_Offline` was destroyed; an export cancelled under
/// machine load, `ExportFormatTests.jobCancelDeletesPartialFiles`, ~1 crash in 15 runs). So a task's cancel handler
/// (and the export stall monitor) only `request` the stop: the pumps — the only threads that read — stop at their next
/// sample, and the caller calls `cancelReading` after they returned. The reader is never cancelled while it is being
/// read; a copy that never returns (an AVFoundation hang) keeps the export waiting — the test hang watchdog reports it.
final class ReaderCancel: @unchecked Sendable {
    private let lock = NSLock()
    private var requestedFlag = false

    /// Checked by the pumps before every `copyNextSampleBuffer`.
    var requested: Bool { lock.withLock { requestedFlag } }

    /// From the cancel handler / stall monitor (any thread): stop reading at the next sample.
    func request() { lock.withLock { requestedFlag = true } }

    /// Every pump returned: nothing reads any more (the caller may now cancel the reader). Kept for symmetry / clarity.
    func finish() {}
}

/// Work done by an export pass (samples read by the pumps), for its stall monitor.
final class ExportActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0, stalledFlag = false
    var samples: Int { lock.withLock { count } }
    var stalled: Bool { lock.withLock { stalledFlag } }
    func tick() { lock.withLock { count += 1 } }
    func markStalled() { lock.withLock { stalledFlag = true } }
}

/// How an export pass's pumps ended for the waiting export: they all returned, or the export was cancelled first.
final class PumpOutcome: @unchecked Sendable {
    enum Value { case finished, cancelled }
    private let lock = NSLock()
    private var value: Value?
    private var waiter: CheckedContinuation<Value, Never>?
    /// First call wins.
    func fire(_ v: Value) {
        let w: CheckedContinuation<Value, Never>? = lock.withLock {
            guard value == nil else { return nil }
            value = v
            defer { waiter = nil }
            return waiter
        }
        w?.resume(returning: v)
    }
    func wait() async -> Value {
        await withCheckedContinuation { (c: CheckedContinuation<Value, Never>) in
            let v: Value? = lock.withLock { if value == nil { waiter = c }; return value }
            if let v { c.resume(returning: v) }
        }
    }
}

/// Readers of abandoned (cancelled) exports whose pumps have not returned yet — e.g. a read stuck inside AVFoundation.
/// Each stays strongly referenced (by its pump task) until the pumps return; then `cleanup` cancels and releases it.
/// It never blocks another export; app quit waits for them a bounded time (`waitAll`).
public final class ParkedReaders: @unchecked Sendable {
    public static let shared = ParkedReaders()
    private let lock = NSLock()
    private var parked: [String: Int] = [:]
    private var cleaned: Set<String> = []
    /// Abandoned readers still being read (tests / diagnostics).
    public var count: Int { lock.withLock { parked.values.reduce(0, +) } }
    /// The export to `id` (its output path) has a reader parked / had it cancelled after its pumps returned.
    public func isParked(_ id: String) -> Bool { lock.withLock { (parked[id] ?? 0) > 0 } }
    public func wasCleanedUp(_ id: String) -> Bool { lock.withLock { cleaned.contains(id) } }

    func park(_ id: String, _ pumps: Task<Void, Never>, cleanup: @escaping @Sendable () -> Void) {
        lock.withLock { parked[id, default: 0] += 1; cleaned.remove(id) }
        Task.detached { [self] in
            await pumps.value
            cleanup()
            lock.withLock { parked[id, default: 1] -= 1; if parked[id] == 0 { parked[id] = nil }; cleaned.insert(id) }
        }
    }

    /// Waits until no reader is parked, at most `timeout` s. Returns false when some are still stuck (app quit then
    /// leaves without framework teardown, `AppShutdown`).
    public func waitAll(timeout: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while count > 0 {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }
}
