import Foundation

// Smart brush (CL-012) and brush-mask tracking (MK-004): object regions as filled closed contours.
//
// Contours of a brush mask are stored in mask-box units (−0.5…0.5, y down; a brush mask's box is the whole layer:
// centre 0, size 1, rotation 0), like its strokes. Vision works on raw source frames, so regions are converted
// through the layer uv space (crop, flips) and the media's rotation (`MaskTracking.uvToRaw` / `rawToUV`).

/// One tracked shape of a brush mask at a media (source) time.
public struct MaskShapeSample: Hashable, Codable, Sendable {
    /// Source time, seconds (survives trims / splits / speed changes like mattes do).
    public var time: Double
    /// Closed contours, mask-box units, even-odd filled.
    public var contours: [[Vec2]]
    public init(time: Double, contours: [[Vec2]]) { self.time = time; self.contours = contours }
}

/// A brush mask's region propagated through the clip (MK-004 "Tracking custom mask"): one shape per sampled frame.
public struct MaskPropagation: Hashable, Codable, Sendable {
    public var samples: [MaskShapeSample]
    public init(samples: [MaskShapeSample]) { self.samples = samples.sorted { $0.time < $1.time } }

    /// Region at source time `t`: neighbouring samples blended point by point when their contours match (same count),
    /// else the nearest sample. Outside the tracked span the first / last shape holds.
    public func contours(at t: Double) -> [[Vec2]] {
        guard let first = samples.first, let last = samples.last else { return [] }
        if t <= first.time { return first.contours }
        if t >= last.time { return last.contours }
        // binary search for the bracketing pair
        var lo = 0, hi = samples.count - 1
        while hi - lo > 1 { let m = (lo + hi) / 2; if samples[m].time <= t { lo = m } else { hi = m } }
        let a = samples[lo], b = samples[hi]
        let k = (t - a.time) / max(b.time - a.time, 1e-9)
        guard a.contours.count == b.contours.count, !a.contours.isEmpty else { return k < 0.5 ? a.contours : b.contours }
        return zip(a.contours, b.contours).map { MaskContours.blend($0, $1, k) }
    }
}

public extension Mask {
    /// The mask as drawn at source time `seconds`: a tracked brush mask (MK-004) becomes one filled region stroke.
    func atSource(_ seconds: Double) -> Mask {
        guard let p = propagation, !p.samples.isEmpty else { return self }
        var m = self
        m.propagation = nil
        m.strokes = [MaskStroke(points: [], radius: 0, region: p.contours(at: seconds))]
        return m
    }
}

/// Contour helpers (pure, unit-tested).
public enum MaskContours {
    /// `n` points evenly spaced along the closed polyline `c`.
    public static func resample(_ c: [Vec2], _ n: Int) -> [Vec2] {
        guard c.count >= 2, n >= 3 else { return c }
        var seg: [Double] = [], total = 0.0
        for i in 0..<c.count { let d = (c[(i + 1) % c.count] - c[i]).length; seg.append(d); total += d }
        guard total > 1e-12 else { return Array(repeating: c[0], count: n) }
        var out: [Vec2] = []; out.reserveCapacity(n)
        var i = 0, acc = 0.0
        for j in 0..<n {
            let target = total * Double(j) / Double(n)
            while i < c.count - 1 && acc + seg[i] < target { acc += seg[i]; i += 1 }
            let k = seg[i] > 0 ? (target - acc) / seg[i] : 0
            out.append(c[i] + (c[(i + 1) % c.count] - c[i]) * min(max(k, 0), 1))
        }
        return out
    }

