import Testing
import Foundation
import CoreGraphics
import MontageCore
import MontageEngine
@testable import MontageUI
import MontageTestSupport

/// Finisher F3 UI-layer logic.
@MainActor struct F3UITests {
    // CV-009
    @Test func distributeEqualisesGaps() {
        let canvas = Size2(1000, 500)
        // three boxes, widths 100 / 50 / 100 at x 0, 600, 900 → outer ones stay, middle centred in the free space
        let b: [(minX: Double, minY: Double, maxX: Double, maxY: Double)] = [(0, 0, 100, 10), (900, 0, 1000, 10), (600, 0, 650, 10)]
        let d = CanvasDistribute.horizontal.deltas(b, canvas: canvas)
        #expect(d[0] == .zero && d[1] == .zero)
        #expect(abs(d[2].x - (475 - 600)) < 1e-9 && d[2].y == 0)   // gap = (1000 − 250) / 2 = 375 → middle starts at 475
        // two boxes: spread across the canvas with equal margins and gap
        let two = CanvasDistribute.vertical.deltas([(0, 0, 10, 100), (0, 50, 10, 150)], canvas: canvas)
        #expect(abs(two[0].y - 100) < 1e-9 && abs(two[1].y - (300 - 50)) < 1e-9)   // gap = (500 − 200) / 3 = 100
        #expect(CanvasDistribute.horizontal.deltas([(0, 0, 1, 1)], canvas: canvas) == [.zero])
    }

    // TX-011
    @Test func textBoxResizeOneSideKeepsTheOppositeEdge() {
        let canvas = Size2(1000, 500)
        var g = LayerGeometry(sourceSize: Size2(2, 2), canvasSize: canvas, transform: Transform(), fitsCanvas: false)
        g.center = Vec2(500, 250); g.halfSize = Vec2(100, 20); g.rotation = 0
        // drag the right pill 50 px left: the left edge (x = 400) stays, width 150 px, centre moves to 475
        let r = CanvasHandles.textBoxResize(g, edge: 1, dragTo: Vec2(550, 250), fromCenter: false, layerScale: 1, canvasWidth: 1000)
        #expect(abs(r.width - 0.15) < 1e-9)
        #expect(abs(r.shift.x - -25) < 1e-9 && abs(r.shift.y) < 1e-9)
        // left pill dragged outwards to x = 350: right edge (600) stays → width 250, centre 475
        let l = CanvasHandles.textBoxResize(g, edge: 3, dragTo: Vec2(350, 250), fromCenter: false, layerScale: 1, canvasWidth: 1000)
        #expect(abs(l.width - 0.25) < 1e-9 && abs(l.shift.x - -25) < 1e-9)
        // ⌥: from the centre, the centre never moves (width = 2 × distance to the centre)
        let c = CanvasHandles.textBoxResize(g, edge: 1, dragTo: Vec2(550, 250), fromCenter: true, layerScale: 1, canvasWidth: 1000)
        #expect(abs(c.width - 0.1) < 1e-9 && c.shift == .zero)
        // rotated 90°: the box's x axis points down
        g.rotation = .pi / 2
        let rot = CanvasHandles.textBoxResize(g, edge: 1, dragTo: Vec2(500, 300), fromCenter: false, layerScale: 1, canvasWidth: 1000)
        #expect(abs(rot.width - 0.15) < 1e-9 && abs(rot.shift.y - -25) < 1e-6 && abs(rot.shift.x) < 1e-6)
        // scaled layer: width is in unscaled canvas fractions
        g.rotation = 0
        let s = CanvasHandles.textBoxResize(g, edge: 1, dragTo: Vec2(600, 250), fromCenter: false, layerScale: 2, canvasWidth: 1000)
        #expect(abs(s.width - 0.1) < 1e-9 && abs(s.shift.x) < 1e-9)
    }
}
