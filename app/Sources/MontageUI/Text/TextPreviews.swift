import SwiftUI
import AppKit
import MontageCore
import MontageEffects
import MontageEngine

/// Rendered thumbnails of text styles / bubbles / templates for tiles. Rendered off the main thread with the real text
/// engine (what you see on the tile is what the clip will look like) and cached for the session.
@MainActor
final class TextPreviewCache {
    static let shared = TextPreviewCache()
    private let cache = NSCache<NSString, NSImage>()
    init() { cache.countLimit = 600 }
    func get(_ key: String) -> NSImage? { cache.object(forKey: key as NSString) }
    func put(_ key: String, _ img: NSImage) { cache.setObject(img, forKey: key as NSString) }

    func image(_ key: String, _ content: TextContent, fontPx: Double) -> NSImage? {
        if let c = get(key) { return c }
        guard let cg = TextRasterizer.image(content, fontPx: fontPx, canvasWidthPx: fontPx * 18) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        put(key, img)
        return img
    }

    /// Renders tiles off the main thread ahead of time (the Text tab calls it on appear).
    func prewarm(_ items: [(key: String, content: TextContent, fontPx: Double)]) {
        let todo = items.filter { get($0.key) == nil }
        guard !todo.isEmpty else { return }
        Task.detached(priority: .utility) {
            for it in todo {
                guard let cg = TextRasterizer.image(it.content, fontPx: it.fontPx, canvasWidthPx: it.fontPx * 18) else { continue }
                await MainActor.run {
                    TextPreviewCache.shared.put(it.key, NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
                }
            }
        }
    }
}

struct TextPreviewImage: View {
    let key: String
    let content: TextContent
    var fontPx: Double = 44
    var padding: CGFloat = 6

    var body: some View {
        // Cached, else rendered right away (a 44 px tile costs ~1 ms; lazy grids only build visible tiles).
        if let image = TextPreviewCache.shared.image(key, content, fontPx: fontPx) {
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(padding)
        }
    }

    // Common preview contents
    static func style(_ d: TextStyleDescriptor, sample: String) -> TextContent {
        var t = TextContent(string: sample, fontSize: 0.1); t.bold = true
        d.restyle(&t)
        t.curve = min(t.curve, 0.35)
        return t
    }

    static func bubble(_ d: TextBubbleDescriptor) -> TextContent {
        var t = TextContent(string: "Aa", fontSize: 0.1); t.bold = true; t.bubbleID = d.id; t.color = d.textColor
        return t
    }
}

/// Tile preview of a per-glyph text animation: "ABC" whose letters move with the descriptor's own glyph spec.
struct GlyphAnimationPreview: View {
    let descriptor: AnimationDescriptor
    let playing: Bool
    let start: Date
    static let letters = Array("ABC")

    var body: some View {
        SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !playing)) { tl in
            let p = progress(at: tl.date)
            HStack(spacing: 1) {
                ForEach(Array(Self.letters.enumerated()), id: \.offset) { i, ch in
                    let s = state(i, p)
                    Text(verbatim: String(ch))
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.9 + 0.1 * s.highlight))
                        .scaleEffect(x: s.scale.x, y: s.scale.y)
                        .rotationEffect(.degrees(s.rotation))
                        .offset(x: s.offset.x * 17, y: s.offset.y * 17)
                        .opacity(s.opacity)
                }
            }
        }
    }

    func progress(at date: Date) -> Double {
        // idle: a mid-animation still (letters caught part-way) so tiles differ at rest, like CapCut's stills
        guard playing else { return descriptor.phase == .out ? 0.6 : (descriptor.phase == .combo ? 0.25 : 0.45) }
        let d = max(descriptor.defaultDuration.seconds, 0.3)
        let t = date.timeIntervalSince(start)
        if descriptor.phase == .combo { return (t / d).truncatingRemainder(dividingBy: 1) }
        return min(t.truncatingRemainder(dividingBy: d + 0.5) / d, 1)
    }

    func state(_ i: Int, _ p: Double) -> GlyphState {
        guard let g = descriptor.glyph else { return GlyphState() }
        let n = Self.letters.count
        let unit: GlyphUnitInfo
        switch g.unit {
        case .character: unit = GlyphUnitInfo(index: i, count: n, random: glyphRandom(i, seed: 11))
        case .word, .line, .all: unit = GlyphUnitInfo(index: 0, count: 1, random: 0.5)
        }
        return g.state(progress: p, phase: descriptor.phase, unit: unit)
    }
}
