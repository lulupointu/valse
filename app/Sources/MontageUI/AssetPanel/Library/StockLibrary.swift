@preconcurrency import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import MontageCore
import MontageEffects
import MontageEngine

/// One Media ▸ Library entry (MI-023 local substitute / MI-026): a colour clip, a still (gradient) or a short video
/// (animated background, countdown, green-screen element). Everything is generated locally from a recipe
/// (`StockLibrary.project(for:)`) by our own renderer: no third-party assets, no network.
nonisolated struct StockItem: Identifiable, Sendable, Hashable {
    enum Kind: Sendable, Hashable { case solid(RGBA); case still; case video(seconds: Double) }

    let id: String
    let nameKey: String
    let category: String
    let kind: Kind
    /// English search tags.
    let tags: [String]
    let recipe: Recipe

    enum Recipe: Sendable, Hashable {
        case solid
        /// Library generator `name` (LibraryGenerators) with colours a/b/c and style.
        case generator(name: String, colors: [RGBA], style: Double, speed: Double)
        /// Countdown ring generator (style) under one big number per second.
        case countdown(seconds: Int, style: Int, colors: [RGBA], text: RGBA)
    }

    var isVideo: Bool { if case .video = kind { return true }; return false }
    var duration: Double {
        switch kind { case .video(let s): return s; default: return 0 }
    }
    /// Representative time for the card still.
    var thumbnailTime: Double {
        switch recipe {
        case .countdown: return 0.35
        case .generator(let n, _, _, _) where n.hasPrefix("gs."): return n == "gs.like" ? 1.3 : 1.0
        default: return isVideo ? 2.0 : 0
        }
    }
}

/// Observable state for the asset panel (cards show a progress ring while their file renders).
@MainActor @Observable
final class StockLibraryState {
    static let shared = StockLibraryState()
    var rendering: Set<String> = []
}

