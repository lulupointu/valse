import Foundation

// Mask tracking (MK-003, CapCut "Track mask" forward / backward / both): the mask's box on the clip's video is tracked
// (MontageAI `ObjectTracker`, Vision) and turned into mask centre (+ size) keyframes, so the mask follows the object.
// Masks live in layer uv space (0…1 of the displayed, cropped and flipped layer, y down; `Mask.center` = offset from the
// layer centre); the tracker works on raw source pixels, so boxes are converted both ways through crop, flips and the
// media's rotation metadata.
public enum MaskTracking {
    public enum Direction: String, CaseIterable, Sendable {
        case forward, backward, both
        public var nameKey: String { "maskTrack.\(rawValue)" }
    }

    /// Display-oriented normalized point → raw source point (inverse of `MotionTracking.rawToDisplay`).
    public static func displayToRaw(_ d: Vec2, rotation: Int) -> Vec2 {
        switch (rotation % 360 + 360) % 360 {
        case 90: return Vec2(d.y, 1 - d.x)
        case 180: return Vec2(1 - d.x, 1 - d.y)
        case 270: return Vec2(1 - d.y, d.x)
        default: return d
        }
    }

    /// Layer uv → raw normalized source point.
    public static func uvToRaw(_ uv: Vec2, clip c: Clip, rotation: Int) -> Vec2 {
        let u = c.transform.flipH ? 1 - uv.x : uv.x, v = c.transform.flipV ? 1 - uv.y : uv.y
        let cr = c.crop
        return displayToRaw(Vec2(cr.left + u * (1 - cr.left - cr.right), cr.top + v * (1 - cr.top - cr.bottom)), rotation: rotation)
    }

    /// Raw normalized source point → layer uv.
    public static func rawToUV(_ raw: Vec2, clip c: Clip, rotation: Int) -> Vec2 {
        let d = MotionTracking.rawToDisplay(raw, rotation: rotation)
        let cr = c.crop
        var u = (d.x - cr.left) / max(1 - cr.left - cr.right, 1e-6), v = (d.y - cr.top) / max(1 - cr.top - cr.bottom, 1e-6)
        if c.transform.flipH { u = 1 - u }
        if c.transform.flipV { v = 1 - v }
        return Vec2(u, v)
    }

    /// Box to track for `mask` (raw source coordinates). Lines (linear / mirror) track a 25 % box around their centre.
    public static func box(for mask: Mask, clip c: Clip, rotation: Int) -> NormRect {
        let lineLike = mask.shape == .linear || mask.shape == .mirror
        let half = lineLike ? Vec2(0.125, 0.125) : Vec2(min(max(abs(mask.size.x), 0.04), 1) / 2, min(max(abs(mask.size.y), 0.04), 1) / 2)
        let cuv = Vec2(0.5 + mask.center.x, 0.5 + mask.center.y)
        let corners = [Vec2(-1, -1), Vec2(1, -1), Vec2(-1, 1), Vec2(1, 1)].map { k in
            uvToRaw(Vec2(cuv.x + k.x * half.x, cuv.y + k.y * half.y), clip: c, rotation: rotation)
        }
        let x0 = max(0, corners.map(\.x).min()!), x1 = min(1, corners.map(\.x).max()!)
        let y0 = max(0, corners.map(\.y).min()!), y1 = min(1, corners.map(\.y).max()!)
        return NormRect(x: x0, y: y0, width: max(x1 - x0, 0.01), height: max(y1 - y0, 0.01))
    }

    /// Media range to track from source time `s0` in `direction`, within the clip's source range.
    public static func range(_ c: Clip, from s0: Time, direction: Direction) -> TimeRange {
        let r = c.sourceRange
        let s = s0.clamped(r.start, r.end)
        switch direction {
        case .forward: return TimeRange(start: s, duration: max(r.end - s, Time(ticks: 1)))
        case .backward: return TimeRange(start: r.start, duration: max(s - r.start, Time(ticks: 1)))
        case .both: return r
        }
    }

    /// Writes mask centre (and size, scaled with the object) keyframes from tracked boxes. Keyframes already outside the
    /// tracked span are kept. `center` / `size` are the ParamKeys of the edited mask (clip mask or Adjust mask).
    public static func apply(_ samples: [TrackSample], start s0: Double, clipID: ClipID, mask keyPath: WritableKeyPath<Clip, Mask?>,
                             center: ParamKey, size: ParamKey, rotation: Int, in project: inout Project) throws {
        guard var c = project.timeline.clip(clipID), let m0 = c.resolved(at: .zero)[keyPath: keyPath] ?? c[keyPath: keyPath] else {
            throw EditError.clipNotFound
        }
        let sorted = samples.sorted { $0.time < $1.time }
        guard let anchor = sorted.min(by: { abs($0.time - s0) < abs($1.time - s0) }) else { throw EditError.nothingToDo }
        let area0 = max(anchor.box.width * anchor.box.height, 1e-6)
        // mask at the anchor (keyframed value if any)
        let anchorLocal = (c.timelineTime(forSource: Time(anchor.time)) ?? c.start) - c.start
        let size0 = c.value(size, at: anchorLocal)?.vec2 ?? m0.size
        var ck: [Keyframe] = [], sk: [Keyframe] = []
        var last = -1.0
        for (i, s) in sorted.enumerated() {
            guard let t = c.timelineTime(forSource: Time(s.time)) else { continue }
            let local = (t - c.start).clamped(.zero, c.duration)
            if local.seconds - last < 1.0 / 15 - 1e-6 && i != sorted.count - 1 { continue }
            last = local.seconds
            let uv = rawToUV(s.box.center, clip: c, rotation: rotation)
            ck.append(Keyframe(time: local, value: .vec2(Vec2(uv.x - 0.5, uv.y - 0.5))))
            let k = (s.box.width * s.box.height / area0).squareRoot()
            sk.append(Keyframe(time: local, value: .vec2(Vec2(size0.x * k, size0.y * k))))
        }
        guard let lo = ck.first?.time, let hi = ck.last?.time else { throw EditError.nothingToDo }
        func merged(_ key: ParamKey, _ new: [Keyframe]) -> KeyframeTrack {
            let kept = (c.keyframes[key.raw]?.keyframes ?? []).filter { $0.time < lo || $0.time > hi }
            return KeyframeTrack((kept + new).sorted { $0.time < $1.time })
        }
        c.keyframes[center.raw] = merged(center, ck)
        if m0.shape != .linear && m0.shape != .mirror { c.keyframes[size.raw] = merged(size, sk) }
        project.timeline[clip: clipID] = c
    }
}
