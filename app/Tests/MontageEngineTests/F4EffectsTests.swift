import Testing
import Foundation
import MontageCore
import MontageEffects
import MontageEngine
import MontageTestSupport

/// F4-FX: effect clip "Apply to" scope (FX-004).
@Suite(.serialized) struct F4EffectScopeTests {
    static let invert = "montage.filter.invert"

    /// Main track: grey full frame; overlay: a red square on the left; an invert effect clip above both.
    static func scene(_ scope: EffectScope?) throws -> TestProject {
        var p = TestProject(canvas: Size2(320, 180), background: .black)
        let mainID = p.project.timeline.mainTrack!.id
        _ = try p.addSolid(RGBA(0.3, 0.3, 0.3), target: .track(mainID))
        let ov = try p.addSolid(RGBA(1, 0, 0))
        p[ov].transform.scale = Vec2(0.3, 0.3)
        p[ov].transform.position = Vec2(-0.25, 0)
        let fx = try p.addAdjustment([Registries.effects[invert]!.makeInstance()])
        p[fx].effectScope = scope
        return p
    }

    // overlay centre at canvas x = 0.5 - 0.25 = 0.25 (position is in canvas-normalized units, ±0.5)
    static func overlayPoint(_ img: Bitmap) -> RGBA { img[0.25, 0.5] }
    static func mainPoint(_ img: Bitmap) -> RGBA { img[0.8, 0.5] }

    @Test func allScopeInvertsEverything() async throws {
        let img = try await Self.scene(nil).render(at: 0.5)
        #expect(Self.mainPoint(img).isClose(to: RGBA(0.7, 0.7, 0.7), tolerance: 0.04), "\(Self.mainPoint(img))")
        #expect(Self.overlayPoint(img).isClose(to: RGBA(0, 1, 1), tolerance: 0.04), "\(Self.overlayPoint(img))")
    }

    @Test func mainScopeLeavesOverlaysUntouched() async throws {
        let img = try await Self.scene(.main).render(at: 0.5)
        #expect(Self.mainPoint(img).isClose(to: RGBA(0.7, 0.7, 0.7), tolerance: 0.04), "main inverted: \(Self.mainPoint(img))")
        #expect(Self.overlayPoint(img).isClose(to: RGBA(1, 0, 0), tolerance: 0.04), "overlay kept: \(Self.overlayPoint(img))")
    }

    @Test func pipScopeLeavesMainTrackUntouched() async throws {
        let img = try await Self.scene(.pip).render(at: 0.5)
        #expect(Self.mainPoint(img).isClose(to: RGBA(0.3, 0.3, 0.3), tolerance: 0.04), "main kept: \(Self.mainPoint(img))")
        #expect(Self.overlayPoint(img).isClose(to: RGBA(0, 1, 1), tolerance: 0.04), "overlay inverted: \(Self.overlayPoint(img))")
    }

    @Test func scopedItemsAreOrderedForTheRenderer() throws {
        let main = FrameEvaluator.evaluate(try Self.scene(.main).project, at: Time(0.5))
        // main layer, main-scoped adjustment, then the overlay
        guard main.items.count == 3, case .layer = main.items[0], case .adjustment = main.items[1], case .layer = main.items[2] else {
            Issue.record("unexpected items \(main.items)"); return
        }
        let pip = FrameEvaluator.evaluate(try Self.scene(.pip).project, at: Time(0.5))
        guard pip.items.count == 2, case .layer = pip.items[0], case .nested(let c, let inner) = pip.items[1] else {
            Issue.record("unexpected items \(pip.items)"); return
        }
        #expect(c.isEffectGroup)
        #expect(inner.count == 2)
        #expect(FrameDescription(time: .zero, canvasSize: Size2(1, 1), background: .black, items: pip.items).mediaLayers.isEmpty)
    }

    @Test func scopeIsPersistedAndOldFilesDecode() throws {
        var c = Clip(content: .adjustment, start: .zero, duration: Time(1))
        c.effectScope = .pip
        let data = try JSONEncoder().encode(c)
        #expect(try JSONDecoder().decode(Clip.self, from: data).effectScope == .pip)
        c.effectScope = nil
        let old = try JSONEncoder().encode(c)
        #expect(!String(decoding: old, as: UTF8.self).contains("effectScope"))
        #expect(try JSONDecoder().decode(Clip.self, from: old).effectScope == nil)
    }
}
