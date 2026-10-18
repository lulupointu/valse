import Testing
import Foundation
import CoreGraphics
import MontageCore
@testable import MontageUI

/// On-canvas mask handles (W2-1): mask frame mapping, hit-testing and edits back into layer units.
struct MaskHandlesTests {
    func geometry(center: Vec2 = Vec2(960, 540), half: Vec2 = Vec2(960, 540), rotation: Double = 0) -> LayerGeometry {
        var g = LayerGeometry(sourceSize: Size2(2, 2), canvasSize: Size2(1920, 1080), transform: Transform(), fitsCanvas: false)
        g.center = center; g.halfSize = half; g.rotation = rotation
        return g
    }

    @Test func frameMatchesShaderMapping() {
        let m = Mask(shape: .rectangle, center: Vec2(0.25, -0.1), size: Vec2(0.5, 0.5), rotation: 90)
        let f = MaskFrame(layer: geometry(), mask: m)
        #expect(abs(f.center.x - (960 + 480)) < 1e-9 && abs(f.center.y - (540 - 108)) < 1e-9)
        #expect(abs(f.half.x - 480) < 1e-9 && abs(f.half.y - 270) < 1e-9)
        #expect(abs(f.rotation - .pi / 2) < 1e-9)
        let p = Vec2(1000, 400)
        let back = f.toCanvas(f.toLocal(p))
        #expect((back - p).length < 1e-9)
        // a rotated layer rotates the mask centre offset with it
        let r = MaskFrame(layer: geometry(rotation: .pi / 2), mask: Mask(shape: .circle, center: Vec2(0.25, 0)))
        #expect(abs(r.center.x - 960) < 1e-6 && abs(r.center.y - (540 + 480)) < 1e-6)
    }

    @Test func hitTestFindsButtonsHandlesAndBody() {
        let f = MaskFrame(layer: geometry(), mask: Mask(shape: .rectangle))
        let vs = 0.5
        #expect(f.hit(f.rotateButton(viewScale: vs), viewScale: vs) == .rotate)
        #expect(f.hit(f.featherButton(viewScale: vs), viewScale: vs) == .feather)
        #expect(f.hit(f.roundnessButton(viewScale: vs), viewScale: vs) == .roundness)
        #expect(f.hit(f.corners[3], viewScale: vs) == .corner(3))
        #expect(f.hit(f.edges()[1].1, viewScale: vs) == .edge(1))
        #expect(f.hit(f.center, viewScale: vs) == .body)
        #expect(f.hit(Vec2(10, 10), viewScale: vs) == nil)
        // circles have no round-corner button, linear masks have no box handles
        let c = MaskFrame(layer: geometry(), mask: Mask(shape: .circle))
        #expect(c.hit(c.roundnessButton(viewScale: vs), viewScale: vs) != .roundness)
        let l = MaskFrame(layer: geometry(), mask: Mask(shape: .linear))
        #expect(l.edges().isEmpty && !l.hasBox)
        #expect(l.hit(Vec2(200, 540), viewScale: vs) == .body)
    }

    @Test func editsConvertBackToLayerUnits() {
        let f = MaskFrame(layer: geometry(), mask: Mask(shape: .rectangle))
        let moved = f.movedCenter(.zero, by: Vec2(192, -108))
        #expect(abs(moved.x - 0.1) < 1e-9 && abs(moved.y + 0.1) < 1e-9)
        let s = f.resized(Vec2(0.5, 0.5), handle: .corner(3), to: Vec2(960 + 960 * 0.8, 540 + 540 * 0.2), keepAspect: false)
        #expect(abs(s.x - 0.8) < 1e-9 && abs(s.y - 0.2) < 1e-9)
        let e = f.resized(Vec2(0.5, 0.5), handle: .edge(1), to: Vec2(960 + 96, 900), keepAspect: false)
        #expect(abs(e.x - 0.1) < 1e-9 && e.y == 0.5)
        let k = f.resized(Vec2(0.5, 0.25), handle: .corner(0), to: Vec2(0, 540 - 54), keepAspect: true)
        #expect(abs(k.x / k.y - 2) < 1e-9)
        let r = f.rotated(0, start: Vec2(960, 900), current: Vec2(600, 540), snapping: true)
        #expect(r == 90)
        #expect(MaskFrame.dragged(0.2, dy: -30) > 0.2 && MaskFrame.dragged(0.2, dy: 300) == 0)
    }