nonisolated enum StockLibrary {
    /// Bump when a recipe or a generator changes so cached renders are redone.
    static let version = 1
    static let categories = ["colors", "gradients", "backgrounds", "countdowns", "greenscreen"]
    static let renderSize = CGSize(width: 1920, height: 1080)

    /// Test hook: render into another folder.
    nonisolated(unsafe) static var directoryOverride: URL?
    static var directory: URL {
        directoryOverride ?? MontagePaths.cacheDirectory.appendingPathComponent("library", isDirectory: true)
    }

    static subscript(id: String) -> StockItem? { all.first { $0.id == id } }
    static func items(in category: String) -> [StockItem] { all.filter { $0.category == category } }

    // MARK: Catalogue

    static let all: [StockItem] = colors + gradients + backgrounds + countdowns + greenscreen

    static let colors: [StockItem] = [
        ("black", RGBA.black, ["black", "blank", "video"]), ("white", .white, ["white", "blank"]), ("gray", RGBA(0.5, 0.5, 0.5), ["grey", "gray"]),
        ("red", RGBA(hex: 0xE5484D), ["red"]), ("green", RGBA(hex: 0x30A46C), ["green"]), ("blue", RGBA(hex: 0x0091FF), ["blue"]),
        ("yellow", RGBA(hex: 0xF5D90A), ["yellow"]), ("chroma", RGBA(0, 1, 0), ["green screen", "chroma", "key"]),
    ].map { StockItem(id: "color.\($0.0)", nameKey: "media.color.\($0.0)", category: "colors", kind: .solid($0.1), tags: $0.2 + ["colour", "color", "solid"], recipe: .solid) }

    private static func gradient(_ name: String, _ a: UInt32, _ b: UInt32, _ c: UInt32, style: Double, _ tags: [String]) -> StockItem {
        StockItem(id: "gradient.\(name)", nameKey: "library.item.gradient.\(name)", category: "gradients", kind: .still,
                  tags: tags + ["gradient", "background"],
                  recipe: .generator(name: "gradient", colors: [RGBA(hex: a), RGBA(hex: b), RGBA(hex: c)], style: style, speed: 1))
    }

    static let gradients: [StockItem] = [
        gradient("sunset", 0xFFB36B, 0xF0607E, 0x6B3FA0, style: 0, ["warm", "orange", "pink", "purple"]),
        gradient("ocean", 0x4FD1C5, 0x2B6CB0, 0x1A2350, style: 1, ["blue", "sea", "cool"]),
        gradient("peach", 0xFFE3D3, 0xFFB199, 0xE8747C, style: 2, ["soft", "pastel", "radial"]),
        gradient("mint", 0xE6FFF4, 0x8FE3C3, 0x2F9E8F, style: 0, ["green", "fresh", "pastel"]),
        gradient("lavender", 0xC7B8FF, 0xF7C6E6, 0x8FD3FE, style: 4, ["mesh", "pastel", "purple"]),
        gradient("night", 0x3A2A7A, 0x161A3A, 0x05060F, style: 2, ["dark", "radial", "blue"]),
        gradient("fire", 0xFFE259, 0xFF8A3D, 0xD7263D, style: 1, ["red", "orange", "hot"]),
        gradient("holo", 0x9CF6FB, 0xF7A6E0, 0xFFF3A6, style: 3, ["rainbow", "conic", "holographic"]),
        gradient("forest", 0xC8E66E, 0x3E8E5A, 0x12352B, style: 0, ["green", "nature"]),
        gradient("candy", 0xFF9AC4, 0xA48BFF, 0x6DE0FF, style: 4, ["mesh", "pink", "blue"]),
        gradient("mono", 0x5A5A60, 0x2A2A2E, 0x0E0E10, style: 2, ["grey", "dark", "neutral"]),
        gradient("gold", 0xFFF1C1, 0xE6B655, 0x8A5A12, style: 0, ["gold", "luxury", "yellow"]),
    ]

    private static func bg(_ name: String, _ gen: String, _ a: UInt32, _ b: UInt32, _ c: UInt32, style: Double = 0, speed: Double = 1,
                           _ tags: [String]) -> StockItem {
        StockItem(id: "bg.\(name)", nameKey: "library.item.bg.\(name)", category: "backgrounds", kind: .video(seconds: 8),
                  tags: tags + ["background", "loop", "animated"],
                  recipe: .generator(name: gen, colors: [RGBA(hex: a), RGBA(hex: b), RGBA(hex: c)], style: style, speed: speed))
    }

    static let backgrounds: [StockItem] = [
        bg("aurora", "aurora", 0x3DF5A6, 0x7B5CFF, 0x07152E, ["northern lights", "night", "green"]),
        bg("aurora.pink", "aurora", 0xFF7AD9, 0x55D6FF, 0x120A2A, ["northern lights", "pink"]),
        bg("plasma", "plasma", 0xFF4F9A, 0x5B6CFF, 0x22E0C0, ["colourful", "psychedelic"]),
        bg("bokeh", "bokeh", 0xFFD27A, 0xFF9E6B, 0x1B1020, ["lights", "blur", "gold"]),
        bg("bokeh.blue", "bokeh", 0x7CC8FF, 0xB89CFF, 0x0A1426, ["lights", "blur", "blue"]),
        bg("lightleak", "lightleak", 0xFF9B42, 0xFF3D6E, 0x1A0A06, ["film", "warm", "light leak"]),
        bg("stars", "starfield", 0xFFFFFF, 0x9FC9FF, 0x05070F, speed: 1, ["space", "stars", "galaxy"]),
        bg("liquid", "liquid", 0xFF7EB3, 0x7AF0E0, 0x6A5BFF, ["fluid", "abstract", "colourful"]),
        bg("waves", "waves", 0xFFE7C2, 0x6FC3DF, 0x1F4E79, ["sea", "ocean", "calm"]),
        bg("synthwave", "synthwave", 0xFF5FA2, 0x2EE6FF, 0x120326, ["retro", "80s", "neon", "grid"]),
        bg("dust", "dust", 0x1E2A44, 0x0B0F1C, 0xFFE7B0, ["particles", "dark", "cinematic"]),
        bg("confetti", "confetti", 0xFFF4E0, 0xFF5E7E, 0x3D8BFF, ["party", "celebration", "birthday"]),
        bg("rays", "rays", 0xFFC93C, 0xFF8A1F, 0xFFF6C8, ["sun", "burst", "comic"]),
        bg("grain", "grain", 0xF08A5D, 0x3E3A6D, 0xF7D488, ["film", "vintage", "noise"]),
        bg("blobs", "blobs", 0x8B7CFF, 0xFF8FCB, 0x14122B, ["lava", "abstract", "soft"]),
        bg("pattern", "pattern", 0xFFCF5C, 0xFF6F91, 0x26203D, ["geometric", "shapes", "retro"]),
    ]

    private static func countdown(_ name: String, seconds: Int, style: Int, _ a: UInt32, _ b: UInt32, _ c: UInt32, text: RGBA) -> StockItem {
        StockItem(id: "countdown.\(name).\(seconds)", nameKey: "library.item.countdown.\(name)", category: "countdowns",
                  kind: .video(seconds: Double(seconds)), tags: ["countdown", "timer", "intro", "\(seconds)"],
                  recipe: .countdown(seconds: seconds, style: style, colors: [RGBA(hex: a), RGBA(hex: b), RGBA(hex: c)], text: text))
    }

    static let countdowns: [StockItem] = [
        countdown("modern", seconds: 3, style: 0, 0x57BECB, 0x1F3A5F, 0x0B0D14, text: .white),
        countdown("modern", seconds: 5, style: 0, 0x57BECB, 0x1F3A5F, 0x0B0D14, text: .white),
        countdown("modern", seconds: 10, style: 0, 0x57BECB, 0x1F3A5F, 0x0B0D14, text: .white),
        countdown("leader", seconds: 5, style: 1, 0xB9B4A8, 0x000000, 0x000000, text: RGBA(0.08, 0.08, 0.08)),
        countdown("leader", seconds: 10, style: 1, 0xB9B4A8, 0x000000, 0x000000, text: RGBA(0.08, 0.08, 0.08)),
        countdown("neon", seconds: 3, style: 2, 0xFF3DB8, 0x2A0B3D, 0x05020A, text: RGBA(hex: 0xFFE6F7)),
    ]

    private static func gs(_ name: String, _ a: UInt32, _ b: UInt32, _ c: UInt32 = 0xFFFFFF, seconds: Double = 4, tags: [String]) -> StockItem {
        StockItem(id: "gs.\(name)", nameKey: "library.item.gs.\(name)", category: "greenscreen", kind: .video(seconds: seconds),
                  tags: tags + ["green screen", "chroma key", "overlay", "element"],
                  recipe: .generator(name: "gs.\(name)", colors: [RGBA(hex: a), RGBA(hex: b), RGBA(hex: c)], style: 0, speed: 1))
    }

    static let greenscreen: [StockItem] = [
        gs("like", 0xFF3B4E, 0x8A8A92, tags: ["like", "subscribe", "button", "social"]),
        gs("arrow", 0xFFCC1F, 0xFFFFFF, tags: ["arrow", "point", "down"]),
        gs("ring", 0xFFFFFF, 0x57BECB, tags: ["ripple", "pulse", "circle", "click"]),
        gs("sparkle", 0xFFE36E, 0xFFFFFF, tags: ["sparkle", "stars", "magic", "shine"]),
        gs("confetti", 0xFF5E7E, 0x3D8BFF, tags: ["confetti", "party", "celebration"]),
        gs("sweep", 0xFFFFFF, 0xFFFFFF, seconds: 3, tags: ["light", "shine", "flash", "sweep"]),
        gs("glitch", 0xFF2E63, 0x08D9D6, 0xFFFFFF, tags: ["glitch", "digital", "bars"]),
        gs("heart", 0xFF3B6B, 0xFF8FB1, tags: ["heart", "love", "like"]),
    ]

    // MARK: Recipes

    /// The project that renders `item` (canvas 1920×1080, 30 fps).
    static func project(for item: StockItem) -> Project {
        LibraryGenerators.register()
        var p = Project(name: item.id, settings: ProjectSettings(canvasSize: Size2(Double(renderSize.width), Double(renderSize.height)),
                                                                  frameRate: .fps30, backgroundColor: .black))
        let seconds = item.isVideo ? item.duration : 1
        var main = Track(kind: .video, isMain: true)
        var tracks: [Track] = []
        switch item.recipe {
        case .solid:
            if case .solid(let c) = item.kind { main.clips = [Clip(content: .solid(c), start: .zero, duration: Time(seconds))] }
        case .generator(let name, let cs, let style, let speed):
            var c = Clip(content: .solid(.black), start: .zero, duration: Time(seconds))
            c.effects = [LibraryGenerators.instance(name, cs[0], cs[1], cs[2], style: style, speed: speed)]
            main.clips = [c]
        case .countdown(let n, let style, let cs, let textColor):
            var c = Clip(content: .solid(.black), start: .zero, duration: Time(Double(n)))
            c.effects = [LibraryGenerators.instance("countdown", cs[0], cs[1], cs[2], style: Double(style))]
            main.clips = [c]
            var text = Track(kind: .text)
            text.clips = (0..<n).map { i in
                var t = TextContent(string: "\(n - i)", fontSize: style == 1 ? 0.42 : 0.30, color: textColor)
                t.bold = true
                if style == 2 { t.glow = TextGlowStyle(color: RGBA(cs[0].r, cs[0].g, cs[0].b), intensity: 0.9, radius: 0.35) }
                return Clip(content: .text(t), start: Time(Double(i)), duration: Time(1))
            }
            tracks.append(text)
        }
        var tl = Timeline()
        tl.tracks = [main] + tracks
        p.timeline = tl
        return p
    }

    // MARK: Files

    static func fileURL(_ i: StockItem) -> URL {
        directory.appendingPathComponent("\(i.id)-v\(version).\(i.isVideo ? "mp4" : "png")")
    }

    /// Rendered file on disk, if any (nil for colour clips).
    static func cachedFile(_ i: StockItem) -> URL? {
        if case .solid = i.kind { return nil }
        let u = fileURL(i)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// Renders `i` once (coalesced) and returns its file. Colour clips have no file (throws).
    static func file(_ i: StockItem) async throws -> URL {
        if case .solid = i.kind { throw StockError.noFile }
        if let u = cachedFile(i) { return u }
        return try await RenderCoordinator.shared.render(i)
    }

    /// Renders `i` to `url` (atomic). `seconds` overrides the video length (tests).
    static func render(_ i: StockItem, to url: URL, seconds: Double? = nil) async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".tmp-\(UUID().uuidString).\(url.pathExtension)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        var project = project(for: i)
        if i.isVideo {
            if let s = seconds {
                for t in project.timeline.tracks.indices {
                    project.timeline.tracks[t].clips = project.timeline.tracks[t].clips.compactMap { c in
                        guard c.start < Time(s) else { return nil }
                        var c = c; c.duration = min(c.duration, Time(s) - c.start); return c
                    }
                }
            }
            var settings = ExportSettings()
            settings.codec = .h264; settings.container = .mp4; settings.resolution = .p1080; settings.frameRate = .fps30
            settings.includeAudio = false; settings.bitrateMode = .higher
            try await Exporter.export(project: project, settings: settings, to: tmp)
        } else {
            let img = try await OfflineRenderer.renderFrame(project, at: .zero, size: renderSize)
            try writePNG(img, to: tmp)
        }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tmp, to: url)
    }

    static func writePNG(_ img: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw StockError.write }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { throw StockError.write }
    }

    enum StockError: Error { case noFile, write, render }

    // MARK: Thumbnails & hover previews

    static func thumbnailURL(_ i: StockItem, height: Int) -> URL {
        directory.appendingPathComponent("thumbs", isDirectory: true).appendingPathComponent("\(i.id)-v\(version)-\(height).png")
    }

    /// Card still (16:9, `height` px), memory + disk cached. At most two renders run at once.
    static func thumbnail(_ i: StockItem, height: Int) async -> CGImage? {
        let key = "\(i.id)#\(height)"
        if let img = ImageCache.shared.image(key) { return img }
        let disk = thumbnailURL(i, height: height)
        if let img = loadImage(disk) { ImageCache.shared.set(key, img); return img }
        await RenderGate.shared.acquire()
        defer { Task { await RenderGate.shared.release() } }
        if let img = ImageCache.shared.image(key) { return img }
        guard let img = try? await frames(i, times: [i.thumbnailTime], height: height).first else { return nil }
        ImageCache.shared.set(key, img)
        try? FileManager.default.createDirectory(at: disk.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? writePNG(img, to: disk)
        return img
    }

    /// `count` evenly spaced frames of a video item (hover animation), memory cached. Stills/colours → [].
    static func previewFrames(_ i: StockItem, count: Int, height: Int) async -> [CGImage] {
        guard i.isVideo, count > 0 else { return [] }
        let key = "\(i.id)#\(height)#\(count)"
        if let f = FrameCache.shared.frames(key) { return f }
        await RenderGate.shared.acquire()
        defer { Task { await RenderGate.shared.release() } }
        let d = i.duration
        let times = (0..<count).map { min(d - 0.05, (Double($0) + 0.5) * d / Double(count)) }
        let f = (try? await frames(i, times: times, height: height)) ?? []
        if !f.isEmpty { FrameCache.shared.set(key, f) }
        return f
    }

    /// Renders frames of the recipe at a small size through the real compositor (one composition build).
    static func frames(_ i: StockItem, times: [Double], height: Int) async throws -> [CGImage] {
        let project = project(for: i)
        let size = CGSize(width: (Double(height) * 16 / 9 / 2).rounded() * 2, height: Double(height))
        let built = try await CompositionBuilder.build(project: project, purpose: .export, renderSize: size)
        let gen = AVAssetImageGenerator(asset: built.composition)
        gen.videoComposition = built.videoComposition
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        gen.maximumSize = size
        var out: [CGImage] = []
        let last = max(.zero, built.duration - project.settings.frameRate.frameDuration)
        for t in times {
            let (img, _) = try await gen.image(at: min(Time(t), last).cmTime)
            out.append(img)
        }
        return out
    }

    static func loadImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    // MARK: Search

    /// Case/diacritic-insensitive match on localized name, category and English tags.
    static func matches(_ i: StockItem, _ query: String) -> Bool {
        func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let q = fold(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return true }
        let hay = ([tr(i.nameKey), tr("library.cat.\(i.category)")] + i.tags).map(fold)
        return q.split(separator: " ").allSatisfy { term in hay.contains { $0.contains(term) } }
    }
}

