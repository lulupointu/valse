import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ValseCore
@testable import ValseEngine
import ValseEffects
import ValseTestSupport

/// ST-003: custom stickers (still, animated GIF / APNG, frame sequence) imported into `UserStickerLibrary` render as
/// sticker layers, timed from the clip start.
@Suite(.serialized) struct UserStickerRenderTests {
    static let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fin-stickers-\(UUID().uuidString)")

    static func solid(_ c: RGBA, w: Int = 64, h: Int = 64) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    static func write(_ frames: [CGImage], type: UTType, name: String, delay: Double = 0.5) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        let d = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, frames.count, nil)!
        for f in frames {
            let props: [CFString: Any] = type == .gif ? [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]]
                : [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: delay]]
            CGImageDestinationAddImage(d, f, frames.count > 1 ? props as CFDictionary : nil)
        }
        #expect(CGImageDestinationFinalize(d))
        return url
    }

    func render(_ id: String, at t: Double) async throws -> RGBA {
        var p = TestProject(canvas: Size2(320, 180), background: .black)
        let c = Clip(content: .sticker(id: id), start: 0, duration: 4)
        try TimelineOps.insert(c, into: &p.project)
        return try await p.render(at: t)[0.5, 0.5]
    }

    @Test func importedStickersRenderAndAnimate() async throws {
        let lib = UserStickerLibrary(directory: Self.dir.appendingPathComponent("lib"))
        UserStickerLibrary.shared = lib
        // still PNG, wide: aspect-fitted in the sticker box
        let still = try lib.importFiles([try Self.write([Self.solid(.red, w: 128, h: 64)], type: .png, name: "red.png")])[0]
        #expect(Registries.stickers[still]?.groupKey == UserStickerLibrary.groupKey)
        #expect(try await render(still, at: 0.5).isClose(to: .red, tolerance: 0.08))
        #expect(lib.size(still, side: 100) == Size2(100, 50))
        // animated GIF: red 0.5 s, then green 0.5 s, looping
        let gif = try lib.importFiles([try Self.write([Self.solid(.red), Self.solid(RGBA(0, 1, 0))], type: .gif, name: "anim.gif")])[0]
        #expect(lib.entry(gif)?.kind == .animated)
        #expect(try await render(gif, at: 0.25).r > 0.8)
        #expect(try await render(gif, at: 0.75).g > 0.8)
        #expect(try await render(gif, at: 1.25).r > 0.8)          // looped
        // frame sequence: 3 PNGs at 2 fps, played once → holds the last frame
        let frames = try [RGBA.red, RGBA(0, 1, 0), RGBA.blue].enumerated().map { i, c in try Self.write([Self.solid(c)], type: .png, name: "f\(i).png") }
        let seq = try lib.importSequence(frames.reversed(), fps: 2, loops: false)   // sorted by name on import
        #expect(lib.entry(seq)?.files.count == 3)
        #expect(try await render(seq, at: 0.2).r > 0.8)
        #expect(try await render(seq, at: 0.7).g > 0.8)
        #expect(try await render(seq, at: 1.2).b > 0.8)
        #expect(try await render(seq, at: 3.0).b > 0.8)            // once: last frame held
        #expect(throws: UserStickerLibrary.ImportError.self) { try lib.importSequence(Array(frames.prefix(2)), fps: 2, loops: true) }
        // persisted: a fresh library over the same folder sees the same stickers
        let again = UserStickerLibrary(directory: lib.directory)
        again.loadAll()
        #expect(Set(again.all.map(\.id)) == [still, gif, seq])
        lib.remove(gif)
        #expect(lib.entry(gif) == nil && !FileManager.default.fileExists(atPath: lib.folder(gif).path))
    }
}
