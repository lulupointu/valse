@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ValseCore

/// Renders single frames of a project through the real compositor (AVAssetImageGenerator + ValseCompositor):
/// used for render tests, project cover thumbnails and "export frame".
public enum OfflineRenderer {
    /// Frame-exact render of `project` at `time`. `size` defaults to the canvas size. `sdr`: HDR projects are composed
    /// in Rec.709 SDR layer by layer (thumbnails / covers: SDR media keep their look instead of Apple's HLG → SDR tone
    /// map of the whole frame, which shows SDR white at ≈ 60 % grey, BUG-SDR-IN-HDR), like `StillFrameExporter`.
    public static func renderFrame(_ project: Project, at time: Time, size: CGSize? = nil, sdr: Bool = false) async throws -> CGImage {
        var project = project
        if sdr { project.settings.colorSpace = .sdr709 }
        let renderSize = size ?? CGSize(width: project.settings.canvasSize.width, height: project.settings.canvasSize.height)
        let built = try await CompositionBuilder.build(project: project, purpose: .export, renderSize: renderSize)
        let gen = AVAssetImageGenerator(asset: built.composition)
        gen.videoComposition = built.videoComposition
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        gen.maximumSize = renderSize
        let t = min(time, max(.zero, built.duration - project.settings.frameRate.frameDuration))
        let (img, _) = try await gen.image(at: t.cmTime)
        return img
    }
}