    /// Point-by-point blend of two closed contours (resampled to the same count, `b` rotated to start nearest `a`'s
    /// first point so the shape doesn't twist).
    public static func blend(_ a: [Vec2], _ b: [Vec2], _ k: Double) -> [Vec2] {
        let n = max(a.count, b.count, 8)
        let ra = resample(a, n)
        var rb = resample(b, n)
        guard let a0 = ra.first, !rb.isEmpty else { return k < 0.5 ? a : b }
        let s = rb.indices.min { (rb[$0] - a0).length < (rb[$1] - a0).length } ?? 0
        rb = Array(rb[s...] + rb[..<s])
        return zip(ra, rb).map { $0 + ($1 - $0) * k }
    }

    /// Bounding box of contours (any units).
    public static func bounds(_ cs: [[Vec2]]) -> (min: Vec2, max: Vec2)? {
        let pts = cs.flatMap { $0 }
        guard let f = pts.first else { return nil }
        var lo = f, hi = f
        for p in pts { lo = Vec2(min(lo.x, p.x), min(lo.y, p.y)); hi = Vec2(max(hi.x, p.x), max(hi.y, p.y)) }
        return (lo, hi)
    }

    /// Mask-box point → layer uv (0…1, y down) of a brush mask (`center` / `size`; rotation is 0 for brush masks).
    public static func boxToUV(_ p: Vec2, mask m: Mask) -> Vec2 {
        Vec2(0.5 + m.center.x + p.x * m.size.x, 0.5 + m.center.y + p.y * m.size.y)
    }

    /// Layer uv → mask-box point (inverse of `boxToUV`).
    public static func uvToBox(_ uv: Vec2, mask m: Mask) -> Vec2 {
        Vec2((uv.x - 0.5 - m.center.x) / (abs(m.size.x) > 1e-9 ? m.size.x : 1),
             (uv.y - 0.5 - m.center.y) / (abs(m.size.y) > 1e-9 ? m.size.y : 1))
    }

    /// Contours in raw source coordinates (normalized, y down) → mask-box units of `m` on clip `c`.
    public static func rawToBox(_ cs: [[Vec2]], mask m: Mask, clip c: Clip, rotation: Int) -> [[Vec2]] {
        cs.map { $0.map { uvToBox(MaskTracking.rawToUV($0, clip: c, rotation: rotation), mask: m) } }
    }

    /// Mask-box point of `m` on clip `c` → raw source coordinates (normalized, y down).
    public static func boxToRaw(_ p: Vec2, mask m: Mask, clip c: Clip, rotation: Int) -> Vec2 {
        MaskTracking.uvToRaw(boxToUV(p, mask: m), clip: c, rotation: rotation)
    }

    /// Writes a propagation into the mask at `keyPath`: the box is reset to the whole layer (centre 0, size 1, no
    /// centre / size keyframes — the shapes move by themselves) and every sample's contours are expressed in it.
    /// `rawSamples` are raw source coordinates.
    public static func applyPropagation(_ rawSamples: [MaskShapeSample], clipID: ClipID, mask keyPath: WritableKeyPath<Clip, Mask?>,
                                        center: ParamKey, size: ParamKey, rotation: Int, in project: inout Project) throws {
        guard var c = project.timeline.clip(clipID), var m = c[keyPath: keyPath] else { throw EditError.clipNotFound }
        guard !rawSamples.isEmpty else { throw EditError.nothingToDo }
        // strokes keep their place on the layer in the reset box (they stay the editable seed)
        let old = m
        let toNew: (Vec2) -> Vec2 = { boxToUV($0, mask: old) - Vec2(0.5, 0.5) }
        m.strokes = m.strokes?.map { s in
            var s = s; s.points = s.points.map(toNew); s.region = s.region?.map { $0.map(toNew) }; return s
        }
        m.center = .zero; m.size = Vec2(1, 1); m.rotation = 0
        c.keyframes[center.raw] = nil; c.keyframes[size.raw] = nil
        let box = m
        m.propagation = MaskPropagation(samples: rawSamples.map {
            MaskShapeSample(time: $0.time, contours: rawToBox($0.contours, mask: box, clip: c, rotation: rotation))
        })
        c[keyPath: keyPath] = m
        project.timeline[clip: clipID] = c
    }
}
