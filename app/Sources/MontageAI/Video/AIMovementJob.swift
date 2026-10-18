import Foundation
import MontageCore
import MontageEngine

/// AI movement (AI-025): finds the subject (SubjectAnalyzer: faces → people → saliency, ≤ 512 px, 2 fps; one look for
/// stills), then builds the keyframed camera move (Core `AIMovement`) as one undoable edit. Subject paths are cached
/// in memory per media range, so changing the preset / strength re-applies instantly.
public enum AIMovementJob {
    private static let cache = SubjectCache()

    public static func run(project p: Project, clipID: ClipID, options: AIMovementOptions,
                           progress: (@Sendable (Double) -> Void)? = nil) async throws -> any EditCommand {
        guard let c = p.timeline.clip(clipID), let a = c.mediaID.flatMap(p.asset), a.kind == .video || a.kind == .image else {
            throw AIToolError.noInput
        }
        let key = "\(a.contentHash)|\(a.kind == .image ? "still" : "\(c.sourceRange.start.ticks)-\(c.sourceRange.end.ticks)")"
        let samples: [SubjectSample]
        if let s = cache.get(key) {
            samples = s
        } else if a.kind == .image {
            samples = [try SubjectAnalyzer.still(a.url)]
            cache.put(key, samples)
        } else {
            samples = try await SubjectAnalyzer.samples(a, range: c.sourceRange, fps: 2, progress: progress)
            cache.put(key, samples)
        }
        progress?(1)
        let source = a.pixelSize
        return Edit("cmd.aiMovement") { p in
            guard var c = p.timeline.clip(clipID) else { throw EditError.clipNotFound }
            let path = AIMovement.localPath(samples, clip: c)
            let beats = AIMovement.beats(for: c, in: p.timeline)
            AIMovement.apply(options, subject: path, beats: beats, to: &c, source: source, canvas: p.settings.canvasSize)
            p.timeline[clip: clipID] = c
        }
    }

    public static func isCached(_ p: Project, _ clipID: ClipID) -> Bool {
        guard let c = p.timeline.clip(clipID), let a = c.mediaID.flatMap(p.asset) else { return false }
        return cache.get("\(a.contentHash)|\(a.kind == .image ? "still" : "\(c.sourceRange.start.ticks)-\(c.sourceRange.end.ticks)")") != nil
    }

    final class SubjectCache: @unchecked Sendable {
        private let lock = NSLock()
        private var map: [String: [SubjectSample]] = [:]
        func get(_ k: String) -> [SubjectSample]? { lock.withLock { map[k] } }
        func put(_ k: String, _ v: [SubjectSample]) { lock.withLock { if map.count > 64 { map.removeAll() }; map[k] = v } }
    }
}
