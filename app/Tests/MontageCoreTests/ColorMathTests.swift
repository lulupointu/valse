import Testing
import Foundation
@testable import MontageCore

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

    @Test func sdrToHDRAndBackIsNearIdentity() {
        for space in [ProjectColorSpace.hdrHLG, .hdrPQ] {
            let c = [0.9, 0.5, 0.2]
            let hdr = ColorMath.convert(c, from: .sdr, wide: false, to: space.transfer, wide: true)
            let back = ColorMath.convert(hdr, from: space.transfer, wide: true, to: .sdr, wide: false)
            // Values above the 0.8 knee are slightly compressed by the shoulder.
            for (a, b) in zip(c, back) { #expect(abs(a - b) < 0.04) }
        }
        #expect(ColorMath.convert([0.3, 0.4, 0.5], from: .sdr, wide: false, to: .sdr, wide: false) == [0.3, 0.4, 0.5])
    }

    @Test func toneMapIsMonotoneAndBounded() {
        var prev = -1.0
        for m in stride(from: 0.0, through: 50, by: 0.25) {
            let t = ColorMath.toneMap(m)
            #expect(t >= prev && t <= 1)
            prev = t
        }
        #expect(ColorMath.toneMap(0.5) == 0.5)
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
