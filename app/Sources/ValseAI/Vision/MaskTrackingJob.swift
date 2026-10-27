import Foundation
import ValseCore
import ValseEngine

/// Mask tracking job (MK-003): tracks the mask's box (Vision object tracking, `ObjectTracker`) from `source` time in
/// `direction`, then one undoable edit writing the mask centre / size keyframes (`MaskTracking.apply`).
public enum MaskTrackingJob {
    public static func run(project p: Project, clipID: ClipID, mask keyPath: WritableKeyPath<Clip, Mask?>, center: ParamKey, size: ParamKey,
                           from source: Time, direction: MaskTracking.Direction,
                           progress: (@Sendable (Double) -> Void)? = nil) async throws -> any EditCommand {
        guard let c = p.timeline.clip(clipID), let asset = c.mediaID.flatMap(p.asset), asset.kind == .video else { throw AIToolError.noInput }
        let local = ((c.timelineTime(forSource: source) ?? c.start) - c.start).clamped(.zero, c.duration)
        guard let m = c.resolved(at: local)[keyPath: keyPath] else { throw AIToolError.noInput }
        let rot = asset.sourceRotation
        let box = MaskTracking.box(for: m, clip: c, rotation: rot)
        let range = MaskTracking.range(c, from: source, direction: direction)
        let samples = try await ObjectTracker.track(asset, box: box, at: source.seconds, range: range, progress: progress)
        let path = MaskKeyPath(keyPath)
        return Edit("cmd.maskTrack") { p in
            try MaskTracking.apply(samples, start: source.seconds, clipID: clipID, mask: path.value, center: center, size: size,
                                   rotation: rot, in: &p)
        }
    }
}

/// Key paths of value types are immutable, so sharing one across tasks is safe.
struct MaskKeyPath: @unchecked Sendable {
    let value: WritableKeyPath<Clip, Mask?>
    init(_ v: WritableKeyPath<Clip, Mask?>) { value = v }
}
