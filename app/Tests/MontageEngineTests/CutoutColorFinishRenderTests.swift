import Testing
import Foundation
import CoreGraphics
@testable import MontageCore
@testable import MontageEngine
import MontageEffects
import MontageTestSupport

/// Finisher P1 render rows: skin tone protection (CL-010), cutout stroke (CK-005), matting blend (CK-008).
@Suite(.serialized) struct CutoutColorFinishRenderTests {
    /// Opaque left half with a soft edge (linear ramp of `ramp` px centred on the middle), like an upscaled AI matte.
    static func softHalfMatte(width: Int, height: Int, ramp: Int) -> CGImage {
        var px = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width {
            let t = Double(x - (width / 2 - ramp / 2)) / Double(ramp)
            px[y * width + x] = UInt8(255 * min(max(1 - t, 0), 1))
        } }
        let ctx = CGContext(data: &px, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        return ctx.makeImage()!
    }

    @Test func skinToneProtectionHoldsTheGradeBackOnSkinOnly() async throws {
        let skin = RGBA(0.87, 0.67, 0.55), sky = RGBA(0.2, 0.5, 0.9)
        var p = TestProject(background: .black)
        let id = try await p.addVideo(.split(skin, sky))
        var grade = Registries.effects["montage.adjust.basic"]!.makeInstance()
        grade.params["saturation"] = .scalar(-1)            // full desaturation
        p[id].effects = [grade]
        let graded = try await p.render(at: 0.5)
        p[id].skinToneProtection = true
        let protected = try await p.render(at: 0.5)
        func chroma(_ c: RGBA) -> Double { max(c.r, c.g, c.b) - min(c.r, c.g, c.b) }
        #expect(chroma(graded[0.25, 0.5]) < 0.05)                                  // grade applies everywhere…
        #expect(chroma(protected[0.25, 0.5]) > 0.2, "\(protected[0.25, 0.5])")     // …but skin keeps its colour
        #expect(chroma(protected[0.75, 0.5]) < 0.05, "\(protected[0.75, 0.5])")    // the sky is still graded
    }

    @Test func cutoutStrokeOutlinesTheKeyedSubject() async throws {
        var p = TestProject(background: .blue)
        try await p.addVideo(.solid(.blue))
        let o = try await p.addVideo(.split(.red, RGBA(0, 1, 0)), target: .newTrack)
        var key = BuiltinKeying.chromaKey.makeInstance()
        key.params["color"] = .color(RGBA(0, 1, 0, 1))
        var stroke = BuiltinCutoutStroke.stroke.makeInstance()
        stroke.params["color"] = .color(RGBA(1, 1, 0, 1))
        stroke.params["size"] = .scalar(0.6)
        p[o].effects = [key, stroke]
        let img = try await p.render(at: 0.5)
        #expect(img[0.25, 0.5].isClose(to: .red))                                    // subject untouched
        #expect(img[0.9, 0.5].isClose(to: .blue))                                    // far background keyed out
        let edge = (0..<20).map { img[0.5 + Double($0) * 0.004, 0.5] }               // just right of the subject
        #expect(edge.contains { $0.r > 0.8 && $0.g > 0.8 && $0.b < 0.3 }, "\(edge)")  // yellow stroke
        p[o].effects = [key]
        let plain = try await p.render(at: 0.5)
        #expect(!(0..<20).map { plain[0.5 + Double($0) * 0.004, 0.5] }.contains { $0.r > 0.8 && $0.g > 0.8 })
    }

    @Test func mattingBlendRemovesTheBackgroundFringe() async throws {
        var p = TestProject(background: .blue)
        let id = try await p.addImage(.split(.red, RGBA(0, 1, 0)), size: CGSize(width: 320, height: 180))
        let asset = p.project.media[0]
        MatteStore.shared.setStill(Self.softHalfMatte(width: 320, height: 180, ramp: 8), media: asset, kind: "fin-blend")
        p[id].matte = ClipMatte(kind: "fin-blend")
        func fringe(_ b: Bitmap) -> Double { (0..<40).map { b[0.46 + Double($0) * 0.0025, 0.5].g }.max() ?? 0 }
        let raw = try await p.render(at: 0.5)
        #expect(fringe(raw) > 0.15, "soft matte edge shows the green background: \(fringe(raw))")
        p[id].matte?.edgeBlend = 1
        let blended = try await p.render(at: 0.5)
        #expect(fringe(blended) < fringe(raw) * 0.5, "\(fringe(raw)) → \(fringe(blended))")
        #expect(blended[0.25, 0.5].isClose(to: .red) && blended[0.8, 0.5].isClose(to: .blue))
    }
}
