import CoreGraphics
import Foundation
import ImageIO
import Testing
import MontageCore
import MontageEngine
import MontageTestSupport

/// BUG-SDR-IN-HDR "the SDR clip also looks lower quality": a 464 × 832 phone clip on a 1080 × 1920 canvas is magnified
/// ×2.3 by the placement pass. Bilinear (the old sampler) loses ≈ 1.3 dB PSNR against bicubic / Lanczos on natural
/// frames (ffmpeg on the owner's clip: bilinear 30.3 dB SSIM 0.916, bicubic 31.5 dB 0.938, Lanczos 31.9 dB 0.942).
/// Magnified layers are now sampled with Catmull-Rom (`sample_layer` in CoreShaders); ≤ 1:1 stays bilinear.
@Suite struct LayerUpscaleQualityTests {
    /// Small image 128 × 80 (a multiple of 16: the layer texture is exactly the source, no pool-size resample).
    static let big = (512, 320), factor = 4

    /// Ground truth: smooth shading + fine detail + hard edges (like a face, foliage and a window frame).
    static func truth(_ x: Int, _ y: Int) -> Double {
        let fx = Double(x), fy = Double(y)
        var v = 0.45 + 0.25 * sin(fx * 0.045) * cos(fy * 0.06) + 0.12 * sin((fx + fy) * 0.35)
        if x > 300 && x < 420 && y > 60 && y < 200 { v = 0.92 }       // window
        if (x / 24 + y / 24) % 2 == 0 && x < 140 && y > 150 { v -= 0.2 }  // tiles
        return min(max(v, 0), 1)
    }

    static func small() throws -> URL {
        try TestMedia.cachedSync(TestMedia.directory.appendingPathComponent("upscale-truth-v2.png")) { url in
            let (w, h) = (big.0 / factor, big.1 / factor)
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            let p = ctx.data!.assumingMemoryBound(to: UInt8.self), bpr = ctx.bytesPerRow
            for y in 0..<h { for x in 0..<w {
                var s = 0.0
                for dy in 0..<factor { for dx in 0..<factor { s += truth(x * factor + dx, y * factor + dy) } }
                let v = UInt8((s / Double(factor * factor) * 255).rounded())
                for c in 0..<3 { p[y * bpr + x * 4 + c] = v }; p[y * bpr + x * 4 + 3] = 255
            } }
            let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(d, ctx.makeImage()!, nil)
            CGImageDestinationFinalize(d)
        }
    }

    static func psnr(_ f: (Int, Int) -> Double) -> Double {
        var se = 0.0, n = 0.0
        // inner area (edge clamping differs between samplers)
        for y in 8..<(big.1 - 8) { for x in 8..<(big.0 - 8) { let d = f(x, y) - truth(x, y); se += d * d; n += 1 } }
        return 10 * log10(1 / (se / n))
    }

    @Test func magnifiedLayersAreSharperThanBilinear() async throws {
        let url = try Self.small()
        var p = TestProject(canvas: Size2(Double(Self.big.0), Double(Self.big.1)))
        try await p.addMedia(url, duration: Time(1))
        let img = try await p.render(at: 0.5)
        #expect(img.width == Self.big.0 && img.height == Self.big.1)
        let ours = Self.psnr { x, y in img.pixel(x, y).g }
        // CPU bilinear of the same small image (what the old sampler did)
        let (w, h) = (Self.big.0 / Self.factor, Self.big.1 / Self.factor)
        let src = Bitmap(CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!)
        func s(_ x: Int, _ y: Int) -> Double { src.pixel(min(max(x, 0), w - 1), min(max(y, 0), h - 1)).g }
        let bilinear = Self.psnr { x, y in
            let u = (Double(x) + 0.5) / Double(Self.factor) - 0.5, v = (Double(y) + 0.5) / Double(Self.factor) - 0.5
            let x0 = Int(floor(u)), y0 = Int(floor(v)), fx = u - floor(u), fy = v - floor(v)
            return (s(x0, y0) * (1 - fx) + s(x0 + 1, y0) * fx) * (1 - fy) + (s(x0, y0 + 1) * (1 - fx) + s(x0 + 1, y0 + 1) * fx) * fy
        }
        print("upscale ×\(Self.factor): ours \(ours) dB, bilinear \(bilinear) dB")
        #expect(ours > bilinear + 0.5, "magnified layer: \(ours) dB vs bilinear \(bilinear) dB")
    }

    /// A source shown at 1:1 whose size is not a multiple of 16 (1080-wide footage, here 120 × 68) is not resampled:
    /// the layer texture used to be rounded up (120 → 128, 1080 → 1088) and the frame stretched there and back.
    @Test func sourceSizedLayersAreNotResampled() async throws {
        let url = try TestMedia.cachedSync(TestMedia.directory.appendingPathComponent("upscale-truth-120x68-v1.png")) { url in
            let (w, h) = (120, 68)
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            let p = ctx.data!.assumingMemoryBound(to: UInt8.self), bpr = ctx.bytesPerRow
            for y in 0..<h { for x in 0..<w {
                let v = UInt8((Self.truth(x * 4, y * 4) * 255).rounded())
                for c in 0..<3 { p[y * bpr + x * 4 + c] = v }; p[y * bpr + x * 4 + 3] = 255
            } }
            let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(d, ctx.makeImage()!, nil)
            CGImageDestinationFinalize(d)
        }
        var p = TestProject(canvas: Size2(120, 68))
        try await p.addMedia(url, duration: Time(1))
        let img = try await p.render(at: 0.5)
        let src = Bitmap(CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!)
        var worst = 0.0, se = 0.0
        for y in 0..<68 { for x in 0..<120 { let d = abs(img.pixel(x, y).g - src.pixel(x, y).g); worst = max(worst, d); se += d * d } }
        print("1:1 layer: max |Δ| \(worst), PSNR \(10 * log10(1 / (se / (120 * 68)))) dB")
        #expect(worst <= 2.0 / 255, "1:1 layer resampled: max |Δ| \(worst)")
    }
}
