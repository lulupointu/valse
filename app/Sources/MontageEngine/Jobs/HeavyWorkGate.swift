import Foundation
import MontageCore

/// Serializes work that saturates the GPU / ANE (whisper.cpp, Vision, Core ML, VideoToolbox ML, export benchmarks)
/// with real-time measurements (playback fps) in the unit tests: all suites share one test process, so without the
/// gate a real-time probe can be starved by an ML test running in parallel. Wrap either kind in `HeavyWorkGate.run { … }`.
///
/// ML jobs started through `JobQueue` (`heavy: true`) take the gate too in a test process (B1: a store flow such as
/// "Remove background" started its Vision job outside the gate), unless the enqueuing task already holds it
/// (re-entrant through the task-local `isHeld`, which `Task { }` inherits). In the app nothing else takes the gate,
/// so jobs are not gated there (`gatesJobs` is false).
public actor HeavyWorkGate {
    public static let shared = HeavyWorkGate()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// True inside `run` (and in tasks created from it).
    @TaskLocal public static var isHeld = false

    /// Unit-test process (`swift test` / Xcode): heavy `JobQueue` jobs go through the gate.
    public static let gatesJobs: Bool = MontageProcess.isUnitTest

    public static func run<T>(isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> T) async rethrows -> T {
        if isHeld { return try await body() }
        await shared.acquire()
        do {
            let r = try await $isHeld.withValue(true) { try await body() }
            await shared.release(); return r
        } catch { await shared.release(); throw error }
    }

    func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}
