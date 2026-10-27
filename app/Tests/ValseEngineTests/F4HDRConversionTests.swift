import Testing
import Foundation
import ValseCore
import ValseEngine
import ValseTestSupport

/// F4 CL-014: per-clip HDR conversion — BT.2390 EETF with a source peak (HDR → SDR), SDR highlight expansion to a peak
/// (SDR → HDR). nil keeps the default pipeline bit for bit.
@Suite(.serialized) struct HDRConversionTests {
    @Test func bt2390IsIdentityBelowTheKneeAndHitsTheTargetPeak() {
        // well below the knee: unchanged
        #expect(abs(ColorMath.bt2390(nits: 20, sourcePeak: 1000, targetPeak: 203) - 20) < 0.01)
        // the source peak lands on the target peak
        #expect(abs(ColorMath.bt2390(nits: 1000, sourcePeak: 1000, targetPeak: 203) - 203) < 0.5)
        // monotone, never above the target
        var last = -1.0
        for n in stride(from: 0.0, through: 1000, by: 10) {
            let v = ColorMath.bt2390(nits: n, sourcePeak: 1000, targetPeak: 203)
            #expect(v >= last - 1e-9 && v <= 203.01)
            last = v
        }
        // a brighter mastering peak compresses the same highlight more
        #expect(ColorMath.bt2390(nits: 600, sourcePeak: 4000, targetPeak: 203) < ColorMath.bt2390(nits: 600, sourcePeak: 1000, targetPeak: 203))
    }

    @Test func inverseToneMapKeepsMidTonesAndLiftsWhite() {
        #expect(abs(ColorMath.inverseToneMap(1, peakNits: 812) - 4) < 1e-9)
        #expect(abs(ColorMath.inverseToneMap(0.18, peakNits: 812) - 0.18) < 0.02)
        #expect(ColorMath.inverseToneMap(1, peakNits: 203) == 1)
    }

    @Test func noConversionOrNaturalIsTheDefaultPipeline() {
        for code in [[0.75, 0.75, 0.75], [0.70, 0.58, 0.50], [0.3, 0.7, 0.35]] {
            let d = ColorMath.convert(code, from: .hlg, wide: true, to: .sdr, wide: false)
            #expect(ColorMath.convert(code, from: .hlg, wide: true, to: .sdr, wide: false, conversion: nil) == d)
            #expect(ColorMath.convert(code, from: .hlg, wide: true, to: .sdr, wide: false, conversion: HDRConversion(method: .natural)) == d)
        }
    }

    @Test func hlgClipRendersWithTheBT2390Curve() async throws {
        var p = TestProject()
        let code = 0.85
        let id = try await p.addMedia(try await HDRTests.hlgVideo(y10: Int(HDRTests.code10(code))))
        let plain = try await p.render(at: 0.5).average(x: 0.4, y: 0.4, w: 0.2, h: 0.2)
        p.project.timeline[clip: id]?.hdrConversion = HDRConversion(method: .bt2390, peakNits: 1000)
        let tm = try await p.render(at: 0.5).average(x: 0.4, y: 0.4, w: 0.2, h: 0.2)
        let want = ColorMath.convert([code, code, code], from: .hlg, wide: true, to: .sdr, wide: false,
                                     conversion: HDRConversion(method: .bt2390, peakNits: 1000))
        #expect(abs(tm.luma - want[0]) < 0.05, "GPU \(tm) vs CPU \(want)")
        #expect(abs(tm.r - tm.b) < 0.05)
        // and it is a different curve from the default one
        let def = ColorMath.convert([code, code, code], from: .hlg, wide: true, to: .sdr, wide: false)
        #expect(abs(plain.luma - def[0]) < 0.05)
        #expect(abs(want[0] - def[0]) > 0.03, "bt2390 \(want[0]) default \(def[0])")
        // a brighter source peak keeps the same pixel darker (more highlight room)
        p.project.timeline[clip: id]?.hdrConversion = HDRConversion(method: .bt2390, peakNits: 4000)
        let bright = try await p.render(at: 0.5).average(x: 0.4, y: 0.4, w: 0.2, h: 0.2)
        #expect(bright.luma < tm.luma - 0.02, "4000 nits \(bright.luma) vs 1000 nits \(tm.luma)")
    }

    @Test func sdrClipInHLGProjectExpandsHighlights() async throws {
        var p = TestProject()
        p.project.settings.colorSpace = .hdrHLG
        let v = try await p.addVideo(.solid(RGBA(0.95, 0.95, 0.95)), seconds: 1)
        let base = try await p.render(at: 0.5).average(x: 0.4, y: 0.4, w: 0.2, h: 0.2)
        p.project.timeline[clip: v]?.hdrConversion = HDRConversion(method: .bt2390, peakNits: 1000)
        let lifted = try await p.render(at: 0.5).average(x: 0.4, y: 0.4, w: 0.2, h: 0.2)
        #expect(lifted.luma > base.luma + 0.02, "expanded \(lifted.luma) vs \(base.luma)")
    }
}
