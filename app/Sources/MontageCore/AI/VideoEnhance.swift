import Foundation

// Video ▸ Basic ▸ Reduce image noise / Remove flickers / Enhance quality (W10, CL-017/018/019, AI-021/022/023).
// These rewrite pixels over time, so they run as a background job that renders a processed copy of the media
// (MontageAI `VideoEnhancer`); the clip then plays that copy (`content` swapped, same timing) and remembers the
// original in `Clip.enhance` so unticking restores it. Preview = export, nothing special in the engine.

public enum DeflickerMode: String, Codable, Sendable, CaseIterable {
    /// Artificial-light flicker (fast, frame-to-frame).
    case flashlight
    /// Time-lapse exposure jumps (slow, smoothed over seconds).
    case timelapse
    public var nameKey: String { "enhance.flicker.\(rawValue)" }
}

public enum EnhanceLevel: String, Codable, Sendable, CaseIterable {
    case weak, normal, strong
    public var nameKey: String { "enhance.level.\(rawValue)" }
}

public enum UpscaleTarget: String, Codable, Sendable, CaseIterable {
    /// ×2 (HD).
    case hd
    /// ×4 capped to 4K (UHD).
    case uhd
    public var nameKey: String { "enhance.quality.\(rawValue)" }
}

/// What has been applied to a clip's media, and where the original is.
public struct VideoEnhancement: Hashable, Codable, Sendable {
    public var original: MediaID
    public var denoise: EnhanceLevel?
    public var deflicker: DeflickerMode?
    public var deflickerLevel: EnhanceLevel
    public var upscale: UpscaleTarget?
    public init(original: MediaID, denoise: EnhanceLevel? = nil, deflicker: DeflickerMode? = nil,
                deflickerLevel: EnhanceLevel = .normal, upscale: UpscaleTarget? = nil) {
        self.original = original; self.denoise = denoise; self.deflicker = deflicker
        self.deflickerLevel = deflickerLevel; self.upscale = upscale
    }
    public var isEmpty: Bool { denoise == nil && deflicker == nil && upscale == nil }
    /// Cache key part of the processed file.
    public var key: String {
        [denoise.map { "dn-\($0.rawValue)" }, deflicker.map { "df-\($0.rawValue)-\(deflickerLevel.rawValue)" },
         upscale.map { "sr-\($0.rawValue)" }].compactMap { $0 }.joined(separator: "_")
    }
}

public enum Deflicker {
    /// Per-frame gains that bring each frame's mean luma onto a temporally smoothed curve. Smoothing window: a few
    /// frames for flashlight flicker, seconds for time-lapse; the level scales it. Gains are clamped to 0.6…1.6.
    public static func gains(meanLuma m: [Double], fps: Double, mode: DeflickerMode, level: EnhanceLevel) -> [Double] {
        guard !m.isEmpty else { return [] }
        let base: Double = mode == .flashlight ? 0.12 : 0.8          // seconds
        let k: Double = level == .weak ? 0.5 : (level == .normal ? 1 : 2)
        let sigma = max(1, base * k * fps)
        let r = Int(sigma * 3)
        let w = (-r...r).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        // smooth in log space (exposure is multiplicative)
        let lg = m.map { log(max($0, 1e-3)) }
        return m.indices.map { i in
            var a = 0.0, n = 0.0
            for (j, wj) in w.enumerated() { let t = min(max(i + j - r, 0), m.count - 1); a += lg[t] * wj; n += wj }
            return min(max(exp(a / n - lg[i]), 0.6), 1.6)
        }
    }

    public static func strength(_ level: EnhanceLevel) -> Float {
        switch level { case .weak: return 0.35; case .normal: return 0.6; case .strong: return 0.9 }
    }
}

extension EnhanceLevel {
    /// VTTemporalNoiseFilter strength.
    public var denoiseStrength: Float { Deflicker.strength(self) }
}

/// AI remove (AI-041): the clip plays an inpainted copy; brush strokes are in raw source coordinates (normalised,
/// y down, radius = fraction of the width) — same convention as the cutout brush.
public struct ObjectRemovalInfo: Hashable, Codable, Sendable {
    public var original: MediaID
    public var strokes: [RemovalStroke]
    /// "Track object" (AI2): the brushed area follows the object; nil = static mask (logos, watermarks).
    public var tracking: RemovalTracking?
    public init(original: MediaID, strokes: [RemovalStroke], tracking: RemovalTracking? = nil) {
        self.original = original; self.strokes = strokes; self.tracking = tracking
    }
}

/// AI remove ▸ Track object (AI-041): the strokes were painted on the frame at media time `time`; the object under
/// their bounding box is tracked through the clip and the mask is moved (and scaled) with it on every frame.
public struct RemovalTracking: Hashable, Codable, Sendable {
    public var time: Double
    public init(time: Double) { self.time = time }

    /// Bounding box of the strokes (raw source coords, y down); `aspect` = source width / height (radius is a fraction
    /// of the width). Erase strokes don't count.
    public static func bounds(_ strokes: [RemovalStroke], aspect: Double) -> NormRect? {
        var x0 = Double.infinity, y0 = Double.infinity, x1 = -Double.infinity, y1 = -Double.infinity
        for s in strokes where !s.erase {
            let ry = s.radius * aspect
            for p in s.points {
                x0 = min(x0, p.x - s.radius); x1 = max(x1, p.x + s.radius)
                y0 = min(y0, p.y - ry); y1 = max(y1, p.y + ry)
            }
        }
        guard x1 > x0, y1 > y0 else { return nil }
        let a = max(0, x0), b = max(0, y0)
        let r = NormRect(x: a, y: b, width: min(1, x1) - a, height: min(1, y1) - b)
        return r.isEmpty ? nil : r
    }

    /// The tracked box at media time `t`: linear between samples, held before the first / after the last (an object
    /// that is lost keeps its last position).
    public static func box(at t: Double, in samples: [TrackSample]) -> NormRect? {
        guard let first = samples.first, let last = samples.last else { return nil }
        if t <= first.time { return first.box }
        if t >= last.time { return last.box }
        var lo = 0, hi = samples.count - 1
        while hi - lo > 1 { let m = (lo + hi) / 2; if samples[m].time <= t { lo = m } else { hi = m } }
        let a = samples[lo], b = samples[hi]
        let k = (t - a.time) / max(b.time - a.time, 1e-9)
        func mix(_ u: Double, _ v: Double) -> Double { u + (v - u) * k }
        return NormRect(x: mix(a.box.x, b.box.x), y: mix(a.box.y, b.box.y), width: mix(a.box.width, b.box.width), height: mix(a.box.height, b.box.height))
    }

    /// Strokes moved from the reference box to `box`: points keep their position relative to the box (centre +
    /// per-axis scale), radii scale with the box width.
    public static func transform(_ strokes: [RemovalStroke], from ref: NormRect, to box: NormRect) -> [RemovalStroke] {
        let sx = box.width / max(ref.width, 1e-6), sy = box.height / max(ref.height, 1e-6)
        let c0 = ref.center, c1 = box.center
        return strokes.map { s in
            RemovalStroke(points: s.points.map { Vec2(c1.x + ($0.x - c0.x) * sx, c1.y + ($0.y - c0.y) * sy) },
                          radius: s.radius * sx, erase: s.erase)
        }
    }
}

public struct RemovalStroke: Hashable, Codable, Sendable {
    public var points: [Vec2]
    public var radius: Double
    public var erase: Bool
    public init(points: [Vec2], radius: Double, erase: Bool = false) { self.points = points; self.radius = radius; self.erase = erase }
}
