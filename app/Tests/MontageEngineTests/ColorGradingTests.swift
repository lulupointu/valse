import Testing
import Foundation
import CoreGraphics
import MontageCore
import MontageEffects
import MontageEngine
import MontageTestSupport

/// Free-point curves (CPU mirror = GPU), Log colour wheels, the extended Adjust ▸ Basic params and Auto adjust.
@Suite(.serialized) struct ColorGradingTests {
    func render(_ color: RGBA, _ effect: EffectInstance) async throws -> RGBA {
        var p = TestProject()
        let id = try await p.addVideo(.solid(color))
        p[id].effects = [effect]
        return try await p.render(at: 0.5).average(x: 0.4, y: 0.4, w: 0.2, h: 0.2)
    }

    func instance(_ d: EffectDescriptor, _ params: [String: Double]) -> EffectInstance {
        var e = d.makeInstance()
        for (k, v) in params { e.params[k] = .scalar(v) }
        return e
    }

    // MARK: Curves

    @Test func curveMathIsMonotoneAndRoundTrips() {
        #expect(abs(ColorCurveMath.evaluate(ColorCurveMath.identity, 0.37) - 0.37) < 1e-9)
        let pts: [ColorCurveMath.Point] = [(0, 0.1), (0.3, 0.15), (0.6, 0.8), (1, 0.95)]
        var last = -1.0
        for k in 0...100 {
            let y = ColorCurveMath.evaluate(pts, Double(k) / 100)
            #expect(y >= last - 1e-9 && y >= 0.1 - 1e-9 && y <= 0.95 + 1e-9)
            last = y
        }
        let params = ColorCurveMath.params(pts.reversed(), channel: "red")    // unsorted input gets sorted
        let back = ColorCurveMath.points(params, channel: "red")
        #expect(back.count == 4 && back.map(\.x) == pts.map(\.x) && back.map(\.y) == pts.map(\.y))
        // legacy instances (only y0…y4) read as 5 uniform knots
        let legacy = ColorCurveMath.points(["luma.y2": .scalar(0.8)], channel: "luma")
        #expect(legacy.count == 5 && legacy[2].x == 0.5 && legacy[2].y == 0.8)
    }

    @Test func gpuCurveMatchesCPUWithFreePoints() async throws {
        let pts: [ColorCurveMath.Point] = [(0, 0), (0.2, 0.45), (0.7, 0.75), (1, 1)]
        var inst = BuiltinColor.curves.makeInstance()
        for (k, v) in ColorCurveMath.params(pts, channel: "green") { inst.params[k] = v }
        let c = try await render(RGBA(0.5, 0.5, 0.5), inst)
        let expected = ColorCurveMath.evaluate(pts, 0.5)
        #expect(abs(c.g - expected) < 0.04, "g \(c.g) vs \(expected)")
        #expect(abs(c.r - 0.5) < 0.04 && abs(c.b - 0.5) < 0.04)
        // two points only: a straight inverted line
        var inv = BuiltinColor.curves.makeInstance()
        for (k, v) in ColorCurveMath.params([(0, 1), (1, 0)], channel: "luma") { inv.params[k] = v }
        let w = try await render(RGBA(0.2, 0.2, 0.2), inv)
        #expect(abs(w.r - 0.8) < 0.05)
    }

    // MARK: Wheels

    @Test func logWheelsTintOnlyTheirRange() async throws {
        let d = BuiltinColor.colorWheels
        var e = instance(d, ["gain.hue": 0, "gain.amount": 1])
        e.params["mode"] = .choice(1)
        let dark = try await render(RGBA(0.08, 0.08, 0.08), e), bright = try await render(RGBA(0.9, 0.9, 0.9), e)
        #expect(abs(dark.r - dark.b) < 0.04)                 // shadows untouched by the highlight wheel
        #expect(bright.r > bright.b + 0.1)                    // highlights tinted red
        var s = instance(d, ["lift.hue": 240, "lift.amount": 1]); s.params["mode"] = .choice(1)
        let sh = try await render(RGBA(0.08, 0.08, 0.08), s)
        #expect(sh.b > sh.r + 0.08)
    }

    // MARK: Basic (new params)

