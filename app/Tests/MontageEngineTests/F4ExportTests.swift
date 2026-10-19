@preconcurrency import AVFoundation
import Foundation
import Testing
import MontageCore
import MontageEngine
import MontageTestSupport

/// F4 EX-016: hardware / software / "faster exporting" encoders give the same picture (colour within a few levels).
@Suite(.serialized) struct HardwareEncodingTests {
    static func meanRGB(_ url: URL, at t: Double) async throws -> (Double, Double, Double) {
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
        let img = try await g.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
        let w = 64, h = 36
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var r = 0.0, gg = 0.0, b = 0.0
        for i in stride(from: 0, to: px.count, by: 4) { r += Double(px[i]); gg += Double(px[i + 1]); b += Double(px[i + 2]) }
        let n = Double(w * h)
        return (r / n, gg / n, b / n)
    }

    @Test func hardwareSoftwareAndFastEncodesMatchInColour() async throws {
        var p = TestProject(canvas: Size2(640, 360))
        try await p.addVideo(.movingBox(.blue, .white), seconds: 1, audioHz: nil)
        func s(_ hw: Bool, _ fast: Bool) -> ExportSettings {
            var e = ExportSettings(); e.resolution = .p480; e.preferHardware = hw; e.fastEncoding = fast; return e
        }
        let hw = try await p.export(seconds: 0.5, settings: s(true, false))
        let sw = try await p.export(seconds: 0.5, settings: s(false, false))
        let fast = try await p.export(seconds: 0.5, settings: s(true, true))
        #expect(fast.probe.videoCodec == "h264" && fast.probe.width == 854)
        let a = try await Self.meanRGB(hw.url, at: 0.25), b = try await Self.meanRGB(sw.url, at: 0.25), c = try await Self.meanRGB(fast.url, at: 0.25)
        for (x, y) in [(a, b), (a, c)] {
            #expect(abs(x.0 - y.0) < 3 && abs(x.1 - y.1) < 3 && abs(x.2 - y.2) < 3, "mean RGB \(x) vs \(y)")
        }
    }

    @Test func fastEncodingRoundTripsAndDefaultsOff() throws {
        #expect(ExportSettings().fastEncoding == false)
        var e = ExportSettings(); e.fastEncoding = true
        let back = try JSONDecoder().decode(ExportSettings.self, from: JSONEncoder().encode(e))
        #expect(back.fastEncoding)
        let old = #"{"codec":"h264","preferHardware":true}"#.data(using: .utf8)!
        #expect(try JSONDecoder().decode(ExportSettings.self, from: old).fastEncoding == false)
    }
}
