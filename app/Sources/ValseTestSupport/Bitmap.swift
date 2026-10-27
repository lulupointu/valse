import CoreGraphics
import Foundation
import ImageIO
import ValseCore

/// RGBA8 copy of a rendered frame with convenient pixel access for asserts.
public struct Bitmap: Sendable {
    public let width: Int
    public let height: Int
    /// RGBA, row-major, top row first.
    public let pixels: [UInt8]

    public init(_ image: CGImage) {
        width = image.width; height = image.height
        var buf = [UInt8](repeating: 0, count: width * height * 4)
        // Draw in the image's own colour space: we assert on encoded values, without colour management.
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: &buf, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        pixels = buf
    }

    /// Pixel at integer coordinates.
    public func pixel(_ x: Int, _ y: Int) -> RGBA {
        let i = (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 4
        return RGBA(Double(pixels[i]) / 255, Double(pixels[i + 1]) / 255, Double(pixels[i + 2]) / 255, Double(pixels[i + 3]) / 255)
    }

    /// Pixel at normalized coordinates (0…1, y down): `img[0.5, 0.5]` is the centre.
    public subscript(_ x: Double, _ y: Double) -> RGBA {
        pixel(Int(x * Double(width - 1)), Int(y * Double(height - 1)))
    }

    /// Mean colour of a normalized rect (robust to codec noise).
    public func average(x: Double, y: Double, w: Double, h: Double) -> RGBA {
        let x0 = Int(x * Double(width)), x1 = max(x0 + 1, Int((x + w) * Double(width)))
        let y0 = Int(y * Double(height)), y1 = max(y0 + 1, Int((y + h) * Double(height)))
        var r = 0.0, g = 0.0, b = 0.0, n = 0.0
        for yy in y0..<min(y1, height) { for xx in x0..<min(x1, width) { let p = pixel(xx, yy); r += p.r; g += p.g; b += p.b; n += 1 } }
        return RGBA(r / n, g / n, b / n)
    }

    /// Writes a PNG (debugging failing render tests).
    public func writePNG(_ url: URL) {
        var copy = pixels
        let ctx = CGContext(data: &copy, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        guard let img = ctx.makeImage(), let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(d, img, nil)
        CGImageDestinationFinalize(d)
    }
}

extension RGBA {
    /// Component-wise closeness (default tolerance absorbs YUV 4:2:0 + H.264 error).
    public func isClose(to o: RGBA, tolerance: Double = 0.08) -> Bool {
        abs(r - o.r) <= tolerance && abs(g - o.g) <= tolerance && abs(b - o.b) <= tolerance
    }
    public var luma: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
}
