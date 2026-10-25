import Foundation

/// Project colour space (CapCut Project settings ▸ Color space): SDR Rec.709, HDR Rec.2020 HLG or PQ.
/// The compositor's working values are encoded in this space; sources are converted on input (`ColorMath`).
public enum ProjectColorSpace: String, Codable, Sendable, CaseIterable {
    case sdr709, hdrHLG, hdrPQ
    public var isHDR: Bool { self != .sdr709 }
    public var transfer: TransferFunction {
        switch self { case .sdr709: return .sdr; case .hdrHLG: return .hlg; case .hdrPQ: return .pq }
    }
    /// HDR spaces use BT.2020 primaries.
    public var isWideGamut: Bool { isHDR }
    public var nameKey: String { "colorspace.\(rawValue)" }
}

/// Transfer characteristic of a source or output.
public enum TransferFunction: String, Codable, Sendable { case sdr, hlg, pq
    /// Shader code (`ColorConvU.inTF/outTF`).
    public var code: Int { switch self { case .sdr: return 0; case .hlg: return 1; case .pq: return 2 } }
}

/// Reference colour math (CPU mirror of the MSL in `CoreShaders`; used for solids/background colours and tests).
///
/// Linear light is relative to SDR reference white = 1.0 (= 203 cd/m², BT.2408). SDR uses a pure 2.4 gamma
/// (BT.1886 display), HLG uses the BT.2100 OETF with a 1000-nit nominal display and the OOTF (γ 1.2) applied on
/// LUMINANCE (BT.2100: F = Lw·Ys^(γ−1)·E — a per-channel γ oversaturates skin), PQ the ST 2084 curve.
///
/// HDR → SDR (HDR footage in an SDR project): BT.2020 → BT.709 in linear light, out-of-gamut colours desaturated toward
/// their luminance (no hard clip), then a hue-preserving exponential tone curve on max(R,G,B):
/// `sdr = 1 − exp(−k·L)`, k = 0.4 for HLG, 1 for PQ. The HLG curve is fitted to Apple's own HDR→SDR rendering of
/// iPhone HLG / Dolby Vision 8.4 footage (AVAssetImageGenerator, mean error 3.6/255 over 6 real clips) and matches its
/// metadata-less HLG curve (HLG 50 % → 0.38, 75 % → 0.63, 100 % → 0.94): what users see in Photos / QuickTime, the
/// "natural" CapCut look. Apple renders PQ display light ≈ 1:1 below reference white, hence k = 1.
///
/// SDR → HDR (SDR footage, stills, text, stickers, solids, background in an HLG / PQ project; BUG-SDR-IN-HDR): the
/// SDR code values are linearised the way Apple DISPLAYS Rec.709 video — `v^1.961` (ColorSync's BT.709 curve, the
/// QuickTime "1.96 gamma"; measured: AVAssetImageGenerator → sRGB and Core Image → extended-linear P3 both give
/// 0.5 → 0.259, 0.2 → 0.043), not the BT.1886 2.4 — and SDR white lands on linear 1 = reference white (HLG 75 %, PQ
/// 203 nits), which Apple's EDR rendering shows at 1.0 = SDR white. Net: Apple shows the SDR clip in an HDR export
/// like the original file (Core Image EDR ΔE00 ≈ 0.6 HLG / 0.2 PQ on a chart); with 2.4 the mid-tones were up to
/// 30 % darker. Apple's own HLG → SDR rendering (thumbnails, SDR screens) shows HLG reference white at ≈ 60 % grey
/// whatever we do (it is fitted to iPhone grading): that target is out of reach for HLG without breaking EDR.
public enum ColorMath {
    public static let referenceWhiteNits = 203.0
    public static let hlgPeakNits = 1000.0
    public static let hlgSystemGamma = 1.2
    /// How Apple displays Rec.709 SDR video (ColorSync's BT.709 transfer): linear = code^1.961, 1 = SDR white.
    public static let appleSDRVideoGamma = 1.961
    /// Decoding exponent of SDR code values: Apple's display curve when they go to an HDR space, else the 2.4 that
    /// SDR ↔ SDR and the fitted HDR → SDR curve use (unchanged: SDR projects stay bit for bit).
    public static func sdrDecodeGamma(to outTF: TransferFunction) -> Double { outTF == .sdr ? 2.4 : appleSDRVideoGamma }
    /// Exposure of the HDR → SDR tone curve (`toneMap`) for a source transfer.
    public static func sdrToneExposure(_ tf: TransferFunction) -> Double { tf == .hlg ? 0.4 : 1 }

    public static let luma709 = [0.2126, 0.7152, 0.0722]
    public static let luma2020 = [0.2627, 0.6780, 0.0593]
    static func luma(_ c: [Double], wide: Bool) -> Double {
        let k = wide ? luma2020 : luma709
        return k[0] * c[0] + k[1] * c[1] + k[2] * c[2]
    }

    static func hlgInverseOETF(_ v: Double) -> Double {
        let a = 0.17883277, b = 0.28466892, c = 0.55991073
        let v = max(v, 0)
        return v <= 0.5 ? v * v / 3 : (exp((v - c) / a) + b) / 12
    }
    static func hlgOETF(_ e: Double) -> Double {
        let a = 0.17883277, b = 0.28466892, c = 0.55991073
        let e = max(e, 0)
        return min(e <= 1.0 / 12 ? (3 * e).squareRoot() : a * log(12 * e - b) + c, 1)
    }