    /// W2-6: the oscilloscope puts a flat colour's luma / channels at the right level (top row = white).
    @Test func scopeLevels() throws {
        // 4×2 image: pure white on the left half, pure red on the right
        var px: [UInt8] = []
        for _ in 0..<2 { for x in 0..<4 { px += x < 2 ? [255, 255, 255, 255] : [255, 0, 0, 255] } }
        let wf = try #require(ScopeAnalyzer.image(rgba: px, width: 4, height: 2, mode: .waveform))
        #expect(wf.width == 4 && wf.height == ScopeAnalyzer.levels)
        let parade = try #require(ScopeAnalyzer.image(rgba: px, width: 4, height: 2, mode: .parade))
        #expect(parade.width == 12)
        func alpha(_ img: CGImage, _ x: Int, _ y: Int) -> UInt8 {
            let d = img.dataProvider!.data! as Data
            return d[(y * img.width + x) * 4 + 3]
        }
        #expect(alpha(wf, 0, 0) > 0)                                       // white → top row
        let redLuma = Int((0.2126 * Double(ScopeAnalyzer.levels - 1)).rounded())
        #expect(alpha(wf, 3, ScopeAnalyzer.levels - 1 - redLuma) > 0 && alpha(wf, 3, 0) == 0)
        #expect(alpha(parade, 3, 0) > 0 && alpha(parade, 4 + 3, ScopeAnalyzer.levels - 1) > 0)   // R full, G zero for red
        #expect(ScopeAnalyzer.image(rgba: px, width: 4, height: 2, mode: .off) == nil)
    }

    /// W2-7: text edge pills sit on the left/right midpoints and set the wrap width (fraction of the canvas width).
    @Test func textEdgePillsSetBoxWidth() {
        let g = geometry(half: Vec2(200, 50))
        let pills = CanvasHandles.edgePills(g)
        #expect(pills.map(\.0) == [1, 3] && abs(pills[0].1.x - 1160) < 1e-9)
        #expect(CanvasHandles.hit(g, isText: true, at: pills[0].1, viewScale: 0.5) == .edge(1))
        #expect(CanvasHandles.hit(g, isText: false, at: pills[0].1, viewScale: 0.5) == .body)
        let w = CanvasHandles.textBoxWidth(g, dragTo: Vec2(960 + 480, 540), layerScale: 2, canvasWidth: 1920)
        #expect(abs(w - 0.25) < 1e-9)
    }

    @Test func textAndPenMasksGetBoxHandlesAndPenPoints() {
        let vs = 0.5
        // text: box handles like a rectangle, no round-corner button, no points
        let t = MaskFrame(layer: geometry(), mask: Mask(shape: .text))
        #expect(t.hasBox && !t.hasRoundness && t.pointPositions.isEmpty)
        #expect(t.hit(t.corners[0], viewScale: vs) == .corner(0))
        #expect(t.hit(t.center, viewScale: vs) == .body)
        // pen: the default outline's points are handles; dragging one moves only that point (mask-box units)
        let f = MaskFrame(layer: geometry(), mask: Mask(shape: .pen))
        #expect(f.pointPositions.count == Mask.defaultPenPoints.count)
        let p0 = f.pointPositions[0]
        #expect(f.hit(p0, viewScale: vs) == .point(0))
        #expect(f.hit(f.center, viewScale: vs) == .body)
        let moved = f.movedPoint(Mask.defaultPenPoints, index: 0, to: f.toCanvas(Vec2(0, -f.half.y * 0.5)))
        #expect(abs(moved[0].x) < 1e-9 && abs(moved[0].y + 0.25) < 1e-9)
        #expect(moved[1] == Mask.defaultPenPoints[1])
        // points outside the box are clamped to twice its size
        let far = f.movedPoint(Mask.defaultPenPoints, index: 2, to: Vec2(1e6, 540))
        #expect(far[2].x == 1)
    }
}
