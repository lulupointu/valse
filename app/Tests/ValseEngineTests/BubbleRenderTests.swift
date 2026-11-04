import Testing
import Foundation
import CoreGraphics
@preconcurrency import Metal
import ValseCore
import ValseEffects
@testable import ValseEngine
import ValseTestSupport

/// TX-BUBBLE2 bubble rendering: v1 presets pixel-identical, neon glow not clipped, dashes, containment, tails, flicker
/// cells, real-time cost.
@Suite struct BubbleRenderTests {
    static let fontPx: CGFloat = 60

    func text(_ s: String, _ edit: (inout TextContent) -> Void) -> TextContent {
        var t = TextContent(string: s, fontSize: 0.1); t.bold = true; edit(&t); return t
    }

    func scene(_ t: TextContent, dynamic: Bool = false) -> TextScene {
        TextSceneBuilder.build(t, fontPx: Self.fontPx, canvasWidthPx: 1080, duration: 4, dynamic: dynamic)
    }

    func bubbleItems(_ s: TextScene) -> [TextScene.Item] {
        s.items.filter { if case .bubble = $0.kind { return true }; return false }
    }

    /// RGBA8 premultiplied bitmap of `rect` (scene space) with `draw` painting in scene space.
    func bitmap(_ rect: CGRect, _ draw: (CGContext) -> Void) -> (w: Int, h: Int, px: [UInt8]) {
        let r = rect.integral
        let w = Int(r.width), h = Int(r.height)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
            ctx.translateBy(x: -r.minX, y: -r.minY)
            draw(ctx)
        }
        return (w, h, px)
    }

    func alpha(_ b: (w: Int, h: Int, px: [UInt8]), _ x: Int, _ y: Int) -> UInt8 { b.px[(y * b.w + x) * 4 + 3] }

    // MARK: 2. v1 presets: same geometry, bounds and pixels as the v1 renderer

    @Test func legacyPresetsArePixelIdentical() {
        for d in BuiltinTextBubbles.legacy {
            #expect(BubblePainter.isClassic(d.style), "\(d.id) must use the v1 geometry")
            for (k, s) in ["Hi", "Hello world\nsecond line"].enumerated() {
                let t = text(s) { $0.bubbleID = d.id; $0.color = d.textColor; if k == 1 { $0.bubbleColor = RGBA(hex: 0x33AA66) } }
                let sc = scene(t)
                guard let it = bubbleItems(sc).first, case .bubble(_, let rect, let part) = it.kind else { Issue.record("no bubble \(d.id)"); continue }
                #expect(part == .whole)
                let em = sc.blocks[it.block].em
                // v1 renderer (TX-014): BubblePaths geometry, fill then a round-join stroke, bounds = path + stroke + 1 px
                let sw = CGFloat(d.strokeWidth) * em
                let v1Bounds = BubblePaths.bounds(d.shape, rect: rect, em: em, strokeWidth: d.stroke == nil ? 0 : sw).applying(it.transform)
                #expect(it.rect == v1Bounds, "\(d.id) bounds")
                let fill = k == 1 ? RGBA(hex: 0x33AA66) : d.fill
                let v1 = bitmap(it.rect) { ctx in
                    ctx.concatenate(it.transform)
                    let p = BubblePaths.path(d.shape, rect: rect, em: em)
                    if fill.a > 0 { ctx.addPath(p); ctx.setFillColor(TextPainter.cg(fill)); ctx.fillPath() }
                    if let st = d.stroke, sw > 0 {
                        ctx.addPath(p); ctx.setStrokeColor(TextPainter.cg(st)); ctx.setLineWidth(sw); ctx.setLineJoin(.round); ctx.strokePath()
                    }
                }
                let now = bitmap(it.rect) { TextPainter.draw(it, scene: sc, in: $0) }
                #expect(v1.px == now.px, "\(d.id)-\(k) pixels differ")
            }
        }
    }

    // MARK: 5. neon glow is inside the render bounds and visible outside the tube

    @Test func neonBubbleGlowIsNotClipped() throws {
        for id in ["valse.bubble.neonPinkPill", "valse.bubble.neonOrangeBurst", "valse.bubble.neonMarquee", "valse.bubble.neonDuo"] {
            let d = try #require(Registries.textBubbles[id])
            let sc = scene(text("Neon") { $0.bubbleID = d.id; $0.color = d.textColor })
            let it = try #require(bubbleItems(sc).first)
            guard case .bubble(let style, let rect, _) = it.kind else { continue }
            let b = bitmap(it.rect) { TextPainter.draw(it, scene: sc, in: $0) }
            var edge: UInt8 = 0
            for x in 0..<b.w { for y in [0, 1, b.h - 2, b.h - 1] { edge = max(edge, alpha(b, x, y)) } }
            for y in 0..<b.h { for x in [0, 1, b.w - 2, b.w - 1] { edge = max(edge, alpha(b, x, y)) } }
            #expect(edge <= 10, "\(id): glow clipped at the item edge (alpha \(edge))")
            // light outside the tube silhouette
            let em = sc.blocks[it.block].em
            let tube = BubblePainter.path(style, rect: rect, em: em).boundingBoxOfPath
                .insetBy(dx: -CGFloat(style.outline!.width) * em, dy: -CGFloat(style.outline!.width) * em).applying(it.transform)
            var glow = 0
            let origin = it.rect.integral.origin
            for y in 0..<b.h { for x in 0..<b.w where alpha(b, x, y) > 20 {
                if !tube.contains(CGPoint(x: origin.x + CGFloat(x) + 0.5, y: origin.y + CGFloat(y) + 0.5)) { glow += 1 }
            } }
            #expect(glow > 200, "\(id): no glow outside the outline (\(glow) px)")
        }
    }

    // MARK: 6. dashed / dotted outlines alternate along the edge

    @Test func dashedAndDottedOutlinesAlternate() throws {
        for dash in [TextBubbleOutline.Dash.dashed, .dotted] {
            var s = TextBubbleStyle(family: .box, cornerRadius: 0.1, fill: .clear, outline: TextBubbleOutline(color: .white, width: 0.06, dash: dash))
            s.padding = Vec2(0.45, 0.3)
            let sc = scene(text("Dashes dashes") { $0.bubbleStyle = s })
            let it = try #require(bubbleItems(sc).first)
            guard case .bubble(_, let rect, _) = it.kind else { continue }
            let b = bitmap(it.rect) { TextPainter.draw(it, scene: sc, in: $0) }
            // top edge of the box, in bitmap pixels
            let top = CGPoint(x: rect.minX, y: rect.minY).applying(it.transform)
            let y = Int((top.y - it.rect.integral.minY).rounded(.down))
            let x0 = Int(top.x - it.rect.integral.minX) + 20, x1 = Int(CGPoint(x: rect.maxX, y: 0).applying(it.transform).x - it.rect.integral.minX) - 20
            var runs = 0, last = false
            for x in x0..<x1 {
                let on = alpha(b, x, max(min(y, b.h - 1), 0)) > 128
                if on != last { runs += 1; last = on }
            }
            #expect(runs >= 8, "\(dash): only \(runs) on/off changes along the edge")
        }
    }

    // MARK: 7. the shape contains every glyph of a 6-line text

    @Test func shapesContainMultiLineText() {
        let six = "First line\nsecond\nthird line here\nfour\nfifth line\nsix"
        for f in [TextBubbleStyle.Family.box, .pill, .oval, .cloud, .burst] {
            var s = TextBubbleStyle(family: f, cornerRadius: 0.9, fill: .white, containsText: true)
            s.padding = f.canContain ? Vec2(0.25, 0.12) : Vec2(0.45, 0.3)
            if f == .burst { s.setEdge(.wild) }
            let sc = scene(text(six) { $0.bubbleStyle = s })
            guard let it = bubbleItems(sc).first, case .bubble(let st, let rect, _) = it.kind else { Issue.record("no bubble \(f)"); continue }
            let p = BubblePainter.path(st, rect: rect, em: sc.blocks[it.block].em)
            var outside = 0
            for c in sc.blocks[it.block].layout.clusters where !c.isWhitespace {
                let r = c.box.applying(c.transform)
                for q in [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
                where !p.contains(q) { outside += 1 }
            }
            #expect(outside == 0, "\(f): \(outside) glyph corners outside the shape")
        }
    }

    // MARK: 8. the tail side moves the bounds, never the text

    @Test func tailSideMovesBoundsNotText() throws {
        func make(_ side: TextBubbleTail.Side?, _ f: TextBubbleStyle.Family) -> TextScene {
            var s = TextBubbleStyle(family: f, fill: .white, containsText: true)
            s.tail = side.map { TextBubbleTail(side: $0, kind: .curve) }
            return scene(text("Tail test") { $0.bubbleStyle = s })
        }
        for f in [TextBubbleStyle.Family.box, .pill, .oval, .cloud, .burst] {
            let none = make(nil, f), bottom = make(.bottom, f), top = make(.top, f), right = make(.right, f), left = make(.bottomLeft, f)
            let r0 = try #require(bubbleItems(none).first).rect
            let rb = try #require(bubbleItems(bottom).first).rect, rt = try #require(bubbleItems(top).first).rect
            let rr = try #require(bubbleItems(right).first).rect, rl = try #require(bubbleItems(left).first).rect
            #expect(rb.maxY > r0.maxY + 10 && abs(rb.minY - r0.minY) < 2, "\(f) bottom tail")
            #expect(rt.minY < r0.minY - 10 && abs(rt.maxY - r0.maxY) < 2, "\(f) top tail")
            #expect(rr.maxX > r0.maxX + 10, "\(f) right tail")
            #expect(rl.maxY > r0.maxY + 10, "\(f) bottom-left tail")
            for s in [bottom, top, right, left] {
                #expect(abs(s.textBounds.midX - none.textBounds.midX) < 0.01 && abs(s.textBounds.midY - none.textBounds.midY) < 0.01)
                #expect(abs(s.bounds.midX - none.textBounds.midX) < 0.01 && abs(s.bounds.midY - none.textBounds.midY) < 0.01)
            }
        }
        // dots: separate circles beyond the shape
        var s = TextBubbleStyle(family: .cloud, fill: .white, containsText: true)
        s.tail = TextBubbleTail(side: .bottomRight, kind: .dots)
        let sc = scene(text("Dots") { $0.bubbleStyle = s })
        let base = scene(text("Dots") { var b = s; b.tail = nil; $0.bubbleStyle = b })
        #expect(try #require(bubbleItems(sc).first).rect.maxY > (try #require(bubbleItems(base).first)).rect.maxY + 5)
    }

    // MARK: flicker: glow and tube are their own (flickering) cells; static bubbles stay one item

    @Test func flickeringNeonSplitsIntoCells() throws {
        let f = scene(text("Open") { $0.bubbleID = "valse.bubble.neonFlicker" }, dynamic: true)
        let items = bubbleItems(f)
        #expect(items.count == 3 && f.hasFlicker)
        #expect(items.map(\.flicker) == [.broken, .off, .broken])
        let st = scene(text("Open") { $0.bubbleID = "valse.bubble.neonPinkPill" }, dynamic: true)
        #expect(bubbleItems(st).count == 1 && !st.hasFlicker)
        // lit tube at rest: the static image of the flickering preset matches a non-flickering copy
        var edited = try #require(Registries.textBubbles["valse.bubble.neonFlicker"]).style
        edited.outline?.neon?.flicker = .off
        let a = TextRasterizer.image(text("Open") { $0.bubbleID = "valse.bubble.neonFlicker" }, fontPx: 60)
        let b = TextRasterizer.image(text("Open") { $0.bubbleStyle = edited }, fontPx: 60)
        #expect(a != nil && a?.width == b?.width && a?.height == b?.height)
    }

    // MARK: perf: static bubbles rasterize once; a flickering one stays within the text-layer budget

    @Test func neonBubbleRendersInRealTime() {
        for (name, id) in [("static", "valse.bubble.neonNightSign"), ("flicker", "valse.bubble.neonFlicker")] {
            var p = Project(name: "b", settings: ProjectSettings(canvasSize: Size2(1920, 1080), frameRate: .fps30, backgroundColor: .black))
            var t = TextContent(string: "Neon bubble at 1080p", fontSize: 0.08); t.bubbleID = id
            try! TimelineOps.insert(Clip(content: .text(t), start: 0, duration: Time(10)), into: &p)
            let r = FrameRenderer()
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1920, height: 1080, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
            let out = MetalContext.shared.device.makeTexture(descriptor: d)!
            func frame(_ i: Int) -> (cpu: Double, gpu: Double) {
                let f = FrameEvaluator.evaluate(p, at: Time(Double(i) / 30))
                let c0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                let cmd = MetalContext.shared.queue.makeCommandBuffer()!
                r.encode(f, media: [:], sources: DictionarySourceProvider([:]), output: out, commandBuffer: cmd)
                cmd.commit()
                let cpu = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - c0) / 1e6
                cmd.waitUntilCompleted()
                return (cpu, max(0, cmd.gpuEndTime - cmd.gpuStartTime) * 1000)
            }
            _ = frame(0)
            let before = r.text.rasterizationCount
            let n = 30
            var cost: [Double] = []
            for i in 1...n { let c = frame(i); cost.append(c.cpu + c.gpu) }
            let median = cost.sorted()[n / 2]
            TimingBudget.metric("unit_text_bubble_\(name)_frame_ms", median, "ms")
            #expect(r.text.rasterizationCount == before, "\(name): bubble re-rasterized during playback")
            #expect(median < TimingBudget.cpuLimit(16), "\(name) neon bubble costs \(median) ms CPU+GPU per frame")
        }
    }
}
