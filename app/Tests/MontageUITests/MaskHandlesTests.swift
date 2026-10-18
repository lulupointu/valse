import Testing
import Foundation
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
}
