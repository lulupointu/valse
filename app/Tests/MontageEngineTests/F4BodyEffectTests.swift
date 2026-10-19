import Testing
import Foundation
import CoreGraphics
@testable import MontageCore
@testable import MontageEngine
import MontageEffects
import MontageTestSupport

/// F4-FX: body effects on plain media through a body-effects-only person matte (FX-002) and Magic cutout (FX-008).
@Suite(.serialized) struct F4BodyEffectTests {
    /// Opaque left half (the "person"), hard edge.
    static func halfMatte(width: Int, height: Int) -> CGImage {
        var px = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<(width / 2) { px[y * width + x] = 255 } }
        let ctx = CGContext(data: &px, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        return ctx.makeImage()!
    }

    /// A red (left) / green (right) photo with a body-only matte of kind `kind`; `ready` = the matte exists.
    static func scene(effect: String, kind: String, ready: Bool) async throws -> TestProject {
        var p = TestProject(canvas: Size2(320, 180), background: .blue)
        let id = try await p.addImage(.split(.red, RGBA(0, 1, 0)), size: CGSize(width: 320, height: 180))
        if ready { MatteStore.shared.setStill(halfMatte(width: 320, height: 180), media: p.project.media[0], kind: kind) }
        var fx = Registries.effects[effect]!.makeInstance()
        if effect.hasSuffix(".outline") { fx.params["size"] = .scalar(1) }
        p[id].effects = [fx]
        p[id].matte = ClipMatte(kind: kind, bodyOnly: true)
        return p
    }

    static func kind(_ s: String) -> String { "f4-\(s)-\(UUID().uuidString.prefix(6))" }

    @Test func outlineGoesAroundThePersonAndTheFrameStaysUncut() async throws {
        let img = try await Self.scene(effect: "montage.effect.outline", kind: Self.kind("body"), ready: true).render(at: 0.5)
        #expect(img[0.25, 0.5].isClose(to: .red), "person untouched: \(img[0.25, 0.5])")
        #expect(img[0.9, 0.5].isClose(to: RGBA(0, 1, 0)), "background NOT cut out: \(img[0.9, 0.5])")
        // just right of the person edge: the (white by default) stroke over the green background
        let edge = (0..<16).map { img[0.5 + Double($0) * 0.003, 0.5] }
        #expect(edge.contains { $0.r > 0.8 && $0.g > 0.8 && $0.b > 0.8 }, "\(edge)")
    }

    @Test func withoutTheMatteTheBodyEffectWaits() async throws {
        let img = try await Self.scene(effect: "montage.effect.outline", kind: Self.kind("missing"), ready: false).render(at: 0.5)
        #expect(img[0.25, 0.5].isClose(to: .red) && img[0.9, 0.5].isClose(to: RGBA(0, 1, 0)))
        let edge = (0..<16).map { img[0.5 + Double($0) * 0.003, 0.5] }
        #expect(!edge.contains { $0.r > 0.8 && $0.g > 0.8 && $0.b > 0.8 }, "\(edge)")
        #expect(img[0.01, 0.5].isClose(to: .red))
    }

    @Test func magicSpotlightKeepsThePersonInColourOverAGreyBackground() async throws {
        let img = try await Self.scene(effect: "montage.effect.magicSpotlight", kind: Self.kind("spot"), ready: true).render(at: 0.5)
        let person = img[0.2, 0.5], back = img[0.85, 0.5]
        #expect(person.isClose(to: .red, tolerance: 0.08), "person in colour: \(person)")
        func chroma(_ c: RGBA) -> Double { max(c.r, c.g, c.b) - min(c.r, c.g, c.b) }
        #expect(chroma(back) < 0.06, "background desaturated: \(back)")
        #expect(back.g < 0.7, "background darkened: \(back)")
    }

    @Test func magicCutoutDarkensTheBackground() async throws {
        let img = try await Self.scene(effect: "montage.effect.magicCutout", kind: Self.kind("magic"), ready: true).render(at: 0.5)
        #expect(img[0.2, 0.5].r > 0.85 && img[0.2, 0.5].g < 0.15, "\(img[0.2, 0.5])")
        #expect(img[0.85, 0.5].g < 0.6 && img[0.85, 0.5].g > 0.1, "\(img[0.85, 0.5])")
    }

    @Test func magicEffectsAreBodyEffectsInTheLibrary() {
        for n in ["magicCutout", "magicSpotlight", "magicColorPop"] {
            let d = Registries.effects["montage.effect.\(n)"]
            #expect(d?.groupKey == "effect.group.body")
            #expect(d?.inputs == [.backdrop, .original])
        }
    }
}