    @Test func basicWhitesBlacksFadeAndVignette() async throws {
        let d = BuiltinAdjustments.basic
        let w = try await render(RGBA(0.9, 0.9, 0.9), instance(d, ["whites": -1]))
        #expect(w.r < 0.85)
        let b = try await render(RGBA(0.05, 0.05, 0.05), instance(d, ["blacks": 1]))
        #expect(b.r > 0.12)
        let f = try await render(RGBA(0, 0, 0), instance(d, ["fade": 1]))
        #expect(f.r > 0.08)
        let h = try await render(RGBA(0.8, 0.2, 0.2), instance(d, ["hue": 1]))
        #expect(h.g > h.b + 0.2)                              // red rotated toward yellow
        var p = TestProject()
        let id = try await p.addVideo(.solid(RGBA(0.5, 0.5, 0.5)))
        p[id].effects = [instance(d, ["vignette": -1])]
        let img = try await p.render(at: 0.5)
        #expect(img[0.02, 0.03].r > img[0.5, 0.5].r + 0.15)  // negative vignette whitens the corners
    }

    @Test func basicSharpenClarityAndGrainChangeTexture() {
        let r = EffectPreviewRenderer.shared
        let base = r.render([], time: 0, width: 192, height: 108)!
        let d = BuiltinAdjustments.basic
        for (k, v) in [("sharpen", 1.0), ("clarity", 1.0), ("grain", 1.0)] {
            let px = r.render(d, params: [k: .scalar(v)], time: 0.4, width: 192, height: 108)!
            #expect(EffectLibraryTests.meanAbsDiff(px, base) > 0.004, "\(k) should change the frame")
            #expect(EffectBehaviourTests.detail(px) > EffectBehaviourTests.detail(base), "\(k) should add detail")
        }
        #expect(EffectLibraryTests.meanAbsDiff(r.render(d, time: 0.4, width: 192, height: 108)!, base) < 0.002)   // defaults = identity
    }

    // MARK: Auto adjust

    static func image(_ c: RGBA, w: Int = 64, h: Int = 36, noise: Bool = true) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let k = noise ? Double((x * 7 + y * 13) % 11) / 11 * 0.2 - 0.1 : 0
            let i = (y * w + x) * 4
            out[i] = UInt8(max(0, min(1, c.r + k)) * 255); out[i + 1] = UInt8(max(0, min(1, c.g + k)) * 255); out[i + 2] = UInt8(max(0, min(1, c.b + k)) * 255)
        } }
        return out
    }

    @Test func autoAdjustStatistics() {
        let dark = AutoColor.analyze(rgba: Self.image(RGBA(0.12, 0.12, 0.12)), width: 64, height: 36)
        #expect((dark["exposure"] ?? 0) > 0.5)
        let bright = AutoColor.analyze(rgba: Self.image(RGBA(0.85, 0.85, 0.85)), width: 64, height: 36)
        #expect((bright["exposure"] ?? 0) < -0.3)
        let blue = AutoColor.analyze(rgba: Self.image(RGBA(0.35, 0.45, 0.7)), width: 64, height: 36)
        #expect((blue["temperature"] ?? 0) > 0.2)             // warms a blue cast
        let green = AutoColor.analyze(rgba: Self.image(RGBA(0.4, 0.6, 0.4)), width: 64, height: 36)
        #expect((green["tint"] ?? 0) > 0.1)                   // magenta against a green cast
        let flat = AutoColor.analyze(rgba: Self.image(RGBA(0.45, 0.45, 0.45)), width: 64, height: 36)
        #expect((flat["contrast"] ?? 0) > 0.2)                // low-contrast frame gets stretched
    }

    @Test func autoAdjustCorrectsAFrameAndProviderCanOverride() async throws {
        var p = TestProject()
        let id = try await p.addVideo(.solid(RGBA(0.15, 0.17, 0.3)))
        let asset = p.project.media[0]
        let frame = try await AutoAdjustAnalyzer.frame(of: p[id], asset: asset, at: Time(0.5))
        let values = await AutoAdjustAnalyzer.analyze(frame)
        print("AUTO", values)
        #expect((values["exposure"] ?? 0) > 0.3 && (values["temperature"] ?? 0) > 0.1)
        var inst = AutoColor.descriptor.makeInstance()
        for (k, v) in values { inst.params[k] = .scalar(v) }
        p[id].effects = [inst]
        let c = try await p.render(at: 0.5).average(x: 0.4, y: 0.4, w: 0.2, h: 0.2)
        #expect(c.luma > 0.25)
        #expect(c.b / max(c.r, 0.01) < 0.3 / 0.15 * 0.8)       // blue cast reduced
        inst.params["strength"] = .scalar(0)
        p[id].effects = [inst]
        let off = try await p.render(at: 0.5).average(x: 0.4, y: 0.4, w: 0.2, h: 0.2)
        #expect(off.isClose(to: RGBA(0.15, 0.17, 0.3)))
        AutoAdjustAnalyzer.setProvider { _ in ["exposure": 1.5] }
        defer { AutoAdjustAnalyzer.setProvider(nil) }
        #expect(await AutoAdjustAnalyzer.analyze(frame)["exposure"] == 1.5)
    }
}
