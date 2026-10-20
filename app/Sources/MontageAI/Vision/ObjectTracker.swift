@preconcurrency import AVFoundation
import Vision
import Foundation
import MontageCore
import MontageEngine

/// Single-object tracker for motion tracking (AI-014 / ST-005): Vision `VNTrackObjectRequest` (accurate level) on a
/// ≤ 640 px decode of the reference media, forward from the box's time to the end of `range` and backward to its start
/// (backward = 1 s chunks decoded then walked in reverse, so memory stays ≈ 30 small frames). Boxes are raw source
/// coordinates (normalized, y down). Tracking stops in a direction when Vision loses the object (confidence < 0.3).
public enum ObjectTracker {
    public static func track(_ asset: MediaAsset, box: NormRect, at start: Double, range: TimeRange,
                             progress: (@Sendable (Double) -> Void)? = nil) async throws -> [TrackSample] {
        let av = AVURLAsset(url: ProxyManager.shared.readyProxyURL(for: asset) ?? asset.url)
        guard let track = try await av.loadTracks(withMediaType: .video).first else { throw AIToolError.noInput }
        let natural = try await track.load(.naturalSize)
        let k = min(1, 640 / max(natural.width, natural.height, 1))
        let size = (max(16, Int(natural.width * k) / 2 * 2), max(16, Int(natural.height * k) / 2 * 2))
        let lo = range.start.seconds, hi = range.end.seconds
        let s0 = min(max(start, lo), hi)
        let total = max(hi - lo, 0.001)
        let done = Counter()
        let report: @Sendable (Double) -> Void = { dt in progress?(min(1, done.add(dt) / total)) }

        var fwd: [TrackSample] = [], bwd: [TrackSample] = []
        // decoding + Vision tracking block: off the cooperative pool (OffPool)
        try await OffPool.run { ctx in
            // forward
            var tracker = Session(box: box)
            try forEachFrame(av, track: track, size: size, from: s0, to: hi, ctx: ctx) { t, pb, dt in
                report(dt)
                guard let b = try tracker.step(pb) else { return false }
                fwd.append(TrackSample(time: t, box: b))
                return true
            }
            // backward, chunk by chunk
            tracker = Session(box: box)
            var chunkEnd = s0
            var lost = false
            while chunkEnd > lo + 1e-3, !lost {
                try ctx.checkCancellation()
                let chunkStart = max(lo, chunkEnd - 1)
                var frames: [(Double, CVPixelBuffer)] = []
                try forEachFrame(av, track: track, size: size, from: chunkStart, to: chunkEnd, copy: true, ctx: ctx) { t, pb, _ in
                    if t < chunkEnd - 1e-4 { frames.append((t, pb)) }
                    return true
                }
                for (t, pb) in frames.reversed() {
                    report((chunkEnd - chunkStart) / Double(max(frames.count, 1)))
                    guard let b = try tracker.step(pb) else { lost = true; break }
                    bwd.append(TrackSample(time: t, box: b))
                }
                chunkEnd = chunkStart
            }
        }
        progress?(1)
        return bwd.reversed() + fwd
    }

    /// One Vision tracking sequence.
    struct Session {
        let handler = VNSequenceRequestHandler()
        var last: VNDetectedObjectObservation
        var first = true
        init(box: NormRect) {
            last = VNDetectedObjectObservation(boundingBox: CGRect(x: box.x, y: 1 - box.y - box.height, width: box.width, height: box.height))
        }
        /// Next box (raw, y down), nil when lost. The first frame returns the input box.
        mutating func step(_ pb: CVPixelBuffer) throws -> NormRect? {
            if first {
                first = false
                return Self.norm(last.boundingBox)
            }
            let req = VNTrackObjectRequest(detectedObjectObservation: last)
            req.trackingLevel = .accurate
            try handler.perform([req], on: pb)
            guard let o = req.results?.first as? VNDetectedObjectObservation, o.confidence >= 0.3 else { return nil }
            last = o
            return Self.norm(o.boundingBox)
        }
        static func norm(_ r: CGRect) -> NormRect {
            NormRect(x: Double(r.minX), y: 1 - Double(r.maxY), width: Double(r.width), height: Double(r.height))
        }
    }

    /// Decodes frames in [from, to] (BGRA, scaled); `body` returns false to stop. `copy` keeps buffers past the call.
    /// Blocking (`copyNextSampleBuffer`): call it off the cooperative pool (`OffPool.run`, passing its context for
    /// cancellation) or from a GCD thread.
    static func forEachFrame(_ av: AVURLAsset, track: AVAssetTrack, size: (Int, Int), from: Double, to: Double, copy: Bool = false,
                             ctx: OffPool.Context? = nil,
                             _ body: (Double, CVPixelBuffer, Double) throws -> Bool) throws {
        let reader = try AVAssetReader(asset: av)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 600),
                                       end: CMTime(seconds: to + 0.001, preferredTimescale: 600))
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.0, kCVPixelBufferHeightKey as String: size.1])
        out.alwaysCopiesSampleData = copy
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? AIToolError.noInput }
        defer { reader.cancelReading() }
        var prev = from
        while let sb = out.copyNextSampleBuffer() {
            if let ctx { try ctx.checkCancellation() } else { try Task.checkCancellation() }
            let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            guard t >= from - 1e-4, t <= to + 1e-4, let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let keep = try autoreleasepool { try body(t, pb, max(0, t - prev)) }
            prev = t
            if !keep { break }
        }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var v = 0.0
        func add(_ d: Double) -> Double { lock.withLock { v += d; return v } }
    }
}

/// Motion tracking job: track the object, then one undoable edit writing the follower's keyframes.
public enum MotionTrackingJob {
    public static func run(project p: Project, follower: ClipID, info: MotionTrackInfo,
                           progress: (@Sendable (Double) -> Void)? = nil) async throws -> any EditCommand {
        guard let ref = p.timeline.clip(info.referenceClipID), let asset = ref.mediaID.flatMap(p.asset), asset.kind == .video,
              let f = p.timeline.clip(follower) else { throw AIToolError.noInput }
        // only the part of the reference media under the follower matters
        let a = ref.sourceTime(at: max(f.start, ref.start)), b = ref.sourceTime(at: min(f.end, ref.end))
        let range = TimeRange(start: min(a, b), duration: abs((b - a).seconds) < 1e-6 ? Time(ticks: 1) : (max(a, b) - min(a, b)))
        let samples = try await ObjectTracker.track(asset, box: info.box, at: info.startTime, range: range, progress: progress)
        return Edit("cmd.tracking") { p in try MotionTracking.apply(samples, info: info, follower: follower, in: &p) }
    }
}
