import Foundation

/// A named keyframe curve preset (CapCut "Preset curves", UX.md §6.5 [102]; FEATURES KF-004).
public struct EasingPreset: Sendable, Identifiable, Hashable {
    public let id: String
    public let nameKey: String
    public let easing: Easing
    public init(_ id: String, _ easing: Easing) { self.id = id; nameKey = "easing.\(id)"; self.easing = easing }
}

extension EasingPreset {
    /// CapCut's preset curves in their panel order, then Valse extras. "None" = hold (step) as in the timeline menu.
    public static let all: [EasingPreset] = [
        EasingPreset("none", .hold), EasingPreset("linear", .linear),
        EasingPreset("easeIn", .easeIn), EasingPreset("quadIn", .bezier(x1: 0.55, y1: 0.085, x2: 0.68, y2: 0.53)),
        EasingPreset("cubicIn", .bezier(x1: 0.55, y1: 0.055, x2: 0.675, y2: 0.19)),
        EasingPreset("easeOut", .easeOut), EasingPreset("quadOut", .bezier(x1: 0.25, y1: 0.46, x2: 0.45, y2: 0.94)),
        EasingPreset("cubicOut", .bezier(x1: 0.215, y1: 0.61, x2: 0.355, y2: 1)),
        EasingPreset("ease", .easeInOut), EasingPreset("quadEase", .bezier(x1: 0.455, y1: 0.03, x2: 0.515, y2: 0.955)),
        EasingPreset("cubicEase", .bezier(x1: 0.645, y1: 0.045, x2: 0.355, y2: 1)),
        EasingPreset("circularEase", .bezier(x1: 0.785, y1: 0.135, x2: 0.15, y2: 0.86)),
        EasingPreset("reboundIn", .bezier(x1: 0.6, y1: -0.28, x2: 0.735, y2: 0.045)),
        EasingPreset("reboundOut", .bezier(x1: 0.175, y1: 0.885, x2: 0.32, y2: 1.275)),
        // extras
        EasingPreset("expoIn", .bezier(x1: 0.95, y1: 0.05, x2: 0.795, y2: 0.035)),
        EasingPreset("expoOut", .bezier(x1: 0.19, y1: 1, x2: 0.22, y2: 1)),
        EasingPreset("bounceOut", .bounceOut), EasingPreset("elasticOut", .elasticOut),
    ]

    public static func preset(for e: Easing) -> EasingPreset? { all.first { $0.easing == e } }
}

extension Easing {
    /// Cubic control points to show in the curve editor (nil for curves that are not one cubic: hold, bounce, elastic).
    public var controlPoints: (x1: Double, y1: Double, x2: Double, y2: Double)? {
        switch self {
        case .linear: return (1.0 / 3, 1.0 / 3, 2.0 / 3, 2.0 / 3)
        case .easeIn: return (0.42, 0, 1, 1)
        case .easeOut: return (0, 0, 0.58, 1)
        case .easeInOut: return (0.42, 0, 0.58, 1)
        case let .bezier(x1, y1, x2, y2): return (x1, y1, x2, y2)
        case .hold, .bounceOut, .elasticOut: return nil
        }
    }

    /// Speed (d progress / d t) sampled at `n` points over the segment — the "variable speed" graph.
    public func speedSamples(_ n: Int = 64) -> [Double] {
        guard n > 1 else { return [] }
        let h = 1.0 / Double(n - 1)
        return (0..<n).map { i in
            let x = Double(i) * h
            let a = apply(max(0, x - h / 2)), b = apply(min(1, x + h / 2))
            return (b - a) / (min(1, x + h / 2) - max(0, x - h / 2))
        }
    }
}

/// Keyframes copied from a clip at one instant (CapCut keyframe ▸ Copy ⌘C; KF "copy/paste keyframes").
public struct KeyframeClipboard: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var key: String
        public var value: AnimValue
        public var easing: Easing
    }
    public var entries: [Entry]
    public init(entries: [Entry]) { self.entries = entries }
}

