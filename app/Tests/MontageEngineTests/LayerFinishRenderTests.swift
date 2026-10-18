import Testing
import Foundation
@testable import MontageCore
@testable import MontageEngine
import MontageEffects
import MontageTestSupport

/// Finisher rows: adjustment layers (CL-011), effect masks on adjustment / effect layers (FX-005, MK-006),
/// stickers as full layers (ST-009).
@Suite struct LayerFinishRenderTests {
    @Test func emptyAdjustmentLayerIsANoOpAndBasicGradeAppliesBelow() async throws {
        var p = TestProject(background: .black)
        try await p.addVideo(.solid(RGBA(0.5, 0.5, 0.5)))
        let adj = try p.addAdjustment([])
        let before = try await p.render(at: 0.5)[0.5, 0.5]
        #expect(before.isClose(to: RGBA(0.5, 0.5, 0.5), tolerance: 0.03))
        // Adjust ▸ Basic on the adjustment layer grades the composite below it.
        var inst = Registries.effects["montage.adjust.basic"]!.makeInstance()
        inst.params["brightness"] = .scalar(0.6)
        p[adj].effects = [inst]
        let after = try await p.render(at: 0.5)[0.5, 0.5]
        #expect(after.luma > before.luma + 0.05)
    }

    @Test func effectMaskLimitsAnAdjustmentLayerToTheMaskRegion() async throws {
        var p = TestProject(background: .black)
        try await p.addVideo(.solid(RGBA(0.2, 0.6, 1.0)))
        let adj = try p.addAdjustment([Registries.effects["montage.filter.invert"]!.makeInstance()])
        p[adj].adjustMask = Mask(shape: .circle, size: Vec2(0.3, 0.3))
        var img = try await p.render(at: 0.5)
        #expect(img[0.5, 0.5].isClose(to: RGBA(0.8, 0.4, 0.0), tolerance: 0.04))   // inside: inverted
        #expect(img[0.05, 0.1].isClose(to: RGBA(0.2, 0.6, 1.0), tolerance: 0.04))  // outside: untouched
        p[adj].adjustMask?.inverted = true
        img = try await p.render(at: 0.5)
        #expect(img[0.5, 0.5].isClose(to: RGBA(0.2, 0.6, 1.0), tolerance: 0.04))
        #expect(img[0.05, 0.1].isClose(to: RGBA(0.8, 0.4, 0.0), tolerance: 0.04))
    }

    @Test func stickerTakesOpacityBlendAndMask() async throws {
        var p = TestProject(canvas: Size2(320, 180), background: .black)
        let c = Clip(content: .sticker(id: "montage.sticker.shape.circle.yellow"), start: 0, duration: 2)
        try TimelineOps.insert(c, into: &p.project)
        let full = try await p.render(at: 0.5)[0.5, 0.5]
        p[c.id].opacity = 0.5
        let half = try await p.render(at: 0.5)[0.5, 0.5]
        #expect(abs(half.r - full.r * 0.5) < 0.08)
        p[c.id].opacity = 1
        // mask: a thin rectangle at the left edge of the sticker hides its centre
        p[c.id].mask = Mask(shape: .rectangle, center: Vec2(-0.4, 0), size: Vec2(0.1, 1))
        let masked = try await p.render(at: 0.5)[0.5, 0.5]
        #expect(masked.luma < 0.05)
        p[c.id].mask = nil
        p[c.id].blendMode = .multiply   // yellow × black = black
        #expect(try await p.render(at: 0.5)[0.5, 0.5].luma < 0.05)
    }
}
