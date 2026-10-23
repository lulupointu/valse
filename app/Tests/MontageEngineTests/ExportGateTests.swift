import Foundation
import Testing
@testable import MontageEngine

/// FLAKY-SYS-UNIT: bounded export concurrency (ExportGate) and OffPool's own threads (BlockingThreads) — both keep
/// blocking AVFoundation reads from exhausting GCD's 64-thread soft limit.
@Suite struct ExportGateTests {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var now = 0, top = 0
        func enter() { lock.withLock { now += 1; top = max(top, now) } }
        func leave() { lock.withLock { now -= 1 } }
        var peak: Int { lock.withLock { top } }
    }

    @Test func atMostLimitBodiesRunAtOnceAndAllFinish() async throws {
        let gate = ExportGate(limit: 3), c = Counter()
        try await withThrowingTaskGroup(of: Void.self) { g in
            for _ in 0..<20 {
                g.addTask {
                    try await gate.run {
                        c.enter(); defer { c.leave() }
                        try await Task.sleep(nanoseconds: 5_000_000)
                    }
                }
            }
            try await g.waitForAll()
        }
        #expect(c.peak <= 3 && c.peak >= 1)
        #expect(gate.peakRunning <= 3)
    }

    @Test func cancelWhileWaitingThrowsAndFreesNothing() async throws {
        let gate = ExportGate(limit: 1)
        let hold = AsyncStream<Void>.makeStream()
        let holder = Task { try await gate.run { for await _ in hold.stream {} } }
        while gate.peakRunning < 1 { await Task.yield() }
        let waiter = Task { try await gate.run { 42 } }
        try await Task.sleep(nanoseconds: 20_000_000)
        waiter.cancel()
        await #expect(throws: CancellationError.self) { _ = try await waiter.value }
        hold.continuation.finish()
        try await holder.value
        // the slot is free again: a new body runs at once
        #expect(try await gate.run { 7 } == 7)
    }

    @Test func transientVideoToolboxErrorsAreRecognisedThroughTheChain() {
        let vt = NSError(domain: NSOSStatusErrorDomain, code: -12902)
        let av = NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [NSUnderlyingErrorKey: vt])
        #expect(VideoToolboxErrors.isTransient(av))
        #expect(!VideoToolboxErrors.isTransient(NSError(domain: "AVFoundationErrorDomain", code: -11800)))
        #expect(!VideoToolboxErrors.isTransient(NSError(domain: NSCocoaErrorDomain, code: -12902)))
        #expect(Exporter.describe(av).contains("-11800 ← NSOSStatusErrorDomain -12902"))
    }

    @Test func blockingWorkDoesNotUseGCDWorkers() async throws {
        // 100 bodies blocked at once (more than GCD's 64 soft limit) all start: each gets its own thread
        let n = 100
        let started = Counter()
        let release = DispatchSemaphore(value: 0)
        try await withThrowingTaskGroup(of: Void.self) { g in
            for _ in 0..<n {
                g.addTask { try await OffPool.run { _ in started.enter(); release.wait() } }
            }
            var spins = 0
            while started.peak < n && spins < 2000 { try await Task.sleep(nanoseconds: 5_000_000); spins += 1 }
            #expect(started.peak == n, "only \(started.peak) of \(n) blocking bodies started")
            for _ in 0..<n { release.signal() }
            try await g.waitForAll()
        }
        #expect(BlockingThreads.shared.peakThreads >= n)
    }
}
