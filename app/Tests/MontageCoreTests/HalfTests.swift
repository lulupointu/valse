import Testing
import Foundation
@testable import MontageCore

/// Portable IEEE half conversion used on x86_64 (no Float16 there). Exhaustively checked against the hardware
/// conversion offline (all 2^32 floats / 2^16 halves, 0 mismatches); here: every half, every rounding tie ± 1 ulp, and a
/// strided sweep of the float space.
@Suite struct HalfTests {
    @Test func knownValues() {
        #expect(Half.softwareBits(1) == 0x3C00)
        #expect(Half.softwareBits(-2) == 0xC000)
        #expect(Half.softwareBits(65504) == 0x7BFF)
        #expect(Half.softwareBits(65520) == 0x7C00)          // ties up into the exponent → +inf
        #expect(Half.softwareBits(0x1p-24) == 0x0001)        // smallest subnormal
        #expect(Half.softwareBits(0x1p-25) == 0x0000)        // tie → even (0)
        #expect(Half.softwareBits(0x1.8p-25) == 0x0001)
        #expect(Half.softwareBits(-0.0) == 0x8000)
        #expect(Half.softwareBits(.infinity) == 0x7C00)
        #expect(Half.softwareBits(.nan) & 0x7E00 == 0x7E00)
        #expect(Half.softwareFloat(0x3555) == 0.333251953125)
        #expect(Half.softwareFloat(0x0001) == 0x1p-24)
        #expect(Half.softwareFloat(0xFC00) == -.infinity)
        #expect(Half.softwareFloat(0x7C01).isNaN)
        // Half.bits / Half.float (the hardware path on arm64) agree with the portable one.
        for f: Float in [0, 1, 0.1, -0.7, 1e-6, 3.14159, 1e5] {
            #expect(Half.bits(f) == Half.softwareBits(f))
        }
    }

    /// Every half decodes to the same float, and re-encodes to itself (NaNs aside).
    @Test func roundTripEveryHalf() {
        for h in UInt16(0)...UInt16.max {
            let f = Half.softwareFloat(h)
            if f.isNaN { continue }
            #expect(Half.softwareBits(f) == h)
            #if arch(arm64)
            #expect(f.bitPattern == Float(Float16(bitPattern: h)).bitPattern)
            #endif
        }
    }

    /// Rounding ties between consecutive halves (and their neighbours) — the cases a wrong rounding mode would miss.
    @Test func tiesMatchHardware() {
        var mismatches = 0
        for h in UInt16(0)..<0x7BFF {   // (the overflow tie at 65520 is in knownValues)
            let a = Half.softwareFloat(h), b = Half.softwareFloat(h + 1)
            let mid = (a + b) / 2   // exact: ≤ 12 significant bits
            for f in [mid, mid.nextUp, mid.nextDown, -mid, -mid.nextUp] {
                let want: UInt16
                #if arch(arm64)
                want = Float16(f).bitPattern
                #else
                // RNE reference: nearest of the two neighbours, ties to the even one.
                let mag = abs(f), lo = a, hi = b
                let pick = mag - lo < hi - mag ? h : (mag - lo > hi - mag ? h + 1 : (h & 1 == 0 ? h : h + 1))
                want = (f.sign == .minus ? 0x8000 : 0) | pick
                #endif
                if Half.softwareBits(f) != want { mismatches += 1 }
            }
        }
        #expect(mismatches == 0)
    }

    #if arch(arm64)
    @Test func stridedSweepMatchesFloat16() {
        var mismatches = 0
        var x: UInt32 = 0
        while true {
            let f = Float(bitPattern: x)
            if Half.softwareBits(f) != Float16(f).bitPattern { mismatches += 1 }
            let (next, o) = x.addingReportingOverflow(65_521)
            if o { break }
            x = next
        }
        #expect(mismatches == 0)
    }
    #endif
}