    /// Encoded → linear for a neutral value (R = G = B, where the luminance OOTF equals a per-channel one).
    public static func toLinear(_ v: Double, _ tf: TransferFunction) -> Double { toLinear([v, v, v], tf, wide: true)[0] }
    /// Linear → encoded for a neutral value.
    public static func fromLinear(_ l: Double, _ tf: TransferFunction) -> Double { fromLinear([l, l, l], tf, wide: true)[0] }

    /// Encoded RGB → linear light (1 = reference white). `wide`: BT.2020 primaries (luminance weights of the HLG OOTF).
    public static func toLinear(_ rgb: [Double], _ tf: TransferFunction, wide: Bool) -> [Double] {
        switch tf {
        case .sdr: return rgb.map { pow(max($0, 0), 2.4) }
        case .hlg:
            let e = rgb.map(hlgInverseOETF)
            let ys = max(luma(e, wide: wide), 1e-9)
            let k = hlgPeakNits * pow(ys, hlgSystemGamma - 1) / referenceWhiteNits
            return e.map { $0 * k }
        case .pq:
            let m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875
            return rgb.map { v in
                let p = pow(max(v, 0), 1 / m2)
                return pow(max(p - c1, 0) / (c2 - c3 * p), 1 / m1) * 10000 / referenceWhiteNits
            }
        }
    }

    /// Linear light (1 = reference white) → encoded RGB.
    public static func fromLinear(_ l: [Double], _ tf: TransferFunction, wide: Bool) -> [Double] {
        switch tf {
        case .sdr: return l.map { pow(min(max($0, 0), 1), 1 / 2.4) }
        case .hlg:
            // inverse OOTF: Yd = Ys^γ  →  E = Fd · Yd^(1/γ − 1)   (Fd normalized to the nominal peak)
            let d = l.map { max($0, 0) * referenceWhiteNits / hlgPeakNits }
            let yd = luma(d, wide: wide)
            guard yd > 1e-12 else { return [0, 0, 0] }
            let k = pow(yd, 1 / hlgSystemGamma - 1)
            return d.map { hlgOETF($0 * k) }
        case .pq:
            let m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875
            return l.map { l in
                let y = min(max(l, 0) * referenceWhiteNits / 10000, 1)
                let p = pow(y, m1)
                return pow((c1 + c2 * p) / (1 + c3 * p), m2)
            }
        }
    }

    /// Encoded source → linear light for a conversion to `outTF`: SDR sources going to HDR use Apple's display curve
    /// (`sdrDecodeGamma`), everything else `toLinear`. Shared by `convert` and `convert(conversion:)`; the MSL mirror is
    /// `tf_to_linear(…, sdr_gamma(outTF))` in CoreShaders.
    public static func linearInput(_ rgb: [Double], _ inTF: TransferFunction, wide: Bool, to outTF: TransferFunction) -> [Double] {
        guard inTF == .sdr else { return toLinear(rgb, inTF, wide: wide) }
        let g = sdrDecodeGamma(to: outTF)
        return rgb.map { pow(max($0, 0), g) }
    }

    /// HDR → SDR tone curve on max(R,G,B) (linear in, linear SDR out, monotone, < 1).
    public static func toneMap(_ m: Double, from tf: TransferFunction = .hlg) -> Double { 1 - exp(-sdrToneExposure(tf) * max(m, 0)) }

    /// BT.709 ↔ BT.2020 primaries (linear light, row-major).
    public static let m709to2020: [[Double]] = [[0.6274, 0.3293, 0.0433], [0.0691, 0.9195, 0.0114], [0.0164, 0.0880, 0.8956]]
    public static let m2020to709: [[Double]] = [[1.6605, -0.5876, -0.0728], [-0.1246, 1.1329, -0.0083], [-0.0182, -0.1006, 1.1187]]

    static func mul(_ m: [[Double]], _ c: [Double]) -> [Double] {
        (0..<3).map { r in m[r][0] * c[0] + m[r][1] * c[1] + m[r][2] * c[2] }
    }

    /// Out-of-gamut (negative) channels: desaturate toward the luminance until the smallest channel is 0.
    static func gamutCompress(_ l: [Double], wide: Bool) -> [Double] {
        let y = max(luma(l, wide: wide), 0)
        let mn = l.min() ?? 0
        guard mn < 0 else { return l }
        guard y > 0 else { return [0, 0, 0] }
        let t = y / (y - mn)
        return l.map { max(y + ($0 - y) * t, 0) }
    }

    /// Converts an encoded RGB triple between transfer/primaries. Identity when both sides match.
    public static func convert(_ rgb: [Double], from inTF: TransferFunction, wide inWide: Bool,
                               to outTF: TransferFunction, wide outWide: Bool) -> [Double] {
        if inTF == outTF && inWide == outWide { return rgb }
        var l = linearInput(rgb, inTF, wide: inWide, to: outTF)
        if inWide && !outWide { l = mul(m2020to709, l) }
        if !inWide && outWide { l = mul(m709to2020, l) }
        l = gamutCompress(l, wide: outWide)
        if outTF == .sdr && inTF != .sdr {
            let m = l.max() ?? 0
            if m > 0 { let k = toneMap(m, from: inTF) / m; l = l.map { $0 * k } }
        }
        return fromLinear(l, outTF, wide: outWide)
    }

    /// An SDR colour (UI pickers, text, solids, background) expressed in the project space.
    public static func color(_ c: RGBA, in space: ProjectColorSpace) -> RGBA {
        guard space.isHDR else { return c }
        let o = convert([c.r, c.g, c.b], from: .sdr, wide: false, to: space.transfer, wide: true)
        return RGBA(o[0], o[1], o[2], c.a)
    }
}
