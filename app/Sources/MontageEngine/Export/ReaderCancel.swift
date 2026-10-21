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
