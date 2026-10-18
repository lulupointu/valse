import Foundation

/// Auto reframe options (UX_AI §4.7 / AI-012 / CV-016: Aspect ratio · Camera moving speed · Image stabilization).
public struct ReframeOptions: Hashable, Codable, Sendable {
    public enum Speed: String, Codable, Sendable, CaseIterable {
        case slow, normal, fast
        public var nameKey: String { "reframe.speed.\(rawValue)" }
        /// Gaussian smoothing of the subject path (seconds).
        var sigma: Double { switch self { case .slow: return 1.2; case .normal: return 0.6; case .fast: return 0.25 } }
    }
    public enum Stability: String, Codable, Sendable, CaseIterable {
        case flexible, normal, stable
        public var nameKey: String { "reframe.stability.\(rawValue)" }
        /// Dead zone (fraction of the frame): the camera only follows when the subject leaves it.
        var deadZone: Double { switch self { case .flexible: return 0; case .normal: return 0.04; case .stable: return 0.1 } }
    }
    /// Ratio id from `ProjectSettings.aspectPresets` ("9:16", "1:1", …).
    public var ratio: String
    public var speed: Speed
    public var stability: Stability
    public init(ratio: String = "9:16", speed: Speed = .normal, stability: Stability = .normal) {
        self.ratio = ratio; self.speed = speed; self.stability = stability
    }
}

/// One subject observation: where the subject is (normalised **display** coordinates of the source, origin top-left).
public struct SubjectSample: Hashable, Codable, Sendable {
    public var time: Double
    public var x: Double
    public var y: Double
    public var confidence: Double
    public init(time: Double, x: Double, y: Double, confidence: Double = 1) { self.time = time; self.x = x; self.y = y; self.confidence = confidence }
}

/// Pure camera-path + keyframe maths of auto reframe (the Vision analysis lives in MontageAI).
public enum ReframePath {
    /// Fills gaps (low confidence → previous point), applies the dead zone, then Gaussian-smooths.
    public static func smooth(_ s: [SubjectSample], options: ReframeOptions) -> [SubjectSample] {
        guard !s.isEmpty else { return [] }
        var pts = s
        for i in pts.indices where pts[i].confidence < 0.2 {
            if i > 0 { pts[i].x = pts[i - 1].x; pts[i].y = pts[i - 1].y } else { pts[i].x = 0.5; pts[i].y = 0.5 }
        }
        let dz = options.stability.deadZone
        if dz > 0 {
            var cx = pts[0].x, cy = pts[0].y
            for i in pts.indices {
                if abs(pts[i].x - cx) > dz { cx = pts[i].x - (pts[i].x > cx ? dz : -dz) }
                if abs(pts[i].y - cy) > dz { cy = pts[i].y - (pts[i].y > cy ? dz : -dz) }
                pts[i].x = cx; pts[i].y = cy
            }
        }
        let dt = pts.count > 1 ? max((pts.last!.time - pts[0].time) / Double(pts.count - 1), 1e-3) : 1
        let sigma = max(options.speed.sigma / dt, 0.5)
        let r = Int(sigma * 3)
        let w = (-r...r).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        func blur(_ v: [Double]) -> [Double] {
            v.indices.map { i in
                var a = 0.0, n = 0.0
                for (k, wk) in w.enumerated() { let j = min(max(i + k - r, 0), v.count - 1); a += v[j] * wk; n += wk }
                return a / n
            }
        }
        let xs = blur(pts.map(\.x)), ys = blur(pts.map(\.y))
        return pts.indices.map { SubjectSample(time: pts[$0].time, x: xs[$0], y: ys[$0], confidence: 1) }
    }

    /// Scale that makes a source of `source` size cover `canvas` (relative to CapCut's aspect-fit scale 1).
    public static func fillScale(source: Size2, canvas: Size2) -> Double {
        guard source.width > 0, source.height > 0 else { return 1 }
        let fit = min(canvas.width / source.width, canvas.height / source.height)
        return max(canvas.width / (source.width * fit), canvas.height / (source.height * fit))
    }

    /// Layer position (fraction of the canvas) that brings subject point (x, y) to the centre, clamped so the frame
    /// keeps covering the canvas.
    public static func position(x: Double, y: Double, source: Size2, canvas: Size2, scale k: Double) -> Vec2 {
        let fit = min(canvas.width / source.width, canvas.height / source.height)
        let w = source.width * fit * k, h = source.height * fit * k
        let mx = max(0, (w - canvas.width) / 2 / canvas.width), my = max(0, (h - canvas.height) / 2 / canvas.height)
        let px = -(x - 0.5) * w / canvas.width, py = -(y - 0.5) * h / canvas.height
        return Vec2(min(max(px, -mx), mx), min(max(py, -my), my))
    }

    /// Applies a smoothed subject path (media-time samples) to a clip: fill scale + position keyframes, crop and
    /// stabilization removed (they exclude auto reframe in CapCut).
    public static func apply(_ path: [SubjectSample], to clip: inout Clip, source: Size2, canvas: Size2) {
        let k = fillScale(source: source, canvas: canvas)
        clip.crop = CropRect()
        clip.stabilization = nil
        clip.cameraLock = nil   // camera tracking and auto reframe exclude each other
        if clip.aiMovement != nil { clip.aiMovement = nil; clip.keyframes[ParamKey.rotation.raw] = nil }   // so does AI movement
        clip.keyframes[ParamKey.position.raw] = nil
        clip.keyframes[ParamKey.scale.raw] = nil
        clip.transform.scale = Vec2(k, k)
        clip.transform.rotation = 0
        var keys: [Keyframe] = []
        var lastT = -1.0
        for s in path {
            guard let t = clip.timelineTime(forSource: Time(s.time)) else { continue }
            let local = (t - clip.start).clamped(.zero, clip.duration)
            if local.seconds - lastT < 0.24 { continue }
            lastT = local.seconds
            let p = position(x: s.x, y: s.y, source: source, canvas: canvas, scale: k)
            keys.append(Keyframe(time: local, value: .vec2(p), easing: .easeInOut))
        }
        if keys.count <= 1 {
            clip.transform.position = keys.first.flatMap { if case .vec2(let v) = $0.value { return v }; return nil } ?? .zero
        } else {
            clip.keyframes[ParamKey.position.raw] = KeyframeTrack(keys)
        }
    }

    /// Canvas size for a ratio id keeping the short side of `current`.
    public static func canvas(for ratio: String, current: Size2) -> Size2? {
        let parts = ratio.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        let short = min(current.width, current.height)
        let a = parts[0] / parts[1]
        func even(_ v: Double) -> Double { (v / 2).rounded() * 2 }
        return a >= 1 ? Size2(even(short * a), even(short)) : Size2(even(short), even(short / a))
    }
}
