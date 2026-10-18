import CoreGraphics
import CoreText
import Foundation
import MontageCore
import MontageEffects

/// A text clip turned into drawable items: one or more blocks (main text, bilingual sub line, template layers), each
/// with decorations (bubble, backgrounds, karaoke word boxes) and per-glyph back (shadow, glow, outlines) / front (fill)
/// items. Scene space = output pixels, y down. The same items are painted once into a static image (rest pose) or one
/// by one into atlas cells that the GPU recomposes per frame (per-glyph animation, karaoke) — see `TextRasterizer`.
struct TextScene: @unchecked Sendable {
    enum Variant { case base, highlight }

    enum Kind {
        case bubble(BubbleShape, fill: RGBA, stroke: RGBA?, strokeWidth: CGFloat, rect: CGRect)
        case shape(BubbleShape, color: RGBA, rect: CGRect)
        case background(rect: CGRect, color: RGBA, radius: CGFloat)
        case wordBox(rect: CGRect, color: RGBA, radius: CGFloat)
        case glyphBack(cluster: Int, variant: Variant)
        case glyphFront(cluster: Int, variant: Variant)
    }

    struct Item {
        var kind: Kind
        var block: Int
        /// Local (block layout or cluster) → scene.
        var transform: CGAffineTransform
        /// Scene-space AABB of everything the item paints.
        var rect: CGRect
        var char = -1, word = -1, line = -1
        /// For highlight variants: index of the base item they replace when highlighted.
        var variantOf: Int?
    }

    struct Block {
        var style: TextContent
        var highlightStyle: TextContent?
        var layout: TextLayoutResult
        var transform: CGAffineTransform
        var em: CGFloat
        /// Template layer timing / animations (nil = the clip's own animations).
        var layer: TextTemplateLayer?
        var karaoke: KaraokeStyle?
        /// Clip-local word timings (seconds) aligned with `layout.words`.
        var wordTimes: [(start: Double, end: Double, keyword: Bool)]
        var charPivots: [CGPoint] = []
        var wordPivots: [CGPoint] = []
        var linePivots: [CGPoint] = []
        var center: CGPoint = .zero
        var isShape = false
        var gradientRect: CGRect = .zero
    }

    var blocks: [Block]
    var items: [Item]
    var bounds: CGRect
    /// Rest bounds without effect padding (selection box / measuring).
    var textBounds: CGRect
}

enum TextSceneBuilder {
    /// Effect extent of a style beyond the glyph box, em.
    static func padEm(_ t: TextContent) -> CGFloat {
        var p: Double = 0.06
        let strokes = ([t.strokeWidth] + t.extraStrokes.map(\.width)).max() ?? 0
        p += strokes
        if let g = t.glow { p += g.radius * 1.6 }
        if t.shadowColor.a > 0 { p += t.shadow.distance + t.shadow.blur * 1.5 }
        return CGFloat(p)
    }

