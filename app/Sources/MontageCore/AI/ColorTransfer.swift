import Foundation
import simd

// Statistical colour (W10, CL-007 Auto adjust / CL-008 Color correction / CL-009 Color match / AI-055). No ML: frame
// statistics in CIELAB (on the encoded working values, which is what effects see) → a 33³ LUT that the render team's
// LUT path applies with a Strength.

/// Colour statistics of a set of frames.
public struct ColorStats: Hashable, Codable, Sendable {
    /// Lab mean and standard deviation.
    public var mean: SIMD3<Double>
    public var std: SIMD3<Double>
    /// 1st / 99th percentile of L (0…100).
    public var lLow: Double, lHigh: Double
    public var count: Int

    public init(mean: SIMD3<Double>, std: SIMD3<Double>, lLow: Double, lHigh: Double, count: Int) {
        self.mean = mean; self.std = std; self.lLow = lLow; self.lHigh = lHigh; self.count = count
    }

    /// Statistics of RGB pixels (encoded 0…1).
    public static func of(_ pixels: [SIMD3<Float>]) -> ColorStats {
        guard !pixels.isEmpty else { return ColorStats(mean: SIMD3(50, 0, 0), std: SIMD3(20, 10, 10), lLow: 0, lHigh: 100, count: 0) }
        var s = SIMD3<Double>.zero, s2 = SIMD3<Double>.zero
        var hist = [Int](repeating: 0, count: 101)
        for p in pixels {
            let lab = ColorTransfer.lab(p)
            s += lab; s2 += lab * lab
            hist[min(max(Int(lab.x.rounded()), 0), 100)] += 1
        }
        let n = Double(pixels.count)
        let m = s / n
        let v = simd_max(s2 / n - m * m, .zero)
        func pct(_ q: Double) -> Double {
            let target = q * n
            var acc = 0
            for (i, h) in hist.enumerated() { acc += h; if Double(acc) >= target { return Double(i) } }
            return 100
        }
        return ColorStats(mean: m, std: SIMD3(v.x.squareRoot(), v.y.squareRoot(), v.z.squareRoot()), lLow: pct(0.01), lHigh: pct(0.99), count: pixels.count)
    }
}

public enum ColorTransfer {
    // MARK: sRGB-encoded ↔ CIELAB (D65)

    static func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    static func enc(_ v: Double) -> Double { v <= 0.0031308 ? v * 12.92 : 1.055 * pow(max(v, 0), 1 / 2.4) - 0.055 }

    public static func lab(_ c: SIMD3<Float>) -> SIMD3<Double> {
        let r = lin(Double(c.x)), g = lin(Double(c.y)), b = lin(Double(c.z))
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116 }
        let fx = f(x), fy = f(y), fz = f(z)
        return SIMD3(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    public static func rgb(_ lab: SIMD3<Double>) -> SIMD3<Float> {
        let fy = (lab.x + 16) / 116, fx = fy + lab.y / 500, fz = fy - lab.z / 200
        func fi(_ t: Double) -> Double { t * t * t > 0.008856 ? t * t * t : (t - 16.0 / 116) / 7.787 }
        let x = fi(fx) * 0.95047, y = fi(fy), z = fi(fz) * 1.08883
        let r = 3.2406 * x - 1.5372 * y - 0.4986 * z
        let g = -0.9689 * x + 1.8758 * y + 0.0415 * z
        let b = 0.0557 * x - 0.2040 * y + 1.0570 * z
        return SIMD3(Float(min(max(enc(r), 0), 1)), Float(min(max(enc(g), 0), 1)), Float(min(max(enc(b), 0), 1)))
    }

    // MARK: Looks

    /// Color match (Reinhard transfer in Lab): `source` statistics are mapped onto `reference`'s. Scale ratios are
    /// clamped (0.5…2) so a flat reference can't blow up the grade.
    public static func matchLUT(source s: ColorStats, reference r: ColorStats, size: Int = 33, title: String = "Color match") -> LUT {
        func ratio(_ a: Double, _ b: Double) -> Double { min(max(b / max(a, 1e-3), 0.5), 2) }
        let k = SIMD3(ratio(s.std.x, r.std.x), ratio(s.std.y, r.std.y), ratio(s.std.z, r.std.z))
        var l = LUT.make(size: size) { c in
            let v = lab(c)
            return rgb((v - s.mean) * k + r.mean)
        }
        l.title = title
        return l
    }

    /// Auto adjust / Color correction: gray-world white balance (removes 80 % of the average cast), a levels stretch
    /// of L between the 1st / 99th percentiles towards 3…97 (60 % of the way) with mid-grey re-centring, and a mild
    /// chroma lift for flat footage.
    public static func autoAdjustLUT(_ s: ColorStats, size: Int = 33, title: String = "Auto adjust") -> LUT {
        let cast = SIMD2(s.mean.y, s.mean.z) * 0.8
        let lo = s.lLow, hi = max(s.lHigh, s.lLow + 10)
        let stretch = 1 + ((94 / (hi - lo)) - 1) * 0.6
        let target = 50 + (s.mean.x - 50) * 0.5   // pull the mean halfway towards mid-grey
        let chroma = (s.std.y + s.std.z) / 2
        let sat = chroma < 12 ? min(1.25, 12 / max(chroma, 6)) : 1
        var l = LUT.make(size: size) { c in
            let v = lab(c)
            let L = min(max((v.x - s.mean.x) * stretch + target, 0), 100)
            return rgb(SIMD3(L, (v.y - cast.x) * sat, (v.z - cast.y) * sat))
        }
        l.title = title
        return l
    }
}
