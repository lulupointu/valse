import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Testing
import MontageCore
@testable import MontageAI

/// F4 CL-028: ColorChecker detection → 3 × 3 correction → look LUT.
@Suite struct ColorCardTests {
    /// A tungsten-ish cast (linear light): red up, blue down, a bit of crosstalk.
    static let cast: [Double] = [1.25, 0.08, 0.0, 0.02, 0.95, 0.03, 0.0, 0.06, 0.62]

    static func castColour(_ c: SIMD3<Double>) -> SIMD3<Double> { ColorCard.apply(cast, c) }

    /// Synthetic frame: grey background, black chart frame, 24 cast patches (6 × 4) with gaps; `flipped` turns it 180°.
    static func chartImage(flipped: Bool = false, width: Int = 960, height: Int = 540) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.42, green: 0.40, blue: 0.37, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let chart = CGRect(x: 280, y: 140, width: 390, height: 262)
        ctx.setFillColor(CGColor(srgbRed: 0.05, green: 0.05, blue: 0.05, alpha: 1)); ctx.fill(chart)
        let inset = 10.0, cw = (chart.width - 2 * inset) / 6, ch = (chart.height - 2 * inset) / 4
        for i in 0..<24 {
            let idx = flipped ? 23 - i : i
            let row = i / 6, col = i % 6
            let c = castColour(ColorCard.reference[idx])
            ctx.setFillColor(CGColor(srgbRed: c.x, green: c.y, blue: c.z, alpha: 1))
            // CG origin bottom-left: row 0 at the top
            let x = chart.minX + inset + Double(col) * cw + 4, y = chart.maxY - inset - Double(row + 1) * ch + 4
            ctx.fill(CGRect(x: x, y: y, width: cw - 8, height: ch - 8))
        }
        return ctx.makeImage()!
    }

    @Test func solveInvertsAKnownCast() {
        let measured = ColorCard.reference.map(Self.castColour)
        let m = ColorCard.solve(measured: measured)
        let corrected = measured.map { ColorCard.apply(m, $0) }
        // a few patches clip in the cast; everything else comes back within ~2 levels
        #expect(ColorCard.rms(corrected, ColorCard.reference) < 0.02)
        #expect(ColorCard.rms(measured, ColorCard.reference) > 0.05)
    }

    @Test(arguments: [false, true])
    func detectsTheChartAndCorrectsIt(flipped: Bool) throws {
        let d = try #require(ColorCard.detect(in: Self.chartImage(flipped: flipped)))
        #expect(d.before > 0.05)
        #expect(d.residual < 0.025, "residual \(d.residual)")
        // the first corner is the dark-skin patch (top-left normally, bottom-right when the chart is upside down)
        #expect(flipped ? d.corners[0].x > 0.5 : d.corners[0].x < 0.5)
        // the baked LUT maps the cast colours to the reference
        let lut = ColorCard.lut(d.matrix)
        var err = 0.0
        for (r, c) in zip(ColorCard.reference, ColorCard.reference.map(Self.castColour)) {
            let o = lut.apply(SIMD3<Float>(Float(c.x), Float(c.y), Float(c.z)))
            err += abs(Double(o.x) - r.x) + abs(Double(o.y) - r.y) + abs(Double(o.z) - r.z)
        }
        #expect(err / 72 < 0.03, "mean LUT error \(err / 72)")
    }

    @Test func noChartNoDetection() {
        let ctx = CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [CGColor(srgbRed: 0.1, green: 0.3, blue: 0.8, alpha: 1), CGColor(srgbRed: 0.9, green: 0.6, blue: 0.2, alpha: 1)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 640, y: 360), options: [])
        ctx.setFillColor(CGColor(gray: 0.1, alpha: 1)); ctx.fill(CGRect(x: 200, y: 100, width: 240, height: 160))
        #expect(ColorCard.detect(in: ctx.makeImage()!) == nil)
    }

    /// `MONTAGE_WRITE_COLORCARD_FIXTURE=<path>` writes the synthetic chart PNG used by the UI script.
    @Test func writeFixtureWhenAsked() throws {
        guard let p = ProcessInfo.processInfo.environment["MONTAGE_WRITE_COLORCARD_FIXTURE"] else { return }
        let d = try #require(CGImageDestinationCreateWithURL(URL(fileURLWithPath: p) as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(d, Self.chartImage(width: 960, height: 540), nil)
        #expect(CGImageDestinationFinalize(d))
    }
}
