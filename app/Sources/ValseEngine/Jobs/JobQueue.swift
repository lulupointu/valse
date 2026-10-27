import Foundation
import ValseCore

public typealias JobID = Identifier<JobQueue>

/// Snapshot of a background job for the UI ("Applying… 34 %", job list).
public struct JobInfo: Sendable, Identifiable, Equatable {
    public enum State: Sendable, Equatable { case queued, running, done, failed(String), cancelled }
    public let id: JobID
    public let titleKey: String
    public let detail: String
    public let priority: Int
    public var progress: Double
    public var state: State
    /// Optional subject (media content hash / clip id) so the UI can show progress on the right item.
    public let subject: String?
}

/// Handle passed to running work.
public final class JobProgress: @unchecked Sendable {
    let id: JobID
    weak var queue: JobQueue?
    init(id: JobID, queue: JobQueue) { self.id = id; self.queue = queue }
    /// Report progress 0…1 (throttle not needed: cheap).
    public func report(_ p: Double) { let q = queue; let id = id; Task { await q?.setProgress(id, p) } }
    public var isCancelled: Bool { Task.isCancelled }
}

/// Background job system: priority queue, bounded concurrency, progress, cancel. Used by proxies, waveform/thumbnail
/// pre-computation and AI tools. Heavy GPU/ANE work should use priority ≤ 0 so interactive jobs go first.
public actor JobQueue {
    public static let shared = JobQueue(maxConcurrent: 2)

    private let maxConcurrent: Int
    private var jobs: [JobID: JobInfo] = [:]
    private var order: [JobID] = []
    private var work: [JobID: @Sendable (JobProgress) async throws -> Void] = [:]
    private var tasks: [JobID: Task<Void, Never>] = [:]
    private var subscribers: [UUID: AsyncStream<[JobInfo]>.Continuation] = [:]
    private var waiters: [JobID: [CheckedContinuation<JobInfo.State, Never>]] = [:]
    /// The error a `.failed` job threw (the state only carries its description): callers present typed reasons
    /// (e.g. `SpeechFailure`) instead of matching strings. Trimmed with the job history.
    private var errors: [JobID: any Error] = [:]
    private var isShutDown = false
    /// Heavy jobs waiting for `HeavyWorkGate` (not schedulable yet) / holding it until they end (test processes).
    private var awaitingGate: Set<JobID> = []
    private var holdingGate: Set<JobID> = []

    public init(maxConcurrent: Int) { self.maxConcurrent = maxConcurrent }

    /// `heavy`: ML / GPU-saturating work (Vision, Core ML, whisper, demucs …). In a unit-test process it runs inside
    /// `HeavyWorkGate` (serialized with the other heavy tests and away from the real-time probes) unless the enqueuing
    /// task already holds the gate.
    @discardableResult
    public func enqueue(titleKey: String, detail: String = "", priority: Int = 0, heavy: Bool = false, subject: String? = nil,
                        _ body: @escaping @Sendable (JobProgress) async throws -> Void) -> JobID {
        let id = JobID()
        jobs[id] = JobInfo(id: id, titleKey: titleKey, detail: detail, priority: priority, progress: 0, state: .queued, subject: subject)
        order.append(id)
        work[id] = body
        // `isHeld` is read in the caller's task (the job runs in a detached task, which doesn't inherit task-locals).
        // The gate is taken BEFORE the job may take a slot: a job waiting for the gate must not hold one of the
        // `maxConcurrent` slots that the gate holder's own job needs.
        if heavy && HeavyWorkGate.gatesJobs && !HeavyWorkGate.isHeld {
            awaitingGate.insert(id)
            Task.detached { [weak self] in
                await HeavyWorkGate.shared.acquire()
                if let self { await self.gateAcquired(id) } else { await HeavyWorkGate.shared.release() }
            }
        }
        publish()
        schedule()
        return id
    }

    public func cancel(_ id: JobID) {
        if let t = tasks[id] { t.cancel() } else if jobs[id]?.state == .queued { finish(id, .cancelled) }
    }

    public func cancelAll() { for id in order { cancel(id) } }

    /// App quit / end of a UI test: cancels every job and waits (up to `timeout` s) until no job body is still running.
    /// Exiting while a Core ML / Metal job is mid-inference crashes in the frameworks' atexit teardown (MPSGraph), so
    /// callers wait for this before `exit`. Returns false when something was still running at the timeout (the caller
    /// then leaves with `_exit`, which skips that teardown). No new job starts afterwards.
    @discardableResult
    public func shutdown(timeout: Double = 8) async -> Bool {
        isShutDown = true
        cancelAll()
        let deadline = Date().addingTimeInterval(timeout)
        while !tasks.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return tasks.isEmpty
    }

    /// Jobs whose body is still executing.
    public var runningCount: Int { tasks.count }

    /// Waits for a job to end.
    public func wait(_ id: JobID) async -> JobInfo.State {
        if let s = jobs[id]?.state, s != .queued, s != .running { return s }
        return await withCheckedContinuation { c in waiters[id, default: []].append(c) }
    }

    /// The error thrown by a failed job (nil while it runs, when it succeeded or was cancelled).
    public func error(_ id: JobID) -> (any Error)? { errors[id] }

    /// Waits for a job to end; returns its final state and, when it failed, the error it threw.
    public func waitResult(_ id: JobID) async -> (state: JobInfo.State, error: (any Error)?) {
        let s = await wait(id)
        return (s, errors[id])
    }

    public var snapshot: [JobInfo] { order.compactMap { jobs[$0] } }

    /// Stream of job lists (current list first).
    public func updates() -> AsyncStream<[JobInfo]> {
        let key = UUID()
        let (stream, cont) = AsyncStream<[JobInfo]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        subscribers[key] = cont
        cont.yield(snapshot)
        cont.onTermination = { [weak self] _ in Task { await self?.unsubscribe(key) } }
        return stream
    }

    private func unsubscribe(_ key: UUID) { subscribers[key] = nil }

    private func gateAcquired(_ id: JobID) {
        awaitingGate.remove(id)
        guard jobs[id]?.state == .queued else { Task { await HeavyWorkGate.shared.release() }; return }   // cancelled meanwhile
        holdingGate.insert(id)
        schedule()
    }

    func setProgress(_ id: JobID, _ p: Double) {
        guard jobs[id]?.state == .running else { return }
        jobs[id]?.progress = min(max(p, 0), 1)
        publish()
    }

    private func schedule() {
        if isShutDown {
            for id in order where jobs[id]?.state == .queued { finish(id, .cancelled) }
            return
        }
        let running = jobs.values.filter { $0.state == .running }.count
        guard running < maxConcurrent else { return }
        let next = order.compactMap { jobs[$0] }.filter { $0.state == .queued && !awaitingGate.contains($0.id) }.max { $0.priority < $1.priority }
        guard let job = next, let body = work[job.id] else { return }
        jobs[job.id]?.state = .running
        let handle = JobProgress(id: job.id, queue: self)
        tasks[job.id] = Task.detached(priority: job.priority > 0 ? .userInitiated : .utility) { [weak self] in
            var end: JobInfo.State = .done
            var thrown: (any Error)?
            do { try await body(handle) } catch is CancellationError { end = .cancelled } catch {
                end = Task.isCancelled ? .cancelled : .failed(String(describing: error))
                thrown = error
            }
            if Task.isCancelled, end == .done { end = .cancelled }
            await self?.finish(job.id, end, error: thrown)
        }
        publish()
        schedule()
    }

    private func finish(_ id: JobID, _ state: JobInfo.State, error: (any Error)? = nil) {
        jobs[id]?.state = state
        if case .failed = state, let error { errors[id] = error }
        if state == .done { jobs[id]?.progress = 1 }
        tasks[id] = nil
        work[id] = nil
        if holdingGate.remove(id) != nil { Task { await HeavyWorkGate.shared.release() } }
        for w in waiters.removeValue(forKey: id) ?? [] { w.resume(returning: state) }
        // keep finished jobs visible briefly; trim history
        let finished = order.filter { if let s = jobs[$0]?.state { return s != .queued && s != .running }; return false }
        if finished.count > 20 { for f in finished.prefix(finished.count - 20) { jobs[f] = nil; errors[f] = nil; order.removeAll { $0 == f } } }
        publish()
        schedule()
    }

    private func publish() {
        let s = snapshot
        for c in subscribers.values { c.yield(s) }
    }
}
