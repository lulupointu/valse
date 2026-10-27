@preconcurrency import AVFoundation
import Foundation
import ValseCore
import ValseEngine

public enum BuiltinAITools {
    /// Auto captions with default options (right-click ▸ Generate captions): transcribes the selected clip (or every
    /// clip with audio) and adds caption clips on a caption track. The Text ▸ Auto captions panel calls
    /// `CaptionGenerator` directly with the user's options.
    public static let autoCaptions = AIToolDescriptor(
        id: "valse.ai.captions", nameKey: "ai.captions", descriptionKey: "ai.captions.desc", symbol: "captions.bubble",
        target: .project
    ) { input, progress in
        let source: CaptionOptions.Source = input.clipID.map { .clip($0) } ?? .allTracks
        let r = try await CaptionGenerator.run(project: input.project, options: CaptionOptions(source: source),
                                               progress: { progress.report($0) })
        return .edit(r.command)
    }

    /// Remove background (person segmentation) → writes a matte movie into the cache. The compositor matte input is
    /// the next step of the AI workstream (see ARCHITECTURE "AI").
    public static let removeBackground = AIToolDescriptor(
        id: "valse.ai.removeBackground", nameKey: "ai.removeBackground", descriptionKey: "ai.removeBackground.desc",
        symbol: "person.crop.rectangle", target: .videoClip
    ) { input, progress in
        guard let clip = input.clip, let asset = input.asset, asset.kind == .video else { throw AIToolError.noInput }
        let dir = ValsePaths.cacheDirectory.appendingPathComponent("mattes", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(asset.contentHash)-person.mov")
        var frames = 0
        try await PersonSegmenter.forEachMask(url: asset.url, range: clip.sourceRange, quality: .balanced,
                                              progress: { progress.report($0) }) { _, _ in frames += 1 }
        EngineLog.info("segmented \(frames) frames for \(asset.name)")
        return .artifact(url)
    }

    public static let all: [AIToolDescriptor] = [autoCaptions, removeBackground]
}
