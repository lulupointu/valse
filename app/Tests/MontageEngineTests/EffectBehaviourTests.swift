import Testing
import Foundation
import simd
import MontageCore
import MontageEffects
import MontageEngine

/// "Changes pixels in the expected way": property checks per effect family on the procedural sample frame.
@Suite(.serialized) struct EffectBehaviourTests {
    typealias Px = EffectPreviewRenderer.Pixels
    static let w = 192, h = 108
    let r = EffectPreviewRenderer.shared

    func src(_ scene: EffectPreviewRenderer.Scene = .full) -> Px { r.render([], time: 0, width: Self.w, height: Self.h, scene: scene)! }
    func fx(_ id: String, t: Double = 0.8, _ params: [String: Double] = [:]) -> Px {
        let d = Registries.effects[id]!
        return r.render(d, params: params.mapValues { .scalar($0) }, time: t, width: Self.w, height: Self.h)!
    }

    /// Mean absolute difference between horizontally adjacent pixels (high-frequency energy).
    static func detail(_ p: Px) -> Float {
        var s: Float = 0, n: Float = 0
        for y in 0..<p.height { for x in 1..<p.width { let a = p[x: x, y: y], b = p[x: x - 1, y: y]; s += abs(a.x - b.x) + abs(a.y - b.y) + abs(a.z - b.z); n += 1 } }
        return s / n
    }
    static func luma(_ v: SIMD4<Float>) -> Float { 0.2126 * v.x + 0.7152 * v.y + 0.0722 * v.z }
    static func chroma(_ v: SIMD4<Float>) -> Float { max(v.x, max(v.y, v.z)) - min(v.x, min(v.y, v.z)) }
    static func meanChroma(_ p: Px) -> Float {
        var s: Float = 0
        for y in 0..<p.height { for x in 0..<p.width { s += chroma(p[x: x, y: y]) } }
        return s / Float(p.width * p.height)
    }

    @Test func blursRemoveDetailAndSharpenAddsIt() {
        let base = Self.detail(src())
        for id in ["montage.effect.blur", "montage.effect.motionBlur", "montage.effect.zoomBlur", "montage.effect.spinBlur",
                   "montage.effect.defocus", "montage.effect.bokehBlur", "montage.effect.softFocus"] {
            #expect(Self.detail(fx(id)) < base * 0.85, "\(id) should smooth the image")
        }
        #expect(Self.detail(fx("montage.effect.sharpen", ["amount": 1])) > base * 1.1)
    }

    @Test func mirrorsAndSplitsAreSymmetric() {
        let m = fx("montage.effect.mirrorLeft")
        for y in stride(from: 5, to: Self.h, by: 17) { for x in stride(from: 3, to: Self.w / 2, by: 13) {
            #expect(simd_distance(m[x: x, y: y], m[x: Self.w - 1 - x, y: y]) < 0.03)
        } }
        let t = fx("montage.effect.mirrorTop")
        for y in stride(from: 3, to: Self.h / 2, by: 9) { for x in stride(from: 5, to: Self.w, by: 21) {
            #expect(simd_distance(t[x: x, y: y], t[x: x, y: Self.h - 1 - y]) < 0.03)
        } }
        let s4 = fx("montage.effect.split4")
        for y in stride(from: 4, to: Self.h / 2, by: 11) { for x in stride(from: 4, to: Self.w / 2, by: 15) {
            #expect(simd_distance(s4[x: x, y: y], s4[x: x + Self.w / 2, y: y + Self.h / 2]) < 0.04)
        } }
    }

    @Test func blackAndWhiteHasNoChroma() {
        for d in Registries.effects(in: .filter) where d.groupKey == "filter.group.bw" && d.id.hasPrefix("montage.") {
            let p = r.render(d, time: 0.5, width: Self.w, height: Self.h)!
            let tinted = ["montage.filter.selenium", "montage.filter.platinum"].contains(d.id)
            #expect(Self.meanChroma(p) < (tinted ? 0.08 : 0.02), "\(d.id) should be monochrome")
        }
        #expect(Self.meanChroma(fx("montage.effect.silentMovie")) < 0.03)
    }

    @Test func filtersAtZeroStrengthAreIdentity() {
        let base = src()
        for d in Registries.effects(in: .filter) where d.id.hasPrefix("montage.") {
            let p = r.render(d, params: ["intensity": .scalar(0)], time: 0.5, width: Self.w, height: Self.h)!
            #expect(EffectLibraryTests.meanAbsDiff(p, base) < 0.002, "\(d.id) at strength 0 must equal the source")
        }
    }

    @Test func colourFiltersMoveTheRightWay() {
        let base = src().mean()
        let warm = fx("montage.filter.goldenHour").mean(), cool = fx("montage.filter.azure").mean()
        #expect(warm.x / warm.z > base.x / base.z * 1.05)
        #expect(cool.z / cool.x > base.z / base.x * 1.05)
        let bright = fx("montage.filter.bright").mean(), mid = fx("montage.filter.midnight").mean()
        #expect(Self.luma(bright) > Self.luma(base) + 0.03)
        #expect(Self.luma(mid) < Self.luma(base) - 0.03)
        #expect(Self.meanChroma(fx("montage.filter.pop")) > Self.meanChroma(src()) * 1.1)
    }