extension Clip {
    /// Every keyframe of the clip within `tolerance` of `local` (all properties: the clip's diamond at that time).
    public func copyKeyframes(at local: Time, tolerance: Time) -> KeyframeClipboard {
        var out: [KeyframeClipboard.Entry] = []
        for key in keyframes.keys.sorted() {
            guard let track = keyframes[key], let i = track.index(near: local, tolerance: tolerance) else { continue }
            let k = track.keyframes[i]
            out.append(.init(key: key, value: k.value, easing: k.easing))
        }
        return KeyframeClipboard(entries: out)
    }

    /// Pastes copied keyframes at clip-local `local`. Effect-parameter keys only paste onto the same effect instance;
    /// properties the clip can't have (e.g. a mask key on a clip without mask) are skipped. Returns how many landed.
    @discardableResult
    public mutating func pasteKeyframes(_ clip: KeyframeClipboard, at local: Time, tolerance: Time = Time(ticks: 1)) -> Int {
        let t = local.clamped(.zero, duration)
        var n = 0
        for e in clip.entries {
            let key = ParamKey(e.key)
            guard baseValue(key) != nil else { continue }
            var track = keyframes[e.key] ?? KeyframeTrack()
            track.set(e.value, at: t, easing: e.easing, tolerance: tolerance)
            keyframes[e.key] = track
            n += 1
        }
        return n
    }

    /// "Reset keyframes": drops every keyframe; properties keep their value at `local` (what the user sees now).
    public mutating func resetKeyframes(keepingValuesAt local: Time) {
        let snapshot = resolved(at: local.clamped(.zero, duration))
        for raw in keyframes.keys {
            if let v = snapshot.baseValue(ParamKey(raw)) { setBaseValue(ParamKey(raw), v) }
        }
        keyframes = [:]
    }

    /// Easing of the segment starting at the keyframe of `key` near `local`.
    public func easing(_ key: String, at local: Time, tolerance: Time) -> Easing? {
        guard let track = keyframes[key], let i = track.index(near: local, tolerance: tolerance) else { return nil }
        return track.keyframes[i].easing
    }

    /// Sets the easing of the segment starting at the keyframe of `key` near `local`; `allSegments` = every
    /// keyframe of that property.
    public mutating func setEasing(_ e: Easing, key: String, at local: Time, tolerance: Time, allSegments: Bool = false) {
        guard var track = keyframes[key] else { return }
        if allSegments {
            for i in track.keyframes.indices { track.setEasing(e, at: i) }
        } else if let i = track.index(near: local, tolerance: tolerance) {
            track.setEasing(e, at: i)
        }
        keyframes[key] = track
    }
}

/// Position keyframes drawn as a path on the canvas (FEATURES KF-007).
public enum MotionPath {
    public struct Path: Equatable, Sendable {
        /// Layer centre in canvas pixels, sampled over the clip (follows easing exactly like the renderer).
        public var points: [Vec2]
        /// Centres at the position keyframes.
        public var keyframes: [Vec2]
    }

    /// nil unless the clip has ≥ 2 position keyframes.
    public static func path(for clip: Clip, canvas: Size2, samplesPerSegment: Int = 24) -> Path? {
        guard let track = clip.keyframes[ParamKey.position.raw], track.keyframes.count >= 2 else { return nil }
        func centre(_ t: Time) -> Vec2? {
            guard let p = track.value(at: t)?.vec2 else { return nil }
            return Vec2(canvas.width / 2 + p.x * canvas.width, canvas.height / 2 + p.y * canvas.height)
        }
        var pts: [Vec2] = []
        let ks = track.keyframes
        for i in 0..<(ks.count - 1) {
            let a = ks[i].time, b = ks[i + 1].time
            for j in 0..<samplesPerSegment {
                let t = a + (b - a) * (Double(j) / Double(samplesPerSegment))
                if let c = centre(t) { pts.append(c) }
            }
        }
        if let last = centre(ks[ks.count - 1].time) { pts.append(last) }
        return Path(points: pts, keyframes: ks.compactMap { centre($0.time) })
    }
}
