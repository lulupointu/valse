import Testing
import Foundation
import MontageCore
import MontageEffects
import MontageEngine
import MontageTestSupport

/// Adjust ▸ Mask (W3-1): the Adjust-tab grading only applies inside the grading mask; filters/effects stay global.
@Suite(.serialized) struct AdjustMaskRenderTests {
    static func brightened(_ p: inout TestProject, _ id: ClipID) {
        var e = BuiltinAdjustments.basic.makeInstance()
        e.params["brightness"] = .scalar(1)
        p[id].effects = [e]
    }

    @Test func gradeAppliesInsideMaskOnly() async throws {
        var plain = TestProject(canvas: Size2(320, 180), background: .black)
        let a = try plain.addSolid(RGBA(0.3, 0.3, 0.3))
        Self.brightened(&plain, a)
        let full = try await plain.render(at: 0.5)

        var p = TestProject(canvas: Size2(320, 180), background: .black)
        let id = try p.addSolid(RGBA(0.3, 0.3, 0.3))
        Self.brightened(&p, id)
        p[id].adjustMask = Mask(shape: .circle, size: Vec2(0.4, 0.6))
        let img = try await p.render(at: 0.5)
        #expect(img[0.5, 0.5].isClose(to: full[0.5, 0.5], tolerance: 0.03), "centre graded like the unmasked clip")
        #expect(img[0.05, 0.05].isClose(to: RGBA(0.3, 0.3, 0.3), tolerance: 0.03), "corner keeps the original colour")
        #expect(full[0.05, 0.05].g > 0.4, "the grade is visible without a mask")

        // inverted: the outside is graded
        p[id].adjustMask?.inverted = true
        let inv = try await p.render(at: 0.5)
        #expect(inv[0.5, 0.5].isClose(to: RGBA(0.3, 0.3, 0.3), tolerance: 0.03))
        #expect(inv[0.05, 0.05].isClose(to: full[0.05, 0.05], tolerance: 0.03))
    }

    @Test func adjustMaskIsKeyframeableAndCopiedWithAttributes() throws {
        var c = Clip(content: .solid(.white), start: .zero, duration: Time(2))
        c.adjustMask = Mask(shape: .rectangle)
        c.toggleKeyframe(.adjustMaskFeather, at: .zero, tolerance: Time(0.01))
        c.setValue(.adjustMaskFeather, .scalar(0.5), at: Time(1))
        #expect(abs((c.resolved(at: Time(1)).adjustMask?.feather ?? -1) - 0.5) < 1e-9)
        #expect(c.mask == nil, "the clip's shape mask is untouched")
    }

    /// Pen mask: a square outline in the top-left quadrant → only that region of the layer shows (orientation check).
    @Test func penMaskCutsItsOutline() async throws {
        for feather in [0.0, 0.3] {
            var p = TestProject(canvas: Size2(320, 320), background: .black)
            let id = try p.addSolid(.white)
            var m = Mask(shape: .pen, center: Vec2(-0.25, -0.25), size: Vec2(0.5, 0.5), feather: feather)
            m.points = [Vec2(-0.5, -0.5), Vec2(0.5, -0.5), Vec2(0.5, 0.5), Vec2(-0.5, 0.5)]
            p[id].mask = m
            let img = try await p.render(at: 0.5)
            #expect(img[0.25, 0.25].isClose(to: .white), "inside (feather \(feather))")
            #expect(img[0.75, 0.75].isClose(to: .black), "bottom-right outside")
            #expect(img[0.75, 0.25].isClose(to: .black), "top-right outside")
            #expect(img[0.25, 0.75].isClose(to: .black), "bottom-left outside")
            p[id].mask?.inverted = true
            let inv = try await p.render(at: 0.5)
            #expect(inv[0.25, 0.25].isClose(to: .black) && inv[0.75, 0.75].isClose(to: .white), "inverted")
        }
    }

    /// Text mask: glyphs fill part of the box, nothing outside it; the grading-mask variant uses the same coverage.
    @Test func textMaskShowsGlyphsInsideItsBox() async throws {
        var p = TestProject(canvas: Size2(320, 180), background: .black)
        let id = try p.addSolid(.white)
        var m = Mask(shape: .text, size: Vec2(0.8, 0.5)); m.text = "HI"
        p[id].mask = m
        let img = try await p.render(at: 0.5)
        var inside = 0, total = 0
        for yi in 0..<20 { for xi in 0..<40 {
            let x = 0.1 + 0.8 * (Double(xi) + 0.5) / 40, y = 0.25 + 0.5 * (Double(yi) + 0.5) / 20
            total += 1; if img[x, y].r > 0.5 { inside += 1 }
        } }
        let frac = Double(inside) / Double(total)
        #expect(frac > 0.15 && frac < 0.85, "glyph coverage \(frac)")
        #expect(img[0.03, 0.05].isClose(to: .black) && img[0.97, 0.95].isClose(to: .black), "outside the box")
        #expect(img[0.45, 0.32].r < 0.5, "inside the H, above its crossbar")
    }
}
