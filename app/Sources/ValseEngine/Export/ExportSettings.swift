import Foundation
import ValseCore

/// Video export options (CapCut "Export" ▸ Video exporting: resolution, bit rate, codec, format, frame rate, colour space).
/// Codable with per-field defaults so the dialog's remembered choice survives new fields.
public struct ExportSettings: Codable, Hashable, Sendable {
    public enum Codec: String, Codable, Sendable, CaseIterable {
        // Raw values of the first four are persisted by older builds — never rename.
        case h264, hevc, proRes422, proRes4444
        case proRes422Proxy, proRes422LT, proRes422HQ, proRes4444XQ

        /// CapCut menu order: H.264, HEVC, ProRes 422, 422 LT, 422 HQ, 4444, 4444 XQ, 422 Proxy.
        public static let menuOrder: [Codec] = [.h264, .hevc, .proRes422, .proRes422LT, .proRes422HQ, .proRes4444, .proRes4444XQ, .proRes422Proxy]
        public var nameKey: String { "export.codec.\(rawValue)" }
        /// Grey subtitle in the codec menu (H.264 / HEVC only, like CapCut).
        public var hintKey: String? {
            switch self { case .h264: "export.codec.h264.hint"; case .hevc: "export.codec.hevc.hint"; default: nil }
        }
        public var isProRes: Bool { self != .h264 && self != .hevc }
        /// Codecs that can carry an alpha channel (ProRes 4444 family, HEVC with alpha).
        public var supportsAlpha: Bool { self == .proRes4444 || self == .proRes4444XQ || self == .hevc }
        /// 10-bit is a choice only for HEVC (Main10); ProRes is always ≥ 10-bit, H.264 always 8-bit.
        public var supportsBitDepthChoice: Bool { self == .hevc }
        /// Kept for callers that only know the codec (ProRes ⇒ mov).
        public var fileExtension: String { isProRes ? "mov" : "mp4" }
        /// Approximate ProRes data rate in bits per pixel per frame (Apple ProRes white paper, 1080p29.97 figures).
        var proResBitsPerPixel: Double {
            switch self {
            case .proRes422Proxy: 0.73; case .proRes422LT: 1.64; case .proRes422: 2.37; case .proRes422HQ: 3.56
            case .proRes4444: 5.33; case .proRes4444XQ: 8.0; default: 0
            }
        }
    }

    /// Output short side in pixels (width follows the canvas aspect, rounded to even).
    public enum Resolution: Int, Codable, Sendable, CaseIterable {
        case p480 = 480, p720 = 720, p1080 = 1080, p1440 = 1440, p2160 = 2160, p4320 = 4320
        /// CapCut labels: 480P, 720P, 1080P, 2K, 4K, 8K.
        public var label: String {
            switch self { case .p1440: "2K"; case .p2160: "4K"; case .p4320: "8K"; default: "\(rawValue)P" }
        }
    }

    public enum BitrateMode: String, Codable, Sendable, CaseIterable {
        case lower, recommended, higher, custom
        public var nameKey: String { "export.bitrate.\(rawValue)" }
    }

    /// Rate control for H.264/HEVC (EX-003). VBR = average bit rate; CBR = constant bit rate (VideoToolbox).
    public enum RateControl: String, Codable, Sendable, CaseIterable {
        case vbr, cbr
        public var nameKey: String { "export.rateControl.\(rawValue)" }
    }

    public enum Container: String, Codable, Sendable, CaseIterable {
        case mov, mp4
        public var fileExtension: String { rawValue }
    }

    public enum BitDepth: Int, Codable, Sendable, CaseIterable { case eight = 8, ten = 10 }

    /// EX-025 "Motion blur" at export: every output frame averages `samples` sub-frames rendered across the frame
    /// interval (360° shutter), so everything that moves — media, keyframes, animations, text — gets natural blur.
    public enum MotionBlurLevel: String, Codable, Sendable, CaseIterable {
        case off, low, medium, high
        public var nameKey: String { "export.motionBlur.\(rawValue)" }
        /// Sub-frames per output frame (CapCut "Times" 2× / 4× / 6×).
        public var samples: Int { switch self { case .off: 1; case .low: 2; case .medium: 4; case .high: 6 } }
    }

    /// Output aspect (platform presets). `.original` keeps the project canvas; others re-frame the canvas (content
    /// stays aspect-fit, like changing the project ratio).
    public enum Aspect: String, Codable, Sendable, CaseIterable {
        case original, landscape16x9, portrait9x16, square1x1, portrait4x5
        public var ratio: Double? {
            switch self { case .original: nil; case .landscape16x9: 16.0 / 9; case .portrait9x16: 9.0 / 16; case .square1x1: 1; case .portrait4x5: 0.8 }
        }
        public var nameKey: String { "export.aspect.\(rawValue)" }
    }

