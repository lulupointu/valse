import Testing
import Foundation
import CoreGraphics
@preconcurrency import Metal
import ValseCore
import ValseEffects
@testable import ValseEngine
import ValseTestSupport

/// Text engine render tests (W7): every style feature, per-glyph animation, karaoke, templates and the caches.
/// Frames are rendered straight through `FrameRenderer` (no AVFoundation) so hundreds of renders stay fast.
@Suite(.serialized) struct TextRenderTests {
    // MARK: Harness

    static let canvas = Size2(640, 360)

    /// Project with one text clip (0…duration) on a black background.
    func project(_ t: TextContent, duration: Double = 4, edit: (inout Clip) -> Void = { _ in }) -> (Project, ClipID) {
        var p = Project(name: "t", settings: ProjectSettings(canvasSize: Self.canvas, frameRate: .fps30, backgroundColor: .black))
        var c = Clip(content: .text(t), start: 0, duration: Time(duration))
        edit(&c)
        try! TimelineOps.insert(c, into: &p)
        return (p, c.id)
    }

    /// Encodes and waits for one frame (no readback) — the timed part of the perf test.
    @discardableResult
    func encode(_ p: Project, at t: Double, renderer: FrameRenderer, into out: MTLTexture) -> MTLCommandBuffer {
        let f = FrameEvaluator.evaluate(p, at: Time(t))
        let cmd = MetalContext.shared.queue.makeCommandBuffer()!
        renderer.encode(f, media: [:], sources: DictionarySourceProvider([:]), output: out, commandBuffer: cmd)
        cmd.commit()
        return cmd
    }

