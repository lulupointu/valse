import Foundation

// Per-clip render-engine features (W6/W9): chroma key, AI matte, smooth slow-mo, motion blur, stabilization.
// All are optional `Clip` fields (nil = off), so old project files decode unchanged.

/// Chroma key ("Cutout ▸ Chroma key"). Colours are straight sRGB like everything in the model.
public struct ChromaKey: Hashable, Codable, Sendable {
    /// Key colour picked on the canvas.
    public var color: RGBA
    /// CapCut "Strength" 0…1 (default 0.2): how far from the key colour pixels are still removed.
    public var intensity: Double
    /// CapCut "Shadow" 0…1: keeps darkening (shadows cast on the screen) as partial opacity.
    public var shadow: Double
    /// Edge feather 0…1: softness of the matte transition.
    public var edgeFeather: Double
    /// Edge clean-up 0…1: chokes the semi-transparent fringe.
    public var edgeCleanup: Double
    /// Spill suppression 0…1: removes the key colour cast from the kept pixels.
    public var spill: Double
    public init(color: RGBA = RGBA(0, 1, 0), intensity: Double = 0.2, shadow: Double = 0, edgeFeather: Double = 0.1,
                edgeCleanup: Double = 0, spill: Double = 0.5) {
        self.color = color; self.intensity = intensity; self.shadow = shadow; self.edgeFeather = edgeFeather
        self.edgeCleanup = edgeCleanup; self.spill = spill
    }
}

/// AI cutout matte applied by the compositor ("Cutout ▸ Auto cutout / Customized"). The matte pixels come from
/// MontageAI through the engine's `MatteStore` (a grey matte video aligned with the media, or a still for images);
/// `kind` names which matte ("person", "subject", "custom.<id>").
public struct ClipMatte: Hashable, Codable, Sendable {
    public var kind: String
    /// Edge feather 0…1.
    public var feather: Double
    /// Expand (> 0) / shrink (< 0) the matte, −1…1.
    public var expand: Double
    public var inverted: Bool
    public init(kind: String = "person", feather: Double = 0, expand: Double = 0, inverted: Bool = false) {
        self.kind = kind; self.feather = feather; self.expand = expand; self.inverted = inverted
    }
}

/// "Smooth slow-mo" method for clips slower than 1×.
public enum SlowMotionMethod: String, Codable, Sendable, CaseIterable {
    /// Cross-fade between the two source frames around the remapped time (real time).
    case frameBlending
    /// Optical-flow interpolation (MontageAI hook `FrameInterpolation.provider`); falls back to frame blending.
    case opticalFlow
    public var nameKey: String { "slowmo.\(rawValue)" }
}

/// Frame-accumulation motion blur ("Motion blur": amount, times).
public struct MotionBlur: Hashable, Codable, Sendable {
    /// Blur amount 0…1 (weight of the trailing frames).
    public var amount: Double
    /// Number of frames accumulated (CapCut "Times" 2× / 4× / 6×), clamped to 2…6.
    public var samples: Int
    public init(amount: Double = 0.5, samples: Int = 2) { self.amount = amount; self.samples = samples }
    public var clampedSamples: Int { min(max(samples, 2), 6) }
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

/// Per-frame stabilization correction in normalized source units (fraction of width/height), plus the uniform zoom
/// that hides the moving borders. Produced by the analyzer, consumed by the renderer.
public struct StabilizationTrack: Codable, Sendable, Equatable {
    public var frameDuration: Time
    /// Correction per source frame (index = frame number from media time 0).
    public var dx: [Float]
    public var dy: [Float]
    public var zoom: Double
    public init(frameDuration: Time, dx: [Float], dy: [Float], zoom: Double) {
        self.frameDuration = frameDuration; self.dx = dx; self.dy = dy; self.zoom = zoom
    }

    /// Correction at media time `t` (nearest frame).
    public func correction(at t: Time) -> (dx: Double, dy: Double) {
        guard !dx.isEmpty, frameDuration.ticks > 0 else { return (0, 0) }
        let i = min(max(Int(t.ticks / frameDuration.ticks), 0), dx.count - 1)
        return (Double(dx[i]), Double(dy[i]))
    }

    /// Builds the track from a raw camera path (cumulative translation per frame): smoothed path − raw path,
    /// zoom = smallest uniform scale that keeps the corrected frame covering the output.
    public static func from(path px: [Double], _ py: [Double], frameDuration: Time, level: StabilizationLevel) -> StabilizationTrack {
        let n = min(px.count, py.count)
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
        var dx = [Float](repeating: 0, count: n), dy = [Float](repeating: 0, count: n)
        var maxX = 0.0, maxY = 0.0
        for i in 0..<n {
            let cx = sx[i] - px[i], cy = sy[i] - py[i]
            dx[i] = Float(cx); dy[i] = Float(cy)
            maxX = max(maxX, abs(cx)); maxY = max(maxY, abs(cy))
        }
        // shifting by c needs a zoom of 1/(1 − 2|c|) to keep the borders out; cap at 1.5×
        let zoom = min(1.5, 1 / max(0.34, 1 - 2 * max(maxX, maxY)))
        return StabilizationTrack(frameDuration: frameDuration, dx: dx, dy: dy, zoom: zoom)
    }
}

/// Where a freeze-frame still came from.
public struct FreezeOrigin: Hashable, Codable, Sendable {
    public var media: MediaID
    public var sourceTime: Time
    public init(media: MediaID, sourceTime: Time) { self.media = media; self.sourceTime = sourceTime }
}
