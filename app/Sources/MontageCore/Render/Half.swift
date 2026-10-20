/// IEEE 754 binary16 ("half") ↔ Float conversions on raw UInt16 bit patterns.
///
/// `Float16` is unavailable on x86_64 macOS, so code that reads/writes half-float pixels (rgba16Float textures,
/// 64RGBAHalf / OneComponent16Half pixel buffers) goes through these helpers on Intel. On arm64 the call sites keep
/// using `Float16` directly (`#if arch(arm64)`), so Apple Silicon output is unchanged. The software conversion is
/// bit-exact with the hardware one (round-to-nearest-even, overflow → ±inf, subnormals kept, NaN quieted with its
/// payload truncated like ARM FCVT / x86 F16C) — verified against `Float16` in HalfTests on arm64.
public enum Half {
    /// Float → half bits, round-to-nearest-even.
    @inline(__always)
    public static func bits(_ f: Float) -> UInt16 {
        #if arch(arm64)
        Float16(f).bitPattern
        #else
        softwareBits(f)
        #endif
    }

    /// Half bits → Float (exact).
    @inline(__always)
    public static func float(_ h: UInt16) -> Float {
        #if arch(arm64)
        Float(Float16(bitPattern: h))
        #else
        softwareFloat(h)
        #endif
    }

    /// Portable float → half (round-to-nearest-even). Same result as the hardware conversion for every input.
    @inline(__always)
    public static func softwareBits(_ f: Float) -> UInt16 {
        let x = f.bitPattern
        let sign = UInt16(truncatingIfNeeded: (x >> 16) & 0x8000)
        let exp = Int((x >> 23) & 0xFF)
        let mant = x & 0x7F_FFFF
        if exp == 0xFF {   // inf / NaN (quiet bit set, payload truncated)
            return sign | 0x7C00 | (mant != 0 ? UInt16(truncatingIfNeeded: 0x200 | (mant >> 13)) : 0)
        }
        let e = exp - 112   // re-biased half exponent
        if e >= 31 { return sign | 0x7C00 }
        if e <= 0 {   // half subnormal (or zero)
            if e < -10 { return sign }
            let m = mant | 0x80_0000
            let s = UInt32(14 - e)
            var h = m >> s
            let rem = m & ((1 << s) - 1), halfway = UInt32(1) << (s - 1)
            if rem > halfway || (rem == halfway && h & 1 == 1) { h += 1 }
            return sign | UInt16(truncatingIfNeeded: h)
        }
        var h = (UInt32(e) << 10) | (mant >> 13)
        let rem = mant & 0x1FFF
        if rem > 0x1000 || (rem == 0x1000 && h & 1 == 1) { h += 1 }   // a carry rolls into the exponent (→ inf at the top)
        return sign | UInt16(truncatingIfNeeded: h)
    }

    /// Portable half → Float (exact).
    @inline(__always)
    public static func softwareFloat(_ h: UInt16) -> Float {
        let sign = UInt32(h & 0x8000) << 16
        let e = UInt32((h >> 10) & 0x1F), m = UInt32(h & 0x3FF)
        if e == 0 {
            if m == 0 { return Float(bitPattern: sign) }
            return Float(bitPattern: sign | (Float(m) * 0x1p-24).bitPattern)   // exact: m < 2^10
        }
        if e == 31 { return Float(bitPattern: sign | 0x7F80_0000 | (m << 13) | (m != 0 ? 0x40_0000 : 0)) }   // NaN → quiet
        return Float(bitPattern: sign | ((e + 112) << 23) | (m << 13))
    }
}
