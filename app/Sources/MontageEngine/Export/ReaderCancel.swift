@preconcurrency import AVFoundation

/// Cancelling an `AVAssetReader` while another thread is inside `copyNextSampleBuffer` is a use-after-free in
/// AVFoundation: `cancelReading` tears down the outputs' decode / offline audio-mix engines under the waiting thread
/// (EXC_BAD_ACCESS in `FigSemaphoreWaitRelative` while `AQMixEngine_Offline` was destroyed; an export cancelled under
/// machine load, `ExportFormatTests.jobCancelDeletesPartialFiles`, ~1 crash in 15 runs). So a task's cancel handler
/// only `request`s the stop: the pumps — the only threads that read — stop at their next sample, and the caller calls
/// `cancelReading` after they returned (`finish`). A pump stuck in a copy that never returns is unblocked by a late
/// `cancelReading` after `fallback` s (last resort: the old behaviour).
final class ReaderCancel: @unchecked Sendable {
    private let lock = NSLock()
    private var requestedFlag = false, finished = false

    /// Checked by the pumps before every `copyNextSampleBuffer`.
    var requested: Bool { lock.withLock { requestedFlag } }

    /// From the cancel handler (any thread): stop reading.
    func request(_ reader: AVAssetReader, fallback: Double = 10) {
        lock.withLock { requestedFlag = true }
        let r = UncheckedSendable(reader)
        DispatchQueue.global().asyncAfter(deadline: .now() + fallback) { [self] in
            if !lock.withLock({ finished }) { r.value.cancelReading() }
        }
    }

    /// Every pump returned: nothing reads any more (the caller may now cancel the reader).
    func finish() { lock.withLock { finished = true } }
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
