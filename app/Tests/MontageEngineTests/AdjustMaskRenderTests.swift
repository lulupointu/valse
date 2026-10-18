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
}