/// Coalesces concurrent renders of the same item.
actor RenderCoordinator {
    static let shared = RenderCoordinator()
    private var inflight: [String: Task<URL, any Error>] = [:]

    func render(_ i: StockItem) async throws -> URL {
        if let t = inflight[i.id] { return try await t.value }
        let t = Task<URL, any Error> {
            let url = StockLibrary.fileURL(i)
            if FileManager.default.fileExists(atPath: url.path) { return url }
            try await StockLibrary.render(i, to: url)
            return url
        }
        inflight[i.id] = t
        defer { inflight[i.id] = nil }
        return try await t.value
    }
}

/// Counting semaphore bounding thumbnail/preview renders (the grid may ask for ~60 at once).
actor RenderGate {
    static let shared = RenderGate(permits: 2)
    private var free: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(permits: Int) { free = permits }
    func acquire() async {
        if free > 0 { free -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if waiters.isEmpty { free += 1 } else { waiters.removeFirst().resume() }
    }
}

nonisolated final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, CGImage>()
    init() { cache.countLimit = 400 }
    func image(_ k: String) -> CGImage? { cache.object(forKey: k as NSString) }
    func set(_ k: String, _ i: CGImage) { cache.setObject(i, forKey: k as NSString) }
}

nonisolated final class FrameCache: @unchecked Sendable {
    static let shared = FrameCache()
    private let cache = NSCache<NSString, NSArray>()
    init() { cache.countLimit = 12 }
    func frames(_ k: String) -> [CGImage]? { (cache.object(forKey: k as NSString) as? [Any])?.map { $0 as! CGImage } }
    func set(_ k: String, _ f: [CGImage]) { cache.setObject(f as NSArray, forKey: k as NSString) }
}

