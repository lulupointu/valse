@preconcurrency import AVFoundation
import Vision
import Foundation
import MontageCore

/// Person segmentation with Vision (runs on ANE/GPU). Masks are IOSurface-backed OneComponent8 CVPixelBuffers that
/// can be wrapped as Metal textures without a copy (ported from the prototype: ~50 fps `.balanced` at 1080p on M1 Pro).
public enum PersonSegmenter {
    public enum Quality: Sendable { case fast, balanced, accurate
        var vision: VNGeneratePersonSegmentationRequest.QualityLevel {
            switch self { case .fast: return .fast; case .balanced: return .balanced; case .accurate: return .accurate }
        }
    }

    /// Calls `body(time, mask)` for each decoded frame of `url` in `range` (sequential; cancellable).
    public static func forEachMask(url: URL, range: TimeRange? = nil, quality: Quality = .balanced,
                                   progress: (@Sendable (Double) -> Void)? = nil,
                                   _ body: (Time, CVPixelBuffer) throws -> Void) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw AIToolError.noInput }
        let total = try await asset.load(.duration).seconds
        let reader = try AVAssetReader(asset: asset)
        if let range { reader.timeRange = range.cmTimeRange }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()])
        out.alwaysCopiesSampleData = false
        reader.add(out)
        reader.startReading()
        let req = VNGeneratePersonSegmentationRequest()
        req.qualityLevel = quality.vision
        req.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNSequenceRequestHandler()
        defer { reader.cancelReading() }
        while let sb = out.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let t = CMSampleBufferGetPresentationTimeStamp(sb)
            try autoreleasepool {
                try handler.perform([req], on: pb)
                guard let mask = req.results?.first?.pixelBuffer else { return }
                try body(Time(cmTime: t), mask)
            }
            progress?(t.seconds / max(total, 0.001))
        }
    }

    /// Segments one still frame (CGImage) — used for previews/thumbnails.
    public static func mask(for image: CGImage, quality: Quality = .balanced) throws -> CVPixelBuffer? {
        let req = VNGeneratePersonSegmentationRequest()
        req.qualityLevel = quality.vision
        req.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try VNImageRequestHandler(cgImage: image).perform([req])
        return req.results?.first?.pixelBuffer
    }
}
