import Testing
import Foundation
import CoreGraphics
import ValseCore
import ValseEffects
import ValseEngine
import ValseTestSupport

/// Procedural vector stickers / shapes and the emoji sticker set: names, rasterization, compositing.
@Suite(.serialized) struct StickerLibraryTests {
    @Test func everyStickerIsNamedAndUnique() {
        let all = Registries.stickers.all.filter { $0.id.hasPrefix("valse.") }
        #expect(all.count >= 150)
        #expect(Set(all.map(\.id)).count == all.count)
        let en = L10n.load("en", from: [EffectsResources.bundle]), fr = L10n.load("fr", from: [EffectsResources.bundle])
        for s in all { #expect(en[s.nameKey] != nil && fr[s.nameKey] != nil && fr[s.groupKey] != nil, "\(s.id)") }
    }

    @Test func everyVectorStickerDrawsSomething() {
        for s in Registries.stickers.all {
            guard case .vector(let layers) = s.source else { continue }
            let img = VectorStickerRenderer.image(layers, px: 64)
            #expect(img != nil, "\(s.id)")
            guard let img else { continue }
            let bm = Bitmap(img)
            var covered = 0
            for y in 0..<bm.height { for x in 0..<bm.width where bm.pixel(x, y).a > 0.5 { covered += 1 } }
            #expect(covered > 64 * 64 / 50, "\(s.id) draws almost nothing (\(covered) px)")
        }
    }

    /// `VALSE_FX_SHEET=<dir>`: stickers.png contact sheet of the vector stickers (dark background).
    @Test func writesStickerSheet() {
        guard let dir = ProcessInfo.processInfo.environment["VALSE_FX_SHEET"] else { return }
        let vec = Registries.stickers.all.compactMap { s -> [VectorLayer]? in if case .vector(let l) = s.source { return l }; return nil }
        let cols = 12, t = 96, rows = (vec.count + cols - 1) / cols
        let ctx = CGContext(data: nil, width: cols * t, height: rows * t, bitsPerComponent: 8, bytesPerRow: cols * t * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.3, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: cols * t, height: rows * t))
        for (i, l) in vec.enumerated() {
            if let img = VectorStickerRenderer.image(l, px: t - 8) {
                ctx.draw(img, in: CGRect(x: (i % cols) * t + 4, y: (rows - 1 - i / cols) * t + 4, width: t - 8, height: t - 8))
            }
        }
        if let img = ctx.makeImage() { Bitmap(img).writePNG(URL(fileURLWithPath: dir).appendingPathComponent("stickers.png")) }
    }

    @Test func shapeStickerCompositesSharplyInItsColour() async throws {
        var p = TestProject(canvas: Size2(320, 180), background: .black)
        let c = Clip(content: .sticker(id: "valse.sticker.shape.circle.yellow"), start: 0, duration: 2)
        try TimelineOps.insert(c, into: &p.project)
        let img = try await p.render(at: 0.5)
        #expect(img[0.5, 0.5].isClose(to: RGBA(hex: 0xFFD400), tolerance: 0.1))
        #expect(img[0.05, 0.05].isClose(to: .black))
        let heart = Clip(content: .sticker(id: "valse.sticker.heartPink"), start: 0, duration: 2)
        var q = TestProject(background: .black)
        try TimelineOps.insert(heart, into: &q.project)
        let h = try await q.render(at: 0.5)[0.5, 0.5]
        #expect(h.r > 0.7 && h.g < 0.5)
    }
}
