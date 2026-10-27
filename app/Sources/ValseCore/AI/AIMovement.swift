import Foundation

// AI movement (W10/AI2, AI-025, UX_AI §4.9): Video ▸ Basic ▸ ☐ AI movement adds a keyframed camera move to a clip or
// still (Ken Burns): Dynamic / Soft / Shake / Zoom presets with a strength, centred on the salient subject (Vision
// analysis in ValseAI) and optionally synced to the project's beat markers (punch zooms / direction changes on beats).
// The result is plain position / scale / rotation keyframes (editable afterwards); `Clip.aiMovement` remembers the
// request. Excludes auto reframe and camera tracking (each removes the others).

public struct AIMovementOptions: Hashable, Codable, Sendable {
    public enum Preset: String, Codable, Sendable, CaseIterable {
        /// Alternating zoom in / out + pan segments (every beat, else every ~1.6 s).
        case dynamic
        /// Slow Ken Burns: gentle zoom-in drifting onto the subject.
        case soft
        /// Handheld shake: small high-frequency position + rotation noise (bursts on beats).
        case shake
        /// Zoom-in onto the subject (punch zooms on beats).
        case zoom
        public var nameKey: String { "aiMovement.preset.\(rawValue)" }
        public var symbol: String {
            switch self {
            case .dynamic: return "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left"
            case .soft: return "wind"
            case .shake: return "waveform.path"
            case .zoom: return "plus.magnifyingglass"
            }
        }
    }
    public var preset: Preset
    /// 0…1 (UI 0–100), scales zoom amount / pan distance / shake amplitude.
    public var strength: Double
    /// Use the project's beat markers (CapCut beats on music clips) when there are any under the clip.
    public var syncToBeats: Bool
    public init(preset: Preset = .dynamic, strength: Double = 0.5, syncToBeats: Bool = true) {
        self.preset = preset; self.strength = strength; self.syncToBeats = syncToBeats
    }
}

public enum AIMovement {
    /// Beat markers of every clip in the project (timeline time), restricted to the clip's range, as clip-local seconds.
    public static func beats(for clip: Clip, in timeline: Timeline) -> [Double] {
        var out: [Double] = []
        for t in timeline.tracks where !t.isMuted {
            for c in t.clips where c.id != clip.id {
                for b in c.beats ?? [] {
                    let tl = c.start + b
                    guard tl >= c.start, tl <= c.end, tl > clip.start, tl < clip.end else { continue }
                    out.append((tl - clip.start).seconds)
                }
            }
        }
        for b in clip.beats ?? [] where b > .zero && b < clip.duration { out.append(b.seconds) }
        let sorted = out.sorted()
        // drop near duplicates (two music tracks on the same grid)
        var dedup: [Double] = []
        for b in sorted where dedup.last.map({ b - $0 > 0.12 }) ?? true { dedup.append(b) }
        return dedup
    }

    /// Subject path in clip-local seconds (from media-time samples; a still has one sample).
    public static func localPath(_ samples: [SubjectSample], clip: Clip) -> [SubjectSample] {
        let smooth = ReframePath.smooth(samples, options: ReframeOptions(speed: .slow, stability: .stable))
        if smooth.count == 1 { return [SubjectSample(time: 0, x: smooth[0].x, y: smooth[0].y)] }
        return smooth.compactMap { s in
            guard let t = clip.timelineTime(forSource: Time(s.time)) else { return nil }
            return SubjectSample(time: (t - clip.start).clamped(.zero, clip.duration).seconds, x: s.x, y: s.y)
        }
    }

    /// Subject point at clip-local time `t` (linear interpolation of the path; centre when empty).
    public static func subject(at t: Double, _ path: [SubjectSample]) -> (x: Double, y: Double) {
        guard let first = path.first else { return (0.5, 0.5) }
        if t <= first.time || path.count == 1 { return (first.x, first.y) }
        guard let last = path.last, t < last.time else { return (path.last!.x, path.last!.y) }
        let i = path.firstIndex { $0.time > t }!
        let a = path[i - 1], b = path[i]
        let f = (t - a.time) / max(b.time - a.time, 1e-6)
        return (a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f)
    }

