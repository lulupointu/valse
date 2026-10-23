import Testing
import Foundation
import CoreGraphics
@testable import MontageEngine
import MontageCore
import MontageTestSupport

/// FLAKY-THUMB: a thumbnail has the same pixels whether it was just generated or read back from the disk cache, and
/// the last quantum of a video (a filmstrip tile at the clip end) yields a frame instead of failing on every redraw.
@Suite struct ThumbnailDeterminismTests {
    static func pixels(_ img: CGImage) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let ctx = CGContext(data: &buf, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return buf
    }

    @Test func generatedThumbnailEqualsDiskCopy() async throws {
        // sharp colour edge: where JPEG round-trips differed from the raw decoded frame
        let a = try await MediaProbe.probe(try await TestMedia.video(.split(RGBA(hex: 0x8E44AD), RGBA(hex: 0x57BECB)), seconds: 2))
        let first = ThumbnailCache()
        let generated = try #require(await first.thumbnail(a, at: Time(0.4), height: 72))
        let second = ThumbnailCache()   // empty memory, same disk folder: loads the JPEG written by `first`
        let fromDisk = try #require(await second.thumbnail(a, at: Time(0.4), height: 72))
        #expect(generated !== fromDisk)
        #expect(generated.width == fromDisk.width && generated.height == fromDisk.height)
        #expect(Self.pixels(generated) == Self.pixels(fromDisk))
        #expect(generated.bitsPerComponent == 8 && generated.alphaInfo == .noneSkipLast)
    }

    @Test func lastQuantumOfAVideoHasAFrame() async throws {
        let a = try await MediaProbe.probe(try await TestMedia.video(.movingBox(.red, .white), seconds: 2))
        let cache = ThumbnailCache()
        // t = duration: the quantum [2.0, 2.25) holds no frame (the old tolerance window failed here every time)
        let end = try #require(await cache.thumbnail(a, at: a.duration, height: 48))
        #expect(end.height == 48)
        #expect(cache.cached(a, at: a.duration, height: 48) != nil)
    }
}
