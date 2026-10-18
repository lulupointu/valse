import Foundation
import MontageCore

/// Export dialog model (CapCut "Export": name, resolution, bitrate, codec, format, frame rate).
public struct ExportSettings: Codable, Hashable, Sendable {
    public enum Codec: String, Codable, Sendable, CaseIterable {
        case h264, hevc, proRes422, proRes4444
        public var nameKey: String { "export.codec.\(rawValue)" }
        public var isProRes: Bool { self == .proRes422 || self == .proRes4444 }
        public var fileExtension: String { isProRes ? "mov" : "mp4" }
    }
    /// Output height in pixels (width follows the canvas aspect, rounded to even).
    public enum Resolution: Int, Codable, Sendable, CaseIterable {
        case p480 = 480, p720 = 720, p1080 = 1080, p1440 = 1440, p2160 = 2160
        public var label: String { self == .p2160 ? "4K" : (self == .p1440 ? "2K" : "\(rawValue)p") }
    }
    public enum BitrateMode: String, Codable, Sendable, CaseIterable {
        case lower, recommended, higher, custom
        public var nameKey: String { "export.bitrate.\(rawValue)" }
    }

    public var codec: Codec = .h264
    public var resolution: Resolution = .p1080
    public var frameRate: FrameRate = .fps30
    public var bitrateMode: BitrateMode = .recommended
    /// Mbps, used when `bitrateMode == .custom`.
    public var customBitrateMbps: Double = 20
    public var includeAudio: Bool = true
    public var audioBitrateKbps: Int = 192
    /// Hardware encoder required (falls back to software if unavailable).
    public var preferHardware: Bool = true

    public init() {}

    /// Output pixel size for a canvas aspect (short side = resolution; even dimensions).
    public func outputSize(canvas: Size2) -> (width: Int, height: Int) {
        let short = Double(resolution.rawValue)
        var w: Double, h: Double
        if canvas.width >= canvas.height { h = short; w = short * canvas.aspect } else { w = short; h = short / canvas.aspect }
        func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }
        return (even(w), even(h))
    }

    /// Video bitrate in bits/s (ignored for ProRes).
    public func videoBitrate(canvas: Size2) -> Int {
        let (w, h) = outputSize(canvas: canvas)
        // ~0.1 bit per pixel per frame for H.264 "recommended", HEVC 30 % less.
        let base = Double(w * h) * frameRate.fps * 0.1 * (codec == .hevc ? 0.7 : 1)
        switch bitrateMode {
        case .lower: return Int(base * 0.6)
        case .recommended: return Int(base)
        case .higher: return Int(base * 1.8)
        case .custom: return Int(customBitrateMbps * 1_000_000)
        }
    }

    /// Rough file size estimate in bytes (shown in the export dialog).
    public func estimatedBytes(duration: Time, canvas: Size2) -> Int64 {
        let (w, h) = outputSize(canvas: canvas)
        let video: Double
        switch codec {
        case .proRes422: video = Double(w * h) * frameRate.fps * 1.0       // ≈ 1 bit/px/frame
        case .proRes4444: video = Double(w * h) * frameRate.fps * 2.2
        default: video = Double(videoBitrate(canvas: canvas))
        }
        let audio = includeAudio ? Double(audioBitrateKbps * 1000) : 0
        return Int64((video + audio) / 8 * duration.seconds)
    }
}
