import Foundation

/// Serializes tests that saturate the GPU / ANE (whisper.cpp, Vision, VideoToolbox ML, export benchmarks) with
/// real-time measurements (playback fps): all suites share one test process, so without the gate a real-time
/// probe can be starved by an ML test running in parallel. Wrap either kind in `HeavyWorkGate.run { … }`.
public actor HeavyWorkGate {
    public static let shared = HeavyWorkGate()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public static func run<T>(isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> T) async rethrows -> T {
        await shared.acquire()
        do { let r = try await body(); await shared.release(); return r } catch { await shared.release(); throw error }
    }

    func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}
