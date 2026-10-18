@preconcurrency import AVFoundation
import Foundation
import MontageCore

/// Background proxy generation + lookup (mandatory for 4K/HEVC on 8 GB machines, STACK.md §5).
///
/// Proxy format: H.264, short side ≤ 720 px, GOP 10, no B-frames (hardware decode on every Apple Silicon, cheap random
/// access), video only (audio always comes from the original). Stored in ~/Library/Caches/Montage/proxies/<hash>.mp4,
/// keyed by content hash, so proxies survive relinks and are shared across projects.
/// Preview uses a proxy automatically as soon as it is ready (`PlaybackEngine.sourceChooser` → rebuild);
/// export always uses originals.
public final class ProxyManager: @unchecked Sendable {
    public static let shared = ProxyManager()

    public enum Policy: String, Codable, Sendable, CaseIterable { case auto, always, never }

    public var policy: Policy = .auto
    public let directory: URL
    private let lock = NSLock()
    private var ready: Set<String> = []
    private var pending: [String: JobID] = [:]
    /// Called (on the main actor) when a proxy becomes ready: argument = content hash.
    @MainActor public var onProxyReady: ((String) -> Void)?

    init() {
        directory = MontagePaths.cacheDirectory.appendingPathComponent("proxies", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        ready = Set(files.filter { $0.hasSuffix(".mp4") }.map { String($0.dropLast(4)) })
    }

    public func proxyURL(for a: MediaAsset) -> URL { directory.appendingPathComponent("\(a.contentHash).mp4") }

    /// Ready proxy file, if any (thread-safe, synchronous: used while building compositions).
    public func readyProxyURL(for a: MediaAsset) -> URL? {
        guard policy != .never, a.kind == .video else { return nil }
        return lock.withLock { ready.contains(a.contentHash) } ? proxyURL(for: a) : nil
    }

    public func isPending(_ a: MediaAsset) -> Bool { lock.withLock { pending[a.contentHash] != nil } }

    public func shouldGenerate(_ a: MediaAsset) -> Bool {
        switch policy {
        case .never: return false
        case .always: return a.kind == .video && a.hasVideo
        case .auto: return MemoryBudget.wantsProxy(a)
        }
    }

    /// Queues proxy generation for the assets that need one (idempotent).
    public func request(_ assets: [MediaAsset], force: Bool = false) async {
        for a in assets where (force || shouldGenerate(a)) && a.kind == .video && !PlayableMediaCache.shared.needsConversion(a) {
            let skip = lock.withLock { ready.contains(a.contentHash) || pending[a.contentHash] != nil }
            if skip { continue }
            let src = PlayableMediaCache.shared.resolvedURL(for: a), dst = proxyURL(for: a), hash = a.contentHash
            let id = await JobQueue.shared.enqueue(titleKey: "job.proxy", detail: a.name, priority: -1, subject: hash) { progress in
                try await ProxyManager.generate(source: src, to: dst, progress: progress)
            }
            lock.withLock { pending[hash] = id }
            Task {
                let state = await JobQueue.shared.wait(id)
                self.lock.withLock { self.pending[hash] = nil }
                if state == .done {
                    self.lock.withLock { _ = self.ready.insert(hash) }
                    await MainActor.run { self.onProxyReady?(hash) }
                }
            }
        }
    }

    public func deleteAll() {
        lock.withLock { ready.removeAll() }
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Transcodes `source` to a proxy (AVAssetReader → AVAssetWriter, hardware H.264, scaled by the writer).
    public static func generate(source: URL, to dst: URL, maxShortSide: Int = 720, progress: JobProgress? = nil) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw MediaProbeError.unsupported(source) }
        let (natural, transform, rate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let duration = try await asset.load(.duration).seconds
        let short = min(natural.width, natural.height)
        let k = min(1, Double(maxShortSide) / Double(max(short, 1)))
        func even(_ v: Double) -> Int { max(2, Int((v * k / 2).rounded()) * 2) }
        let w = even(natural.width), h = even(natural.height)

        let tmp = dst.deletingLastPathComponent().appendingPathComponent("tmp-\(UUID().uuidString).mp4")
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()])
        out.alwaysCopiesSampleData = false
        reader.add(out)
        let writer = try AVAssetWriter(outputURL: tmp, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(2_000_000, w * h * 6),
                                              AVVideoMaxKeyFrameIntervalKey: 10,
                                              AVVideoAllowFrameReorderingKey: false,
                                              AVVideoExpectedSourceFrameRateKey: max(Double(rate), 1)]])
        input.transform = transform
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        guard reader.startReading(), writer.startWriting() else { throw reader.error ?? writer.error ?? NSError(domain: "Montage", code: 70) }
        writer.startSession(atSourceTime: .zero)
        let io = UncheckedSendable((reader, out, input))
        let cancelled: Bool = await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                let q = DispatchQueue(label: "montage.proxy")
                let done = UncheckedSendable(Flag())
                io.value.2.requestMediaDataWhenReady(on: q) {
                    let (reader, out, input) = io.value
                    while input.isReadyForMoreMediaData && !done.value.v {
                        if let sb = out.copyNextSampleBuffer() {
                            progress?.report(CMSampleBufferGetPresentationTimeStamp(sb).seconds / max(duration, 0.001))
                            if !input.append(sb) { done.value.v = true }
                        } else { done.value.v = true }
                        if done.value.v { input.markAsFinished(); c.resume(returning: reader.status == .cancelled) }
                    }
                }
            }
        } onCancel: { io.value.0.cancelReading() }
        if cancelled || Task.isCancelled {
            writer.cancelWriting(); try? FileManager.default.removeItem(at: tmp); throw CancellationError()
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? NSError(domain: "Montage", code: 71) }
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.moveItem(at: tmp, to: dst)
    }

    private final class Flag { var v = false }
}
