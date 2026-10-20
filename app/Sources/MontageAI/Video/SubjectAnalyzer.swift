@preconcurrency import AVFoundation
import Vision
import ImageIO
import Foundation
import MontageCore
import MontageEngine

/// Finds the subject of each sampled frame for auto reframe (AI-012) and AI movement: faces first (largest),
/// then people (human rectangles), then attention saliency, else the frame centre. Samples at `fps` on a ≤ 512 px decode.
public enum SubjectAnalyzer {
    public static func samples(_ asset: MediaAsset, range: TimeRange? = nil, fps: Double = 5,
                               progress: (@Sendable (Double) -> Void)? = nil) async throws -> [SubjectSample] {
        let av = AVURLAsset(url: asset.url)
        guard let track = try await av.loadTracks(withMediaType: .video).first else { throw AIToolError.noInput }
        let natural = try await track.load(.naturalSize)
        let full = try await av.load(.duration).seconds
        let total = range?.duration.seconds ?? full
        let k = min(1, 512 / max(natural.width, natural.height, 1))
        let reader = try AVAssetReader(asset: av)
        if let range { reader.timeRange = range.cmTimeRange }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey as String: max(16, Int(natural.width * k) / 2 * 2),
            kCVPixelBufferHeightKey as String: max(16, Int(natural.height * k) / 2 * 2)])
        out.alwaysCopiesSampleData = false
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? AIToolError.noInput }
        defer { reader.cancelReading() }
        let orientation = Self.orientation(asset.sourceRotation)
        var result: [SubjectSample] = []
        var next = -Double.infinity
        let start = range?.start.seconds ?? 0
        // blocking read loop: off the cooperative pool (OffPool)
        try await OffPool.run { ctx in
            while let sb = out.copyNextSampleBuffer() {
                try ctx.checkCancellation()
                let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
                guard t >= next, let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
                next = t + 1 / fps
                let s = try autoreleasepool { try subject(pb, orientation: orientation) }
                result.append(SubjectSample(time: t, x: s.x, y: s.y, confidence: s.c))
                progress?(min(1, (t - start) / max(total, 0.001)))
            }
        }
        return result
    }

    static func orientation(_ rotation: Int) -> CGImagePropertyOrientation {
        switch (rotation % 360 + 360) % 360 { case 90: return .right; case 180: return .down; case 270: return .left; default: return .up }
    }

    /// Subject centre in normalised display coordinates (origin top-left) + confidence.
    static func subject(_ pb: CVPixelBuffer, orientation: CGImagePropertyOrientation) throws -> (x: Double, y: Double, c: Double) {
        try subject(VNImageRequestHandler(cvPixelBuffer: pb, orientation: orientation))
    }

    /// Subject of a still image (AI movement Ken Burns on photos), decoded at ≤ 512 px.
    public static func still(_ url: URL) throws -> SubjectSample {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                                                     kCGImageSourceThumbnailMaxPixelSize: 512] as CFDictionary)
        else { throw AIToolError.noInput }
        let s = try subject(VNImageRequestHandler(cgImage: img))
        return SubjectSample(time: 0, x: s.x, y: s.y, confidence: s.c)
    }

    static func subject(_ handler: VNImageRequestHandler) throws -> (x: Double, y: Double, c: Double) {
        let faces = VNDetectFaceRectanglesRequest()
        let humans = VNDetectHumanRectanglesRequest()
        humans.upperBodyOnly = false
        let saliency = VNGenerateObjectnessBasedSaliencyImageRequest()
        try handler.perform([faces, humans, saliency])
        func centre(_ r: CGRect, bias: Double = 0) -> (Double, Double) { (Double(r.midX), 1 - Double(r.midY) - bias) }
        if let f = faces.results?.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }),
           f.confidence > 0.5 {
            // keep head room: aim slightly below the face
            let (x, y) = centre(f.boundingBox, bias: -Double(f.boundingBox.height) * 0.4)
            return (x, y, Double(f.confidence))
        }
        if let h = humans.results?.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }),
           h.confidence > 0.4 {
            // aim at the upper third of the body (where the face usually is)
            let r = h.boundingBox
            return (Double(r.midX), 1 - Double(r.maxY) + Double(r.height) * 0.3, Double(h.confidence))
        }
        if let obs = saliency.results?.first, let objs = obs.salientObjects, !objs.isEmpty {
            let best = objs.max { $0.confidence * Float($0.boundingBox.width * $0.boundingBox.height) < $1.confidence * Float($1.boundingBox.width * $1.boundingBox.height) }!
            let (x, y) = centre(best.boundingBox)
            return (x, y, Double(max(best.confidence, 0.3)))
        }
        return (0.5, 0.5, 0)
    }
}

/// Auto reframe job: analysis + path + keyframes (+ project ratio change), as one undoable edit.
public enum AutoReframe {
    public static func run(project p: Project, clipID: ClipID, options: ReframeOptions,
                           progress: (@Sendable (Double) -> Void)? = nil) async throws -> any EditCommand {
        guard let clip = p.timeline.clip(clipID), let asset = clip.mediaID.flatMap(p.asset), asset.kind == .video else { throw AIToolError.noInput }
        let raw = try await SubjectAnalyzer.samples(asset, range: clip.sourceRange, progress: progress)
        let path = ReframePath.smooth(raw, options: options)
        let target = ReframePath.canvas(for: options.ratio, current: p.settings.canvasSize) ?? p.settings.canvasSize
        let source = asset.pixelSize
        return Edit("cmd.reframe") { p in
            if target != p.settings.canvasSize {
                p.settings.canvasSize = target
                p.settings.aspectPreset = options.ratio
            }
            guard var c = p.timeline.clip(clipID) else { throw EditError.clipNotFound }
            ReframePath.apply(path, to: &c, source: source, canvas: target)
            p.timeline[clip: clipID] = c
        }
    }
}
