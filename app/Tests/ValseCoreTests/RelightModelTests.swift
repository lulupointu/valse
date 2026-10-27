import Testing
import Foundation
@testable import ValseCore

@Suite struct RelightModelTests {
    @Test func presetsAreDistinctAndCodable() throws {
        let all = RelightSettings.Preset.allCases.map { RelightSettings.preset($0) }
        #expect(Set(all).count == all.count)
        #expect(RelightSettings.preset(.facial).target == .people)
        #expect(RelightSettings.preset(.creative).lights.count == 2)
        for s in all {
            let d = try JSONEncoder().encode(s)
            #expect(try JSONDecoder().decode(RelightSettings.self, from: d) == s)
        }
    }

    @Test func oldClipsDecodeWithoutRelight() throws {
        let c = Clip(content: .solid(.red), start: 0, duration: 1)
        let d = try JSONEncoder().encode(c)
        #expect(!String(decoding: d, as: UTF8.self).contains("relight"))
        #expect(try JSONDecoder().decode(Clip.self, from: d).relight == nil)
    }

    @Test func animationsResolveOverTime() {
        let still = RelightLight(x: 0.3, y: 0.4, intensity: 0.8)
        #expect(still.resolved(at: 3) == still)
        var moving = still; moving.movingSpeed = 0.5
        #expect(moving.resolved(at: 0).x == 0.3)
        #expect(moving.resolved(at: 1.3) != moving.resolved(at: 0))
        var blink = still; blink.blinkingSpeed = 1
        let vals = stride(from: 0.0, to: 1, by: 0.05).map { blink.resolved(at: $0).intensity }
        #expect(vals.min()! < 0.2 && vals.max()! > 0.75)
        var hue = still; hue.color = RGBA(1, 0, 0); hue.colorChanging = 1
        let c = hue.resolved(at: 1).color
        #expect(c != RGBA(1, 0, 0))
        #expect(abs(max(c.r, c.g, c.b) - 1) < 1e-9)   // value kept
    }

    @Test func hueRotationIsCyclic() {
        let c = RGBA(0.2, 0.6, 0.9)
        let back = RelightLight.rotateHue(c, by: 1)
        #expect(abs(back.r - c.r) < 1e-9 && abs(back.g - c.g) < 1e-9 && abs(back.b - c.b) < 1e-9)
        let g = RelightLight.rotateHue(RGBA(1, 0, 0), by: 1.0 / 3)
        #expect(abs(g.g - 1) < 1e-9 && g.r < 1e-9)
    }

    @Test func evaluatorResolvesRelightOnMediaLayers() throws {
        var (p, ids) = Fx.project(mainClips: 1)
        var s = RelightSettings.preset(.object); s.lights[0].movingSpeed = 1
        p.timeline[clip: ids[0]]!.relight = s
        let f = FrameEvaluator.evaluate(p, at: Time(0.7))
        let layer = f.items.compactMap { if case .layer(let l) = $0 { return l }; return nil }.first { $0.clipID == ids[0] }
        #expect(layer?.relight != nil)
        #expect(layer?.relight?.lights[0].x != s.lights[0].x)
    }
}
