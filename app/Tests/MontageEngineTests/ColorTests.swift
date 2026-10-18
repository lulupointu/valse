import Testing
import Foundation
import simd
import MontageCore
import MontageEffects
import MontageEngine
import MontageTestSupport

/// Colour pipeline render tests: LUTs (3D textures), HSL, curves, colour wheels, white balance.
@Suite(.serialized) struct ColorTests {
    func render(_ color: RGBA, _ effect: EffectInstance) async throws -> RGBA {
        var p = TestProject()
        let id = try await p.addVideo(.solid(color))
        p[id].effects = [effect]
        return try await p.render(at: 0.5).average(x: 0.4, y: 0.4, w: 0.2, h: 0.2)
    }

    func instance(_ id: String, _ params: [String: Double]) -> EffectInstance {
        var e = Registries.effects[id]!.makeInstance()
        for (k, v) in params { e.params[k] = .scalar(v) }
        return e
    }

    // MARK: LUT

    @Test func lutTextureInvertsColours() async throws {
        let id = LUTLibrary.shared.add(LUT.make(size: 17) { 1 - $0 }, id: "user.lut.test-invert", name: "Invert test")
        let c = try await render(RGBA(0.2, 0.6, 0.9), instance(id, [:]))
        #expect(c.isClose(to: RGBA(0.8, 0.4, 0.1)))
    }

    @Test func lutStrengthMixesWithSource() async throws {
        let id = LUTLibrary.shared.add(LUT.make(size: 9) { _ in SIMD3(1, 1, 1) }, id: "user.lut.test-white", name: "White test")
        let c = try await render(RGBA(0, 0, 0), instance(id, ["intensity": 0.5]))
        #expect(c.isClose(to: RGBA(0.5, 0.5, 0.5)))
    }

    @Test func importedCubeFileRendersAndPersists() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lut-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("Swap RB.cube")
        try LUT.make(size: 5) { SIMD3($0.z, $0.y, $0.x) }.cubeText().write(to: file, atomically: true, encoding: .utf8)
        let lib = LUTLibrary(directory: dir.appendingPathComponent("lib"))
        let id = try lib.importLUT(file)
        #expect(id.hasPrefix(LUTLibrary.idPrefix))
        #expect(lib.entry(id)?.name == "Swap RB")
        #expect(try lib.importLUT(file) == id)  // idempotent
        let c = try await render(RGBA(1, 0, 0), instance(id, [:]))
        #expect(c.isClose(to: RGBA(0, 0, 1)))
        let again = LUTLibrary(directory: dir.appendingPathComponent("lib"))
        again.loadAll()
        #expect(again.all.map(\.id) == [id] && again.all.first?.name == "Swap RB")
    }

    @Test func missingLUTSkipsEffect() async throws {
        let d = EffectDescriptor(id: "user.lut.missing", category: .adjustment, nameKey: "x", groupKey: "x",
                                 inputs: [.lut3D(id: "user.lut.nope")],
                                 shader: "float4 effect(float2 uv, texture2d<float> src, sampler s, constant float* p, FXContext ctx, texture3d<float> lut, sampler s3) { return float4(1,0,1,1); }")
        Registries.effects.register(d)
        let c = try await render(RGBA(0, 1, 0), d.makeInstance())
        #expect(c.isClose(to: RGBA(0, 1, 0)))
    }

    // MARK: HSL

    @Test func hslDesaturatesOnlyItsRange() async throws {
        let e = instance("montage.color.hsl", ["red.sat": -1])
        let red = try await render(RGBA(0.9, 0.1, 0.1), e)
        #expect(abs(red.r - red.g) < 0.06 && abs(red.g - red.b) < 0.06)
        let blue = try await render(RGBA(0.1, 0.1, 0.9), e)
        #expect(blue.isClose(to: RGBA(0.1, 0.1, 0.9)))
        let grey = try await render(RGBA(0.5, 0.5, 0.5), instance("montage.color.hsl", ["red.light": 1, "red.hue": 1]))
        #expect(grey.isClose(to: RGBA(0.5, 0.5, 0.5)))
    }

    @Test func hslHueShiftsTowardNeighbour() async throws {
        let c = try await render(RGBA(0.9, 0.1, 0.1), instance("montage.color.hsl", ["red.hue": 1]))
        #expect(c.r > 0.75 && c.g > 0.35 && c.b < 0.2)   // red → orange
        let dark = try await render(RGBA(0.1, 0.8, 0.1), instance("montage.color.hsl", ["green.light": -1]))
        #expect(dark.g < 0.5 && dark.g > 0.25)
    }

    // MARK: Curves

    @Test func curvesIdentityByDefault() async throws {
        let c = try await render(RGBA(0.3, 0.5, 0.7), Registries.effects["montage.color.curves"]!.makeInstance())
        #expect(c.isClose(to: RGBA(0.3, 0.5, 0.7), tolerance: 0.04))
    }

    @Test func redCurveLiftsMidtonesOnly() async throws {
        let e = instance("montage.color.curves", ["red.y2": 0.8])
        let c = try await render(RGBA(0.5, 0.5, 0.5), e)
        #expect(abs(c.r - 0.8) < 0.05 && abs(c.g - 0.5) < 0.05 && abs(c.b - 0.5) < 0.05)
        let black = try await render(RGBA(0, 0, 0), e)
        #expect(black.r < 0.04)
        let luma = try await render(RGBA(0.25, 0.5, 0.75), instance("montage.color.curves", ["luma.y1": 0.1, "luma.y2": 0.3, "luma.y3": 0.6]))
        #expect(abs(luma.r - 0.1) < 0.05 && abs(luma.g - 0.3) < 0.05 && abs(luma.b - 0.6) < 0.05)
    }

    // MARK: Color wheels

    @Test func gainLumaBrightensAndLiftTintsShadows() async throws {
        let g = try await render(RGBA(0.4, 0.4, 0.4), instance("montage.color.wheels", ["gain.luma": 1]))
        #expect(abs(g.r - 0.6) < 0.05 && abs(g.r - g.b) < 0.03)
        let l = try await render(RGBA(0.1, 0.1, 0.1), instance("montage.color.wheels", ["lift.hue": 0, "lift.amount": 1]))
        #expect(l.r > l.g + 0.1 && l.r > l.b + 0.1)
        let off = try await render(RGBA(0.4, 0.4, 0.4), instance("montage.color.wheels", ["gain.luma": 1, "strength": 0]))
        #expect(off.isClose(to: RGBA(0.4, 0.4, 0.4), tolerance: 0.04))
    }

    // MARK: White balance

    @Test func warmWhiteBalanceKeepsLuminance() async throws {
        let c = try await render(RGBA(0.5, 0.5, 0.5), instance("montage.color.whiteBalance", ["temperature": 1]))
        #expect(c.r > c.g + 0.03 && c.g > c.b + 0.05)
        #expect(abs(c.luma - 0.5) < 0.06)
        let m = try await render(RGBA(0.5, 0.5, 0.5), instance("montage.color.whiteBalance", ["tint": 1]))
        #expect(m.g < m.r - 0.05 && abs(m.r - m.b) < 0.03)
    }
}