    /// Deterministic pseudo-random value in -1…1 (shake noise; same clip = same shake).
    static func noise(_ i: Int, _ seed: UInt64) -> Double {
        var z = seed &+ UInt64(bitPattern: Int64(i)) &* 0x9E3779B97F4A7C15
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Double(z % 2_000_001) / 1_000_000 - 1
    }

    /// One camera pose: zoom factor relative to the clip's base scale, how far the frame is pulled onto the subject
    /// (0 = centred frame, 1 = subject centred), extra pan (fraction of the canvas) and rotation (degrees).
    struct Pose { var t: Double; var zoom: Double; var pull: Double; var pan = Vec2(0, 0); var rotation = 0.0; var easing: Easing = .easeInOut }

    static func poses(_ o: AIMovementOptions, duration d: Double, beats: [Double], seed: UInt64) -> [Pose] {
        let s = min(max(o.strength, 0), 1)
        let useBeats = o.syncToBeats && !beats.isEmpty
        switch o.preset {
        case .soft:
            let z = 1.06 + 0.16 * s
            return [Pose(t: 0, zoom: 1.04, pull: 0.15, easing: .linear), Pose(t: d, zoom: z, pull: 0.85, easing: .linear)]
        case .zoom:
            let hi = 1.12 + 0.38 * s
            guard useBeats else { return [Pose(t: 0, zoom: 1, pull: 0), Pose(t: d, zoom: hi, pull: 1)] }
            // punch: snap in on the beat, relax before the next one
            var out = [Pose(t: 0, zoom: 1.02, pull: 0.3, easing: .linear)]
            let base = 1.02, punch = 1.06 + 0.24 * s
            for (i, b) in beats.enumerated() {
                let next = i + 1 < beats.count ? beats[i + 1] : d
                let pre = max(b - 0.04, out.last!.t + 0.01)
                if pre < b { out.append(Pose(t: pre, zoom: base, pull: 0.3, easing: .linear)) }
                out.append(Pose(t: b, zoom: punch, pull: 1, easing: .easeOut))
                let relax = min(b + max(0.12, (next - b) * 0.7), d)
                if relax > b + 0.02 { out.append(Pose(t: relax, zoom: base + (punch - base) * 0.25, pull: 0.5, easing: .easeInOut)) }
            }
            if out.last!.t < d { out.append(Pose(t: d, zoom: base, pull: 0.3)) }
            return out
        case .dynamic:
            let marks: [Double] = useBeats ? [0] + beats + [d] : stride(from: 0, through: d, by: max(1.6, d / 6)).map { $0 } + [d]
            var times: [Double] = []
            for m in marks where times.last.map({ m - $0 > 0.05 }) ?? true { times.append(min(m, d)) }
            let lo = 1.03, hi = 1.1 + 0.3 * s, pan = 0.02 + 0.06 * s
            return times.enumerated().map { i, t in
                let inward = i % 2 == 1
                let dir = noise(i, seed) >= 0 ? 1.0 : -1.0
                return Pose(t: t, zoom: inward ? hi : lo, pull: inward ? 1 : 0.4,
                            pan: Vec2(inward ? 0 : dir * pan, inward ? 0 : -dir * pan * 0.5),
                            easing: useBeats ? .easeOut : .easeInOut)
            }
        case .shake:
            let amp = 0.004 + 0.016 * s, rot = 0.3 + 1.7 * s
            let zoom = 1.06 + 0.06 * s
            let step = 1.0 / 12
            let n = max(1, Int((d / step).rounded(.up)))
            return (0...n).map { i in
                let t = min(Double(i) * step, d)
                var a = 1.0
                if useBeats {
                    // bursts: strong on the beat, decaying over 0.35 s, a light tremble in between
                    let since = beats.last { $0 <= t + 1e-6 }.map { t - $0 } ?? 10
                    a = 0.25 + 1.5 * exp(-since / 0.15)
                }
                return Pose(t: t, zoom: zoom, pull: 0.5,
                            pan: Vec2(noise(3 * i, seed) * amp * a, noise(3 * i + 1, seed) * amp * a),
                            rotation: noise(3 * i + 2, seed) * rot * a, easing: .easeInOut)
            }
        }
    }

