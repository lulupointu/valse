import AVFoundation
import Vision

public struct SegmentationResult {
    public let frames: Int
    public let seconds: Double        // excluding first frame (model load / warm-up)
    public let firstFrameMs: Double
    public var fps: Double { Double(frames) / seconds }
}

/// Person segmentation (Vision, runs on ANE/GPU). Masks come back as IOSurface-backed
/// OneComponent8 CVPixelBuffers → wrap as MTLTexture via CVMetalTextureCache for the compositor (zero-copy).
public enum Segmenter {
    public static func run(url: URL, frames: Int, quality: VNGeneratePersonSegmentationRequest.QualityLevel) async throws -> SegmentationResult {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw NSError(domain: "Montage", code: 30) }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        out.alwaysCopiesSampleData = false
        reader.add(out)
        reader.startReading()
        let req = VNGeneratePersonSegmentationRequest()
        req.qualityLevel = quality
        req.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNSequenceRequestHandler()
        var n = 0
        var firstMs = 0.0
        var tStart = CACurrentMediaTime()
        while n < frames + 1, let sb = out.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let t = CACurrentMediaTime()
            try autoreleasepool {
                try handler.perform([req], on: pb)
                guard let mask = req.results?.first?.pixelBuffer, CVPixelBufferGetWidth(mask) > 0 else {
                    throw NSError(domain: "Montage", code: 31, userInfo: [NSLocalizedDescriptionKey: "no mask"])
                }
            }
            if n == 0 { firstMs = (CACurrentMediaTime() - t) * 1000; tStart = CACurrentMediaTime() }
            n += 1
        }
        reader.cancelReading()
        return SegmentationResult(frames: n - 1, seconds: CACurrentMediaTime() - tStart, firstFrameMs: firstMs)
    }
}
