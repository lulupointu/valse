import Foundation

// Per-clip render-engine features (W6/W9): AI matte, smooth slow-mo, motion blur, stabilization.
// All are optional `Clip` fields (nil = off), so old project files decode unchanged.

/// AI cutout matte applied by the compositor ("Cutout ▸ Auto cutout / Customized"). The matte pixels come from
/// ValseAI through the engine's `MatteStore` (a grey matte video aligned with the media, or a still for images);
/// `kind` names which matte ("person", "subject", "custom.<id>").
public struct ClipMatte: Hashable, Codable, Sendable {
    public var kind: String
    /// Edge feather 0…1.
    public var feather: Double
    /// Expand (> 0) / shrink (< 0) the matte, −1…1.
    public var expand: Double
    public var inverted: Bool
    /// Matting blend (CK-008) 0…1: edge-aware smoothing of the matte edge + colour decontamination. nil = off.
    public var edgeBlend: Double?
    /// FX-002 body effects on plain video: the matte only feeds the clip's body effects (outline, aura, shadow…);
    /// the layer itself is NOT cut out. nil / false = ordinary cutout.
    public var bodyOnly: Bool?
    public var isBodyOnly: Bool { bodyOnly ?? false }
    public init(kind: String = "person", feather: Double = 0, expand: Double = 0, inverted: Bool = false, edgeBlend: Double? = nil,
                bodyOnly: Bool? = nil) {
        self.kind = kind; self.feather = feather; self.expand = expand; self.inverted = inverted; self.edgeBlend = edgeBlend
        self.bodyOnly = bodyOnly
    }
}

/// "Smooth slow-mo" method for clips slower than 1×.
public enum SlowMotionMethod: String, Codable, Sendable, CaseIterable {
    /// Cross-fade between the two source frames around the remapped time (real time).
    case frameBlending
    /// Optical-flow interpolation (ValseAI hook `FrameInterpolation.provider`); falls back to frame blending.
    case opticalFlow
    public var nameKey: String { "slowmo.\(rawValue)" }
}

/// Frame-rate up-conversion (SP-009 "Make video playback smoother"): a clip with `smoothSlowMo` also interpolates when
/// the project frame rate is higher than what the clip delivers (source fps × speed), e.g. 24 fps footage in a 60 fps
/// project, not only when it is slowed down.
public enum FrameUpconversion {
    /// Output frames fall between source frames at this speed rate.
    public static func needsInterpolation(rate: Double, sourceRate: FrameRate?, projectRate: FrameRate) -> Bool {
        rate < 0.999 || rate * (sourceRate ?? .fps30).fps < projectRate.fps * 0.999
    }

    /// Lowest rate reached by a speed (constant, or the slowest curve point).
    public static func minRate(_ s: Speed) -> Double {
        switch s {
        case .constant(let v): return v
        case .curve(let c): return c.points.map(\.v).min() ?? 1
        }
    }

    /// Video clips of the timeline whose source is slower than the project (candidates for optical flow).
    public static func candidates(_ project: Project) -> [ClipID] {
        let lookup = project.mediaLookup
        return project.timeline.tracks.filter(\.kind.isVisual).flatMap(\.clips).compactMap { c in
            guard let id = c.mediaID, let a = lookup[id], a.kind == .video,
                  minRate(c.speed) * (a.frameRate ?? .fps30).fps < project.settings.frameRate.fps * 0.999 else { return nil }
            return c.id
        }
    }
}

/// Frame-accumulation motion blur ("Motion blur": amount, times).
public struct MotionBlur: Hashable, Codable, Sendable {
    /// Blur amount 0…1 (weight of the trailing frames).
    public var amount: Double
    /// Number of frames accumulated (CapCut "Times" 2× / 4× / 6×), clamped to 2…6.
    public var samples: Int
    /// Which neighbouring frames are blended (CapCut "Direction", CV-014); nil = backward (trailing, as before).
    public var direction: MotionBlurDirection?
    public init(amount: Double = 0.5, samples: Int = 2, direction: MotionBlurDirection? = nil) {
        self.amount = amount; self.samples = samples; self.direction = direction
    }
    public var clampedSamples: Int { min(max(samples, 2), 6) }

    /// Source-frame offsets of the extra frames, nearest first (−1 = previous frame, +1 = next frame).
    public var frameOffsets: [Int] {
        let n = clampedSamples - 1
        switch direction ?? .backward {
        case .backward: return (1...n).map { -$0 }
        case .forward: return (1...n).map { $0 }
        case .both: return (0..<n).map { i in (i % 2 == 0 ? -1 : 1) * (i / 2 + 1) }
        }
    }
}

/// Motion blur direction: trailing (previous frames), leading (next frames) or both ways (centred).
public enum MotionBlurDirection: String, Codable, Sendable, CaseIterable {
    case backward, forward, both
    public var nameKey: String { "inspector.motionBlur.direction.\(rawValue)" }
}