    /// CapCut frame-rate menu (+ the NTSC rates).
    public static let frameRates: [FrameRate] = [.fps23_976, .fps24, .fps25, .fps29_97, .fps30, .fps50, .fps59_94, .fps60, FrameRate(120)]

    public var codec: Codec = .h264
    public var container: Container = .mov
    public var resolution: Resolution = .p1080
    public var frameRate: FrameRate = .fps30
    public var bitrateMode: BitrateMode = .recommended
    /// Mbps, used when `bitrateMode == .custom`.
    public var customBitrateMbps: Double = 20
    public var rateControl: RateControl = .vbr
    /// HEVC only; HDR always exports 10-bit.
    public var bitDepth: BitDepth = .eight
    /// Transparent background + alpha channel (ProRes 4444 / HEVC with alpha).
    public var alpha: Bool = false
    /// HDR project → Rec.709 SDR (tone-mapped by the renderer's HDR→SDR shoulder). "Smart HDR to SDR".
    public var toneMapToSDR: Bool = false
    public var aspect: Aspect = .original
    public var includeAudio: Bool = true
    public var audioBitrateKbps: Int = 192
    /// Hardware encoder preferred (falls back to software if unavailable). Settings ▸ "Speed up hardware encoding".
    public var preferHardware: Bool = true
    /// EX-016 Settings ▸ "Faster exporting, but may have color differences": the hardware encoder prioritises speed
    /// over quality (VideoToolbox `PrioritizeEncodingSpeedOverQuality`). Ignored by the software encoder and ProRes.
    public var fastEncoding: Bool = false
    /// Captions are rendered into the picture (false = only the sidecar caption file).
    public var burnCaptions: Bool = true
    /// EX-019: prepend the cover frame as the first frame (social thumbnails).
    public var prependCover: Bool = false
    /// EX-025: export-time motion blur (frame accumulation).
    public var motionBlur: MotionBlurLevel = .off
    /// EX-018 "AI ultra HD": before rendering, video clips smaller than what the export shows are super-resolved
    /// (on-device VideoToolbox ML super resolution via `ExportHooks.superResolve`, set by ValseAI).
    public var aiUltraHD: Bool = false

    public init() {}

    enum CodingKeys: String, CodingKey {
        case codec, container, resolution, frameRate, bitrateMode, customBitrateMbps, rateControl, bitDepth, alpha, toneMapToSDR,
             aspect, includeAudio, audioBitrateKbps, preferHardware, fastEncoding, burnCaptions, prependCover, motionBlur, aiUltraHD
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ExportSettings()
        codec = (try? c.decodeIfPresent(Codec.self, forKey: .codec)) ?? d.codec
        container = (try? c.decodeIfPresent(Container.self, forKey: .container)) ?? (codec.isProRes ? .mov : .mp4)
        resolution = (try? c.decodeIfPresent(Resolution.self, forKey: .resolution)) ?? d.resolution
        frameRate = (try? c.decodeIfPresent(FrameRate.self, forKey: .frameRate)) ?? d.frameRate
        bitrateMode = (try? c.decodeIfPresent(BitrateMode.self, forKey: .bitrateMode)) ?? d.bitrateMode
        customBitrateMbps = (try? c.decodeIfPresent(Double.self, forKey: .customBitrateMbps)) ?? d.customBitrateMbps
        rateControl = (try? c.decodeIfPresent(RateControl.self, forKey: .rateControl)) ?? d.rateControl
        bitDepth = (try? c.decodeIfPresent(BitDepth.self, forKey: .bitDepth)) ?? d.bitDepth
        alpha = (try? c.decodeIfPresent(Bool.self, forKey: .alpha)) ?? d.alpha
        toneMapToSDR = (try? c.decodeIfPresent(Bool.self, forKey: .toneMapToSDR)) ?? d.toneMapToSDR
        aspect = (try? c.decodeIfPresent(Aspect.self, forKey: .aspect)) ?? d.aspect
        includeAudio = (try? c.decodeIfPresent(Bool.self, forKey: .includeAudio)) ?? d.includeAudio
        audioBitrateKbps = (try? c.decodeIfPresent(Int.self, forKey: .audioBitrateKbps)) ?? d.audioBitrateKbps
        preferHardware = (try? c.decodeIfPresent(Bool.self, forKey: .preferHardware)) ?? d.preferHardware
        fastEncoding = (try? c.decodeIfPresent(Bool.self, forKey: .fastEncoding)) ?? d.fastEncoding
        burnCaptions = (try? c.decodeIfPresent(Bool.self, forKey: .burnCaptions)) ?? d.burnCaptions
        prependCover = (try? c.decodeIfPresent(Bool.self, forKey: .prependCover)) ?? d.prependCover
        motionBlur = (try? c.decodeIfPresent(MotionBlurLevel.self, forKey: .motionBlur)) ?? d.motionBlur
        aiUltraHD = (try? c.decodeIfPresent(Bool.self, forKey: .aiUltraHD)) ?? d.aiUltraHD
    }

