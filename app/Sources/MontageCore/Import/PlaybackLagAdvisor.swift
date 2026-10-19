import Foundation

/// "Your media may cause playback lag → Transcode" (MI-009): heuristics for videos that decode slowly on a MacBook
/// Air — variable frame rate, very high bitrate for their size, high resolution at high frame rates, 10-bit HDR at 4K.
/// Transcoding = an edit-friendly proxy (H.264, GOP 10, no B-frames) made right away; export keeps the original.
public enum PlaybackLagAdvisor {
    public enum Reason: String, Sendable, CaseIterable { case variableFrameRate, highBitrate, highFrameRate, hdr4K
        public var nameKey: String { "lag.reason.\(rawValue)" }
    }

    public static func reasons(_ a: MediaAsset) -> [Reason] {
        guard a.kind == .video, a.hasVideo else { return [] }
        var r: [Reason] = []
        let long = max(a.pixelSize.width, a.pixelSize.height)
        let fps = a.frameRate?.fps ?? 30
        if a.techInfo?.isVariableFrameRate == true { r.append(.variableFrameRate) }
        if let b = a.techInfo?.bitrate {
            // ≈ 0.35 bits per pixel per frame is far above camera H.264/HEVC (0.1–0.2); ProRes-class files decode in hardware
            let budget = Double(a.pixelSize.width * a.pixelSize.height) * fps * 0.35
            let prores = (a.codec ?? "").lowercased().contains("prores") || (a.codec ?? "").hasPrefix("ap")
            if !prores, Double(b) > max(budget, 25_000_000) { r.append(.highBitrate) }
        }
        if long > 1920, fps > 31 { r.append(.highFrameRate) }
        if long > 1920, a.isHDR || (a.bitDepth ?? 8) > 8 { r.append(.hdr4K) }
        return r
    }
}
