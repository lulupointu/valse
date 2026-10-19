import Testing
import Foundation
import CoreGraphics
import CoreText
import AppKit
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
        try await HeavyWorkGate.run {   // CPU-heavy: keep real-time probes from starving
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
    }

    @Test func colorMatchTakesTheReferenceTheme() async throws {
        try await HeavyWorkGate.run {   // CPU-heavy: keep real-time probes from starving
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

    @Test func skinCastTurnsSkinToTheSkinHue() throws {
        let h = ColorTransfer.skinHue * .pi / 180
        let natural = SIMD2(cos(h), sin(h)) * 20
        #expect(simd_length(try #require(ColorTransfer.skinCast(natural))) < 1e-9)
        // blue-cast skin (b pulled down): the cast points to −b, and removing it lands on the skin hue
        let blue = natural + SIMD2(0, -15)
        let cast = try #require(ColorTransfer.skinCast(blue))
        #expect(cast.y < -8)
        let fixed = blue - cast
        #expect(abs(atan2(fixed.y, fixed.x) * 180 / .pi - ColorTransfer.skinHue) < 1e-6)
        #expect(ColorTransfer.skinMean([SIMD3<Float>](repeating: SIMD3(0.8, 0.6, 0.5), count: 10)) == nil)   // too few
    }

    /// A face on a big green lawn: gray-world white balance pushes the face towards magenta, the face-aware correction
    /// puts the skin on a natural skin hue (CL-008).
    @Test func colorCorrectionWhiteBalancesOnFaces() throws {
        let (w, h) = (360, 240)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.25, green: 0.55, blue: 0.2, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "🧑", attributes: [.font: CTFontCreateWithName("Apple Color Emoji" as CFString, 150, nil)]))
        ctx.textPosition = CGPoint(x: 100, y: 50)
        CTLineDraw(line, ctx)
        let img = ctx.makeImage()!
        let skinPx = ColorLooks.skinPixels(img)
        #expect(skinPx.count > 200, "no face found")
        let skin = try #require(ColorTransfer.skinMean(skinPx))
        let stats = ColorStats.of(ColorLooks.rgb(img))
        let grayWorld = ColorTransfer.autoAdjustLUT(stats), faceAware = ColorTransfer.autoAdjustLUT(stats, skin: skin)
        let sample = ColorTransfer.rgb(skin)
        func hueShift(_ lut: LUT) -> Double {
            let o = ColorTransfer.lab(lut.apply(sample))
            return abs(atan2(o.z, o.y) * 180 / .pi - ColorTransfer.skinHue)   // distance from a natural skin hue
        }
        print("metric color_correct_skin_hue_shift gray=\(hueShift(grayWorld)) face=\(hueShift(faceAware))")
        #expect(hueShift(faceAware) < 12 && hueShift(grayWorld) > 30)
    }

    /// AI QA (project 1018 is an HLG project): looks are computed on SDR frames; applied unchanged to HLG Rec.2020
    /// working values they gave a strong cyan / green cast. Re-baked for the project space: identity stays identity,
    /// a contrast curve keeps greys neutral, a warm look stays warm, highlights keep their headroom.
    @Test func looksAreRebakedForHDRProjects() {
        let id = LUT.identity(size: 17)
        #expect(ColorLooks.inProjectSpace(id, .sdr709) == id)
        let hid = ColorLooks.inProjectSpace(id, .hdrHLG)
        for c in [SIMD3<Float>(0.2, 0.4, 0.6), SIMD3<Float>(0.75, 0.75, 0.75), SIMD3<Float>(0.95, 0.9, 0.85)] {
            let o = hid.apply(c)
            #expect(abs(o.x - c.x) < 0.01 && abs(o.y - c.y) < 0.01 && abs(o.z - c.z) < 0.01, "identity \(c) → \(o)")
        }
        let contrast = LUT.make(size: 17) { c in (c - 0.5) * 1.3 + 0.5 }
        let grey = ColorLooks.inProjectSpace(contrast, .hdrHLG).apply(SIMD3<Float>(0.6, 0.6, 0.6))
        #expect(abs(grey.x - grey.y) < 0.01 && abs(grey.y - grey.z) < 0.01, "neutral stays neutral: \(grey)")
        let warm = LUT.make(size: 17) { c in SIMD3<Float>(min(1, c.x * 1.08), c.y, c.z * 0.92) }
        let w = ColorLooks.inProjectSpace(warm, .hdrHLG).apply(SIMD3<Float>(0.6, 0.6, 0.6))
        #expect(w.x > w.y + 0.01 && w.z < w.y - 0.01, "warm stays warm: \(w)")
    }
}
