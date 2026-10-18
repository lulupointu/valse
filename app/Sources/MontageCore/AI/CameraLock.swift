import Foundation

// Camera tracking / lens lock (W10, AI-013, UX_AI §4.8): the clip is moved (and optionally scaled) so a person's face
// or body stays at the centre of the canvas. Analysis in MontageAI (`CameraTracker`), keyframes here.

public struct CameraLockOptions: Hashable, Codable, Sendable {
    public enum Target: String, Codable, Sendable, CaseIterable {
        case face, body, hand
        public var nameKey: String { "cameraLock.target.\(rawValue)" }
        /// "Keep face size" / "Keep body size" / "Keep hand size".
        public var keepSizeKey: String {
            switch self { case .face: return "cameraLock.keepFace"; case .body: return "cameraLock.keepBody"; case .hand: return "cameraLock.keepHand" }
        }
    }
    public enum Fill: String, Codable, Sendable, CaseIterable {
        /// Revealed edges show the canvas (project background).
        case fit
        /// Revealed edges show a blurred copy (main-track canvas blur).
        case blur
        public var nameKey: String { "cameraLock.fill.\(rawValue)" }
    }
    public var target: Target
    /// Keep the subject's on-screen size constant (zooms in / out with it).
    public var keepSize: Bool
    public var fill: Fill
    /// Base zoom (1 = fitted).
    public var zoom: Double
    public init(target: Target = .face, keepSize: Bool = false, fill: Fill = .blur, zoom: Double = 1.25) {
        self.target = target; self.keepSize = keepSize; self.fill = fill; self.zoom = zoom
    }
}

/// Subject box centre + height in normalised display coordinates of the source (origin top-left).
public struct LockSample: Hashable, Codable, Sendable {
    public var time: Double, x: Double, y: Double, size: Double
    public init(time: Double, x: Double, y: Double, size: Double) { self.time = time; self.x = x; self.y = y; self.size = size }
}

public enum CameraLock {
    /// Hand target (AI-013): box (centre + size, normalised display coords, origin top-left) around the confident
    /// joints of one detected hand pose. `points` = Vision-normalised joint locations (origin bottom-left).
    /// Size = the larger side, padded ×1.3 like a face box; nil when fewer than 4 joints are confident.
    public static func handBox(_ points: [(x: Double, y: Double, confidence: Double)], minConfidence: Double = 0.3) -> (x: Double, y: Double, size: Double)? {
        let ok = points.filter { $0.confidence >= minConfidence }
        guard ok.count >= 4 else { return nil }
        let xs = ok.map(\.x), ys = ok.map { 1 - $0.y }
        let (x0, x1, y0, y1) = (xs.min()!, xs.max()!, ys.min()!, ys.max()!)
        return ((x0 + x1) / 2, (y0 + y1) / 2, max(x1 - x0, y1 - y0) * 1.3)
    }

    /// Fills gaps by holding the last seen subject (size 0 = not found) and Gaussian-smooths (σ ≈ 0.35 s).
    public static func smooth(_ s: [LockSample]) -> [LockSample] {
        guard let firstFound = s.first(where: { $0.size > 0 }) else { return [] }
        var pts = s
        var last = firstFound
        for i in pts.indices { if pts[i].size > 0 { last = pts[i] } else { pts[i].x = last.x; pts[i].y = last.y; pts[i].size = last.size } }
        let dt = pts.count > 1 ? max((pts.last!.time - pts[0].time) / Double(pts.count - 1), 1e-3) : 1
        let sigma = max(0.35 / dt, 0.5), r = Int(sigma * 3)
        let w = (-r...r).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        func blur(_ v: [Double]) -> [Double] {
            v.indices.map { i in
                var a = 0.0, n = 0.0
                for (k, wk) in w.enumerated() { let j = min(max(i + k - r, 0), v.count - 1); a += v[j] * wk; n += wk }
                return a / n
            }
        }
        let xs = blur(pts.map(\.x)), ys = blur(pts.map(\.y)), ss = blur(pts.map(\.size))
        return pts.indices.map { LockSample(time: pts[$0].time, x: xs[$0], y: ys[$0], size: ss[$0]) }
    }

    /// Position (+ scale) keyframes that bring the subject to the canvas centre. Media-time samples.
    public static func apply(_ samples: [LockSample], to clip: inout Clip, source: Size2, canvas: Size2, options o: CameraLockOptions) {
        let path = smooth(samples)
        clip.keyframes[ParamKey.position.raw] = nil
        clip.keyframes[ParamKey.scale.raw] = nil
        clip.transform.rotation = 0
        let fit = min(canvas.width / max(source.width, 1), canvas.height / max(source.height, 1))
        let refSize = path.map(\.size).sorted().dropFirst(path.count / 2).first ?? 0.3   // median subject size
        var pk: [Keyframe] = [], sk: [Keyframe] = []
        var lastT = -1.0
        for s in path {
            guard let t = clip.timelineTime(forSource: Time(s.time)) else { continue }
            let local = (t - clip.start).clamped(.zero, clip.duration)
            if local.seconds - lastT < 0.1 { continue }
            lastT = local.seconds
            let k = o.keepSize ? min(3, max(1, o.zoom * refSize / max(s.size, 0.02))) : o.zoom
            let w = source.width * fit * k, h = source.height * fit * k
            let p = Vec2(-(s.x - 0.5) * w / canvas.width, -(s.y - 0.5) * h / canvas.height)
            pk.append(Keyframe(time: local, value: .vec2(p), easing: .linear))
            if o.keepSize { sk.append(Keyframe(time: local, value: .vec2(Vec2(k, k)), easing: .linear)) }
        }
        clip.transform.scale = Vec2(o.zoom, o.zoom)
        if pk.count > 1 { clip.keyframes[ParamKey.position.raw] = KeyframeTrack(pk) } else if let p = pk.first?.value.vec2 { clip.transform.position = p }
        if sk.count > 1 { clip.keyframes[ParamKey.scale.raw] = KeyframeTrack(sk) }
        clip.cameraLock = o
        clip.reframe = nil   // excludes auto reframe
        clip.aiMovement = nil   // and AI movement
        clip.keyframes[ParamKey.rotation.raw] = nil
        if o.fill == .blur { clip.canvas = .blur(level: 3) }
    }

    public static func remove(_ clip: inout Clip) {
        guard clip.cameraLock != nil else { return }
        clip.cameraLock = nil
        clip.keyframes[ParamKey.position.raw] = nil
        clip.keyframes[ParamKey.scale.raw] = nil
        clip.transform.position = .zero; clip.transform.scale = .one
    }
}