    /// Writes the move as position / scale (+ rotation for Shake) keyframes. `subject` = clip-local subject path,
    /// `beats` = clip-local seconds, `source` = display size of the media.
    public static func apply(_ o: AIMovementOptions, subject path: [SubjectSample], beats: [Double],
                             to clip: inout Clip, source: Size2, canvas: Size2) {
        clip.keyframes[ParamKey.position.raw] = nil
        clip.keyframes[ParamKey.scale.raw] = nil
        clip.keyframes[ParamKey.rotation.raw] = nil
        clip.transform.position = .zero; clip.transform.scale = .one; clip.transform.rotation = 0
        clip.reframe = nil
        clip.cameraLock = nil
        let d = max(clip.duration.seconds, 0.04)
        let base = 1.0
        // stable per clip (FNV-1a of the id), so re-applying gives the same move
        let seed = clip.id.raw.uuidString.utf8.reduce(UInt64(0xcbf29ce484222325)) { ($0 ^ UInt64($1)) &* 0x100000001b3 }
        let ps = poses(o, duration: d, beats: beats.filter { $0 > 0 && $0 < d }, seed: seed)
        var pk: [Keyframe] = [], sk: [Keyframe] = [], rk: [Keyframe] = []
        for p in ps {
            let k = base * p.zoom
            let subj = subject(at: p.t, path)
            // pull the frame towards the subject (clamped so the frame keeps covering what it covered)
            let full = ReframePath.position(x: subj.x, y: subj.y, source: source, canvas: canvas, scale: k)
            let fit = min(canvas.width / max(source.width, 1), canvas.height / max(source.height, 1))
            let mx = max(0, (source.width * fit * k - canvas.width) / 2 / canvas.width)
            let my = max(0, (source.height * fit * k - canvas.height) / 2 / canvas.height)
            let x = min(max(full.x * p.pull + p.pan.x, -mx), mx)
            let y = min(max(full.y * p.pull + p.pan.y, -my), my)
            let time = Time(p.t).clamped(.zero, clip.duration)
            if let last = pk.last, last.time == time { continue }
            pk.append(Keyframe(time: time, value: .vec2(Vec2(x, y)), easing: p.easing))
            sk.append(Keyframe(time: time, value: .vec2(Vec2(k, k)), easing: p.easing))
            if o.preset == .shake { rk.append(Keyframe(time: time, value: .scalar(p.rotation), easing: p.easing)) }
        }
        if pk.count > 1 {
            clip.keyframes[ParamKey.position.raw] = KeyframeTrack(pk)
            clip.keyframes[ParamKey.scale.raw] = KeyframeTrack(sk)
            if !rk.isEmpty { clip.keyframes[ParamKey.rotation.raw] = KeyframeTrack(rk) }
        } else if let p = pk.first?.value.vec2, let s = sk.first?.value.vec2 {
            clip.transform.position = p; clip.transform.scale = s
        }
        clip.aiMovement = o
    }

    /// Unticking AI movement: drops its keyframes and resets the transform.
    public static func remove(_ clip: inout Clip) {
        guard clip.aiMovement != nil else { return }
        clip.aiMovement = nil
        clip.keyframes[ParamKey.position.raw] = nil
        clip.keyframes[ParamKey.scale.raw] = nil
        clip.keyframes[ParamKey.rotation.raw] = nil
        clip.transform.position = .zero; clip.transform.scale = .one; clip.transform.rotation = 0
    }
}
