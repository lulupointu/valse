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

/// Rendered frames of per-glyph text animation tiles ("ABC123" through the real text engine, CapCut-style), made off
/// the main thread once per animation and kept for the session (24 frames × ~150×40 px each).
@MainActor
final class GlyphAnimationFrames: ObservableObject {
    static let shared = GlyphAnimationFrames()
    nonisolated static let sample = "ABC123"
    nonisolated static let frameCount = 24
    @Published private(set) var frames: [String: [NSImage]] = [:]
    private var pending: Set<String> = []

    /// Progress values of the rendered loop: In 0→1, Out 0→1, Loop one cycle.
    nonisolated static func progresses(_ phase: AnimationPhaseKind) -> [Double] {
        (0..<frameCount).map { Double($0) / Double(frameCount - (phase == .combo ? 0 : 1)) }
    }

    /// Frame shown while idle: a mid-animation pose (letters caught in motion), like CapCut's tile stills.
    static func stillIndex(_ phase: AnimationPhaseKind) -> Int {
        switch phase {
        case .in: return Int(Double(frameCount - 1) * 0.7)
        case .out: return Int(Double(frameCount - 1) * 0.3)
        case .combo: return frameCount / 4
        }
    }

    nonisolated static func content() -> TextContent {
        var t = TextContent(string: sample, fontSize: 0.1); t.bold = true
        return t
    }

    func frames(for d: AnimationDescriptor) -> [NSImage]? {
        if let f = frames[d.id] { return f }
        request([d])
        return nil
    }

    func request(_ ds: [AnimationDescriptor]) {
        let todo = ds.filter { $0.glyph != nil && frames[$0.id] == nil && !pending.contains($0.id) }
        guard !todo.isEmpty else { return }
        for d in todo { pending.insert(d.id) }
        let jobs = todo.map { ($0.id, $0.phase) }
        Task.detached(priority: .utility) {
            for (id, phase) in jobs {
                let cgs = TextRasterizer.animationFrames(Self.content(), fontPx: 40, animationID: id, progresses: Self.progresses(phase),
                                                         maxMarginEm: 0.6)
                let imgs = cgs.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
                await MainActor.run {
                    GlyphAnimationFrames.shared.frames[id] = imgs
                    GlyphAnimationFrames.shared.pending.remove(id)
                }
            }
        }
    }
}

/// Tile preview of a per-glyph text animation: "ABC123" rendered by the text engine with the descriptor's own glyph
/// spec. Idle = a mid-animation still; hovered (or `playing`) = the rendered loop.
struct GlyphAnimationPreview: View {
    let descriptor: AnimationDescriptor
    let playing: Bool
    let start: Date
    @ObservedObject private var cache = GlyphAnimationFrames.shared

    var body: some View {
        if let frames = cache.frames(for: descriptor), !frames.isEmpty {
            SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !playing)) { tl in
                Image(nsImage: frames[min(index(at: tl.date, count: frames.count), frames.count - 1)])
                    .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .padding(.horizontal, 4)
            }
        } else {
            ProgressView().controlSize(.small).opacity(0.5)
        }
    }

    func index(at date: Date, count: Int) -> Int {
        guard playing else { return GlyphAnimationFrames.stillIndex(descriptor.phase) }
        let d = max(descriptor.defaultDuration.seconds, 0.3)
        let t = date.timeIntervalSince(start)
        if descriptor.phase == .combo { return Int((t / d).truncatingRemainder(dividingBy: 1) * Double(count)) }
        // play once, hold the end pose 0.5 s, repeat
        return Int(min(t.truncatingRemainder(dividingBy: d + 0.5) / d, 1) * Double(count - 1))
    }
}
