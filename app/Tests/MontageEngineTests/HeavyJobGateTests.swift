import Testing
import Foundation
import MontageCore
import MontageEngine

/// B1: heavy (ML) `JobQueue` jobs respect `HeavyWorkGate` in test processes, re-entrant for the gate holder, and a job
/// waiting for the gate never holds one of the queue's slots.
@Suite struct HeavyJobGateTests {
    @Test func heavyJobsWaitForTheGateWithoutTakingASlot() async throws {
        #expect(HeavyWorkGate.gatesJobs)
        let q = JobQueue(maxConcurrent: 1)
        let other: JobID = try await HeavyWorkGate.run {
            // enqueued by a task that doesn't hold the gate: waits for it
            let other = await Task.detached { await q.enqueue(titleKey: "t", heavy: true) { _ in } }.value
            // the holder's own heavy job runs at once (and isn't stuck behind `other` for the single slot)
            let mine = await q.enqueue(titleKey: "t", heavy: true) { _ in }
            #expect(await q.wait(mine) == .done)
            #expect(await q.snapshot.first { $0.id == other }?.state == .queued)
            return other
        }
        #expect(await q.wait(other) == .done)
    }

    @Test func cancellingAJobWaitingForTheGateReleasesIt() async throws {
        let q = JobQueue(maxConcurrent: 1)
        let waiting: JobID = await HeavyWorkGate.run {
            let id = await Task.detached { await q.enqueue(titleKey: "t", heavy: true) { _ in } }.value
            await q.cancel(id)
            return id
        }
        #expect(await q.wait(waiting) == .cancelled)
        // the gate is free again
        let done = await Task.detached { await HeavyWorkGate.run { true } }.value
        #expect(done)
    }
}
