import Testing
import Foundation
import CoreGraphics
import MontageCore
import MontageEffects
import MontageEngine
import MontageTestSupport

/// Relight (AI-024 / CL-020) through the real compositor: lights, directional light, People target via the person
/// matte, relief from the depth matte. Preview and export share this compositor.
@Suite(.serialized) struct RelightRenderTests {
    static let grey = RGBA(0.41, 0.42, 0.43)   // unique media (MatteStore caches by content hash)

    static func clearMattes(_ a: MediaAsset) {
        for k in [RelightOps.depthKind, RelightOps.personKind] {
            try? FileManager.default.removeItem(at: MatteStore.shared.matteVideoURL(media: a, kind: k))
        }
    }

    static func image(width: Int, height: Int, _ fill: (Int, Int) -> UInt8) -> CGImage {
        var b = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width { b[y * width + x] = fill(x, y) } }
        let ctx = CGContext(data: &b, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        return ctx.makeImage()!
    }

    static func writeMatte(_ a: MediaAsset, kind: String, _ img: CGImage) async throws {
        let w = try MatteVideoWriter(media: a, kind: kind, size: CGSize(width: img.width, height: img.height))
        for f in 0..<30 { try await w.append(img, at: FrameRate.fps30.time(ofFrame: Int64(f))) }
        try await w.finish()
    }

    @Test func pointLightOnTheLeftBrightensTheLeft() async throws {
        var p = TestProject()
        let id = try await p.addVideo(.solid(Self.grey), seconds: 1)
        Self.clearMattes(p.project.media[0])
        let raw = try await p.render(at: 0.5)
        var s = RelightSettings(preset: .custom, target: .both,
                                lights: [RelightLight(kind: .point, x: 0.15, y: 0.5, color: .white, intensity: 0.8, radius: 0.35)],
                                ambientDarkening: 0.4)
        p[id].relight = s
        let lit = try await p.render(at: 0.5)
        #expect(lit[0.15, 0.5].luma > raw[0.15, 0.5].luma + 0.08, "\(lit[0.15, 0.5]) vs \(raw[0.15, 0.5])")
        #expect(lit[0.15, 0.5].luma > lit[0.85, 0.5].luma + 0.15)
        #expect(lit[0.85, 0.5].luma < raw[0.85, 0.5].luma)          // ambient darkening away from the light
        // coloured light tints the lit area
        s.lights[0].color = RGBA(1, 0.2, 0.2)
        p[id].relight = s
        let red = try await p.render(at: 0.5)[0.15, 0.5]
        #expect(red.r > red.b + 0.1)
    }

    @Test func directionalLightLightsTheSideItComesFrom() async throws {
        var p = TestProject()
        let id = try await p.addVideo(.solid(Self.grey), seconds: 1)
        Self.clearMattes(p.project.media[0])
        p[id].relight = RelightSettings(preset: .custom, target: .both,
                                        lights: [RelightLight(kind: .directional, x: 1, y: 0.5, color: .white, intensity: 0.7)])
        let img = try await p.render(at: 0.5)
        #expect(img[0.9, 0.5].luma > img[0.1, 0.5].luma + 0.05, "\(img[0.9, 0.5]) \(img[0.1, 0.5])")
    }

    @Test func peopleTargetOnlyLightsThePersonMatte() async throws {
        var p = TestProject()
        let id = try await p.addVideo(.solid(Self.grey), seconds: 1)
        let a = p.project.media[0]
        Self.clearMattes(a)
        try await Self.writeMatte(a, kind: RelightOps.personKind, Self.image(width: 160, height: 90) { x, _ in x < 80 ? 255 : 0 })
        let raw = try await p.render(at: 0.5)
        p[id].relight = RelightSettings(preset: .custom, target: .people,
                                        lights: [RelightLight(kind: .directional, x: 0.5, y: 0.5, color: .white, intensity: 1)],
                                        ambientDarkening: 0)
        let lit = try await p.render(at: 0.5)
        #expect(lit[0.25, 0.5].luma > raw[0.25, 0.5].luma + 0.1, "person lit")
        #expect(abs(lit[0.75, 0.5].luma - raw[0.75, 0.5].luma) < 0.03, "background untouched")
        p[id].relight?.target = .background
        let bg = try await p.render(at: 0.5)
        #expect(abs(bg[0.25, 0.5].luma - raw[0.25, 0.5].luma) < 0.03)
        #expect(bg[0.75, 0.5].luma > raw[0.75, 0.5].luma + 0.1)
        Self.clearMattes(a)
    }

    @Test func depthReliefShadesSlopesFacingAwayFromTheLight() async throws {
        var p = TestProject()
        let id = try await p.addVideo(.solid(Self.grey), seconds: 1)
        let a = p.project.media[0]
        Self.clearMattes(a)
        let light = RelightLight(kind: .directional, x: 0, y: 0.5, color: .white, intensity: 0.8, distance: 0.1)
        p[id].relight = RelightSettings(preset: .custom, target: .both, lights: [light], ambientDarkening: 0, relief: 1)
        let flat = try await p.render(at: 0.5)
        // a ridge: depth rises to the centre then falls → left half faces the light (left), right half faces away
        try await Self.writeMatte(a, kind: RelightOps.depthKind, Self.image(width: 160, height: 90) { x, _ in
            UInt8(255 - abs(x - 80) * 3)
        })
        p[id].relight = RelightSettings(preset: .custom, target: .both, lights: [light], ambientDarkening: 0, relief: 1)
        let relief = try await p.render(at: 0.5)
        let dl = relief[0.3, 0.5].luma - flat[0.3, 0.5].luma, dr = relief[0.7, 0.5].luma - flat[0.7, 0.5].luma
        #expect(dl > dr + 0.05, "towards light \(dl), away \(dr)")
        Self.clearMattes(a)
    }
}
