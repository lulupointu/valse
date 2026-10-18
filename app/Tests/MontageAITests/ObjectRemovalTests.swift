import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MontageAI
import MontageCore
import MontageEngine
import MontageTestSupport

/// AI remove (AI-041): LaMa removes a brushed object from an image and from a short video.
@Suite(.serialized) struct ObjectRemovalTests {
    /// Sky-blue gradient with a red square at x 0.4…0.55, y 0.35…0.6.
    static func scene(_ w: Int = 640, _ h: Int = 360) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [CGColor(red: 0.3, green: 0.55, blue: 0.9, alpha: 1),
                                                                                        CGColor(red: 0.6, green: 0.8, blue: 0.95, alpha: 1)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: h), options: [])
        ctx.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: Double(w) * 0.4, y: Double(h) * 0.4, width: Double(w) * 0.15, height: Double(h) * 0.25))
        return ctx.makeImage()!
    }

    static let strokes = [RemovalStroke(points: [Vec2(0.43, 0.48), Vec2(0.52, 0.48), Vec2(0.52, 0.55), Vec2(0.43, 0.55)], radius: 0.06)]

    @Test func removesTheBrushedObjectFromAnImage() async throws {
        try await HeavyWorkGate.run {
            guard LaMaInpainter.isAvailable else { print("skip: LaMa model not installed"); return }
            let url = TestMedia.directory.appendingPathComponent("remove-scene-v1.png")
            let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dst, Self.scene(), nil); CGImageDestinationFinalize(dst)
            var p = TestProject(canvas: Size2(640, 360))
            let id = try await p.addMedia(url)
            let before = try await p.render(at: 0.5)[0.475, 0.5]
            #expect(before.r > 0.7 && before.b < 0.3)
            let clock = ContinuousClock(), t0 = clock.now
            let cmd = try await ObjectRemovalJob.run(project: p.project, clipID: id, strokes: Self.strokes)
            print("metric lama_image_seconds=\(clock.now - t0)")
            try cmd.apply(to: &p.project)
            let after = try await p.render(at: 0.5)[0.475, 0.5]
            print("metric lama_removed=\(after)")
            #expect(after.r < 0.6 && after.b > 0.6, "red square gone: \(after)")
            #expect(p[id].removal != nil)
            let back = try await ObjectRemovalJob.run(project: p.project, clipID: id, strokes: [])
            try back.apply(to: &p.project)
            #expect(p[id].removal == nil && p[id].mediaID == p.project.media[0].id)
        }
    }
}