    func render(_ p: Project, at t: Double, renderer: FrameRenderer = .shared, function: String = #function) -> Bitmap {
        let b = renderRaw(p, at: t, renderer: renderer)
        if let dir = ProcessInfo.processInfo.environment["VALSE_TEXT_DEBUG_DIR"] {
            Self.debugCounter += 1
            b.writePNG(URL(fileURLWithPath: dir).appendingPathComponent("\(function.prefix(while: { $0 != "(" }))-\(Self.debugCounter).png"))
        }
        return b
    }

    func renderRaw(_ p: Project, at t: Double, renderer: FrameRenderer) -> Bitmap {
        let f = FrameEvaluator.evaluate(p, at: Time(t))
        let w = Int(p.settings.canvasSize.width), h = Int(p.settings.canvasSize.height)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
        let out = MetalContext.shared.device.makeTexture(descriptor: d)!
        let cmd = MetalContext.shared.queue.makeCommandBuffer()!
        renderer.encode(f, media: [:], sources: DictionarySourceProvider([:]), output: out, commandBuffer: cmd)
        cmd.commit(); cmd.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        out.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        return Bitmap(ctx.makeImage()!)
    }

    func render(_ t: TextContent, at time: Double = 1, duration: Double = 4, edit: (inout Clip) -> Void = { _ in },
                function: String = #function) -> Bitmap {
        render(project(t, duration: duration, edit: edit).0, at: time, function: function)
    }
    nonisolated(unsafe) static var debugCounter = 0

    /// Bounding box (pixels) of pixels matching `pred`.
    func box(_ b: Bitmap, _ pred: (RGBA) -> Bool) -> CGRect? {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<b.height { for x in 0..<b.width where pred(b.pixel(x, y)) {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        return maxX < 0 ? nil : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    func count(_ b: Bitmap, _ pred: (RGBA) -> Bool) -> Int {
        var n = 0
        for y in 0..<b.height { for x in 0..<b.width where pred(b.pixel(x, y)) { n += 1 } }
        return n
    }

    static func lit(_ c: RGBA) -> Bool { c.luma > 0.25 }
    static func isRed(_ c: RGBA) -> Bool { c.r > 0.6 && c.g < 0.3 && c.b < 0.3 }
    static func isGreen(_ c: RGBA) -> Bool { c.g > 0.5 && c.r < 0.35 && c.b < 0.35 }
    static func isBlue(_ c: RGBA) -> Bool { c.b > 0.6 && c.r < 0.3 && c.g < 0.35 }
    static func isYellow(_ c: RGBA) -> Bool { c.r > 0.7 && c.g > 0.6 && c.b < 0.35 }

    func text(_ s: String = "HELLO", size: Double = 0.2, _ edit: (inout TextContent) -> Void = { _ in }) -> TextContent {
        var t = TextContent(string: s, fontSize: size); t.bold = true; edit(&t); return t
    }

    // MARK: Basic style

    @Test func plainTextIsCentredAndSized() {
        let img = render(text())
        let b = box(img, Self.lit)!
        #expect(abs(b.midX - 320) < 8 && abs(b.midY - 180) < 12)
        #expect(b.height > 360 * 0.2 * 0.55 && b.height < 360 * 0.2 * 1.1)     // cap height of a 72 px font
        let bigger = box(render(text(size: 0.3)), Self.lit)!
        #expect(bigger.width > b.width * 1.3)
    }

    @Test func colorBoldItalicUnderlineCase() {
        #expect(count(render(text { $0.color = RGBA(1, 0, 0) }), Self.isRed) > 500)
        let regular = count(render(text { $0.bold = false }), Self.lit), bold = count(render(text()), Self.lit)
        #expect(bold > regular)
        // italic slants: the top of the box moves right relative to the bottom
        let it = render(text("I", size: 0.4) { $0.italic = true })
        let topRow = box(it) { Self.lit($0) }!
        let topLine = (Int(topRow.minX)..<Int(topRow.maxX)).filter { Self.lit(it.pixel($0, Int(topRow.minY) + 2)) }
        let botLine = (Int(topRow.minX)..<Int(topRow.maxX)).filter { Self.lit(it.pixel($0, Int(topRow.maxY) - 2)) }
        #expect((topLine.first ?? 0) > (botLine.first ?? 0))
        // underline adds a bar below the baseline
        let plain = box(render(text("ace")), Self.lit)!, under = box(render(text("ace") { $0.underline = true }), Self.lit)!
        #expect(under.maxY > plain.maxY + 2)
        // case
        let upper = box(render(text("abc") { $0.textCase = .upper }), Self.lit)!, lower = box(render(text("abc")), Self.lit)!
        #expect(upper.height < lower.height + 2 && upper.minY < lower.minY + 2)
    }

    @Test func letterAndLineSpacingAndAlignment() {
        let tight = box(render(text("HHHH")), Self.lit)!, wide = box(render(text("HHHH") { $0.letterSpacing = 0.3 }), Self.lit)!
        #expect(wide.width > tight.width + 40)
        let two = box(render(text("A\nB")), Self.lit)!, spaced = box(render(text("A\nB") { $0.lineSpacing = 0.5 }), Self.lit)!
        #expect(spaced.height > two.height + 20)
        // left alignment: the short line hugs the left edge of the box
        let left = render(text("WWWWW\nI") { $0.alignment = .left })
        let full = box(left, Self.lit)!
        let lower = box(left) { Self.lit($0) }.map { _ in (Int(full.minX)..<Int(full.maxX)).filter { x in
            (Int(full.midY + 6)..<Int(full.maxY)).contains { Self.lit(left.pixel(x, $0)) } } }!
        #expect((lower.first ?? 999) < Int(full.minX) + 25)
    }

    @Test func richTextRunsStyleTheirRange() {
        var t = text("AAA BBB")
        t.applyStyle(TextRunStyle(color: RGBA(1, 0, 0)), to: TextSpan(4, 3))
        let img = render(t)
        let red = box(img, Self.isRed)!, all = box(img, Self.lit)!
        #expect(red.minX > all.midX && count(img, Self.isRed) > 300)
        // size override makes the range bigger
        var big = text("ab")
        big.applyStyle(TextRunStyle(sizeScale: 2), to: TextSpan(1, 1))
        #expect(box(render(big), Self.lit)!.height > box(render(text("ab")), Self.lit)!.height * 1.4)
    }

    // MARK: Effects

    @Test func strokeIsOutsideTheGlyph() {
        let white: (RGBA) -> Bool = { $0.r > 0.9 && $0.g > 0.9 }
        let fill = count(render(text("O")), white)
        let img = render(text("O") { $0.strokeColor = RGBA(1, 0, 0); $0.strokeWidth = 0.1 })
        #expect(count(img, Self.isRed) > 300)
        #expect(count(img, white) > Int(Double(fill) * 0.85))   // white fill kept on top of the outline
    }

    @Test func multiLayerOutlines() {
        let img = render(text("O") {
            $0.strokeColor = RGBA(1, 0, 0); $0.strokeWidth = 0.05
            $0.extraStrokes = [TextStrokeLayer(color: RGBA(0, 0, 1), width: 0.12), TextStrokeLayer(color: RGBA(0, 1, 0), width: 0.2)]
        })
        #expect(count(img, Self.isRed) > 100 && count(img, Self.isBlue) > 100 && count(img, Self.isGreen) > 100)
        // green (outermost) box encloses blue
        #expect(box(img, Self.isGreen)!.width > box(img, Self.isBlue)!.width)
    }

    @Test func backgroundModes() {
        let block = render(text("AB\nCD") { $0.backgroundColor = RGBA(0, 0, 1) })
        let bb = box(block, Self.isBlue)!, tb = box(block) { $0.r > 0.8 && $0.g > 0.8 && $0.b > 0.8 }!
        #expect(bb.contains(tb) && bb.width > tb.width + 10)
        #expect(count(block, Self.isBlue) > 2000)
        // per-letter boxes leave gaps between letters
        let letters = render(text("A  A") { $0.backgroundColor = RGBA(0, 0, 1); $0.background = TextBackgroundStyle(mode: .letter, paddingX: 0.05, paddingY: 0.05) })
        let lb = box(letters, Self.isBlue)!
        #expect(!Self.isBlue(letters.pixel(Int(lb.midX), Int(lb.midY))))
        // offset moves the box
        let off = box(render(text("A") { $0.backgroundColor = RGBA(0, 0, 1); $0.background.offset = Vec2(0.3, 0) }), Self.isBlue)!
        let centred = box(render(text("A") { $0.backgroundColor = RGBA(0, 0, 1) }), Self.isBlue)!
        #expect(off.midX > centred.midX + 10)
    }

    @Test func dropShadowAnd3DShadow() {
        let img = render(text("I", size: 0.3) { $0.shadowColor = RGBA(0, 1, 0); $0.shadow = TextShadowStyle(distance: 0.1, angle: 45, blur: 0) })
        let g = box(img, Self.isGreen)!, w = box(img) { $0.r > 0.8 && $0.g > 0.8 && $0.b > 0.8 }!
        #expect(g.maxX > w.maxX + 5 && g.maxY > w.maxY + 5)        // down-right
        let ex = render(text("I", size: 0.3) { $0.shadowColor = RGBA(0, 1, 0); $0.shadow = TextShadowStyle(distance: 0.15, angle: 45, blur: 0, extrude: true) })
        #expect(count(ex, Self.isGreen) > count(img, Self.isGreen))   // extrusion fills the gap
        let blur = render(text("I", size: 0.3) { $0.shadowColor = RGBA(0, 1, 0); $0.shadow = TextShadowStyle(distance: 0.1, angle: 45, blur: 0.3) })
        #expect(box(blur) { $0.g > 0.05 && $0.r < 0.5 }!.width > g.width + 10)
    }

    @Test func glowOuterAndInner() {
        let outer = render(text("I", size: 0.3) { $0.glow = TextGlowStyle(color: RGBA(1, 0, 0), intensity: 1, radius: 0.3, mode: .outer) })
        let w = box(outer) { $0.r > 0.9 && $0.g > 0.9 }!
        #expect(box(outer) { $0.r > 0.15 && $0.g < 0.1 }!.width > w.width + 20)
        let inner = render(text("I", size: 0.3) { $0.glow = TextGlowStyle(color: RGBA(1, 0, 0), intensity: 1, radius: 0.15, mode: .inner) })
        #expect(count(inner) { $0.r > 0.8 && $0.g < 0.75 && $0.g > 0.05 } > 50)   // pink-ish rim inside the white glyph
    }

    @Test func gradientAndTextureFills() {
        let img = render(text("█████", size: 0.25) { $0.fill = .gradient(TextGradient([RGBA(1, 0, 0), RGBA(0, 0, 1)], angle: 0)) })
        let b = box(img) { $0.luma > 0.03 }!
        let l = img.pixel(Int(b.minX) + 6, Int(b.midY)), r = img.pixel(Int(b.maxX) - 6, Int(b.midY))
        #expect(l.r > 0.7 && l.b < 0.35 && r.b > 0.7 && r.r < 0.35)
        for id in BuiltinTextStyles.textures {
            let t = render(text("███", size: 0.25) { $0.fill = .texture(TextTexture(id: id)) })
            let n = count(t) { $0.luma > 0.05 }
            #expect(n > 3000, "texture \(id)")
        }
    }

    @Test func curveAndPathBendTheBaseline() {
        let straight = box(render(text("CURVED TEXT", size: 0.08)), Self.lit)!
        let arch = box(render(text("CURVED TEXT", size: 0.08) { $0.curve = 0.6 }), Self.lit)!
        #expect(arch.height > straight.height * 1.6 && arch.width < straight.width)
        for kind in TextPathShape.Kind.allCases where kind != .custom {
            let b = box(render(text("ON A PATH", size: 0.07) { $0.path = TextPathShape(kind, amount: 0.6) }), Self.lit)
            #expect(b != nil && b!.height > straight.height * 0.9, "path \(kind)")
        }
        let custom = box(render(text("ZIGZAG", size: 0.07) { $0.path = TextPathShape(.custom, points: [Vec2(0, 0), Vec2(1, 1), Vec2(2, 0)]) }), Self.lit)!
        #expect(custom.height > straight.height)
    }

    @Test func verticalTextStacksCharacters() {
        let b = box(render(text("ABCD", size: 0.12) { $0.orientation = .vertical }), Self.lit)!
        #expect(b.height > b.width * 2.5)
        let cols = box(render(text("AB\nCD", size: 0.12) { $0.orientation = .vertical }), Self.lit)!
        #expect(cols.width > b.width * 1.6)
    }

    @Test func fixedBoxWidthWraps() {
        let one = box(render(text("one two three four", size: 0.08)), Self.lit)!
        let wrapped = box(render(text("one two three four", size: 0.08) { $0.boxWidth = 0.3 }), Self.lit)!
        #expect(wrapped.width <= 640 * 0.3 + 4 && wrapped.height > one.height * 1.8)
    }

    /// Owner bug: on a 9:16 project auto captions were ~1.8× too big and two lines ran off both edges. Old captions
    /// (16:9 size and position) are wrapped and shrunk into the safe width; new ones get the vertical size, wrap in ≤ 2
    /// lines and sit in the lower third above the platform UI.
    @Test func verticalCaptionsStayInsideTheFrame() {
        let canvas = Size2(360, 640)
        let long = "refuse de passer mes trente ans sans ma soeur et on va lui faire passer trois jours inoubliables"
        var p = Project(name: "v", settings: ProjectSettings(canvasSize: canvas, frameRate: .fps30, backgroundColor: .black))
        // a caption made before the fix: 16:9 font size and position, a 2-line text much wider than the frame
        CaptionOps.addCaptionTrack([CaptionSegment(text: "refuse de passer mes trente\nans sans ma soeur Il faut", start: 0, end: 2)],
                                   to: &p, style: CaptionOps.defaultStyle(), position: CaptionOps.defaultPosition)
        let old = box(render(p, at: 1), Self.lit)!
        #expect(old.minX >= 360 * 0.05 && old.maxX <= 360 * 0.95, "old caption leaves the frame: \(old)")
        #expect(old.height < 640 * 0.055 * 2.8, "more than two lines: \(old)")
        // regenerated: canvas-aware defaults
        var q = Project(name: "v", settings: ProjectSettings(canvasSize: canvas, frameRate: .fps30, backgroundColor: .black))
        let segs = SpeechSegmenter.segments(long.split(separator: " ").enumerated().map {
            TranscriptWord(text: String($0.element), start: Double($0.offset) * 0.2, end: Double($0.offset) * 0.2 + 0.18)
        }, language: "fr", settings: CaptionSettings(maxCharsPerLine: CaptionLayout.maxCharsPerLine(canvas: canvas)))
        #expect(segs.count >= 2)
        let track = segs.map { CaptionSegment(text: $0.text, start: $0.start, end: $0.end) }
        CaptionOps.addCaptionTrack(track, to: &q)
        for s in segs {
            let b = box(render(q, at: (s.start + s.end) / 2), Self.lit)!
            #expect(b.minX >= 360 * 0.06 && b.maxX <= 360 * 0.94, "\(s.text): \(b)")
            #expect(b.midY > 640 * 0.6 && b.maxY < 640 * 0.8, "\(s.text): \(b)")       // lower third, above the Reels UI
            #expect(b.height < 640 * CaptionLayout.fontSize(canvas: canvas) * 2.8)
        }
        // the renderer's last-resort shrink: one unbreakable word wider than the frame
        var r = Project(name: "v", settings: ProjectSettings(canvasSize: canvas, frameRate: .fps30, backgroundColor: .black))
        CaptionOps.addCaptionTrack([CaptionSegment(text: "Anticonstitutionnellement!", start: 0, end: 2)], to: &r)
        let w = box(render(r, at: 1), Self.lit)!
        #expect(w.minX >= 360 * 0.05 && w.maxX <= 360 * 0.95, "\(w)")
    }

    @Test func complexScriptsAndEmoji() {
        for s in ["مرحبا بالعالم", "שלום עולם", "你好，世界", "こんにちは", "안녕하세요", "สวัสดี", "नमस्ते", "Ünïcødé"] {
            #expect(count(render(text(s, size: 0.12)), Self.lit) > 300, "script \(s)")
        }
        let emoji = render(text("🔥🎉", size: 0.2))
        #expect(count(emoji) { $0.r > 0.6 && $0.b < 0.5 } > 300)                    // colour glyphs
    }

    @Test func bubblesSurroundTheText() {
        let plain = box(render(text("Hi there", size: 0.08)), Self.lit)!
        for d in Registries.textBubbles.all {
            var t = text("Hi there", size: 0.08)
            t.bubbleID = d.id; t.color = d.textColor
            let img = render(t)
            let any = box(img) { $0.luma > 0.03 }
            #expect(any != nil, "bubble \(d.id)")
            if d.fill.a > 0, let a = any { #expect(a.width > plain.width + d.padding.x * 2 * 0.08 * 360 * 0.8, "bubble \(d.id) too small") }
        }
        let speech = render(text("Hi", size: 0.1) { $0.bubbleID = "valse.bubble.speechYellow"; $0.color = .black })
        #expect(count(speech, Self.isYellow) > 3000)
    }

    // MARK: Presets & caption looks

    @Test func everyTextStylePresetRenders() {
        var seen = Set<String>()
        for d in Registries.textStyles.all {
            var t = text("Aa", size: 0.06)
            d.restyle(&t)
            #expect(t.styleID == d.id && t.string == "Aa")
            guard let img = TextRasterizer.image(t, fontPx: 48) else { Issue.record("no image for \(d.id)"); continue }
            let bm = Bitmap(img)
            #expect(count(bm) { $0.a > 0.5 } > 200, "preset \(d.id)")
            seen.insert(d.id)
        }
        #expect(seen.count >= 200)
        #expect(Registries.textStyles(.preset).count >= 20)
    }

    @Test func everyCaptionTemplateRenders() {
        for d in Registries.captionTemplates.all {
            var t = CaptionOps.defaultStyle()
            t.string = "two words here"
            d.apply(&t)
            let img = render(t, at: 1, duration: 3)
            #expect(count(img, Self.lit) > 150, "caption template \(d.id)")
        }
    }

    // MARK: Per-glyph animation

    @Test func typewriterRevealsCharactersLeftToRight() {
        let t = text("ABCDEFGH", size: 0.1)
        let (p, _) = project(t) { $0.animations.inAnim = AnimationInstance(typeID: "valse.anim.text.in.typewriter", duration: Time(2)) }
        let full = box(render(p, at: 3), Self.lit)!
        let quarter = box(render(p, at: 0.5), Self.lit)!
        #expect(quarter.width < full.width * 0.45 && abs(quarter.minX - full.minX) < 4)
        #expect(box(render(p, at: 1.5), Self.lit)!.width > full.width * 0.6)
    }

    @Test func animationAtRestMatchesTheStaticImage() {
        // the end of an In animation must not pop: compare dynamic (last frame of the in) with static (after it)
        var t = text("Rest", size: 0.15)
        t.strokeColor = RGBA(1, 0, 0); t.strokeWidth = 0.08; t.shadowColor = RGBA(0, 0, 0, 0.8)
        let (p, _) = project(t) { $0.animations.inAnim = AnimationInstance(typeID: "valse.anim.text.in.fadeChars", duration: Time(1)) }
        let dyn = render(p, at: 0.9999), stat = render(p, at: 2)
        var diff = 0
        for y in stride(from: 0, to: 360, by: 2) { for x in stride(from: 0, to: 640, by: 2) {
            let a = dyn.pixel(x, y), b = stat.pixel(x, y)
            if abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b) > 0.12 { diff += 1 }
        } }
        #expect(diff < 30, "\(diff) differing pixels")
    }

    @Test func everyTextAnimationRendersAndEndsAtRest() {
        let t = text("Motion", size: 0.12)
        let restCount = count(render(t, at: 1), Self.lit)
        for d in Registries.animations(.in, for: .text) + Registries.animations(.out, for: .text) + Registries.animations(.combo, for: .text) {
            let (p, _) = project(t, duration: 4) { c in
                let inst = AnimationInstance(typeID: d.id, duration: Time(1))
                switch d.phase { case .in: c.animations.inAnim = inst; case .out: c.animations.outAnim = inst; case .combo: c.animations.combo = inst }
            }
            let mid: Double = d.phase == .in ? 0.5 : (d.phase == .out ? 3.5 : 1.3)
            _ = render(p, at: mid)  // must not crash; content may legitimately be hidden mid-way
            if d.phase != .combo {
                let rest = render(p, at: d.phase == .in ? 2 : 1)
                #expect(abs(count(rest, Self.lit) - restCount) < restCount / 10 + 20, "rest pose of \(d.id)")
            }
            if d.glyph != nil, d.phase == .in {
                let start = render(p, at: 0.02)
                #expect(count(start, Self.lit) != restCount, "\(d.id) does nothing at its start")
            }
        }
    }

    @Test func dropMovesCharactersAndPopScales() {
        let t = text("ABC", size: 0.15)
        let rest = box(render(t), Self.lit)!
        let (p, _) = project(t) { $0.animations.inAnim = AnimationInstance(typeID: "valse.anim.text.in.drop", duration: Time(1)) }
        let early = box(render(p, at: 0.03)) { $0.luma > 0.1 }!
        #expect(early.minY < rest.minY - 20)                           // first letter falls from above
        let (q, _) = project(t) { $0.animations.combo = AnimationInstance(typeID: "valse.anim.text.combo.wave", duration: Time(1)) }
        let a = render(q, at: 0.2), b = render(q, at: 0.7)
        var diff = 0
        for y in 0..<360 { for x in 0..<640 where abs(a.pixel(x, y).luma - b.pixel(x, y).luma) > 0.3 { diff += 1 } }
        #expect(diff > 300)
    }

    // MARK: Karaoke & captions

    func caption(_ s: String, words: [(String, Double, Double)], _ k: KaraokeStyle) -> TextContent {
        var t = text(s, size: 0.12)
        t.caption = CaptionData(words: words.map { CaptionWord($0.0, start: Time($0.1), end: Time($0.2)) }, origin: .auto)
        t.karaoke = k
        return t
    }

    @Test func karaokeHighlightsTheSpokenWord() {
        let t = caption("ONE TWO", words: [("ONE", 0, 1), ("TWO", 1, 2)], KaraokeStyle(mode: .highlightWord, highlightColor: RGBA(1, 1, 0), highlightScale: 1))
        let (p, _) = project(t, duration: 2)
        let a = render(p, at: 0.5), b = render(p, at: 1.5)
        let ya = box(a, Self.isYellow)!, yb = box(b, Self.isYellow)!
        #expect(ya.midX < 320 && yb.midX > 320)
    }

    @Test func karaokeBoxRevealAndSingleWord() {
        let box1 = caption("ONE TWO", words: [("ONE", 0, 1), ("TWO", 1, 2)], KaraokeStyle(mode: .highlightWord, highlightColor: .white, highlightScale: 1, boxColor: RGBA(0, 0, 1)))
        let img = render(project(box1, duration: 2).0, at: 1.5)
        #expect(box(img, Self.isBlue)!.minX > 300)
        let reveal = caption("ONE TWO", words: [("ONE", 0, 1), ("TWO", 1, 2)], KaraokeStyle(mode: .reveal, highlightColor: .white, highlightScale: 1))
        #expect(box(render(project(reveal, duration: 2).0, at: 0.5), Self.lit)!.maxX < 330)
        let single = caption("ONE TWO", words: [("ONE", 0, 1), ("TWO", 1, 2)], KaraokeStyle(mode: .singleWord, highlightColor: .white, highlightScale: 1))
        let s = box(render(project(single, duration: 2).0, at: 1.5), Self.lit)!
        #expect(abs(s.midX - 320) < 10)                       // the current word is centred
    }

    @Test func bilingualCaptionStacksTranslation() {
        var t = text("Hello", size: 0.1)
        t.caption = CaptionData(translation: "Bonjour", display: .both, subStyle: CaptionSubStyle(color: RGBA(1, 1, 0)))
        let img = render(t)
        let y = box(img, Self.isYellow)!, w = box(img) { $0.r > 0.85 && $0.g > 0.85 && $0.b > 0.85 }!
        #expect(y.minY > w.maxY - 2)
        var only = t; only.caption?.display = .translationOnly
        #expect(box(render(only), Self.isYellow) == nil && count(render(only), Self.lit) > 300)
    }

    @Test func captionTrackRendersOnlyTheActiveCaption() {
        var p = Project(name: "c", settings: ProjectSettings(canvasSize: Self.canvas, frameRate: .fps30, backgroundColor: .black))
        CaptionOps.addCaptionTrack([CaptionSegment(text: "FIRST", start: 0, end: 1), CaptionSegment(text: "SECOND", start: 1, end: 2)], to: &p)
        let a = box(render(p, at: 0.5), Self.lit)!, b = box(render(p, at: 1.5), Self.lit)!
        #expect(b.width > a.width && a.midY > 180)                // lower third
    }

    // MARK: Templates

    @Test func everyTemplateRendersItsLayers() {
        for d in Registries.textTemplates.all {
            let t = d.makeContent()
            #expect(t.template?.templateID == d.id && !t.string.isEmpty)
            let (p, _) = project(t, duration: d.defaultDuration.seconds)
            let img = render(p, at: d.defaultDuration.seconds * 0.5)
            #expect(count(img) { $0.luma > 0.1 } > 400, "template \(d.id)")
        }
        // slot texts are editable
        var t = Registries.textTemplates["valse.template.titleSubtitle"]!.makeContent()
        t.template?.texts = ["x"]
        let before = count(render(project(t).0, at: 2), Self.lit)
        t.template?.texts = ["a much longer subtitle line"]
        #expect(count(render(project(t).0, at: 2), Self.lit) > before)
    }

    @Test func templateLayersFollowTheirTimeWindow() {
        let t = Registries.textTemplates["valse.template.titleSubtitle"]!.makeContent()
        let (p, _) = project(t, duration: 4)
        let early = count(render(p, at: 0.05), Self.lit), mid = count(render(p, at: 2), Self.lit)
        #expect(early < mid / 2)
    }

    // MARK: Caching / performance

    @Test func animatedPlaybackRasterizesOnce() {
        let r = FrameRenderer()
        let t = caption("one two three four", words: [("one", 0, 0.5), ("two", 0.5, 1), ("three", 1, 1.5), ("four", 1.5, 2)], KaraokeStyle())
        let (p, _) = project(t, duration: 2) { $0.animations.combo = AnimationInstance(typeID: "valse.anim.text.combo.wave", duration: Time(1)) }
        let before = r.text.rasterizationCount
        for i in 0..<30 { _ = render(p, at: Double(i) / 15, renderer: r) }
        #expect(r.text.rasterizationCount - before == 1)
    }

    @Test func fiftyAnimatedCaptionsRenderFast() {
        var p = Project(name: "perf", settings: ProjectSettings(canvasSize: Size2(1920, 1080), frameRate: .fps30, backgroundColor: .black))
        let tid = TimelineOps.addTrack(.text, to: &p.timeline)
        var clips: [Clip] = []
        for i in 0..<50 {
            var t = CaptionOps.defaultStyle()
            t.string = "Caption number \(i) says hi"
            t.karaoke = KaraokeStyle(mode: .highlightWord)
            var c = Clip(content: .text(t), start: 0, duration: Time(10))
            c.transform.position = Vec2(Double(i % 5) * 0.2 - 0.4, Double(i / 5) * 0.09 - 0.42)
            c.animations.combo = AnimationInstance(typeID: "valse.anim.text.combo.wave", duration: Time(1.2))
            clips.append(c)
        }
        // 50 simultaneous captions: one per track
        p.timeline.tracks.removeAll { $0.id == tid }
        for c in clips { let id = TimelineOps.addTrack(.text, to: &p.timeline); p.timeline.tracks[p.timeline.trackIndex(id)!].clips = [c] }
        let r = FrameRenderer()
        _ = render(p, at: 0, renderer: r)   // warm caches (rasterize atlases once)
        let n = Int(ProcessInfo.processInfo.environment["VALSE_BENCH_FRAMES"] ?? "") ?? 30
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1920, height: 1080, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
        let out = MetalContext.shared.device.makeTexture(descriptor: d)!
        let start = Date()
        var cpu: [Double] = [], gpu: [Double] = []
        for i in 0..<n {
            let c0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            let cmd = encode(p, at: Double(i % 300) / 30, renderer: r, into: out)
            cpu.append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - c0) / 1e6)
            cmd.waitUntilCompleted()
            gpu.append(max(0, cmd.gpuEndTime - cmd.gpuStartTime) * 1000)
        }
        let ms = Date().timeIntervalSince(start) / Double(n) * 1000
        TimingBudget.metric("unit_text_50captions_frame_ms", ms, "ms")
        // split: frame evaluation + encode on the calling thread vs GPU execution (median)
        TimingBudget.metric("unit_text_50captions_cpu_ms", cpu.sorted()[n / 2], "ms")
        TimingBudget.metric("unit_text_50captions_gpu_ms", gpu.sorted()[n / 2], "ms")
        if let lim = TimingBudget.limit(16, "50 animated captions") { #expect(ms < lim, "50 animated captions took \(ms) ms/frame") }
        // always: the frame's cost as thread CPU + GPU time (load-robust gross bound of the same 16 ms budget)
        let cost = cpu.sorted()[n / 2] + gpu.sorted()[n / 2]
        #expect(cost < TimingBudget.cpuLimit(16), "50 animated captions cost \(cost) ms CPU+GPU per frame")
        #expect(r.text.rasterizationCount == 50)
    }

    /// Captions draw their glyphs straight onto the frame (no layer texture): same pixels as the layer-texture path
    /// for static, karaoke, per-glyph animated and transformed / translucent text.
    @Test func directTextMatchesLayerTexturePath() {
        let direct = FrameRenderer(), layered = FrameRenderer()
        layered.allowsDirectText = false
        let k = caption("ONE TWO THREE", words: [("ONE", 0, 0.6), ("TWO", 0.6, 1.2), ("THREE", 1.2, 2)],
                        KaraokeStyle(mode: .highlightWord, highlightColor: RGBA(1, 1, 0), highlightScale: 1.2))
        let cases: [(String, TextContent, Double, (inout Clip) -> Void)] = [
            ("static", text("Static", { $0.strokeWidth = 0.08; $0.strokeColor = RGBA(0, 0, 1) }), 1, { _ in }),
            ("karaoke", k, 0.9, { _ in }),
            ("glyph-anim", text("Wave"), 0.4, { $0.animations.combo = AnimationInstance(typeID: "valse.anim.text.combo.wave", duration: Time(1.2)) }),
            ("transformed", k, 1.5, { $0.transform.rotation = 17; $0.transform.scale = Vec2(1.3, 0.8); $0.transform.position = Vec2(0.1, -0.1); $0.opacity = 0.6 }),
        ]
        for (name, t, at, edit) in cases {
            let (p, _) = project(t, duration: 2, edit: edit)
            let a = renderRaw(p, at: at, renderer: direct), b = renderRaw(p, at: at, renderer: layered)
            if let dir = ProcessInfo.processInfo.environment["VALSE_TEXT_DEBUG_DIR"] {
                a.writePNG(URL(fileURLWithPath: dir).appendingPathComponent("direct-\(name).png"))
                b.writePNG(URL(fileURLWithPath: dir).appendingPathComponent("layered-\(name).png"))
            }
            var worst = 0, differing = 0, lit = 0
            for i in stride(from: 0, to: a.pixels.count, by: 4) {
                var d = 0
                for c in 0..<3 { d = max(d, abs(Int(a.pixels[i + c]) - Int(b.pixels[i + c]))) }
                worst = max(worst, d)
                if d > 24 { differing += 1 }
                if b.pixels[i] > 60 || b.pixels[i + 1] > 60 || b.pixels[i + 2] > 60 { lit += 1 }
            }
            #expect(lit > 200, "\(name): nothing rendered")
            // Only antialiased edges may differ: the layer-texture path resamples a layer taller than 64 px to the
            // 16-px texture quantum (a sub-pixel stretch), the direct path samples the atlas once.
            #expect(Double(differing) < Double(max(lit, 1)) * 0.15, "\(name): \(differing) of \(lit) lit pixels differ (max \(worst))")
            if let ba = box(a, Self.lit), let bb = box(b, Self.lit) {
                #expect(abs(ba.minX - bb.minX) <= 1 && abs(ba.maxX - bb.maxX) <= 1 && abs(ba.minY - bb.minY) <= 1 && abs(ba.maxY - bb.maxY) <= 1,
                        "\(name): \(ba) vs \(bb)")
            } else { Issue.record("\(name): empty frame") }
        }
    }

    @Test func steadyTextPlaybackAllocatesNoTextures() {
        let r = FrameRenderer()
        var p = Project(name: "a", settings: ProjectSettings(canvasSize: Size2(1280, 720), frameRate: .fps30, backgroundColor: .black))
        for i in 0..<20 {
            var t = CaptionOps.defaultStyle(); t.string = "Line \(i)"; t.karaoke = KaraokeStyle(mode: .highlightWord)
            var c = Clip(content: .text(t), start: 0, duration: Time(4))
            c.transform.position = Vec2(0, Double(i) * 0.04 - 0.4)
            c.animations.combo = AnimationInstance(typeID: "valse.anim.text.combo.wave", duration: Time(1.2))
            let id = TimelineOps.addTrack(.text, to: &p.timeline)
            p.timeline.tracks[p.timeline.trackIndex(id)!].clips = [c]
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1280, height: 720, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
        let out = MetalContext.shared.device.makeTexture(descriptor: d)!
        for i in 0..<3 { encode(p, at: Double(i) / 30, renderer: r, into: out).waitUntilCompleted() }
        let pool = MetalContext.shared.pool
        let before = pool.allocations
        for i in 3..<30 { encode(p, at: Double(i) / 30, renderer: r, into: out).waitUntilCompleted() }
        // other suites may render concurrently on the shared pool: allow a little, never one per layer per frame
        #expect(pool.allocations - before < 20)
    }

    @Test func measureMatchesRenderedSize() {
        let t = text("Measure me", size: 0.1)
        let m = FrameRenderer.shared.text.measure(t, canvasSize: Self.canvas)
        let b = box(render(t), Self.lit)!
        #expect(m.width >= Double(b.width) && m.width < Double(b.width) + 40)
        #expect(m.height >= Double(b.height))
    }

    @Test func zoomedTextIsRasterizedSharper() {
        let r = FrameRenderer()
        let t = text("Z", size: 0.05)
        let (p, id) = project(t)
        var q = p
        q.timeline[clip: id]!.transform.scale = Vec2(4, 4)
        let img = render(q, at: 1, renderer: r)
        // a sharp edge: few intermediate grey pixels relative to the lit area
        let lit = count(img) { $0.luma > 0.8 }, grey = count(img) { $0.luma > 0.15 && $0.luma < 0.6 }
        #expect(lit > 0 && Double(grey) / Double(lit) < 0.35)
    }

    /// Inspector tiles (UX_GAPS W7-1): CPU frames of a glyph animation follow the engine — typewriter at 0 shows
    /// nothing, half-way shows part of the text, at 1 the whole rest pose; all frames share one size.
    @Test func animationTileFramesFollowTheGlyphSpec() {
        var t = TextContent(string: "ABC123", fontSize: 0.1); t.bold = true
        let frames = TextRasterizer.animationFrames(t, fontPx: 40, animationID: "valse.anim.text.in.typewriter", progresses: [0, 0.5, 1])
        #expect(frames.count == 3)
        #expect(Set(frames.map { "\($0.width)x\($0.height)" }).count == 1)
        func coverage(_ img: CGImage) -> Double {
            let w = img.width, h = img.height
            var px = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            var n = 0
            for i in stride(from: 3, to: px.count, by: 4) where px[i] > 128 { n += 1 }
            return Double(n) / Double(w * h)
        }
        let c = frames.map(coverage)
        #expect(c[0] < 0.002, "\(c)")
        #expect(c[1] > c[0] + 0.01 && c[2] > c[1] + 0.01, "\(c)")
        #expect(TextRasterizer.animationFrames(t, fontPx: 40, animationID: "valse.anim.video.in.fade", progresses: [0.5]).isEmpty)
    }
}
