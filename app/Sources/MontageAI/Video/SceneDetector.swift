@preconcurrency import AVFoundation
import Accelerate
import Foundation
import MontageCore
import MontageEngine

/// Shot-boundary detection (AI-026 "Split scene"): frames are decoded at 64×36, compared with a colour histogram
/// (HSV-like 8×4×4 bins, histogram intersection) and mean luma difference; a cut is a frame whose distance stands
/// out from the local average (adaptive threshold, PySceneDetect-style) with a minimum shot length. Pure CPU, ~1000+
/// fps on Apple silicon, so it runs on whole files in seconds.
public enum SceneDetector {
    public struct Options: Sendable {
        /// 0…1, higher = fewer cuts.
        public var threshold: Double = 0.35
        public var minShot: Double = 0.5
        public init(threshold: Double = 0.35, minShot: Double = 0.5) { self.threshold = threshold; self.minShot = minShot }
    }

    /// Media times (seconds) where a new shot starts, inside `range` (whole media when nil).
    public static func cuts(_ url: URL, range: TimeRange? = nil, options: Options = Options(),
                            progress: (@Sendable (Double) -> Void)? = nil) async throws -> [Double] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw AIToolError.noInput }
        let full = try await asset.load(.duration).seconds
        let total = range?.duration.seconds ?? full
        let reader = try AVAssetReader(asset: asset)
        if let range { reader.timeRange = range.cmTimeRange }
        let w = 64, h = 36
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        out.alwaysCopiesSampleData = false
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? AIToolError.noInput }
        defer { reader.cancelReading() }
        var times: [Double] = [], dist: [Double] = []
        var prevHist: [Float]?, prevLuma: Float = 0
        let start = range?.start.seconds ?? 0
        // blocking read loop: off the cooperative pool (OffPool)
        try await OffPool.run { ctx in
            while let sb = out.copyNextSampleBuffer() {
                try ctx.checkCancellation()
                guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
                let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
                let (hist, luma) = features(pb)
                if let ph = prevHist {
                    var inter: Float = 0
                    for i in hist.indices { inter += min(hist[i], ph[i]) }
                    dist.append(Double(1 - inter) * 0.8 + Double(abs(luma - prevLuma)) * 0.2)
                    times.append(t)
                }
                prevHist = hist; prevLuma = luma
                progress?(min(1, (t - start) / max(total, 0.001)))
            }
        }
        return pick(times: times, dist: dist, options: options)
    }

    /// Adaptive peak picking (exposed for tests).
    static func pick(times: [Double], dist: [Double], options o: Options) -> [Double] {
        var cuts: [Double] = []
        let win = 15
        for i in dist.indices {
            let lo = max(0, i - win), hi = min(dist.count, i + win + 1)
            let neighbours = (lo..<hi).filter { $0 != i }.map { dist[$0] }
            let mean = neighbours.isEmpty ? 0 : neighbours.reduce(0, +) / Double(neighbours.count)
            let isPeak = dist[i] >= (lo..<hi).map { dist[$0] }.max() ?? 0
            guard isPeak, dist[i] > o.threshold, dist[i] > mean * 3 + 0.05 else { continue }
            if let last = cuts.last, times[i] - last < o.minShot { continue }
            cuts.append(times[i])
        }
        return cuts
    }

    static func features(_ pb: CVPixelBuffer) -> ([Float], Float) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
        var hist = [Float](repeating: 0, count: 8 * 4 * 4)
        var luma: Float = 0
        guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else { return (hist, 0) }
        for y in 0..<h {
            let p = base.advanced(by: y * row)
            for x in 0..<w {
                let b = Float(p[4 * x]) / 255, g = Float(p[4 * x + 1]) / 255, r = Float(p[4 * x + 2]) / 255
                let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
                var hue: Float = 0
                if d > 1e-4 {
                    if mx == r { hue = (g - b) / d } else if mx == g { hue = 2 + (b - r) / d } else { hue = 4 + (r - g) / d }
                    hue = (hue / 6).truncatingRemainder(dividingBy: 1); if hue < 0 { hue += 1 }
                }
                let s = mx > 0 ? d / mx : 0
                let hi = min(7, Int(hue * 8)), si = min(3, Int(s * 4)), vi = min(3, Int(mx * 4))
                hist[hi * 16 + si * 4 + vi] += 1
                luma += 0.2126 * r + 0.7152 * g + 0.0722 * b
            }
        }
        let n = Float(w * h)
        return (hist.map { $0 / n }, luma / n)
    }
}

/// Split scene on the timeline: splits a media clip at every detected cut inside its source range.
public enum SceneSplit {
    /// Timeline split times for media cuts (media seconds) of `clip`.
    public static func splitTimes(_ cuts: [Double], clip: Clip) -> [Time] {
        cuts.compactMap { clip.timelineTime(forSource: Time($0)) }
            .filter { $0 - clip.start >= TimelineOps.minimumClipDuration && clip.end - $0 >= TimelineOps.minimumClipDuration }
    }

    public static func apply(_ times: [Time], to id: ClipID, in tl: inout Timeline) throws {
        var current = id
        guard !times.isEmpty else { throw EditError.nothingToDo }
        for t in times.sorted() { current = try TimelineOps.split(current, at: t, in: &tl) }
    }
}
