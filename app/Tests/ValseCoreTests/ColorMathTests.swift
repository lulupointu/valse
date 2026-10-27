import Testing
import Foundation
@testable import ValseCore

@Suite struct ColorMathTests {
    @Test func referenceWhiteCodes() {
        // BT.2408: 203-nit reference white = HLG 75 %, PQ ≈ 58 %.
        #expect(abs(ColorMath.fromLinear(1, .hlg) - 0.75) < 0.005)
        #expect(abs(ColorMath.fromLinear(1, .pq) - 0.58) < 0.005)
        #expect(abs(ColorMath.fromLinear(1, .sdr) - 1) < 1e-9)
    }

    @Test func transfersRoundTrip() {
        for tf in [TransferFunction.sdr, .hlg, .pq] {
            for v in stride(from: 0.05, through: 0.95, by: 0.1) {
                #expect(abs(ColorMath.fromLinear(ColorMath.toLinear(v, tf), tf) - v) < 1e-6)
            }
        }
    }

    @Test func sdrToHDRRoundTripsThroughLinear() {
        for space in [ProjectColorSpace.hdrHLG, .hdrPQ] {
            let c = [0.9, 0.5, 0.2]
            let hdr = ColorMath.convert(c, from: .sdr, wide: false, to: space.transfer, wide: true)
            // HDR → linear → 709 recovers the SDR colour (the HLG luminance OOTF is inverted exactly); SDR → HDR decodes
            // SDR with Apple's Rec.709 display curve (BUG-SDR-IN-HDR)
            let l = ColorMath.mul(ColorMath.m2020to709, ColorMath.toLinear(hdr, space.transfer, wide: true))
            for (a, b) in zip(c, l.map { pow($0, 1 / ColorMath.appleSDRVideoGamma) }) { #expect(abs(a - b) < 0.01) }
        }
        #expect(ColorMath.convert([0.3, 0.4, 0.5], from: .sdr, wide: false, to: .sdr, wide: false) == [0.3, 0.4, 0.5])
    }

    @Test func toneMapIsMonotoneAndBounded() {
        var prev = -1.0
        for m in stride(from: 0.0, through: 50, by: 0.25) {
            let t = ColorMath.toneMap(m)
            #expect(t >= prev && t < 1)
            prev = t
        }
        #expect(ColorMath.toneMap(0) == 0)
    }

    /// HDR footage in an SDR project: Apple's own HLG → SDR rendering (AVAssetImageGenerator, no metadata) of grey
    /// patches is HLG 25/50/75/100 % → 55/98/156/255 (8-bit); the owner's iPhone DV footage fits the same curve.
    @Test func hlgToSDRMatchesApple() {
        let apple: [(Double, Double)] = [(0.25, 55), (0.5, 98), (0.75, 156), (1.0, 255)]
        for (v, ref) in apple {
            let o = ColorMath.convert([v, v, v], from: .hlg, wide: true, to: .sdr, wide: false)
            #expect(abs(o[1] * 255 - ref) < 18, "HLG \(v) → \(o[1] * 255), Apple \(ref)")
        }
        // HLG reference white (75 %) is no longer blown out (old shoulder: 0.97)
        #expect(ColorMath.convert([0.75, 0.75, 0.75], from: .hlg, wide: true, to: .sdr, wide: false)[0] < 0.7)
    }

    /// Skin in BT.2020 HLG keeps its hue and isn't pushed to orange/red: luminance OOTF + gamut desaturation instead
    /// of per-channel γ and a hard clip. Apple renders HLG (0.70, 0.58, 0.50) as (161, 105, 90).
    @Test func hlgSkinToneIsNatural() {
        let o = ColorMath.convert([0.70, 0.58, 0.50], from: .hlg, wide: true, to: .sdr, wide: false).map { $0 * 255 }
        let apple = [161.0, 105, 90]
        for (a, b) in zip(o, apple) { #expect(abs(a - b) < 20, "\(o) vs Apple \(apple)") }
        #expect(o[0] / o[1] < 1.7)
    }

    @Test func hlgOOTFIsOnLuminance() {
        // neutral: same as a per-channel OOTF; coloured: channel ratios of the scene light are preserved
        let n = ColorMath.toLinear([0.6, 0.6, 0.6], .hlg, wide: true)
        #expect(abs(n[0] - ColorMath.toLinear(0.6, .hlg)) < 1e-12)
        let c = ColorMath.toLinear([0.7, 0.5, 0.4], .hlg, wide: true)
        let e = [0.7, 0.5, 0.4].map { ColorMath.hlgInverseOETF($0) }
        #expect(abs(c[0] / c[1] - e[0] / e[1]) < 1e-9)
        let back = ColorMath.fromLinear(c, .hlg, wide: true)
        for (a, b) in zip(back, [0.7, 0.5, 0.4]) { #expect(abs(a - b) < 1e-6) }
    }

    @Test func outOfGamutIsDesaturatedNotClipped() {
        // saturated BT.2020 green is outside BT.709: no negative channel, luminance kept
        let o = ColorMath.convert([0.3, 0.7, 0.35], from: .hlg, wide: true, to: .sdr, wide: false)
        #expect(o.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(o[1] > o[2] && o[2] >= o[0], "hue kept (green): \(o)")
    }

    @Test func settingsDecodeWithoutColorSpace() throws {
        let json = #"{"canvasSize":{"width":1920,"height":1080},"frameRate":{"numerator":30,"denominator":1},"backgroundColor":{"r":0,"g":0,"b":0,"a":1},"aspectPreset":"16:9"}"#
        let s = try JSONDecoder().decode(ProjectSettings.self, from: Data(json.utf8))
        #expect(s.colorSpace == .sdr709)
        var hdr = s; hdr.colorSpace = .hdrHLG
        let round = try JSONDecoder().decode(ProjectSettings.self, from: JSONEncoder().encode(hdr))
        #expect(round == hdr)
    }
}
