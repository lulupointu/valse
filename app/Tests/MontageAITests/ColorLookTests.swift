import Testing
import Foundation
import CoreGraphics
import simd
@testable import MontageAI
import MontageCore
import MontageEngine
import MontageTestSupport

/// Auto adjust / Color match (CL-007 / CL-009 / AI-055): statistics → generated LUT effect, rendered.
@Suite(.serialized) struct ColorLookTests {
    @Test func labRoundTrip() {
        for c in [SIMD3<Float>(0.2, 0.5, 0.8), SIMD3(1, 1, 1), SIMD3(0, 0, 0), SIMD3(0.9, 0.1, 0.3)] {
            let back = ColorTransfer.rgb(ColorTransfer.lab(c))
            #expect(simd_length(back - c) < 0.003, "\(c) → \(back)")
        }
    }

    @Test func autoAdjustRemovesAColourCast() async throws {
        var p = TestProject()
        // a dim scene with a strong blue cast: dark blue-grey | light blue-grey
        let id = try await p.addImage(.split(RGBA(0.18, 0.22, 0.42), RGBA(0.42, 0.48, 0.68)))
        let before = try await p.render(at: 0.5).average(x: 0.3, y: 0.1, w: 0.4, h: 0.8)
        let cmd = try await ColorLooks.autoAdjust(project: p.project, clipID: id, strength: 1)
        try cmd.apply(to: &p.project)
        #expect(p[id].effects.contains { ColorLooks.kind(of: $0) == .auto })
        let after = try await p.render(at: 0.5).average(x: 0.3, y: 0.1, w: 0.4, h: 0.8)
        func cast(_ c: RGBA) -> Double { c.b - (c.r + c.g) / 2 }
        print("metric auto_adjust_cast_before=\(cast(before)) after=\(cast(after))")
        #expect(cast(after) < cast(before) * 0.35, "before \(before) after \(after)")
        // strength 0 = untouched
        let e = p[id].effects.first { ColorLooks.kind(of: $0) == .auto }!
        p[id].effects[0].params["intensity"] = .scalar(0)
        let zero = try await p.render(at: 0.5).average(x: 0.3, y: 0.1, w: 0.4, h: 0.8)
        #expect(abs(zero.b - before.b) < 0.02 && e.typeID.hasPrefix("ai.look.auto."))
    }

    @Test func colorMatchTakesTheReferenceTheme() async throws {
        var p = TestProject()
        let id = try await p.addImage(.split(RGBA(0.5, 0.3, 0.25), RGBA(0.8, 0.6, 0.5)))   // warm
        // reference: a teal frame
        let ref = (0..<400).map { i in i % 2 == 0 ? SIMD3<Float>(0.1, 0.45, 0.5) : SIMD3<Float>(0.25, 0.65, 0.7) }
        let cmd = try await ColorLooks.match(project: p.project, clipID: id, reference: ref)
        try cmd.apply(to: &p.project)
        let out = try await p.render(at: 0.5).average(x: 0.3, y: 0.1, w: 0.4, h: 0.8)
        let refMean = ref.reduce(SIMD3<Float>.zero, +) / Float(ref.count)
        print("metric color_match_out=\(out) ref=\(refMean)")
        #expect(abs(out.r - Double(refMean.x)) < 0.08 && abs(out.g - Double(refMean.y)) < 0.08 && abs(out.b - Double(refMean.z)) < 0.08)
        // a second match replaces the first look (one per kind)
        let again = try await ColorLooks.match(project: p.project, clipID: id, reference: ref.map { SIMD3($0.z, $0.y, $0.x) })
        try again.apply(to: &p.project)
        #expect(p[id].effects.filter { ColorLooks.kind(of: $0) == .match }.count == 1)
    }
}