    @Test func vignettesAndFramesShapeTheBorders() {
        let base = src()
        let corner = { (p: Px) in Self.luma(p.mean(x: 0, y: 0, w: 0.08, h: 0.12)) }
        #expect(corner(fx("montage.effect.darkVignette")) < corner(base) - 0.15)
        #expect(corner(fx("montage.effect.whiteVignette")) > corner(base) + 0.1)
        let bars = fx("montage.effect.cinemaBars", t: 1.0)
        #expect(Self.luma(bars.mean(x: 0, y: 0, w: 1, h: 0.04)) < 0.02)
        #expect(Self.luma(bars.mean(x: 0.3, y: 0.4, w: 0.4, h: 0.2)) > 0.1)
        let border = fx("montage.effect.whiteBorder")
        #expect(Self.luma(border[x: 1, y: 1]) > 0.9)
        let rounded = fx("montage.effect.roundedCorners")
        #expect(rounded[x: 0, y: 0].w < 0.05 && rounded[x: Self.w / 2, y: Self.h / 2].w > 0.99)
    }

    @Test func lightEffectsOnlyBrighten() {
        let base = src()
        for id in ["montage.effect.lightLeak", "montage.effect.glow", "montage.effect.bloom", "montage.effect.godRays",
                   "montage.effect.lensFlare", "montage.effect.sparkle", "montage.effect.bokehLights"] {
            let p = fx(id)
            var darker = 0
            for i in stride(from: 0, to: p.data.count, by: 4) where Self.luma(SIMD4(p.data[i], p.data[i + 1], p.data[i + 2], 1)) + 0.01
                < Self.luma(SIMD4(base.data[i], base.data[i + 1], base.data[i + 2], 1)) { darker += 1 }
            #expect(Double(darker) / Double(p.width * p.height) < 0.02, "\(id) should not darken (\(darker) px)")
            #expect(Self.luma(p.mean()) > Self.luma(base.mean()) + 0.0005, "\(id) should brighten")
        }
    }

    @Test func flashesPeakOnTheBeat() {
        let base = Self.luma(src().mean())
        #expect(Self.luma(fx("montage.effect.flash", t: 0).mean()) > base + 0.3)
        #expect(Self.luma(fx("montage.effect.blackFlash", t: 0).mean()) < base - 0.3)
    }

    @Test func cameraMotionKeepsColoursAndMovesPixels() {
        let base = src()
        for id in ["montage.effect.shake", "montage.effect.earthquake", "montage.effect.swing", "montage.effect.pulse",
                   "montage.effect.wave", "montage.effect.twirl", "montage.effect.ripple", "montage.effect.barrel"] {
            let p = fx(id, t: 1.3)
            #expect(simd_distance(p.mean(), base.mean()) < 0.08, "\(id) should only move pixels")
            #expect(EffectLibraryTests.meanAbsDiff(p, base) > 0.005, "\(id) should move pixels")
        }
    }

    @Test func weatherAddsParticles() {
        let base = Self.luma(src().mean())
        for id in ["montage.effect.snow", "montage.effect.blizzard", "montage.effect.lightSnow", "montage.effect.bubbles"] {
            #expect(Self.luma(fx(id).mean()) > base + 0.004, "\(id) should add light particles")
        }
        #expect(EffectLibraryTests.changedFraction(fx("montage.effect.confetti"), src()) > 0.02)
        // deterministic: same time → same pixels (preview = export)
        #expect(EffectLibraryTests.meanAbsDiff(fx("montage.effect.snow", t: 1.234), fx("montage.effect.snow", t: 1.234)) == 0)
        #expect(EffectLibraryTests.meanAbsDiff(fx("montage.effect.snow", t: 0.5), fx("montage.effect.snow", t: 1.5)) > 0.002)
    }

    @Test func bodyEffectsDrawAroundTheSubjectOnly() {
        let base = r.render([], time: 0, width: Self.w, height: Self.h, scene: .subjectOverBackground)!
        let p = fx("montage.effect.outline")
        // far from the subject (top-left sky) nothing changes; near its silhouette something does
        #expect(simd_distance(p.mean(x: 0, y: 0, w: 0.15, h: 0.2), base.mean(x: 0, y: 0, w: 0.15, h: 0.2)) < 0.01)
        #expect(EffectLibraryTests.changedFraction(p, base) > 0.01)
        let aura = fx("montage.effect.aura")
        #expect(EffectLibraryTests.changedFraction(aura, base) > 0.02)
    }

    @Test func effectParametersChangeTheResult() {
        // sliders matter: amount 0 ≈ source for strength-style params, larger = stronger
        let base = src()
        let weak = fx("montage.effect.rgbSplit", ["amount": 0.1]), strong = fx("montage.effect.rgbSplit", ["amount": 1])
        #expect(EffectLibraryTests.meanAbsDiff(strong, base) > EffectLibraryTests.meanAbsDiff(weak, base) * 2)
        let none = fx("montage.effect.oldPhoto", ["amount": 0])
        #expect(EffectLibraryTests.meanAbsDiff(none, base) < 0.002)
    }
}
