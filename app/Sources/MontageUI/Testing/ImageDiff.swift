import Foundation
import CoreGraphics
import ImageIO

/// Screenshot comparison with tolerance (UI test baselines in app/Tests/Baselines, `Montage --imgdiff`).
///
/// A pixel "differs" when any RGB channel differs by more than `threshold` (0–255). The images match when the
/// fraction of differing pixels is ≤ `tolerance`. Sizes must be equal. `diffImage` paints differing pixels red over a
/// dimmed grey copy of the baseline.
nonisolated public struct ImageDiff: Sendable {
    nonisolated public struct Result: Sendable, Codable {
        public var width: Int
        public var height: Int
        public var differingPixels: Int
        public var fraction: Double
        public var maxChannelDelta: Int
        public var meanChannelDelta: Double
        public var sizeMismatch: Bool
        public var passed: Bool
    }

    public var threshold: Int
    public var tolerance: Double
    public init(threshold: Int = 16, tolerance: Double = 0.005) { self.threshold = threshold; self.tolerance = tolerance }

    /// RGBA8 pixels of an image (sRGB).
    nonisolated public struct Pixels: Sendable {
        public let width: Int, height: Int
        public var data: [UInt8]
        public init(width: Int, height: Int, data: [UInt8]) { self.width = width; self.height = height; self.data = data }
        public init?(_ image: CGImage) {
            let w = image.width, h = image.height; width = w; height = h
            var d = [UInt8](repeating: 0, count: w * h * 4)
            let ok = d.withUnsafeMutableBytes { buf -> Bool in
                guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard ok else { return nil }
            data = d
        }
        public var cgImage: CGImage? {
            guard let provider = CGDataProvider(data: Data(data) as CFData) else { return nil }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
    }

    public func compare(_ a: Pixels, _ b: Pixels) -> (Result, diff: Pixels?) {
        guard a.width == b.width, a.height == b.height else {
            return (Result(width: a.width, height: a.height, differingPixels: max(a.width * a.height, b.width * b.height), fraction: 1,
                           maxChannelDelta: 255, meanChannelDelta: 255, sizeMismatch: true, passed: false), nil)
        }
        let n = a.width * a.height
        var out = [UInt8](repeating: 255, count: n * 4)
        var differing = 0, maxD = 0
        var sum = 0
        a.data.withUnsafeBufferPointer { pa in
            b.data.withUnsafeBufferPointer { pb in
                for i in 0..<n {
                    let o = i * 4
                    let d = max(abs(Int(pa[o]) - Int(pb[o])), abs(Int(pa[o + 1]) - Int(pb[o + 1])), abs(Int(pa[o + 2]) - Int(pb[o + 2])))
                    sum += d
                    if d > maxD { maxD = d }
                    if d > threshold {
                        differing += 1
                        out[o] = 255; out[o + 1] = 0; out[o + 2] = 0
                    } else {
                        let g = UInt8((Int(pb[o]) + Int(pb[o + 1]) + Int(pb[o + 2])) / 9)  // dimmed grey baseline
                        out[o] = g; out[o + 1] = g; out[o + 2] = g
                    }
                }
            }
        }
        let fraction = n == 0 ? 0 : Double(differing) / Double(n)
        let r = Result(width: a.width, height: a.height, differingPixels: differing, fraction: fraction, maxChannelDelta: maxD,
                       meanChannelDelta: n == 0 ? 0 : Double(sum) / Double(n), sizeMismatch: false, passed: fraction <= tolerance)
        return (r, Pixels(width: a.width, height: a.height, data: out))
    }

    /// Compares two PNG files; writes the diff image to `diffURL` when given and the images differ.
    public func compare(_ a: URL, _ b: URL, diffURL: URL? = nil) -> Result? {
        guard let ia = Self.load(a).flatMap(Pixels.init), let ib = Self.load(b).flatMap(Pixels.init) else { return nil }
        let (r, d) = compare(ia, ib)
        if let diffURL, !r.passed, let img = d?.cgImage { _ = Self.writePNG(img, to: diffURL) }
        return r
    }

    public static func load(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    @discardableResult
    public static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(d, image, nil)
        return CGImageDestinationFinalize(d)
    }
}
