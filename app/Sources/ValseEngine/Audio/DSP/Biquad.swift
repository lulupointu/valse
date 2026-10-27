import Foundation

/// Normalized biquad coefficients (a0 = 1). Formulas: RBJ "Audio EQ Cookbook".
public struct BiquadCoefficients: Sendable, Equatable {
    public var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    public static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    init(b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) {
        self.b0 = b0 / a0; self.b1 = b1 / a0; self.b2 = b2 / a0; self.a1 = a1 / a0; self.a2 = a2 / a0
    }
    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    private static func w(_ f: Double, _ sr: Double) -> (cos: Double, sin: Double) {
        let w0 = 2 * Double.pi * min(max(f, 1), sr * 0.49) / sr
        return (Foundation.cos(w0), Foundation.sin(w0))
    }

    public static func lowPass(_ f: Double, q: Double = 0.7071, sampleRate sr: Double) -> Self {
        let (c, s) = w(f, sr); let al = s / (2 * q)
        return .init(b0: (1 - c) / 2, b1: 1 - c, b2: (1 - c) / 2, a0: 1 + al, a1: -2 * c, a2: 1 - al)
    }
    public static func highPass(_ f: Double, q: Double = 0.7071, sampleRate sr: Double) -> Self {
        let (c, s) = w(f, sr); let al = s / (2 * q)
        return .init(b0: (1 + c) / 2, b1: -(1 + c), b2: (1 + c) / 2, a0: 1 + al, a1: -2 * c, a2: 1 - al)
    }
    /// Constant 0 dB peak gain band-pass.
    public static func bandPass(_ f: Double, q: Double, sampleRate sr: Double) -> Self {
        let (c, s) = w(f, sr); let al = s / (2 * q)
        return .init(b0: al, b1: 0, b2: -al, a0: 1 + al, a1: -2 * c, a2: 1 - al)
    }
    public static func peaking(_ f: Double, q: Double, gainDB: Double, sampleRate sr: Double) -> Self {
        let (c, s) = w(f, sr); let al = s / (2 * q); let a = pow(10, gainDB / 40)
        return .init(b0: 1 + al * a, b1: -2 * c, b2: 1 - al * a, a0: 1 + al / a, a1: -2 * c, a2: 1 - al / a)
    }
    public static func lowShelf(_ f: Double, gainDB: Double, slope: Double = 1, sampleRate sr: Double) -> Self {
        let (c, s) = w(f, sr); let a = pow(10, gainDB / 40)
        let al = s / 2 * sqrt((a + 1 / a) * (1 / slope - 1) + 2); let sa = 2 * sqrt(a) * al
        return .init(b0: a * ((a + 1) - (a - 1) * c + sa), b1: 2 * a * ((a - 1) - (a + 1) * c), b2: a * ((a + 1) - (a - 1) * c - sa),
                     a0: (a + 1) + (a - 1) * c + sa, a1: -2 * ((a - 1) + (a + 1) * c), a2: (a + 1) + (a - 1) * c - sa)
    }
    public static func highShelf(_ f: Double, gainDB: Double, slope: Double = 1, sampleRate sr: Double) -> Self {
        let (c, s) = w(f, sr); let a = pow(10, gainDB / 40)
        let al = s / 2 * sqrt((a + 1 / a) * (1 / slope - 1) + 2); let sa = 2 * sqrt(a) * al
        return .init(b0: a * ((a + 1) + (a - 1) * c + sa), b1: -2 * a * ((a - 1) + (a + 1) * c), b2: a * ((a + 1) + (a - 1) * c - sa),
                     a0: (a + 1) - (a - 1) * c + sa, a1: 2 * ((a - 1) - (a + 1) * c), a2: (a + 1) - (a - 1) * c - sa)
    }

    /// Magnitude response at `f` (for tests / EQ curve drawing).
    public func magnitude(at f: Double, sampleRate sr: Double) -> Double {
        let w0 = 2 * Double.pi * f / sr
        let (c1, s1, c2, s2) = (cos(w0), sin(w0), cos(2 * w0), sin(2 * w0))
        let nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2)
        let dr = 1 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2)
        return sqrt((nr * nr + ni * ni) / (dr * dr + di * di))
    }
}

/// One biquad section, one channel (transposed direct form II, double-precision state).
public struct Biquad: Sendable {
    public var k: BiquadCoefficients
    var z1 = 0.0, z2 = 0.0
    public init(_ k: BiquadCoefficients = .identity) { self.k = k }

    @inline(__always) public mutating func tick(_ x: Float) -> Float {
        let xd = Double(x)
        let y = k.b0 * xd + z1
        z1 = k.b1 * xd - k.a1 * y + z2
        z2 = k.b2 * xd - k.a2 * y
        return Float(y)
    }

    public mutating func process(_ p: UnsafeMutablePointer<Float>, _ n: Int) {
        var a = z1, b = z2
        let (b0, b1, b2, a1, a2) = (k.b0, k.b1, k.b2, k.a1, k.a2)
        for i in 0..<n {
            let x = Double(p[i])
            let y = b0 * x + a
            a = b1 * x - a1 * y + b
            b = b2 * x - a2 * y
            p[i] = Float(y)
        }
        // flush denormals
        z1 = abs(a) < 1e-25 ? 0 : a; z2 = abs(b) < 1e-25 ? 0 : b
    }

    public mutating func reset() { z1 = 0; z2 = 0 }
}
