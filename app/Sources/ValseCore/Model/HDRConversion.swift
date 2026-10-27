import Foundation

/// Per-clip HDR conversion (CL-014, CapCut "HDR conversion tool"): how a source whose transfer differs from the
/// project's is converted. nil on the clip = the default pipeline (`ColorMath.convert`: Apple-matched HDR → SDR curve,
/// SDR white at 203 nits in HDR projects) — existing projects render exactly as before.
public struct HDRConversion: Codable, Sendable, Hashable {
    public enum Method: String, Codable, Sendable, CaseIterable {
        /// The default curve (Apple-matched, what Photos / QuickTime show).
        case natural
        /// ITU-R BT.2390 EETF (HDR → SDR) / highlight expansion to `peakNits` (SDR → HDR).
        case bt2390
        public var nameKey: String { "hdrConv.method.\(rawValue)" }
    }
    public var method: Method
    /// HDR → SDR: mastering peak of the source (nits; brighter → more highlight compression).
    /// SDR → HDR: peak brightness given to SDR white highlights (nits; 203 = no expansion).
    public var peakNits: Double

    public init(method: Method = .bt2390, peakNits: Double = 1000) { self.method = method; self.peakNits = peakNits }

    public static let sourcePeakRange: ClosedRange<Double> = 400...4000
    public static let targetPeakRange: ClosedRange<Double> = 203...1000

    /// Shader parameters (`ConvertU.toneMode/peak`): mode 0 = default path.
    public var shaderMode: Float { method == .bt2390 ? 1 : 0 }
}

extension ColorMath {
    // MARK: PQ helpers (absolute nits)

    static func pqEncode(nits: Double) -> Double {
        let m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875
        let p = pow(min(max(nits, 0) / 10000, 1), m1)
        return pow((c1 + c2 * p) / (1 + c3 * p), m2)
    }
    static func pqDecode(_ v: Double) -> Double {
        let m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875
        let p = pow(max(v, 0), 1 / m2)
        return pow(max(p - c1, 0) / (c2 - c3 * p), 1 / m1) * 10000
    }

    /// BT.2390 EETF on a luminance-like value in nits: source range 0…`sourcePeak` → display 0…`targetPeak`
    /// (PQ domain, Hermite knee at KS = 1.5·maxLum − 0.5, no black lift).
    public static func bt2390(nits: Double, sourcePeak: Double, targetPeak: Double) -> Double {
        guard sourcePeak > targetPeak else { return min(nits, targetPeak) }
        let pw = pqEncode(nits: sourcePeak)
        let e1 = min(pqEncode(nits: nits) / pw, 1)
        let maxLum = pqEncode(nits: targetPeak) / pw
        let ks = 1.5 * maxLum - 0.5
        var e2 = e1
        if e1 > ks {
            let t = (e1 - ks) / (1 - ks), t2 = t * t, t3 = t2 * t
            e2 = (2 * t3 - 3 * t2 + 1) * ks + (t3 - 2 * t2 + t) * (1 - ks) + (-2 * t3 + 3 * t2) * maxLum
        }
        return pqDecode(e2 * pw)
    }

    /// SDR → HDR highlight expansion on max(R,G,B) linear (1 = SDR white): mid-tones stay, white reaches peak/203.
    public static func inverseToneMap(_ m: Double, peakNits: Double) -> Double {
        let g = max(peakNits / referenceWhiteNits, 1)
        let x = max(m, 0)
        return x * (1 + (g - 1) * x * x)
    }

    /// `convert` with a clip's HDR conversion (nil or `.natural` = the default `convert`, bit for bit).
    public static func convert(_ rgb: [Double], from inTF: TransferFunction, wide inWide: Bool,
                               to outTF: TransferFunction, wide outWide: Bool, conversion: HDRConversion?) -> [Double] {
        guard let h = conversion, h.method == .bt2390, inTF != outTF, inTF == .sdr || outTF == .sdr else {
            return convert(rgb, from: inTF, wide: inWide, to: outTF, wide: outWide)
        }
        var l = linearInput(rgb, inTF, wide: inWide, to: outTF)
        if inWide && !outWide { l = mul(m2020to709, l) }
        if !inWide && outWide { l = mul(m709to2020, l) }
        l = gamutCompress(l, wide: outWide)
        let m = l.max() ?? 0
        if m > 0 {
            let out: Double
            if outTF == .sdr {
                // linear 1 = 203 nits; SDR white is the display peak
                out = bt2390(nits: m * referenceWhiteNits, sourcePeak: h.peakNits, targetPeak: referenceWhiteNits) / referenceWhiteNits
            } else {
                out = inverseToneMap(m, peakNits: h.peakNits)
            }
            let k = out / m
            l = l.map { $0 * k }
        }
        return fromLinear(l, outTF, wide: outWide)
    }
}
