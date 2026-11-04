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

    // MARK: 5b. TX-NEON: tube cross-section = the owner's reference sign, for every hue

    /// A straight neon tube (default bubble neon, tube T = 0.098 em at 97 px, as in the reference) sampled across:
    /// near-white core, halo in the tube colour ≈ 0.55 at half a tube width beyond the edge, fading smoothly to nothing
    /// ~3.5 T out (reference values, normalised to the colour's brightest channel, ± 0.09), for each swatch colour.
    @Test func neonTubeMatchesTheReferenceProfile() {
        let em: CGFloat = 97, T: CGFloat = 0.098 * em
        // (distance beyond the tube edge in tube widths, reference level)
        let ref: [(CGFloat, Double)] = [(0.5, 0.55), (1.25, 0.37), (1.75, 0.25), (2.25, 0.14), (2.75, 0.06), (3.6, 0)]
        for s in TextNeonStyle.swatches {
            var o = TextBubbleOutline(color: s.color, width: 0.098, neon: TextBubbleOutline.neonStyle())
            o.tubeBreak = false
            let n = BubblePainter.neonStyle(o)!
            var pr = NeonPainter.Params(n, em: em); pr.stroked = true
            let line = CGMutablePath(); line.move(to: CGPoint(x: 0, y: 100)); line.addLine(to: CGPoint(x: 200, y: 100))
            let tube = BubblePainter.tube(line, o, em: em)
            let b = bitmap(CGRect(x: 0, y: 0, width: 200, height: 200)) { ctx in
                NeonPainter.drawHalo(tube, pr, in: ctx); NeonPainter.drawTube(tube, pr, in: ctx)
            }
            func px(_ y: Int) -> [Double] { let o = (y * b.w + 100) * 4; return (0..<3).map { Double(b.px[o + $0]) / 255 } }
            let core = px(100)
            #expect(core.min()! > 0.9, "\(s.name): core not near-white \(core)")
            let ch = [s.color.r, s.color.g, s.color.b].enumerated().max { $0.element < $1.element }!.offset
            for (e, want) in ref {
                for y in [Int((100 + T / 2 + e * T).rounded()), Int((100 - T / 2 - e * T).rounded())] {
                    let got = px(y)[ch]
                    #expect(abs(got - want) <= 0.09, "\(s.name): halo at \(e) T = \(got), reference \(want)")
                }
            }
        }
    }

    /// TX-NEON tube break: one gap with round ends near the top right of a neon outline (none with Tube break off, on a
    /// dashed outline or a plain line); the thought dots are kept.
    @Test func neonTubeBreak() throws {
        let r = CGRect(x: 0, y: 0, width: 400, height: 200)
        let ellipse = CGPath(ellipseIn: r, transform: nil)
        let x = r.midX + 0.78 * r.width / 2
        let broken = NeonPainter.broken(ellipse, x: x, gap: 30)
        var moves = 0, closes = 0, first: CGPoint?, last = CGPoint.zero
        broken.applyWithBlock { el in
            switch el.pointee.type {
            case .moveToPoint: moves += 1; if first == nil { first = el.pointee.points[0] }; last = el.pointee.points[0]
            case .closeSubpath: closes += 1
            default: last = el.pointee.points[0]
            }
        }
        #expect(moves == 1 && closes == 0, "the outline becomes one open tube")
        let a = try #require(first)
        #expect(abs(hypot(a.x - last.x, a.y - last.y) - 30) < 1.5, "gap between the cap centres")
        let mid = CGPoint(x: (a.x + last.x) / 2, y: (a.y + last.y) / 2)
        #expect(abs(mid.x - x) < 4 && mid.y < r.midY, "gap at the top right (\(mid))")
        // presets: on for neon outlines, off when unticked / dashed / not neon
        let d = try #require(Registries.textBubbles["valse.bubble.neonLimeSpeech"])
        let o = try #require(d.style.outline)
        #expect(o.tubeBreak && BubblePainter.tubeBreakX(o, r, tail: d.style.tail) != nil)
        var off = o; off.tubeBreak = false
        #expect(BubblePainter.tubeBreakX(off, r, tail: nil) == nil)
        var dashed = o; dashed.dash = .dashed
        #expect(BubblePainter.tubeBreakX(dashed, r, tail: nil) == nil)
        #expect(BubblePainter.tubeBreakX(TextBubbleOutline(color: .white), r, tail: nil) == nil)
        #expect(BubblePainter.tubeBreakX(o, r, tail: TextBubbleTail(side: .topRight))! < r.midX, "mirrored away from a top-right tail")
        // thought dots survive the break (cloud + 3 dots = 4 subpaths)
        let sc = scene(text("Hi") { $0.bubbleID = "valse.bubble.neonVioletThought" })
        let it = try #require(bubbleItems(sc).first)
        guard case .bubble(let st, let rect, _) = it.kind else { return }
        let p = BubblePainter.path(st, rect: rect, em: sc.blocks[it.block].em)
        var subs = 0
        NeonPainter.broken(p, x: BubblePainter.tubeBreakX(st.outline!, BubblePainter.shapeRect(st, rect), tail: st.tail)!, gap: 20)
            .applyWithBlock { if $0.pointee.type == .moveToPoint { subs += 1 } }
        #expect(subs == 4)
        // rendered: the tube is dark in the gap, lit either side of it
        let tubeOn = NeonPainter.broken(ellipse, x: x, gap: 40)
        let bmp = bitmap(r.insetBy(dx: -40, dy: -40)) { ctx in
            ctx.addPath(tubeOn.copy(strokingWithWidth: 8, lineCap: .round, lineJoin: .round, miterLimit: 4)); ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fillPath()
        }
        #expect(alpha(bmp, Int(mid.x) + 40, Int(mid.y) + 40) < 10)
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
        #expect(items.map(\.flicker) == [.oneLetter, .off, .oneLetter])
        #expect(items.map(\.flickerFaulty) == [true, false, true], "a neon bubble alone stutters as one faulty tube")
        let st = scene(text("Open") { $0.bubbleID = "valse.bubble.neonPinkPill" }, dynamic: true)
        #expect(bubbleItems(st).count == 1 && !st.hasFlicker)
        // lit tube at rest: the static image of the flickering preset matches a non-flickering copy
        var edited = try #require(Registries.textBubbles["valse.bubble.neonFlicker"]).style
        edited.outline?.neon?.flicker = .off
        let a = TextRasterizer.image(text("Open") { $0.bubbleID = "valse.bubble.neonFlicker" }, fontPx: 60)
        let b = TextRasterizer.image(text("Open") { $0.bubbleStyle = edited }, fontPx: 60)
        #expect(a != nil && a?.width == b?.width && a?.height == b?.height)
    }

    /// TX-NEON: One letter marks exactly one glyph (both its halo and tube items) faulty, spaces skipped; Whole text
    /// flickers every glyph and the neon bubble from one shared level.
    @Test func neonFlickerUnitsInTheScene() throws {
        let one = scene(text("NEON BAR") { $0.neon = TextNeonStyle(flicker: .oneLetter) }, dynamic: true)
        let faulty = one.items.filter(\.flickerFaulty)
        #expect(one.hasFlicker && faulty.count == 2 && faulty.allSatisfy { $0.char == 4 })
        var s = try #require(Registries.textBubbles["valse.bubble.neonPinkPill"]).style
        s.outline?.neon?.flicker = .wholeText
        let whole = scene(text("NEON BAR") {
            $0.neon = TextNeonStyle(flicker: .wholeText)
            $0.bubbleID = "valse.bubble.neonPinkPill"
            $0.bubbleStyle = s
        }, dynamic: true)
        let lit = whole.items.filter { $0.flicker == .wholeText }
        #expect(lit.count == 7 * 2 + 2)
        // one level for all of them at any time
        for t in stride(from: 0.0, to: 30, by: 1.0 / 30) {
            let ls = Set(lit.map { TextNeonStyle.flickerLevel($0.flicker, t: t, faulty: $0.flickerFaulty, seed: whole.flickerSeed) })
            #expect(ls.count == 1)
        }
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

    // MARK: 9. padding: 0 = the oval touches the text box; negative padding = a smaller shape, never collapsed

    @Test func ovalAtZeroPaddingTouchesTheTextBox() throws {
        for (str, f) in [("Default text", TextBubbleStyle.Family.oval), ("Hi", .oval), ("A\nB\nC\nD", .oval), ("Default text", .cloud)] {
            var s = TextBubbleStyle(family: f, fill: .white, containsText: true)
            s.padding = Vec2(0, 0)
            let sc = scene(text(str) { $0.bubbleStyle = s })
            let it = try #require(bubbleItems(sc).first)
            guard case .bubble(_, let rect, _) = it.kind else { Issue.record("no bubble"); continue }
            #expect(rect == sc.blocks[it.block].layout.bounds, "padding 0 = the text box")
            let e = BubblePainter.shapeRect(s, rect)
            let a = rect.width / 2, b = rect.height / 2, rx = e.width / 2, ry = e.height / 2
            #expect(abs(a * a / (rx * rx) + b * b / (ry * ry) - 1) < 1e-3, "\(str): the ellipse passes through the text box corners")
            #expect(max(rx / ry, ry / rx) <= 3 + 1e-6)
            // wide text: tighter than the v0.6 fit (rx = a·√2, ry = max(b·√2, rx/3)), on both axes
            let oldRx = a * sqrt(2), oldRy = max(b * sqrt(2), oldRx / 3)
            if str == "Default text" { #expect(rx < oldRx * 0.9 && ry < oldRy * 0.9, "\(str): \(rx)×\(ry) vs \(oldRx)×\(oldRy)") }
        }
    }

    @Test func negativePaddingShrinksTheShape() throws {
        func bounds(_ str: String, _ pad: Vec2, _ f: TextBubbleStyle.Family) throws -> (rect: CGRect, em: CGFloat) {
            var s = TextBubbleStyle(family: f, fill: .white, containsText: true)
            s.padding = pad
            let sc = scene(text(str) { $0.bubbleStyle = s })
            let it = try #require(bubbleItems(sc).first)
            guard case .bubble(let st, let rect, _) = it.kind else { throw CancellationError() }
            return (BubblePainter.path(st, rect: rect, em: sc.blocks[it.block].em).boundingBoxOfPath, sc.blocks[it.block].em)
        }
        for f in [TextBubbleStyle.Family.box, .pill, .oval, .cloud, .burst, .hexagon] {
            let zero = try bounds("Default text", Vec2(0, 0), f).rect, neg = try bounds("Default text", Vec2(-0.2, -0.2), f).rect
            #expect(neg.width < zero.width - 1 && neg.height < zero.height - 1, "\(f): \(neg) vs \(zero)")
            let tiny = try bounds("i", Vec2(TextBubbleStyle.minPadding, TextBubbleStyle.minPadding), f)
            #expect(tiny.rect.width >= tiny.em * 0.4 - 0.5 && tiny.rect.height >= tiny.em * 0.4 - 0.5, "\(f) never collapses: \(tiny.rect)")
        }
        // H and V are independent
        let wide = try bounds("Default text", Vec2(0.5, 0), .box).rect, tall = try bounds("Default text", Vec2(0, 0.5), .box).rect
        #expect(wide.width > tall.width && wide.height < tall.height)
    }

    // MARK: 10. circle: w == h, contains the text, obeys max(H, V) padding (negative too), carries a tail

    @Test func circleIsRoundAndContainsTheText() throws {
        func make(_ str: String, _ pad: Vec2, tail: Bool = false) throws -> (path: CGPath, shape: CGRect, scene: TextScene, block: Int) {
            var s = TextBubbleStyle(family: .circle, fill: .white, containsText: true)
            s.padding = pad
            if tail { s.tail = TextBubbleTail(side: .bottomLeft, kind: .curve) }
            let sc = scene(text(str) { $0.bubbleStyle = s })
            let it = try #require(bubbleItems(sc).first)
            guard case .bubble(let st, let rect, _) = it.kind else { throw CancellationError() }
            let em = sc.blocks[it.block].em
            return (BubblePainter.path(st, rect: rect, em: em), BubblePainter.shapeRect(st, rect, em: em), sc, it.block)
        }
        for str in ["Default text", "Hi", "One\ntwo\nthree lines"] {
            let c = try make(str, Vec2(0.12, 0.12))
            #expect(abs(c.shape.width - c.shape.height) < 0.01, "\(str): a circle")
            let b = c.path.boundingBoxOfPath
            #expect(abs(b.width - b.height) < 1, "\(str): drawn round \(b)")
            var outside = 0
            for cl in c.scene.blocks[c.block].layout.clusters where !cl.isWhitespace {
                let r = cl.box.applying(cl.transform)
                for q in [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
                where !c.path.contains(q) { outside += 1 }
            }
            #expect(outside == 0, "\(str): \(outside) glyph corners outside the circle")
            // padding 0: the circle passes through the text box corners
            let z = try make(str, Vec2(0, 0))
            let lb = z.scene.blocks[z.block].layout.bounds
            #expect(abs(z.shape.width / 2 - hypot(lb.width / 2, lb.height / 2)) < 0.01)
        }
        let em = try make("Hi", Vec2(0, 0)).scene.blocks[0].em
        let base = try make("Default text", Vec2(0, 0)).shape.width
        #expect(abs(try make("Default text", Vec2(0.3, 0.1)).shape.width - (base + 0.6 * em)) < 0.01, "max(H, V) padding")
        #expect(try make("Default text", Vec2(-0.2, -0.2)).shape.width < base - 0.3 * em, "negative padding tightens it")
        // a tail reaches out of the circle
        let plain = try make("Hi", Vec2(0.12, 0.12)).path.boundingBoxOfPath, tailed = try make("Hi", Vec2(0.12, 0.12), tail: true).path.boundingBoxOfPath
        #expect(tailed.maxY > plain.maxY + 0.3 * em && tailed.minX < plain.minX + 1)
    }

    // MARK: contact sheet (VALSE_SNAPSHOT_DIR=…): every TX-BUBBLE2 preset, then oval / cloud / burst at padding 0 and −0.3

    @Test func contactSheet() {
        guard let dir = ProcessInfo.processInfo.environment["VALSE_SNAPSHOT_DIR"] else { return }
        var cells: [TextContent] = BuiltinTextBubbles.added.map { d in text("Default text") { $0.bubbleID = d.id; $0.color = d.textColor } }
        for f in [TextBubbleStyle.Family.oval, .circle, .cloud, .burst, .pill, .hexagon] {
            for p in [Vec2(0, 0), Vec2(-0.3, -0.3)] {
                var s = TextBubbleStyle(family: f, fill: RGBA(1, 1, 1, 0.25), outline: TextBubbleOutline(color: .white, width: 0.04), containsText: true)
                s.padding = p
                cells.append(text("Default text") { $0.bubbleStyle = s })
            }
        }
        let cw = 640, ch = 260, cols = 5, rows = (cells.count + cols - 1) / cols
        let ctx = CGContext(data: nil, width: cw * cols, height: ch * rows, bitsPerComponent: 8, bytesPerRow: cw * cols * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.18, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: cw * cols, height: ch * rows))
        for (i, t) in cells.enumerated() {
            let sc = scene(t)
            let lb = sc.blocks[0].layout.bounds.applying(sc.blocks[0].transform)
            ctx.saveGState()
            // y-down scene, cell i at column i % cols, row i / cols (from the top)
            ctx.translateBy(x: CGFloat(i % cols * cw), y: CGFloat(ch * rows - i / cols * ch))
            ctx.scaleBy(x: 1, y: -1)
            ctx.translateBy(x: CGFloat(cw) / 2 - lb.midX, y: CGFloat(ch) / 2 - lb.midY)
            TextPainter.drawStatic(sc, in: ctx)
            ctx.setStrokeColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.6)); ctx.setLineWidth(1); ctx.stroke(lb)
            ctx.restoreGState()
        }
        Bitmap(ctx.makeImage()!).writePNG(URL(fileURLWithPath: dir).appendingPathComponent("bubble-contact-sheet.png"))
    }
}
