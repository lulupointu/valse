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
/// (BT.1886 display), HLG uses the BT.2100 OETF with a 1000-nit nominal display (OOTF γ 1.2 applied per channel),
/// PQ the ST 2084 curve. HDR → SDR tone-mapping is a soft-knee shoulder on max(R,G,B) (hue-preserving): linear up to
/// 0.8, then exponential roll-off to 1.0.
public enum ColorMath {
    public static let referenceWhiteNits = 203.0
    public static let hlgPeakNits = 1000.0

    public static func toLinear(_ v: Double, _ tf: TransferFunction) -> Double {
        switch tf {
        case .sdr: return pow(max(v, 0), 2.4)
        case .hlg:
            let a = 0.17883277, b = 0.28466892, c = 0.55991073
            let e = v <= 0.5 ? v * v / 3 : (exp((v - c) / a) + b) / 12
            return hlgPeakNits * pow(max(e, 0), 1.2) / referenceWhiteNits
        case .pq:
            let m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875
            let p = pow(max(v, 0), 1 / m2)
            let y = pow(max(p - c1, 0) / (c2 - c3 * p), 1 / m1)
            return y * 10000 / referenceWhiteNits
        }
    }

    public static func fromLinear(_ l: Double, _ tf: TransferFunction) -> Double {
        switch tf {
        case .sdr: return pow(min(max(l, 0), 1), 1 / 2.4)
        case .hlg:
            let a = 0.17883277, b = 0.28466892, c = 0.55991073
            let e = pow(max(l, 0) * referenceWhiteNits / hlgPeakNits, 1 / 1.2)
            return min(e <= 1.0 / 12 ? (3 * e).squareRoot() : a * log(12 * e - b) + c, 1)
        case .pq:
            let m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875
            let y = min(max(l, 0) * referenceWhiteNits / 10000, 1)
            let p = pow(y, m1)
            return pow((c1 + c2 * p) / (1 + c3 * p), m2)
        }
    }

    /// Soft-knee shoulder (applied to max channel).
    public static func toneMap(_ m: Double) -> Double {
        let k = 0.8
        return m <= k ? m : k + (1 - k) * (1 - exp(-(m - k) / (1 - k)))
    }

    /// BT.709 ↔ BT.2020 primaries (linear light, row-major).
    public static let m709to2020: [[Double]] = [[0.6274, 0.3293, 0.0433], [0.0691, 0.9195, 0.0114], [0.0164, 0.0880, 0.8956]]
    public static let m2020to709: [[Double]] = [[1.6605, -0.5876, -0.0728], [-0.1246, 1.1329, -0.0083], [-0.0182, -0.1006, 1.1187]]

    static func mul(_ m: [[Double]], _ c: [Double]) -> [Double] {
        (0..<3).map { r in m[r][0] * c[0] + m[r][1] * c[1] + m[r][2] * c[2] }
    }

    /// Converts an encoded RGB triple between transfer/primaries. Identity when both sides match.
    public static func convert(_ rgb: [Double], from inTF: TransferFunction, wide inWide: Bool,
                               to outTF: TransferFunction, wide outWide: Bool) -> [Double] {
        if inTF == outTF && inWide == outWide { return rgb }
        var l = rgb.map { toLinear($0, inTF) }
        if inWide && !outWide { l = mul(m2020to709, l) }
        if !inWide && outWide { l = mul(m709to2020, l) }
        l = l.map { max($0, 0) }
        if outTF == .sdr && inTF != .sdr {
            let m = l.max() ?? 0
            if m > 0 { let k = toneMap(m) / m; l = l.map { $0 * k } }
        }
        return l.map { fromLinear($0, outTF) }
    }

    /// An SDR colour (UI pickers, text, solids, background) expressed in the project space.
    public static func color(_ c: RGBA, in space: ProjectColorSpace) -> RGBA {
        guard space.isHDR else { return c }
        let o = convert([c.r, c.g, c.b], from: .sdr, wide: false, to: space.transfer, wide: true)
        return RGBA(o[0], o[1], o[2], c.a)
    }
}
