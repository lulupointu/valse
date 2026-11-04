import Testing
import Foundation
import CoreGraphics
import ValseCore
import ValseEffects
@testable import ValseEngine

/// TX-BUBBLE-TAIL: dragging a bubble's tail tip on the canvas — the base re-anchors on the outline nearest to the
/// tip, the length follows the distance, the tip lands where it was dropped; no free tip = the side / length placement.
@Suite struct BubbleTailDragTests {
    static let fontPx: CGFloat = 60

    func text(_ style: TextBubbleStyle, _ s: String = "Hello there") -> TextContent {
        var t = TextContent(string: s, fontSize: 0.1); t.bold = true; t.bubbleStyle = style; return t
    }

    func info(_ style: TextBubbleStyle) throws -> TextScene.BubbleTail {
        let sc = TextSceneBuilder.build(text(style), fontPx: Self.fontPx, canvasWidthPx: 1080, duration: 4, dynamic: false)
        return try #require(sc.bubbleTail)
    }

    func style(_ f: TextBubbleStyle.Family, _ kind: TextBubbleTail.Kind = .point, side: TextBubbleTail.Side = .bottom) -> TextBubbleStyle {
        var s = TextBubbleStyle.blank(f); s.tail = TextBubbleTail(side: side, kind: kind); return s
    }

    func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    /// Drags `s`'s tail to `target` and returns the new style.
    func dragged(_ s: TextBubbleStyle, _ bt: TextScene.BubbleTail, to target: CGPoint) throws -> TextBubbleStyle {
        var n = s
        n.tail = try #require(BubblePainter.draggedTail(s, rect: bt.rect, em: bt.em, to: target))
        return n
    }

    @Test func boxBaseAnchorsOnTheNearestEdgeAndTheTipLandsOnTheTarget() throws {
        let s = style(.box)
        let bt = try info(s)
        let r = BubblePainter.shapeRect(s, bt.rect, em: bt.em)
        // below, right of centre → bottom edge, base under the target
        let below = CGPoint(x: r.midX + r.width * 0.2, y: r.maxY + 50)
        let n1 = try dragged(s, bt, to: below)
        let a1 = try #require(BubblePainter.tailAnchor(n1, rect: bt.rect, em: bt.em))
        #expect(dist(a1.tip, below) < 0.01)
        #expect(abs(a1.base.y - r.maxY) < 0.01)
        #expect(abs(a1.base.x - below.x) < 0.01)
        #expect(abs(n1.tail!.length * Double(bt.em) - Double(dist(a1.base, below))) < 0.01)
        #expect(n1.tail!.side == .bottom || n1.tail!.side == .bottomRight)
        // the path reaches the tip
        let pb = BubblePainter.path(n1, rect: bt.rect, em: bt.em).boundingBoxOfPath
        #expect(abs(pb.maxY - below.y) < 0.5)
        // right of the box, slightly above the middle → right edge
        let right = CGPoint(x: r.maxX + 40, y: r.midY - 4)
        let n2 = try dragged(s, bt, to: right)
        let a2 = try #require(BubblePainter.tailAnchor(n2, rect: bt.rect, em: bt.em))
        #expect(abs(a2.base.x - r.maxX) < 0.01)
        #expect(dist(a2.tip, right) < 0.01)
        #expect(n2.tail!.side == .right)
        // far left of the box's end, above: the base slides only between the corners
        let far = CGPoint(x: r.minX - 300, y: r.minY - 400)
        let n3 = try dragged(s, bt, to: far)
        let a3 = try #require(BubblePainter.tailAnchor(n3, rect: bt.rect, em: bt.em))
        #expect(abs(a3.base.y - r.minY) < 0.01)
        #expect(a3.base.x > r.minX && a3.base.x < r.midX)
        #expect(dist(a3.tip, far) < 0.01)
    }

    @Test func curvedShapesAnchorOnTheOutline() throws {
        for f in [TextBubbleStyle.Family.oval, .circle, .cloud, .burst] {
            for kind in [TextBubbleTail.Kind.point, .curve] {
                let s = style(f, kind)
                let bt = try info(s)
                let r = BubblePainter.shapeRect(s, bt.rect, em: bt.em)
                for target in [CGPoint(x: r.maxX + 30, y: r.maxY + 40), CGPoint(x: r.minX - 60, y: r.midY), CGPoint(x: r.midX, y: r.minY - 80)] {
                    let n = try dragged(s, bt, to: target)
                    let a = try #require(BubblePainter.tailAnchor(n, rect: bt.rect, em: bt.em))
                    #expect(dist(a.tip, target) < 0.01, "\(f) \(kind) tip")
                    if f == .oval || f == .circle {   // base on the ellipse
                        let q = pow((a.base.x - r.midX) / (r.width / 2), 2) + pow((a.base.y - r.midY) / (r.height / 2), 2)
                        #expect(abs(q - 1) < 1e-6, "\(f) base on the outline")
                    }
                    // the base faces the target: closer to it than the shape centre is
                    #expect(dist(a.base, target) < dist(CGPoint(x: r.midX, y: r.midY), target), "\(f) base side")
                    let pb = BubblePainter.path(n, rect: bt.rect, em: bt.em).boundingBoxOfPath.insetBy(dx: -0.5, dy: -0.5)
                    #expect(pb.contains(target), "\(f) path reaches the tip")
                }
            }
        }
    }

    @Test func dotsEndOnTheTarget() throws {
        for f in [TextBubbleStyle.Family.box, .oval, .cloud] {
            let s = style(f, .dots, side: .bottomLeft)
            let bt = try info(s)
            let r = BubblePainter.shapeRect(s, bt.rect, em: bt.em)
            let target = CGPoint(x: r.minX - 20, y: r.maxY + 90)
            let n = try dragged(s, bt, to: target)
            let a = try #require(BubblePainter.tailAnchor(n, rect: bt.rect, em: bt.em))
            #expect(dist(a.tip, target) < 0.01, "\(f) last dot on the target")
        }
    }

