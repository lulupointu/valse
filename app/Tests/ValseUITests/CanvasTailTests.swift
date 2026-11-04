import Testing
import Foundation
import CoreGraphics
import ValseCore
import ValseEngine
import ValseEffects
@testable import ValseUI
import ValseTestSupport

/// TX-BUBBLE-TAIL: the canvas tail handle — placement through the layer's rotation / scale / flips, hit priority.
struct CanvasTailTests {
    let canvas = Size2(1920, 1080)

    @Test func tailFrameRoundTripsThroughRotationScaleAndFlips() {
        let t = TextContent(string: "x")
        for (rot, scale) in [(0.0, Vec2(1, 1)), (0.7, Vec2(1.8, 1.8)), (-2.1, Vec2(-0.6, 1.3))] {
            let f = CanvasTail(center: Vec2(700, 400), rotation: rot, scale: scale, localTip: Vec2(30, 80), text: t)
            let p = Vec2(123, 987)
            let back = f.toCanvas(f.toLocal(p))
            #expect((back - p).length < 1e-9)
            // distance from the centre scales with the layer
            #expect(abs((f.tip - f.center).length - (Vec2(30 * scale.x, 80 * scale.y)).length) < 1e-9)
        }
        // 90° clockwise: a tip below the centre goes to its left
        let f = CanvasTail(center: Vec2(500, 500), rotation: .pi / 2, scale: .one, localTip: Vec2(0, 100), text: t)
        #expect((f.tip - Vec2(400, 500)).length < 1e-9)
    }

    @Test func tailHandleBeatsCornersAndBody() {
        var g = LayerGeometry(sourceSize: Size2(2, 2), canvasSize: canvas, transform: Transform(), fitsCanvas: false)
        g.center = Vec2(500, 500); g.halfSize = Vec2(100, 50)
        let s = 0.5
        let corner = g.corners[3]
        #expect(CanvasHandles.hit(g, isText: true, at: corner, viewScale: s) == .corner(3))
        #expect(CanvasHandles.hit(g, isText: true, at: corner, viewScale: s, tail: corner + Vec2(4, 0)) == .tail)
        let inside = Vec2(520, 510)
        #expect(CanvasHandles.hit(g, isText: true, at: inside, viewScale: s, tail: inside) == .tail)
        #expect(CanvasHandles.hit(g, isText: true, at: inside, viewScale: s, tail: Vec2(900, 900)) == .body)
    }

    @Test func canvasLayerCarriesTheTailOfARotatedScaledBubble() throws {
        var p = Project(settings: ProjectSettings(canvasSize: canvas))
        var t = TextContent(string: "Hello")
        var b = TextBubbleStyle.blank(.box); b.tail = TextBubbleTail(side: .bottom)
        t.bubbleStyle = b
        var clip = Clip(content: .text(t), start: .zero, duration: Time(3))
        clip.transform.rotation = 30
        clip.transform.scale = Vec2(1.5, 1.5)
        try TimelineOps.insert(clip, into: &p)
        let l = try #require(CanvasLayers.at(Time(1), project: p).first { $0.clipID == clip.id })
        let tail = try #require(l.tail)
        // below the text in the layer's frame = rotated 30° clockwise around its centre
        let d = tail.tip - (l.textGeometry ?? l.geometry).center
        let local = tail.toLocal(tail.tip)
        #expect(local.y > 0 && abs(local.x) < 1)
        #expect(abs(atan2(d.y, d.x) - (90 + 30) * .pi / 180) < 0.02)
        // no tail → no handle
        b.tail = nil; t.bubbleStyle = b
        var p2 = Project(settings: ProjectSettings(canvasSize: canvas))
        let c2 = Clip(content: .text(t), start: .zero, duration: Time(3))
        try TimelineOps.insert(c2, into: &p2)
        #expect(try #require(CanvasLayers.at(Time(1), project: p2).first { $0.clipID == c2.id }).tail == nil)
    }
}