    /// - Parameters:
    ///   - fontPx: clip font size in pixels.
    ///   - canvasWidthPx: canvas width in pixels (text box width).
    ///   - duration: clip duration in seconds (template timing).
    ///   - dynamic: also build highlight variants and word boxes (karaoke).
    static func build(_ t: TextContent, fontPx fontPx0: CGFloat, canvasWidthPx: CGFloat, duration: Double, dynamic: Bool) -> TextScene {
        var blocks: [TextScene.Block] = []
        // Captions stay inside the frame (CapCut): they wrap at the safe width (`CaptionLayout.safeWidth`, or their own
        // box) and, as a last resort, shrink until they fit in ≤ 2 lines (more only when the text has explicit breaks).
        let fitCaption = isFittedCaption(t) && canvasWidthPx > 0
        let boxW: CGFloat? = fitCaption ? CGFloat(t.boxWidth ?? CaptionLayout.safeWidth) * canvasWidthPx
            : t.boxWidth.map { CGFloat($0) * canvasWidthPx }
        var fontPx = fontPx0
        var hiddenBlocks: Set<Int> = []   // separated template parts (TX-032): laid out for placement, not drawn

        func textBlock(_ style: TextContent, px: CGFloat, string: String? = nil, layer: TextTemplateLayer? = nil) -> TextScene.Block {
            var st = style
            if let s = string { st.string = s; st.runs = [] }
            // keyword colouring is part of the base look
            let words = wordTimes(st, karaoke: st.karaoke, duration: duration)
            if let k = st.karaoke, words.contains(where: \.keyword) {
                // keyword emphasis is laid out (bigger font, reflowed line), not just scaled
                let ranges = TextTokenizer.words(in: st.displayString)
                for (i, w) in words.enumerated() where w.keyword && i < ranges.count {
                    st.runs.append(TextRun(ranges[i], TextRunStyle(color: k.keywordColor, sizeScale: k.keywordScale == 1 ? nil : k.keywordScale)))
                }
                st.runs = TextContent.normalized(st.runs, length: st.displayString.utf16.count)
            }
            let layout = TextLayoutEngine.layout(st, fontPx: px, boxWidthPx: boxW)
            var hi: TextContent?
            if dynamic, let k = st.karaoke {
                var h = st
                h.color = k.highlightColor
                h.runs = h.runs.map { var r = $0; r.style.color = nil; return r }
                if let s = k.highlightStroke { h.strokeColor = s; if h.strokeWidth == 0 { h.strokeWidth = 0.06 } }
                h.fill = nil
                hi = h
            }
            return TextScene.Block(style: st, highlightStyle: hi, layout: layout, transform: .identity, em: px, layer: layer,
                                   karaoke: st.karaoke, wordTimes: words)
        }

        if fitCaption, let w = boxW {
            let allowed = max(CaptionLayout.maxLines, t.displayString.components(separatedBy: "\n").count)
            func fits(_ px: CGFloat) -> Bool {
                let l = textBlock(t, px: px).layout
                return l.lines.count <= allowed && (l.bounds.isNull || l.bounds.width <= w + 1)
            }
            if !fits(fontPx) {
                var lo = CGFloat(CaptionLayout.minFitScale), hi: CGFloat = 1
                for _ in 0..<7 { let mid = (lo + hi) / 2; if fits(fontPx * mid) { lo = mid } else { hi = mid } }
                fontPx *= lo
            }
        }
        if let inst = t.template, let d = Registries.textTemplates[inst.templateID] {
            var slotWidth: [Int: CGFloat] = [:]
            var built: [Int: TextScene.Block] = [:]
            for (li, layer) in d.layers.enumerated() {
                guard case .text(let slot, let styleFn) = layer.kind else { continue }
                var st = t
                st.template = nil; st.caption = nil; st.karaoke = nil
                st.string = TextTemplateDescriptor.text(slot: slot, of: t, descriptor: d)
                if slot != 0 { st.runs = [] }
                styleFn(&st)
                let px = fontPx * CGFloat(st.fontSize / max(t.fontSize, 1e-6))
                var b = textBlock(st, px: px, layer: layer)
                slotWidth[slot] = max(slotWidth[slot] ?? 0, b.layout.bounds.width * CGFloat(layer.scale))
                place(&b, center: CGPoint(x: layer.offset.x * fontPx, y: layer.offset.y * fontPx), rotation: layer.rotation,
                      scale: layer.scale)
                built[li] = b
            }
            for (li, layer) in d.layers.enumerated() {
                if !inst.showsLayer(li) { hiddenBlocks.insert(blocks.count) }
                switch layer.kind {
                case .text:
                    if let b = built[li] { blocks.append(b) }
                case .shape(let shape, let size, let color):
                    var st = TextContent(string: "")
                    st.color = color
                    var w = CGFloat(size.x) * fontPx
                    if let s = layer.fitSlot, let tw = slotWidth[s] { w = max(w, tw + CGFloat(layer.fitPadding) * 2 * fontPx) }
                    let h = CGFloat(size.y) * fontPx
                    var b = TextScene.Block(style: st, highlightStyle: nil,
                                            layout: TextLayoutResult(clusters: [], lines: [], words: [],
                                                                     bounds: CGRect(x: -w / 2, y: -h / 2, width: w, height: h),
                                                                     fontPx: fontPx, visibleCharCount: 0, isBent: false),
                                            transform: .identity, em: fontPx, layer: layer, karaoke: nil, wordTimes: [])
                    _ = (shape, color)  // drawn from `layer.kind` in `assemble`
                    b.isShape = true
                    place(&b, center: CGPoint(x: layer.offset.x * fontPx, y: layer.offset.y * fontPx), rotation: layer.rotation, scale: layer.scale)
                    blocks.append(b)
                }
            }
        } else if let cap = t.caption, let tr = cap.translation, !tr.isEmpty {
            switch cap.display ?? .both {
            case .translationOnly:
                var st = t; st.karaoke = nil; st.caption = nil
                blocks.append(textBlock(st, px: fontPx, string: tr))
            case .both:
                var main = textBlock(t, px: fontPx)
                let sub = cap.subStyle ?? CaptionSubStyle()
                var st = t
                st.karaoke = nil; st.caption = nil; st.bubbleID = nil
                st.color = sub.color; st.fontSize = t.fontSize * sub.fontScale
                if let f = sub.fontName { st.fontName = f }
                if let s = sub.strokeColor { st.strokeColor = s }
                if let w = sub.strokeWidth { st.strokeWidth = w }
                var subB = textBlock(st, px: fontPx * CGFloat(sub.fontScale), string: tr)
                let mh = main.layout.bounds.height, sh = subB.layout.bounds.height
                let gap = CGFloat(sub.gap) * fontPx
                let total = mh + gap + sh
                place(&main, center: CGPoint(x: 0, y: -total / 2 + mh / 2), rotation: 0, scale: 1)
                place(&subB, center: CGPoint(x: 0, y: total / 2 - sh / 2), rotation: 0, scale: 1)
                blocks.append(main); blocks.append(subB)
            }
        } else {
            blocks.append(textBlock(t, px: fontPx))
        }
        // blocks without explicit placement: centre at origin
        for i in blocks.indices where blocks[i].transform == .identity && !blocks[i].isShape {
            place(&blocks[i], center: .zero, rotation: 0, scale: 1)
        }
        return assemble(blocks, clip: t, dynamic: dynamic, hidden: hiddenBlocks)
    }