    @Test func lengthFollowsTheDistanceAndLengthEditsKeepTheDirection() throws {
        let s = style(.oval)
        let bt = try info(s)
        let r = BubblePainter.shapeRect(s, bt.rect, em: bt.em)
        let near = try dragged(s, bt, to: CGPoint(x: r.maxX + 10, y: r.maxY + 10))
        let far = try dragged(s, bt, to: CGPoint(x: r.maxX + 100, y: r.maxY + 100))
        #expect(far.tail!.length > near.tail!.length * 2)
        // the Length slider with a free tip: same base and direction, tip moves along it
        var half = far
        half.tail!.length /= 2
        let a = try #require(BubblePainter.tailAnchor(far, rect: bt.rect, em: bt.em))
        let b = try #require(BubblePainter.tailAnchor(half, rect: bt.rect, em: bt.em))
        #expect(dist(a.base, b.base) < 1e-6)
        let mid = CGPoint(x: (a.base.x + a.tip.x) / 2, y: (a.base.y + a.tip.y) / 2)
        #expect(dist(b.tip, mid) < 0.01)
    }

    @Test func padSideClearsTheFreeTip() throws {
        let s = style(.box)
        let bt = try info(s)
        var n = try dragged(s, bt, to: CGPoint(x: bt.rect.maxX + 50, y: bt.rect.maxY + 50))
        #expect(n.tail?.tipOffset != nil)
        #expect(!BubblePainter.isClassic(n))
        n.tail?.side = .top
        #expect(n.tail?.tipOffset == nil)
        // back to the side placement: the tip is above the box
        let a = try #require(BubblePainter.tailAnchor(n, rect: bt.rect, em: bt.em))
        #expect(a.tip.y < bt.rect.minY)
    }

    @Test func noFreeTipKeepsTheSidePlacement() throws {
        // tailAnchor mirrors the drawn geometry: the tip is the extreme point of the path on the tail's side
        for f in [TextBubbleStyle.Family.box, .pill, .oval, .circle, .burst] {
            for side in [TextBubbleTail.Side.bottom, .top, .left, .right] {
                let s = style(f, .point, side: side)
                let bt = try info(s)
                let a = try #require(BubblePainter.tailAnchor(s, rect: bt.rect, em: bt.em))
                let pb = BubblePainter.path(s, rect: bt.rect, em: bt.em).boundingBoxOfPath
                let edge: CGFloat
                switch side {
                case .bottom: edge = abs(a.tip.y - pb.maxY)
                case .top: edge = abs(a.tip.y - pb.minY)
                case .left: edge = abs(a.tip.x - pb.minX)
                default: edge = abs(a.tip.x - pb.maxX)
                }
                #expect(edge < 0.5, "\(f) \(side)")
            }
        }
        // classic v1 presets (speech / thought): the tip handle sits at the tail end
        for d in BuiltinTextBubbles.legacy where d.style.tail != nil {
            var t = TextContent(string: "Hi", fontSize: 0.1); t.bubbleID = d.id
            let sc = TextSceneBuilder.build(t, fontPx: Self.fontPx, canvasWidthPx: 1080, duration: 4, dynamic: false)
            guard let bt = sc.bubbleTail else { continue }
            #expect(BubblePainter.isClassic(bt.style))
            let a = try #require(BubblePainter.tailAnchor(bt.style, rect: bt.rect, em: bt.em), "\(d.id)")
            let pb = BubblePainter.path(bt.style, rect: bt.rect, em: bt.em).boundingBoxOfPath.insetBy(dx: -0.5, dy: -0.5)
            #expect(pb.contains(a.tip), "\(d.id)")
            #expect(!bt.rect.insetBy(dx: -0.5, dy: -0.5).contains(a.tip), "\(d.id) tip outside the box")
        }
    }

    @Test func tipOffsetRoundTripsAndOldFilesDecode() throws {
        var t = TextBubbleTail(side: .right, kind: .curve, length: 1.4)
        t.tipOffset = Vec2(2.5, -0.75)
        let data = try JSONEncoder().encode(t)
        #expect(try JSONDecoder().decode(TextBubbleTail.self, from: data) == t)
        let old = try JSONEncoder().encode(TextBubbleTail(side: .right))
        #expect(!(String(data: old, encoding: .utf8) ?? "").contains("tipOffset"))
        #expect(try JSONDecoder().decode(TextBubbleTail.self, from: Data(#"{"side":"left","length":1}"#.utf8)).tipOffset == nil)
    }

    @Test func rasterizerMapsTheTipAroundTheLayerCentre() throws {
        let s = style(.box)
        let t = text(s)
        let canvas = Size2(1920, 1080)
        let tip = try #require(FrameRenderer.shared.text.bubbleTailTip(t, canvasSize: canvas))
        #expect(tip.y > 0)   // bottom tail: below the layer centre
        // dragging to a point lands the tip there (layer-centre space round trip)
        let target = Vec2(tip.x + 80, tip.y + 60)
        let nt = try #require(FrameRenderer.shared.text.draggedBubbleTail(t, canvasSize: canvas, to: target))
        var t2 = t
        t2.editBubble { $0.tail = nt }
        let tip2 = try #require(FrameRenderer.shared.text.bubbleTailTip(t2, canvasSize: canvas))
        #expect((tip2 - target).length < 1.1)   // the layer bounds are integral: ≤ ½ px each way
    }
}
