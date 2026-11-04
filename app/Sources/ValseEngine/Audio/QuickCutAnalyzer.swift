@preconcurrency import AVFoundation
import Foundation
import ValseCore

/// Quick cut analysis per media (TL-048): decodes the first audio track at 16 kHz mono (audio only, never the video),
/// runs `QuickCutDetector` while streaming, and caches the `QuickCutMask` per content hash in memory and on disk
/// (`Caches/Valse/quickcut/<contentHash>.v3`). ≈ 1000× realtime per file; work runs off the main thread and off the
/// cooperative pool (`OffPool`), at most 4 files at once, cancellable, and concurrent requests for one media share
/// one decode.
///
/// UI use: `prefetch` on import and when the Quick cut popover opens (utility QoS), `cached` for what is ready (cheap,
/// main-thread safe after the first disk read), `analyze` to await one media with progress.
public final class QuickCutAnalyzer: @unchecked Sendable {
    public static let shared = QuickCutAnalyzer()
    /// Files analysed at once.
    public static let parallelFiles = 4

    private let lock = NSLock()
    private var memory: [String: QuickCutMask] = [:]
    private var jobs: [String: Job] = [:]
    private let limiter = AsyncLimiter(QuickCutAnalyzer.parallelFiles)
    private let root: URL?
    private var decodeCount = 0
    /// Analyses started (decodes), for tests.
    var decodes: Int { lock.withLock { decodeCount } }

    /// `directory` overrides the disk cache folder (tests).
    public init(directory: URL? = nil) { root = directory }

    var directory: URL { root ?? ValsePaths.cacheDirectory.appendingPathComponent("quickcut", isDirectory: true) }
    /// Disk cache suffix, bumped whenever the detector's output changes (v2 = TL-048-fix2 speech edges, v3 = fix3:
    /// 25 dB edge level, exhales dropped, fricatives kept).
    static let cacheVersion = "v3"
    func file(_ hash: String) -> URL { directory.appendingPathComponent("\(hash).\(Self.cacheVersion)") }

    static func key(_ a: MediaAsset) -> String { a.contentHash.isEmpty ? "url:" + a.url.path : a.contentHash }

    /// The mask if already computed (memory, then disk). Nil = not analysed yet.
    public func cached(_ asset: MediaAsset) -> QuickCutMask? {
        if !asset.hasAudio { return .empty }
        let k = Self.key(asset)
        if let m = lock.withLock({ memory[k] }) { return m }
        guard !asset.contentHash.isEmpty, let d = try? Data(contentsOf: file(asset.contentHash)),
              let m = try? JSONDecoder().decode(QuickCutMask.self, from: d) else { return nil }
        lock.withLock { memory[k] = m }
        return m
    }

    /// Masks of the assets already analysed, by media id (for `QuickCut.plan`).
    public func cachedMasks(_ assets: [MediaAsset]) -> [MediaID: QuickCutMask] {
        var out: [MediaID: QuickCutMask] = [:]
        for a in assets { if let m = cached(a) { out[a.id] = m } }
        return out
    }

    /// Analyses one media (or joins the analysis already running for it). Progress 0 … 1. Cancelling the calling task
    /// stops the decode unless another caller still waits for it.
    public func analyze(_ asset: MediaAsset, progress: (@Sendable (Double) -> Void)? = nil) async throws -> QuickCutMask {
        if let m = cached(asset) { progress?(1); return m }
        try Task.checkCancellation()
        let k = Self.key(asset)
        let (job, token) = lock.withLock { () -> (Job, UUID) in
            let j = jobs[k] ?? makeJob(asset, key: k)
            return (j, j.addWaiter(progress))
        }
        return try await withTaskCancellationHandler {
            defer { leave(job, token, key: k) }
            return try await job.task.value
        } onCancel: {
            leave(job, token, key: k)
        }
    }

    /// Starts analysing every asset not analysed yet, in the background (utility QoS, `parallelFiles` at once).
    /// Cancel the returned task to stop (analyses other callers wait for keep running).
    @discardableResult
    public func prefetch(_ assets: [MediaAsset]) -> Task<Void, Never> {
        var seen = Set<String>()
        let todo = assets.filter { a in
            let k = Self.key(a)
            return a.hasAudio && seen.insert(k).inserted && lock.withLock { memory[k] } == nil
        }
        return Task.detached(priority: .utility) { [self] in
            await withTaskGroup(of: Void.self) { g in
                for a in todo { g.addTask(priority: .utility) { _ = try? await self.analyze(a) } }
            }
        }
    }