    /// Caption clips laid out by the caption fit (plain horizontal text; templates, curves and paths keep their own layout).
    static func isFittedCaption(_ t: TextContent) -> Bool {
        t.caption != nil && t.template == nil && t.orientation == .horizontal && t.path == nil && t.curve == 0
    }

    /// Positions a block so that its layout bounds centre lands on `center`.
    static func place(_ b: inout TextScene.Block, center: CGPoint, rotation: Double, scale: Double) {
        let lb = b.layout.bounds
        b.transform = CGAffineTransform(translationX: -lb.midX, y: -lb.midY)
            .concatenating(CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
            .concatenating(CGAffineTransform(rotationAngle: CGFloat(rotation * .pi / 180)))
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
    }

    /// Clip-local word timings (seconds) for karaoke, spreading words evenly when none are stored.
    static func wordTimes(_ t: TextContent, karaoke: KaraokeStyle?, duration: Double) -> [(start: Double, end: Double, keyword: Bool)] {
        let tokens = TextTokenizer.tokens(t.displayString)
        if let w = t.caption?.words, w.count == tokens.count, !w.isEmpty {
            return w.map { ($0.start.seconds, $0.end.seconds, $0.isKeyword) }
        }
        guard karaoke != nil, !tokens.isEmpty else { return [] }
        let even = CaptionOps.evenWords(tokens, start: .zero, end: Time(max(duration, 0.1)))
        return even.map { ($0.start.seconds, $0.end.seconds, false) }
    }

    static func assemble(_ blocksIn: [TextScene.Block], clip: TextContent, dynamic: Bool, hidden: Set<Int> = []) -> TextScene {
        var blocks = blocksIn
        var items: [TextScene.Item] = []
        var textBounds = CGRect.null
        for bi in blocks.indices {
            var b = blocks[bi]
            let T = b.transform
            let em = b.em
            let st = b.style
            let lb = b.layout.bounds
            b.center = CGPoint(x: lb.midX, y: lb.midY).applying(T)
            b.gradientRect = lb.applying(T)
            textBounds = textBounds.union(lb.applying(T))
            if b.isShape, let layer = b.layer, case .shape(let shape, _, let color) = layer.kind {
                let r = BubblePaths.bounds(shape, rect: lb, em: em, strokeWidth: 0).applying(T)
                items.append(.init(kind: .shape(shape, color: color, rect: lb), block: bi, transform: T, rect: r))
                blocks[bi] = b
                continue
            }
            // bubble
            if let id = st.bubbleID, let d = Registries.textBubbles[id] {
                let rect = lb.insetBy(dx: -CGFloat(d.padding.x) * em, dy: -CGFloat(d.padding.y) * em)
                let sw = CGFloat(d.strokeWidth) * em
                let r = BubblePaths.bounds(d.shape, rect: rect, em: em, strokeWidth: d.stroke == nil ? 0 : sw).applying(T)
                items.append(.init(kind: .bubble(d.shape, fill: st.bubbleColor ?? d.fill, stroke: d.stroke, strokeWidth: sw, rect: rect),
                                   block: bi, transform: T, rect: r))
            }
            // backgrounds
            let bg = st.background
            let padX = CGFloat(bg.paddingX) * em, padY = CGFloat(bg.paddingY) * em
            let off = CGPoint(x: CGFloat(bg.offset.x) * em, y: CGFloat(bg.offset.y) * em)
            func bgItem(_ rect0: CGRect, color: RGBA, transform: CGAffineTransform, char: Int = -1, line: Int = -1) {
                let rect = rect0.insetBy(dx: -padX, dy: -padY).offsetBy(dx: off.x, dy: off.y)
                let radius = min(rect.height, rect.width) / 2 * CGFloat(min(max(bg.cornerRadius, 0), 1))
                items.append(.init(kind: .background(rect: rect, color: color, radius: radius), block: bi, transform: transform,
                                   rect: rect.insetBy(dx: -1, dy: -1).applying(transform), char: char, line: line))
            }
            if st.backgroundColor.a > 0 {
                switch bg.mode {
                case .block:
                    bgItem(lb, color: st.backgroundColor, transform: T)
                case .line:
                    if b.layout.isBent { bgItem(lb, color: st.backgroundColor, transform: T) }
                    else { for (li, l) in b.layout.lines.enumerated() where l.rect.width > 0 { bgItem(l.rect, color: st.backgroundColor, transform: T, line: li) } }
                case .letter:
                    for c in b.layout.clusters where !c.isWhitespace {
                        bgItem(c.box, color: st.backgroundColor, transform: c.transform.concatenating(T), char: c.charIndex)
                    }
                }
            }
            // per-run backgrounds (grouped per line)
            var runGroups: [(line: Int, color: RGBA, rect: CGRect, firstChar: Int)] = []
            for c in b.layout.clusters {
                guard let col = c.style.backgroundColor, col.a > 0 else { continue }
                let r = c.box.applying(c.transform)
                if let last = runGroups.last, last.line == c.lineIndex, last.color == col, abs(last.rect.maxX - r.minX) < em * 0.6 {
                    runGroups[runGroups.count - 1].rect = last.rect.union(r)
                } else { runGroups.append((c.lineIndex, col, r, c.charIndex)) }
            }
            for g in runGroups {
                let rect = g.rect.insetBy(dx: -em * 0.08, dy: -em * 0.02)
                items.append(.init(kind: .background(rect: rect, color: g.color, radius: em * 0.12), block: bi, transform: T,
                                   rect: rect.applying(T), line: g.line))
            }
            // karaoke word boxes
            if dynamic, let k = b.karaoke, let box = k.boxColor {
                for (wi, w) in b.layout.words.enumerated() where !w.clusters.isEmpty {
                    let rect = w.rect.insetBy(dx: -em * 0.14, dy: -em * 0.04)
                    items.append(.init(kind: .wordBox(rect: rect, color: box, radius: em * 0.22), block: bi, transform: T,
                                       rect: rect.insetBy(dx: -1, dy: -1).applying(T), word: wi))
                }
            }
            // glyphs: all backs, then all fronts (like Core Text drawing strokes under fills)
            let hasBack = st.strokeWidth > 0 || !st.extraStrokes.isEmpty || st.shadowColor.a > 0 || (st.glow.map { $0.mode != .inner } ?? false)
            let hiStyle = b.highlightStyle
            let hiBack = hiStyle.map { $0.strokeWidth > 0 || !$0.extraStrokes.isEmpty || $0.shadowColor.a > 0 || $0.glow != nil } ?? false
            let pad = padEm(st) * em
            let hiPad = hiStyle.map { padEm($0) * em } ?? 0
            func clusterRect(_ c: TextLayoutResult.Element, _ p: CGFloat, _ M: CGAffineTransform) -> CGRect {
                c.box.union(c.ink).insetBy(dx: -p, dy: -p).applying(M)
            }
            var fronts: [TextScene.Item] = []
            for (ci, c) in b.layout.clusters.enumerated() where !c.isWhitespace {
                let M = c.transform.concatenating(T)
                let unit = (char: c.charIndex, word: c.wordIndex, line: c.lineIndex)
                if hasBack || hiBack {
                    let r = clusterRect(c, max(pad, hiPad), M)
                    items.append(.init(kind: .glyphBack(cluster: ci, variant: .base), block: bi, transform: M, rect: r,
                                       char: unit.char, word: unit.word, line: unit.line))
                    if hiStyle != nil {
                        let base = items.count - 1
                        items.append(.init(kind: .glyphBack(cluster: ci, variant: .highlight), block: bi, transform: M, rect: r,
                                           char: unit.char, word: unit.word, line: unit.line, variantOf: base))
                    }
                }
                let fr = clusterRect(c, em * 0.08 + (st.glow?.mode != .outer && st.glow != nil ? CGFloat(st.glow!.radius) * em : 0), M)
                fronts.append(.init(kind: .glyphFront(cluster: ci, variant: .base), block: bi, transform: M, rect: fr,
                                    char: unit.char, word: unit.word, line: unit.line))
                if hiStyle != nil {
                    fronts.append(.init(kind: .glyphFront(cluster: ci, variant: .highlight), block: bi, transform: M, rect: fr,
                                        char: unit.char, word: unit.word, line: unit.line, variantOf: -1))
                }
            }
            // fix variantOf indices for fronts (they follow their base front)
            let firstFront = items.count
            for (k, var f) in fronts.enumerated() {
                if f.variantOf != nil { f.variantOf = firstFront + k - 1 }
                items.append(f)
            }
            // pivots
            let L = b.layout
            b.charPivots = [CGPoint](repeating: b.center, count: L.visibleCharCount)
            for c in L.clusters where c.charIndex >= 0 { b.charPivots[c.charIndex] = c.center.applying(T) }
            b.wordPivots = L.words.map { $0.rect.isEmpty ? b.center : CGPoint(x: $0.rect.midX, y: $0.rect.midY).applying(T) }
            b.linePivots = L.lines.map { CGPoint(x: $0.rect.midX, y: $0.rect.midY).applying(T) }
            blocks[bi] = b
        }
        var bounds = CGRect.null
        for it in items { bounds = bounds.union(it.rect) }
        if bounds.isNull { bounds = textBounds.isNull ? CGRect(x: 0, y: 0, width: 1, height: 1) : textBounds }
        // Symmetric around the text box centre: the layer is anchored on the text, so a shadow, an offset background or
        // a bubble tail never shifts the text itself.
        if !textBounds.isNull {
            let c = CGPoint(x: textBounds.midX, y: textBounds.midY)
            let hw = max(bounds.maxX - c.x, c.x - bounds.minX), hh = max(bounds.maxY - c.y, c.y - bounds.minY)
            bounds = CGRect(x: c.x - hw, y: c.y - hh, width: hw * 2, height: hh * 2)
        }
        // Separated template part: the whole template's layout fixes the bounds (the part stays where it was in the
        // template), only its own layer is drawn.
        if !hidden.isEmpty {
            var remap: [Int: Int] = [:]
            var kept: [TextScene.Item] = []
            for (i, it) in items.enumerated() where !hidden.contains(it.block) { remap[i] = kept.count; kept.append(it) }
            items = kept.map { var it = $0; if let v = it.variantOf, v >= 0 { it.variantOf = remap[v] }; return it }
        }
        return TextScene(blocks: blocks, items: items, bounds: bounds, textBounds: textBounds.isNull ? bounds : textBounds)
    }
}

extension TextLayoutResult { typealias Element = LaidCluster }
