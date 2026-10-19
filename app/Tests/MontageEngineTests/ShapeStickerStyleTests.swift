import Testing
import Foundation
@testable import MontageCore
@testable import MontageEngine
import MontageEffects
import MontageTestSupport

/// ST-008: shape stickers take a per-clip style — fill / gradient / stroke (dashed) / corner radius / custom outline —
/// with keyframeable fill.
@Suite struct ShapeStickerStyleTests {
    func project(_ id: String = "montage.sticker.shape.rect.white", style: ShapeStickerStyle?) throws -> (TestProject, ClipID) {
        var p = TestProject(canvas: Size2(320, 180), background: .black)
        var c = Clip(content: .sticker(id: id), start: 0, duration: 4)
        c.shapeStyle = style
        try TimelineOps.insert(c, into: &p.project)
        return (p, c.id)
    }

    @Test func fillGradientAndStroke() async throws {
        // sticker square: 63 px centred → x 0.40…0.60; the rectangle shape is 0.88 × 0.64 of it
        var (p, _) = try project(style: nil)
        #expect(try await p.render(at: 1)[0.5, 0.5].isClose(to: .white))
        (p, _) = try project(style: ShapeStickerStyle(fill: .red))
        #expect(try await p.render(at: 1)[0.5, 0.5].isClose(to: .red))
        // vertical gradient: red top, blue bottom
        (p, _) = try project(style: ShapeStickerStyle(fill: .red, fillEnd: RGBA(0, 0, 1)))
        var img = try await p.render(at: 1)
        #expect(img[0.5, 0.43].r > img[0.5, 0.43].b + 0.3 && img[0.5, 0.57].b > img[0.5, 0.57].r + 0.3)
        // outline only: hollow inside, yellow on the left edge
        (p, _) = try project(style: ShapeStickerStyle(fill: nil, stroke: RGBA(1, 1, 0), strokeWidth: 0.1))
        img = try await p.render(at: 1)
        #expect(img[0.5, 0.5].luma < 0.05)
        #expect(img[0.416, 0.5].isClose(to: RGBA(1, 1, 0), tolerance: 0.15))
    }

    @Test func dashedStrokeHasGaps() async throws {
        let (p, _) = try project(style: ShapeStickerStyle(fill: nil, stroke: .white, strokeWidth: 0.06, dash: .dashed))
        let img = try await p.render(at: 1)
        // walk down the left edge: some samples lit, some dark
        let samples = stride(from: 0.42, through: 0.58, by: 0.004).map { img[0.414, $0].luma }
        #expect(samples.contains { $0 > 0.6 } && samples.contains { $0 < 0.15 })
    }

    @Test func keyframedFillAnimates() async throws {
        var (p, id) = try project(style: ShapeStickerStyle(fill: .red))
        p[id].keyframes[ParamKey.shapeFill.raw] = KeyframeTrack([Keyframe(time: 0, value: .color(.red)),
                                                                Keyframe(time: 2, value: .color(RGBA(0, 0, 1)))])
        let mid = try await p.render(at: 1)[0.5, 0.5]
        #expect(mid.r > 0.25 && mid.b > 0.25)
        #expect(try await p.render(at: 2)[0.5, 0.5].isClose(to: RGBA(0, 0, 1)))
    }

    @Test func customOutlineReplacesTheShape() async throws {
        // a triangle pointing down: top corners lit, bottom corners of the square dark
        let tri = [Vec2(0.1, 0.1), Vec2(0.9, 0.1), Vec2(0.5, 0.9)]
        let (p, _) = try project(style: ShapeStickerStyle(fill: .white, points: tri))
        let img = try await p.render(at: 1)
        #expect(img[0.5, 0.42].luma > 0.8)              // top middle (inside)
        #expect(img[0.41, 0.58].luma < 0.1)             // bottom-left of the square (outside)
        // the custom shape sticker exists and starts as a blob
        #expect(Registries.stickers[BuiltinStickers.customShapeID] != nil)
    }

    @Test func styledLayersFromTheStickerLook() throws {
        let base = [VectorLayer(.ring, stroke: .white, strokeWidth: 0.09)]
        #expect(base[0].isStrokeOnly && base[0].shapeStyle.fill == nil && base[0].shapeStyle.stroke == .white)
        var s = base[0].shapeStyle; s.stroke = .red; s.dash = .dotted
        let l = VectorLayer.styled(base, s)[0]
        #expect(l.fill == nil && l.stroke == .red && l.dash == [0, 0.18])
        let filled = VectorLayer.styled([VectorLayer(.circle, fill: .white)], ShapeStickerStyle(fill: .red, stroke: .white, strokeWidth: 0.1))[0]
        #expect(filled.inset >= 0.06 - 1e-9 && filled.strokeWidth == 0.1)
        // Codable round trip on the clip
        var c = Clip(content: .sticker(id: "x"), start: 0, duration: 1)
        c.shapeStyle = ShapeStickerStyle(fill: .red, fillEnd: .white, dash: .dashed, cornerRadius: 0.2, points: [Vec2(0, 0), Vec2(1, 0), Vec2(0, 1)])
        let back = try JSONDecoder().decode(Clip.self, from: try JSONEncoder().encode(c))
        #expect(back.shapeStyle == c.shapeStyle)
    }
}
