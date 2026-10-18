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
