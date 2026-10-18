@preconcurrency import AVFoundation
import Foundation
import MontageCore

/// CapCut "Export GIF" (EX-011): resolution 240P / 320P / 640P (short side).
public struct GIFSettings: Codable, Hashable, Sendable {
    public enum Resolution: Int, Codable, Sendable, CaseIterable {
        case p240 = 240, p320 = 320, p640 = 640
        public var label: String { "\(rawValue)P" }
    }
    public var resolution: Resolution = .p240
    /// GIF frame rate (centisecond delays): 15 fps keeps files small and plays evenly everywhere.
    public var fps: Double = 15
    public var dither: Bool = true
    public init(resolution: Resolution = .p240, fps: Double = 15) { self.resolution = resolution; self.fps = fps }

    public func outputSize(canvas: Size2) -> (width: Int, height: Int) {
        let short = Double(resolution.rawValue)
        let (w, h) = canvas.width >= canvas.height ? (short * canvas.aspect, short) : (short, short / canvas.aspect)
        func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }
        return (even(w), even(h))
    }

    public func frameCount(duration: Time) -> Int { max(1, Int((duration.seconds * fps).rounded())) }

    /// Rough size (LZW on dithered video ≈ 0.6 byte per pixel per frame).
    public func estimatedBytes(duration: Time, canvas: Size2) -> Int64 {
        let (w, h) = outputSize(canvas: canvas)
        return Int64(Double(w * h) * 0.6 * Double(frameCount(duration: duration)))
    }
}

public enum GIFExporter {
    /// Renders the range through the export compositor at GIF size and streams frames into `GIFEncoder`.
    public static func export(project: Project, settings: GIFSettings = GIFSettings(), to url: URL, range: TimeRange? = nil,
                              progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard project.duration > .zero else { throw ExportError.emptyProject }
        var project = project
        project.settings.colorSpace = .sdr709        // GIF is 8-bit sRGB-ish: tone-map HDR projects
        let (w, h) = settings.outputSize(canvas: project.settings.canvasSize)
        let fps = FrameRate(Int32(max(1, min(50, Int(settings.fps.rounded())))))
        let full = TimeRange(start: .zero, duration: project.duration)
        let r = range.flatMap { $0.intersection(full) } ?? full
        let built = try await CompositionBuilder.build(project: project, purpose: .export,
                                                       renderSize: CGSize(width: w, height: h), frameRate: fps)
        let reader = try AVAssetReader(asset: built.composition)
        reader.timeRange = r.cmTimeRange
        let out = AVAssetReaderVideoCompositionOutput(videoTracks: try await built.composition.loadTracks(withMediaType: .video),
                                                      videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        out.videoComposition = built.videoComposition
        out.alwaysCopiesSampleData = false
        reader.add(out)
        guard reader.startReading() else { throw ExportError.failed(reader.error?.localizedDescription ?? "reader") }
        try? FileManager.default.removeItem(at: url)
        let enc = try GIFEncoder(url: url, width: w, height: h, fps: fps.fps)
        enc.dither = settings.dither
        let expected = settings.frameCount(duration: r.duration)
        do {
            while let sb = out.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard enc.framesWritten < expected, let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
                CVPixelBufferLockBaseAddress(pb, .readOnly)
                if let base = CVPixelBufferGetBaseAddress(pb) {
                    enc.addFrame(bgra: base, bytesPerRow: CVPixelBufferGetBytesPerRow(pb))
                }
                CVPixelBufferUnlockBaseAddress(pb, .readOnly)
                progress?(min(0.999, Double(enc.framesWritten) / Double(expected)))
            }
            if reader.status == .failed { throw ExportError.failed(reader.error?.localizedDescription ?? "read failed") }
        } catch {
            reader.cancelReading(); enc.finish(); try? FileManager.default.removeItem(at: url)
            throw (error is CancellationError) ? ExportError.cancelled : error
        }
        enc.finish()
        progress?(1)
    }
}
