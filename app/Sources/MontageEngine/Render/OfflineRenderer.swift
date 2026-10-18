@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import MontageCore

/// Renders single frames of a project through the real compositor (AVAssetImageGenerator + MontageCompositor):
/// used for render tests, project cover thumbnails and "export frame".
public enum OfflineRenderer {
    /// Frame-exact render of `project` at `time`. `size` defaults to the canvas size.
    public static func renderFrame(_ project: Project, at time: Time, size: CGSize? = nil) async throws -> CGImage {
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