extension DragPayload {
    /// Media ▸ Library item dragged to the timeline.
    public static func stock(_ id: String) -> String { "montage-stock:\(id)" }
    public static func parseStock(_ s: String) -> String? {
        s.hasPrefix("montage-stock:") ? String(s.dropFirst("montage-stock:".count)) : nil
    }
}

extension EditorStore {
    /// Adds a Library item at `time` (default: the playhead). Colour clips are inserted directly; other items are
    /// rendered once (card shows progress), imported into the bin (reused when already there) and placed like media.
    func addStockItem(_ i: StockItem, at time: Time? = nil, target: InsertTarget = .automatic) {
        let at = time ?? transport.playhead
        if case .solid(let color) = i.kind {
            var c = Clip(content: .solid(color), start: at, duration: Time(3))
            c.name = tr(i.nameKey)
            guard perform(InsertClip(c, target: target)) else { return }
            selection = [c.id]
            return
        }
        let state = StockLibraryState.shared
        guard !state.rendering.contains(i.id) else { return }
        state.rendering.insert(i.id)
        Task {
            defer { state.rendering.remove(i.id) }
            do {
                let url = try await StockLibrary.file(i)
                let asset = try await libraryAsset(url, name: tr(i.nameKey))
                addToTimeline(asset.id, at: at, target: target)
            } catch {
                showToast(tr("library.toast.failed"), error: true)
            }
        }
    }

    /// Bin asset for a rendered library file (existing one reused by path or content hash).
    func libraryAsset(_ url: URL, name: String) async throws -> MediaAsset {
        if let e = project.media.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) { return e }
        var a = try await Task.detached { try await MediaProbe.probe(url) }.value
        if let e = project.media.first(where: { $0.contentHash == a.contentHash }) { return e }
        a.name = name
        guard perform(AddMedia([a])) else { throw StockLibrary.StockError.render }
        let added = a
        await ProxyManager.shared.request([added])
        proxyPending.formUnion([added].filter { ProxyManager.shared.isPending($0) }.map(\.contentHash))
        Task.detached { _ = await ThumbnailCache.shared.thumbnail(added, at: .zero, height: 96) }
        return added
    }
}
