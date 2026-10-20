@preconcurrency import AVFoundation
import Vision
import Foundation
import MontageCore
import MontageEngine

/// Camera tracking analysis (AI-013): the main face (largest, sticky to the previous one) or the main body per frame,
/// sampled at 10 fps on a ≤ 512 px decode → `LockSample`s in display coordinates (size 0 = not found).
public enum CameraTracker {
    public static func samples(_ asset: MediaAsset, range: TimeRange, target: CameraLockOptions.Target,
                               progress: (@Sendable (Double) -> Void)? = nil) async throws -> [LockSample] {
        let av = AVURLAsset(url: ProxyManager.shared.readyProxyURL(for: asset) ?? asset.url)
        guard let track = try await av.loadTracks(withMediaType: .video).first else { throw AIToolError.noInput }
        let natural = try await track.load(.naturalSize)
        let k = min(1, 512 / max(natural.width, natural.height, 1))
        let reader = try AVAssetReader(asset: av)
        reader.timeRange = range.cmTimeRange
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey as String: max(16, Int(natural.width * k) / 2 * 2),
            kCVPixelBufferHeightKey as String: max(16, Int(natural.height * k) / 2 * 2)])
        out.alwaysCopiesSampleData = false
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? AIToolError.noInput }
        defer { reader.cancelReading() }
        let orientation = SubjectAnalyzer.orientation(asset.sourceRotation)
        var result: [LockSample] = []
        var next = -Double.infinity
        var prev: CGRect?
        let total = max(range.duration.seconds, 0.001)
        // blocking read loop: off the cooperative pool (OffPool)
        try await OffPool.run { ctx in
            while let sb = out.copyNextSampleBuffer() {
                try ctx.checkCancellation()
                let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
                guard t >= next, let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
                next = t + 0.1
                let boxes: [CGRect] = try autoreleasepool {
                    let h = VNImageRequestHandler(cvPixelBuffer: pb, orientation: orientation)
                    if target == .face {
                        let r = VNDetectFaceRectanglesRequest(); try h.perform([r])
                        return (r.results ?? []).filter { $0.confidence > 0.5 }.map(\.boundingBox)
                    }
                    if target == .hand {
                        let r = VNDetectHumanHandPoseRequest(); r.maximumHandCount = 2; try h.perform([r])
                        return (r.results ?? []).compactMap { Self.handRect($0) }
                    }
                    let r = VNDetectHumanRectanglesRequest(); r.upperBodyOnly = false; try h.perform([r])
                    return (r.results ?? []).filter { $0.confidence > 0.4 }.map(\.boundingBox)
                }
                // stick to the subject followed so far (nearest), else the largest
                let pick = prev.flatMap { p in boxes.min { hypot($0.midX - p.midX, $0.midY - p.midY) < hypot($1.midX - p.midX, $1.midY - p.midY) } }
                    ?? boxes.max { $0.width * $0.height < $1.width * $1.height }
                if let b = pick {
                    prev = b
                    result.append(LockSample(time: t, x: Double(b.midX), y: 1 - Double(b.midY), size: Double(b.height)))
                } else {
                    result.append(LockSample(time: t, x: 0.5, y: 0.5, size: 0))
                }
                progress?(min(1, (t - range.start.seconds) / total))
            }
        }
        return result
    }

    /// Square box (Vision coordinates, origin bottom-left) around a hand pose's confident joints.
    static func handRect(_ o: VNHumanHandPoseObservation) -> CGRect? {
        guard let pts = try? o.recognizedPoints(.all) else { return nil }
        let joints = pts.values.map { (x: Double($0.location.x), y: Double($0.location.y), confidence: Double($0.confidence)) }
        guard let b = CameraLock.handBox(joints) else { return nil }
        let cy = 1 - b.y   // back to Vision's bottom-left origin
        return CGRect(x: b.x - b.size / 2, y: cy - b.size / 2, width: b.size, height: b.size)
    }
}

/// Camera tracking job → one undoable edit.
public enum CameraLockJob {
    public static func run(project p: Project, clipID: ClipID, options: CameraLockOptions,
                           progress: (@Sendable (Double) -> Void)? = nil) async throws -> any EditCommand {
        guard let c = p.timeline.clip(clipID), let a = c.mediaID.flatMap(p.asset), a.kind == .video else { throw AIToolError.noInput }
        let s: [LockSample]
        if options.target == .custom {
            // custom box (AI2): track the drawn object like motion tracking, then lock the camera on it
            guard let box = options.customBox else { throw AIToolError.noInput }
            let t = try await ObjectTracker.track(a, box: box, at: options.customTime ?? c.sourceStart.seconds, range: c.sourceRange, progress: progress)
            s = CameraLock.samples(fromTracked: t, rotation: a.sourceRotation)
        } else {
            s = try await CameraTracker.samples(a, range: c.sourceRange, target: options.target, progress: progress)
        }
        guard s.contains(where: { $0.size > 0 }) else { throw AIToolError.noInput }
        let source = a.pixelSize, canvas = p.settings.canvasSize
        return Edit("cmd.cameraLock") { p in
            guard var c = p.timeline.clip(clipID) else { throw EditError.clipNotFound }
            CameraLock.apply(s, to: &c, source: source, canvas: canvas, options: options)
            p.timeline[clip: clipID] = c
        }
    }
}