    // MARK: Derived

    /// Codec actually used for a project colour space: HDR needs 10 bits, so H.264 becomes HEVC Main10
    /// (CapCut also exports HDR only as HEVC/ProRes).
    public func effectiveCodec(for space: ProjectColorSpace) -> Codec {
        // 8K is beyond H.264 levels on Apple encoders: HEVC.
        (outputColorSpace(for: space).isHDR || resolution == .p4320) && codec == .h264 ? .hevc : codec
    }

    /// Colour space written to the file.
    public func outputColorSpace(for space: ProjectColorSpace) -> ProjectColorSpace { toneMapToSDR ? .sdr709 : space }

    /// ProRes needs a QuickTime container.
    public var effectiveContainer: Container { codec.isProRes ? .mov : container }
    public var fileExtension: String { effectiveContainer.fileExtension }

    /// Alpha is honoured only by alpha-capable codecs.
    public var effectiveAlpha: Bool { alpha && codec.supportsAlpha }

    /// Bit depth of the encoded video for a project colour space.
    public func effectiveBitDepth(for space: ProjectColorSpace) -> Int {
        let c = effectiveCodec(for: space)
        if c.isProRes { return (c == .proRes4444 || c == .proRes4444XQ) ? 12 : 10 }
        if c == .hevc && effectiveAlpha { return 8 }   // HEVC with alpha is 8-bit only
        if c == .hevc && (outputColorSpace(for: space).isHDR || bitDepth == .ten) { return 10 }
        return 8
    }

    /// Canvas the export renders (aspect preset applied: same short side as the project canvas).
    public func exportCanvas(_ canvas: Size2) -> Size2 {
        guard let r = aspect.ratio else { return canvas }
        let short = min(canvas.width, canvas.height)
        return r >= 1 ? Size2((short * r).rounded(), short) : Size2(short, (short / r).rounded())
    }

    /// Output pixel size for a canvas aspect (short side = resolution; even dimensions; 8K capped at 8192 wide).
    public func outputSize(canvas c0: Size2) -> (width: Int, height: Int) {
        let canvas = exportCanvas(c0)
        let short = Double(resolution.rawValue)
        var w: Double, h: Double
        if canvas.width >= canvas.height { h = short; w = short * canvas.aspect } else { w = short; h = short / canvas.aspect }
        let longMax = 8192.0
        if max(w, h) > longMax { let k = longMax / max(w, h); w *= k; h *= k }
        func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }
        return (even(w), even(h))
    }

    /// Video bitrate in bits/s for H.264/HEVC (ProRes: the codec's nominal rate).
    /// "Recommended" ≈ 12 Mbps for 1080p30 H.264 (CapCut: 48 s → 72 MB), HEVC 35 % less; sub-linear in frame rate.
    public func videoBitrate(canvas: Size2) -> Int {
        let (w, h) = outputSize(canvas: canvas)
        if codec.isProRes { return Int(Double(w * h) * frameRate.fps * codec.proResBitsPerPixel) }
        let fpsFactor = pow(max(frameRate.fps, 1) / 30, 0.75) * 30
        let base = Double(w * h) * fpsFactor * 0.19 * (codec == .hevc ? 0.65 : 1)
        switch bitrateMode {
        case .lower: return Int(base * 0.5)
        case .recommended: return Int(base)
        case .higher: return Int(base * 1.8)
        case .custom: return Int(max(0.5, customBitrateMbps) * 1_000_000)
        }
    }

    /// File size estimate in bytes (dialog footer).
    public func estimatedBytes(duration: Time, canvas: Size2) -> Int64 {
        let video = Double(videoBitrate(canvas: canvas)) * (effectiveAlpha && !codec.isProRes ? 1.3 : 1)
        let audio = includeAudio ? Double(audioBitrateKbps * 1000) : 0
        return Int64((video + audio) / 8 * duration.seconds)
    }
}
