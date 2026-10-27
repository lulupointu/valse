import Foundation

// Motion tracking (W10, AI-014 / ST-005): a text / sticker / overlay clip follows an object picked with a box on the
// video under it. The tracker (ValseAI `ObjectTracker`, Vision) produces boxes in the reference video's raw source
// coordinates; `MotionTracking.apply` turns them into position (and optionally scale) keyframes on the follower,
// through the reference clip's on-canvas placement at each instant (its transform, crop, flips and keyframes).

/// Axis-aligned box, normalized 0…1, y down (raw source pixels of the tracked media, before its rotation metadata).
public struct NormRect: Hashable, Codable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
    public var center: Vec2 { Vec2(x + width / 2, y + height / 2) }
    public var isEmpty: Bool { width <= 0 || height <= 0 }
}

/// One tracked box at a media time of the reference clip.
public struct TrackSample: Hashable, Codable, Sendable {
    public var time: Double
    public var box: NormRect
    public init(time: Double, box: NormRect) { self.time = time; self.box = box }
}

/// Stored on the follower clip so the inspector can show / re-run / remove the tracking.
public struct MotionTrackInfo: Hashable, Codable, Sendable {
    /// Clip whose video was tracked.
    public var referenceClipID: ClipID
    /// Media time (reference clip source) where the box was drawn.
    public var startTime: Double
    /// Box drawn by the user (raw source coordinates).
    public var box: NormRect
    /// Scale the follower with the object's size ("Size changes with the object"); false = "Lock object size".
    public var scaleWithObject: Bool
    public init(referenceClipID: ClipID, startTime: Double, box: NormRect, scaleWithObject: Bool = false) {
        self.referenceClipID = referenceClipID; self.startTime = startTime; self.box = box; self.scaleWithObject = scaleWithObject
    }
}

public enum MotionTracking {
    /// Display-oriented (after rotation metadata) normalized point of a raw source point.
    public static func rawToDisplay(_ p: Vec2, rotation: Int) -> Vec2 {
        // inverse of the cutout brush's display → raw mapping
        switch (rotation % 360 + 360) % 360 {
        case 90: return Vec2(1 - p.y, p.x)
        case 180: return Vec2(1 - p.x, 1 - p.y)
        case 270: return Vec2(p.y, 1 - p.x)
        default: return p
        }
    }

    /// Canvas pixel of a display-normalized source point of a layer (crop, flips, transform).
    public static func canvasPoint(_ d: Vec2, layer l: LayerDescription, canvas: Size2) -> Vec2 {
        let g = l.geometry(canvasSize: canvas)
        let cr = l.crop
        var u = (d.x - cr.left) / max(1 - cr.left - cr.right, 1e-6), v = (d.y - cr.top) / max(1 - cr.top - cr.bottom, 1e-6)
        if l.transform.flipH { u = 1 - u }
        if l.transform.flipV { v = 1 - v }
        let x = (u * 2 - 1) * g.halfSize.x, y = (v * 2 - 1) * g.halfSize.y
        let c = cos(g.rotation), s = sin(g.rotation)
        return Vec2(g.center.x + x * c - y * s, g.center.y + x * s + y * c)
    }

    /// Canvas pixel → raw normalized source point of a layer (nil outside the layer).
    public static func sourcePoint(_ p: Vec2, layer l: LayerDescription, canvas: Size2, rotation: Int) -> Vec2? {
        let g = l.geometry(canvasSize: canvas)
        let c = cos(-g.rotation), s = sin(-g.rotation)
        let d = p - g.center
        let x = (d.x * c - d.y * s) / max(abs(g.halfSize.x), 1e-6), y = (d.x * s + d.y * c) / max(abs(g.halfSize.y), 1e-6)
        guard abs(x) <= 1.001, abs(y) <= 1.001 else { return nil }
        var u = (x + 1) / 2, v = (y + 1) / 2
        if l.transform.flipH { u = 1 - u }
        if l.transform.flipV { v = 1 - v }
        let cr = l.crop
        u = cr.left + u * (1 - cr.left - cr.right); v = cr.top + v * (1 - cr.top - cr.bottom)
        switch (rotation % 360 + 360) % 360 {
        case 90: return Vec2(v, 1 - u)
        case 180: return Vec2(1 - u, 1 - v)
        case 270: return Vec2(1 - v, u)
        default: return Vec2(u, v)
        }
    }