    /// Forgets the memory cache (tests).
    public func clearMemory() { lock.withLock { memory.removeAll() } }

    // MARK: Jobs

    /// One running analysis shared by every caller waiting for that media.
    final class Job: @unchecked Sendable {
        var task: Task<QuickCutMask, Error>!
        private let lock = NSLock()
        private var waiters: [UUID: (@Sendable (Double) -> Void)?] = [:]
        private var last = 0.0

        func addWaiter(_ p: (@Sendable (Double) -> Void)?) -> UUID {
            let id = UUID()
            let v = lock.withLock { waiters[id] = p; return last }
            if v > 0 { p?(v) }
            return id
        }
        /// Removes a waiter; true when it was the last one (false when already removed).
        func removeWaiter(_ id: UUID) -> Bool {
            lock.withLock { waiters.removeValue(forKey: id) != nil && waiters.isEmpty }
        }
        func report(_ v: Double) {
            let handlers = lock.withLock { last = v; return Array(waiters.values) }
            for h in handlers { h?(v) }
        }
    }

    /// Called with `lock` held.
    private func makeJob(_ asset: MediaAsset, key: String) -> Job {
        decodeCount += 1
        let job = Job()
        let limiter = self.limiter
        // the task holds the job until it finishes (progress relay), the job holds the task: released together
        job.task = Task.detached(priority: .utility) { [weak self, job] in
            try await limiter.acquire()
            defer { limiter.release() }
            let mask = try await Self.compute(url: asset.url) { job.report($0) }
            self?.store(mask, for: asset, key: key)
            return mask
        }
        jobs[key] = job
        return job
    }

    private func leave(_ job: Job, _ token: UUID, key: String) {
        // nobody waits any more: forget the job (a later request starts afresh) and stop it if still running
        let stop = lock.withLock { () -> Bool in
            guard job.removeWaiter(token) else { return false }
            if jobs[key] === job { jobs[key] = nil }
            return true
        }
        if stop { job.task.cancel() }
    }

    private func store(_ mask: QuickCutMask, for asset: MediaAsset, key: String) {
        lock.withLock { memory[key] = mask }
        guard !asset.contentHash.isEmpty else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(mask).write(to: file(asset.contentHash), options: .atomic)
    }

    // MARK: Decode + detect

    public enum AnalysisError: Error { case unreadable }

    /// Decodes the first audio track of `url` at 16 kHz mono and runs the detector on the stream. A file without an
    /// audio track gives `QuickCutMask.empty`. Resampled by `AudioFileIO.stream` (deterministic; the reader's own
    /// resampling zeroed samples at random AAC packet boundaries, BUG-AUDIO-RESAMPLE-ALL).
    public static func compute(url: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> QuickCutMask {
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { return .empty }
        let duration = try await asset.load(.duration).seconds
        var det = QuickCutDetector()
        var fed = 0
        var lastReport = 0.0
        // (the blocking read loop + DSP run off the cooperative pool: AudioFileIO.stream → OffPool)
        try await AudioFileIO.stream(url, sampleRate: Double(QuickCutDetector.sampleRate), channels: 1, qos: .utility) { b in
            det.feed(UnsafeBufferPointer(start: b[0], count: b.frames))
            fed += b.frames
            if duration > 0 {
                let f = min(0.99, Double(fed) / Double(QuickCutDetector.sampleRate) / duration)
                if f - lastReport >= 0.02 { lastReport = f; progress?(f) }
            }
        }
        try Task.checkCancellation()
        let mask = QuickCutDetector.mask(det.finishFeatures())
        progress?(1)
        return mask
    }
}

/// Async counting semaphore (bounded parallelism), cancellation-aware.
final class AsyncLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private var free: Int
    private var waiters: [(id: UUID, c: CheckedContinuation<Void, Error>)] = []

    init(_ n: Int) { free = n }

    func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled { lock.unlock(); c.resume(throwing: CancellationError()); return }
                if free > 0 { free -= 1; lock.unlock(); c.resume(); return }
                waiters.append((id, c))
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            if let i = waiters.firstIndex(where: { $0.id == id }) {
                let c = waiters.remove(at: i).c
                lock.unlock()
                c.resume(throwing: CancellationError())
            } else { lock.unlock() }
        }
    }

    func release() {
        lock.lock()
        if waiters.isEmpty { free += 1; lock.unlock(); return }
        let c = waiters.removeFirst().c
        lock.unlock()
        c.resume()
    }
}
