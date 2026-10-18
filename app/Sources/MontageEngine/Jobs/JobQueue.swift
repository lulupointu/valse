import Foundation
import MontageCore

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

    public init(maxConcurrent: Int) { self.maxConcurrent = maxConcurrent }

    @discardableResult
    public func enqueue(titleKey: String, detail: String = "", priority: Int = 0, subject: String? = nil,
                        _ body: @escaping @Sendable (JobProgress) async throws -> Void) -> JobID {
        let id = JobID()
        jobs[id] = JobInfo(id: id, titleKey: titleKey, detail: detail, priority: priority, progress: 0, state: .queued, subject: subject)
        order.append(id)
        work[id] = body
        publish()
        schedule()
        return id
    }

    public func cancel(_ id: JobID) {
        if let t = tasks[id] { t.cancel() } else if jobs[id]?.state == .queued { finish(id, .cancelled) }
    }

    public func cancelAll() { for id in order { cancel(id) } }

    /// Waits for a job to end.
    public func wait(_ id: JobID) async -> JobInfo.State {
        if let s = jobs[id]?.state, s != .queued, s != .running { return s }
        return await withCheckedContinuation { c in waiters[id, default: []].append(c) }
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

    func setProgress(_ id: JobID, _ p: Double) {
        guard jobs[id]?.state == .running else { return }
        jobs[id]?.progress = min(max(p, 0), 1)
        publish()
    }

    private func schedule() {
        let running = jobs.values.filter { $0.state == .running }.count
        guard running < maxConcurrent else { return }
        let next = order.compactMap { jobs[$0] }.filter { $0.state == .queued }.max { $0.priority < $1.priority }
        guard let job = next, let body = work[job.id] else { return }
        jobs[job.id]?.state = .running
        let handle = JobProgress(id: job.id, queue: self)
        tasks[job.id] = Task.detached(priority: job.priority > 0 ? .userInitiated : .utility) { [weak self] in
            var end: JobInfo.State = .done
            do { try await body(handle) } catch is CancellationError { end = .cancelled } catch {
                end = Task.isCancelled ? .cancelled : .failed(String(describing: error))
            }
            if Task.isCancelled, end == .done { end = .cancelled }
            await self?.finish(job.id, end)
        }
        publish()
        schedule()
    }

    private func finish(_ id: JobID, _ state: JobInfo.State) {
        jobs[id]?.state = state
        if state == .done { jobs[id]?.progress = 1 }
        tasks[id] = nil
        work[id] = nil
        for w in waiters.removeValue(forKey: id) ?? [] { w.resume(returning: state) }
        // keep finished jobs visible briefly; trim history
        let finished = order.filter { if let s = jobs[$0]?.state { return s != .queued && s != .running }; return false }
        if finished.count > 20 { for f in finished.prefix(finished.count - 20) { jobs[f] = nil; order.removeAll { $0 == f } } }
        publish()
        schedule()
    }

    private func publish() {
        let s = snapshot
        for c in subscribers.values { c.yield(s) }
    }
}