    /// The reference clip's layer at timeline time `t` (nil when not visible then).
    public static func layer(of clipID: ClipID, in project: Project, at t: Time) -> LayerDescription? {
        for item in FrameEvaluator.evaluate(project, at: t).items {
            switch item {
            case .layer(let l) where l.clipID == clipID: return l
            case .transition(let a, let b, _, _, _):
                if a.clipID == clipID { return a }
                if b.clipID == clipID { return b }
            default: continue
            }
        }
        return nil
    }

    /// Writes position (+ scale when `info.scaleWithObject`) keyframes on `followerID` from tracked boxes. The follower
    /// keeps its offset from the object at the box's start time. Existing position / scale keyframes are replaced.
    public static func apply(_ samples: [TrackSample], info: MotionTrackInfo, follower followerID: ClipID, in project: inout Project) throws {
        guard let ref = project.timeline.clip(info.referenceClipID), let refAsset = ref.mediaID.flatMap(project.asset),
              var f = project.timeline.clip(followerID) else { throw EditError.clipNotFound }
        let canvas = project.settings.canvasSize
        let rot = refAsset.sourceRotation
        // canvas placement of each sample (only where the reference clip is visible)
        var placed: [(local: Time, center: Vec2, size: Double)] = []
        let sorted = samples.sorted { $0.time < $1.time }
        for s in sorted {
            guard let t = ref.timelineTime(forSource: Time(s.time)), t >= f.start, t < f.end,
                  let l = layer(of: ref.id, in: project, at: t) else { continue }
            let tl = MotionTracking.canvasPoint(rawToDisplay(Vec2(s.box.x, s.box.y), rotation: rot), layer: l, canvas: canvas)
            let br = MotionTracking.canvasPoint(rawToDisplay(Vec2(s.box.x + s.box.width, s.box.y + s.box.height), rotation: rot), layer: l, canvas: canvas)
            let c = MotionTracking.canvasPoint(rawToDisplay(s.box.center, rotation: rot), layer: l, canvas: canvas)
            placed.append((t - f.start, c, (br - tl).length))
        }
        guard !placed.isEmpty else { throw EditError.nothingToDo }
        // anchor: the sample nearest to the box's start time
        let anchorT = ref.timelineTime(forSource: Time(info.startTime)).map { $0 - f.start } ?? placed[0].local
        let anchor = placed.min { abs(($0.local - anchorT).seconds) < abs(($1.local - anchorT).seconds) }!
        let pos0 = f.evaluatedPosition(at: anchor.local)
        let scale0 = f.transform.scale
        let offset = Vec2(pos0.x * canvas.width + canvas.width / 2, pos0.y * canvas.height + canvas.height / 2) - anchor.center
        var pk: [Keyframe] = [], sk: [Keyframe] = []
        var last = -1.0
        for p in placed {
            if p.local.seconds - last < 1.0 / 15 - 1e-6 && p.local != placed.last!.local { continue }
            last = p.local.seconds
            let k = info.scaleWithObject ? p.size / max(anchor.size, 1e-6) : 1
            let c = p.center + offset * k
            pk.append(Keyframe(time: p.local, value: .vec2(Vec2((c.x - canvas.width / 2) / canvas.width, (c.y - canvas.height / 2) / canvas.height)), easing: .linear))
            if info.scaleWithObject { sk.append(Keyframe(time: p.local, value: .vec2(Vec2(scale0.x * k, scale0.y * k)), easing: .linear)) }
        }
        f.keyframes[ParamKey.position.raw] = KeyframeTrack(pk)
        if info.scaleWithObject { f.keyframes[ParamKey.scale.raw] = KeyframeTrack(sk) }
        f.tracking = info
        project.timeline[clip: followerID] = f
    }

    /// Removes the tracking keyframes ("None").
    public static func remove(from followerID: ClipID, in project: inout Project) throws {
        guard var f = project.timeline.clip(followerID), let info = f.tracking else { return }
        if let k = f.keyframes[ParamKey.position.raw], let first = k.keyframes.first?.value.vec2 { f.transform.position = first }
        f.keyframes[ParamKey.position.raw] = nil
        if info.scaleWithObject { f.keyframes[ParamKey.scale.raw] = nil }
        f.tracking = nil
        project.timeline[clip: followerID] = f
    }
}

extension Clip {
    /// Position at clip-local time (keyframes if any, else the static transform).
    public func evaluatedPosition(at local: Time) -> Vec2 {
        if let k = keyframes[ParamKey.position.raw], let v = k.value(at: local)?.vec2 { return v }
        return transform.position
    }
}