public enum StabilizationLevel: String, Codable, Sendable, CaseIterable {
    case minimalCrop, recommended, mostStable
    public var nameKey: String { "stabilize.\(rawValue)" }
    /// Camera-path smoothing window in seconds.
    public var smoothingSeconds: Double {
        switch self { case .minimalCrop: return 0.5; case .recommended: return 1.0; case .mostStable: return 2.5 }
    }
}

/// Video stabilization: the engine applies a per-frame correction (from the analysis in `StabilizationStore`) and
/// the crop zoom it needs, inside the layer's source sampling (so masks/transform still work in layer space).
public struct Stabilization: Hashable, Codable, Sendable {
    public var level: StabilizationLevel
    public init(level: StabilizationLevel = .recommended) { self.level = level }
}

/// Per-frame stabilization correction in normalized source units (fraction of width/height), an optional roll
/// correction (radians, image coordinates y-down: positive = clockwise), plus the uniform zoom that hides the moving
/// borders. Produced by the analyzer, consumed by the renderer.
public struct StabilizationTrack: Codable, Sendable, Equatable {
    public var frameDuration: Time
    /// Correction per source frame (index = frame number from media time 0).
    public var dx: [Float]
    public var dy: [Float]
    /// Roll correction per frame (nil = translation-only analysis).
    public var dr: [Float]?
    /// Width / height of the analysed frames (rotation is applied in square pixels).
    public var aspect: Double?
    public var zoom: Double
    public init(frameDuration: Time, dx: [Float], dy: [Float], dr: [Float]? = nil, aspect: Double? = nil, zoom: Double) {
        self.frameDuration = frameDuration; self.dx = dx; self.dy = dy; self.dr = dr; self.aspect = aspect; self.zoom = zoom
    }

    func index(_ t: Time) -> Int { min(max(Int(t.ticks / frameDuration.ticks), 0), dx.count - 1) }

    /// Correction at media time `t` (nearest frame).
    public func correction(at t: Time) -> (dx: Double, dy: Double) {
        guard !dx.isEmpty, frameDuration.ticks > 0 else { return (0, 0) }
        let i = index(t)
        return (Double(dx[i]), Double(dy[i]))
    }

    /// Roll correction at media time `t` (radians).
    public func rotation(at t: Time) -> Double {
        guard let dr, !dr.isEmpty, !dx.isEmpty, frameDuration.ticks > 0 else { return 0 }
        return Double(dr[min(index(t), dr.count - 1)])
    }

    /// Builds the track from a raw camera path (cumulative translation, and roll when `pr` is given, per frame):
    /// smoothed path − raw path, zoom = smallest uniform scale that keeps the corrected frame covering the output.
    public static func from(path px: [Double], _ py: [Double], rotation pr: [Double]? = nil, aspect: Double? = nil,
                            frameDuration: Time, level: StabilizationLevel) -> StabilizationTrack {
        let n = min(px.count, py.count, pr?.count ?? .max)
        guard n > 0 else { return StabilizationTrack(frameDuration: frameDuration, dx: [], dy: [], zoom: 1) }
        let fps = 1 / max(frameDuration.seconds, 1e-6)
        let sigma = max(1, level.smoothingSeconds * fps / 2)
        let radius = Int(sigma * 3)
        let weights = (-radius...radius).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        func smooth(_ v: [Double]) -> [Double] {
            (0..<n).map { i in
                var acc = 0.0, w = 0.0
                for (k, wk) in weights.enumerated() {
                    let j = min(max(i + k - radius, 0), n - 1)
                    acc += v[j] * wk; w += wk
                }
                return acc / w
            }
        }
        let sx = smooth(Array(px.prefix(n))), sy = smooth(Array(py.prefix(n)))
        let sr = pr.map { smooth(Array($0.prefix(n))) }
        var dx = [Float](repeating: 0, count: n), dy = [Float](repeating: 0, count: n)
        var dr: [Float]? = pr == nil ? nil : [Float](repeating: 0, count: n)
        let a = max(aspect ?? 16.0 / 9, 1 / (aspect ?? 16.0 / 9))
        var zoom = 1.0
        for i in 0..<n {
            let cx = sx[i] - px[i], cy = sy[i] - py[i]
            dx[i] = Float(cx); dy[i] = Float(cy)
            var roll = 0.0
            if let pr, let sr { roll = sr[i] - pr[i]; dr?[i] = Float(roll) }
            // rotating by φ needs cos φ + a·sin φ; shifting by c needs 1/(1 − 2|c|)
            let need = (cos(abs(roll)) + a * sin(abs(roll))) / max(0.34, 1 - 2 * max(abs(cx), abs(cy)))
            zoom = max(zoom, need)
        }
        return StabilizationTrack(frameDuration: frameDuration, dx: dx, dy: dy, dr: dr, aspect: aspect, zoom: min(1.5, zoom))
    }
}

