@preconcurrency import Metal
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import ValseCore
import ValseEffects

/// Custom stickers (ST-003, CapCut Stickers ▸ "Yours" ▸ Import): still images (PNG, JPEG, HEIC, WebP…), animated
/// images (GIF, APNG, animated WebP — frame delays from the file, looped), Lottie JSON, and frame-sequence stickers
/// (3–49 images played at 1–50 fps, once or repeating).
///
/// Like `LUTLibrary`: files are copied (content hash ids) to `~/Library/Application Support/Valse/Stickers/<id>/`
/// with an `index.json`, and every entry is registered as a `StickerDescriptor` (`.user(id)`, group
/// `sticker.group.yours`) so it behaves like a built-in sticker: tiles, drag & drop, layers, render and export.
public final class UserStickerLibrary: @unchecked Sendable {
    nonisolated(unsafe) public static var shared = UserStickerLibrary(directory: defaultDirectory)
    public static let idPrefix = "user.sticker."
    public static let groupKey = "sticker.group.yours"
    public static let maxSequenceFrames = 49
    public static let minSequenceFrames = 3

    public static var defaultDirectory: URL {
        if let d = ProcessInfo.processInfo.environment["VALSE_USER_STICKERS_DIR"], !d.isEmpty { return URL(fileURLWithPath: d) }
        let name = ProcessInfo.processInfo.processName
        if CommandLine.arguments.contains("--uitest") || name.contains("xctest") || name.contains("swiftpm-testing") {
            // UI / unit tests: sandboxed, empty per run (never the user's library)
            return FileManager.default.temporaryDirectory.appendingPathComponent("valse-uitest-stickers-\(getpid())", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Valse/Stickers", isDirectory: true)
    }

    public enum Kind: String, Codable, Sendable { case still, animated, lottie, sequence }

    public struct Entry: Codable, Sendable, Hashable {
        public let id: String
        public var name: String
        public let kind: Kind
        /// File names inside the entry folder (one, or the frames of a sequence in order).
        public let files: [String]
        /// Sequence frame rate (1…50).
        public var fps: Double
        public var loops: Bool
        /// Pixel aspect (width / height) of the first frame.
        public var aspect: Double
    }

    public let directory: URL
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    /// Decoded animation timing per entry: cumulative frame end times (s) for animated images.
    private var timings: [String: [Double]] = [:]
    private var textures: [String: MTLTexture] = [:]
    private var textureOrder: [String] = []
    private var thumbs: [String: CGImage] = [:]

    public init(directory: URL) { self.directory = directory }

    public var all: [Entry] { lock.withLock { order.compactMap { entries[$0] } } }
    public func entry(_ id: String) -> Entry? { lock.withLock { entries[id] } }
    func folder(_ id: String) -> URL { directory.appendingPathComponent(String(id.dropFirst(Self.idPrefix.count)), isDirectory: true) }

    // MARK: Import

    public enum ImportError: Error { case unsupported, unreadable, sequenceCount }

    /// Static image extensions accepted for stills and frame sequences.
    public static let imageTypes: [UTType] = [.png, .jpeg, .heic, .tiff, .bmp, .gif, .webP].compactMap { $0 }
    public static var importTypes: [UTType] { imageTypes + [.json] + (UTType(filenameExtension: "apng").map { [$0] } ?? []) }

    /// Imports one sticker per file (still / animated / Lottie). Returns the new ids (registered).
    @discardableResult
    public func importFiles(_ urls: [URL]) throws -> [String] {
        try urls.map { url in
            let ext = url.pathExtension.lowercased()
            if ext == "json" {
                guard (try? LottieAnimation(url: url)) != nil else { throw ImportError.unsupported }
                return try store([url], kind: .lottie, name: url.deletingPathExtension().lastPathComponent, fps: 0, loops: true, aspect: 1)
            }
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0,
                  let size = Self.pixelSize(src) else { throw ImportError.unreadable }
            let animated = CGImageSourceGetCount(src) > 1
            return try store([url], kind: animated ? .animated : .still, name: url.deletingPathExtension().lastPathComponent,
                             fps: 0, loops: true, aspect: size.width / max(size.height, 1))
        }
    }

    /// "Import as frame sequence sticker": 3–49 still images (sorted by name), `fps` 1…50, played once or repeated.
    @discardableResult
    public func importSequence(_ urls: [URL], fps: Double, loops: Bool) throws -> String {
        guard (Self.minSequenceFrames...Self.maxSequenceFrames).contains(urls.count) else { throw ImportError.sequenceCount }
        let sorted = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard let src = CGImageSourceCreateWithURL(sorted[0] as CFURL, nil), let size = Self.pixelSize(src) else { throw ImportError.unreadable }
        return try store(sorted, kind: .sequence, name: sorted[0].deletingPathExtension().lastPathComponent,
                         fps: min(max(fps, 1), 50), loops: loops, aspect: size.width / max(size.height, 1))
    }

    private func store(_ urls: [URL], kind: Kind, name: String, fps: Double, loops: Bool, aspect: Double) throws -> String {
        var hasher = SHA256()
        for u in urls { hasher.update(data: try Data(contentsOf: u)) }
        hasher.update(data: Data("\(kind.rawValue)|\(fps)|\(loops)".utf8))
        let hash = hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
        let id = Self.idPrefix + hash
        if entry(id) != nil { return id }
        let dir = folder(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var files: [String] = []
        for (i, u) in urls.enumerated() {
            let fn = String(format: "%03d.", i) + (u.pathExtension.isEmpty ? "img" : u.pathExtension.lowercased())
            let dst = dir.appendingPathComponent(fn)
            if !FileManager.default.fileExists(atPath: dst.path) { try FileManager.default.copyItem(at: u, to: dst) }
            files.append(fn)
        }
        let e = Entry(id: id, name: name, kind: kind, files: files, fps: fps, loops: loops, aspect: aspect)
        lock.withLock { if entries[id] == nil { order.append(id) }; entries[id] = e }
        try writeIndex()
        register(e)
        return id
    }

    public func remove(_ id: String) {
        lock.withLock {
            entries[id] = nil; order.removeAll { $0 == id }; timings[id] = nil; thumbs[id] = nil
            for k in textures.keys where k.hasPrefix(id + "#") { textures[k] = nil }
        }
        try? FileManager.default.removeItem(at: folder(id))
        try? writeIndex()
    }

    public func rename(_ id: String, to name: String) {
        lock.withLock { entries[id]?.name = name }
        if let e = entry(id) { register(e) }
        try? writeIndex()
    }

    /// Registers every sticker already in the library (startup).
    public func loadAll() {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("index.json")),
              let list = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        for e in list where FileManager.default.fileExists(atPath: folder(e.id).path) {
            lock.withLock { if entries[e.id] == nil { order.append(e.id) }; entries[e.id] = e }
            register(e)
        }
    }

    private func register(_ e: Entry) {
        Registries.stickers.register(StickerDescriptor(id: e.id, nameKey: e.name, groupKey: Self.groupKey, source: .user(e.id),
                                                       tags: ["custom", "import", e.kind.rawValue]))
    }

    private func writeIndex() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(all)
        try data.write(to: directory.appendingPathComponent("index.json"), options: .atomic)
    }

    static func pixelSize(_ src: CGImageSource) -> CGSize? {
        guard let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Double, let h = p[kCGImagePropertyPixelHeight] as? Double, w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }

    // MARK: Playback

    /// Canvas-pixel size of the sticker inside its nominal `side` × `side` box (aspect-fitted).
    public func size(_ id: String, side: Double) -> Size2 {
        let a = entry(id)?.aspect ?? 1
        return a >= 1 ? Size2(side, side / a) : Size2(side * a, side)
    }

    /// (file URL, frame index inside that file) shown `seconds` after the clip start.
    func frame(_ e: Entry, seconds: Double) -> (URL, Int) {
        let dir = folder(e.id)
        switch e.kind {
        case .still, .lottie: return (dir.appendingPathComponent(e.files[0]), 0)
        case .sequence:
            var i = Int((max(seconds, 0) * e.fps).rounded(.down))
            i = e.loops ? i % e.files.count : min(i, e.files.count - 1)
            return (dir.appendingPathComponent(e.files[i]), 0)
        case .animated:
            let url = dir.appendingPathComponent(e.files[0])
            let ends = animationTimes(e, url)
            guard let total = ends.last, total > 0 else { return (url, 0) }
            let t = e.loops ? max(seconds, 0).truncatingRemainder(dividingBy: total) : min(max(seconds, 0), total - 1e-6)
            return (url, ends.firstIndex { t < $0 } ?? ends.count - 1)
        }
    }

    /// Cumulative frame end times of an animated image (GIF / APNG / WebP delays; ≥ 20 ms like browsers).
    private func animationTimes(_ e: Entry, _ url: URL) -> [Double] {
        if let t = lock.withLock({ timings[e.id] }) { return t }
        var out: [Double] = []
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
            var acc = 0.0
            for i in 0..<CGImageSourceGetCount(src) {
                let p = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any] ?? [:]
                var d: Double?
                for (dictKey, unclamped, clamped) in [(kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
                                                      (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
                                                      (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime)] {
                    if let dict = p[dictKey] as? [CFString: Any] {
                        d = (dict[unclamped] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? dict[clamped] as? Double
                        if d != nil { break }
                    }
                }
                acc += max(d ?? 0.1, 0.02)
                out.append(acc)
            }
        }
        lock.withLock { timings[e.id] = out }
        return out
    }

    /// Texture of the frame at `seconds` (max side `side` px), cached (LRU).
    public func texture(_ id: String, seconds: Double, side: Int) -> MTLTexture? {
        guard let e = entry(id) else { return nil }
        if e.kind == .lottie {
            return LottieLibrary.shared.texture(folder(id).appendingPathComponent(e.files[0]), seconds: seconds, side: side)
        }
        let (url, index) = frame(e, seconds: seconds)
        let key = "\(id)#\(url.lastPathComponent)#\(index)@\(side)"
        if let t = lock.withLock({ textures[key] }) { return t }
        guard let img = Self.image(url, index: index, maxSide: side), let tex = Self.makeTexture(img) else { return nil }
        lock.withLock {
            textures[key] = tex; textureOrder.append(key)
            if textureOrder.count > 96 { textures[textureOrder.removeFirst()] = nil }
        }
        return tex
    }

    /// Poster frame for library tiles (144 px).
    public func thumbnail(_ id: String) -> CGImage? {
        if let t = lock.withLock({ thumbs[id] }) { return t }
        guard let e = entry(id) else { return nil }
        let url = folder(id).appendingPathComponent(e.files[0])
        let img = e.kind == .lottie ? LottieLibrary.shared.thumbnail(url) : Self.image(url, index: 0, maxSide: 144)
        if let img { lock.withLock { thumbs[id] = img } }
        return img
    }

    static func image(_ url: URL, index: Int, maxSide: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: max(8, maxSide)]
        return CGImageSourceCreateThumbnailAtIndex(src, min(index, max(CGImageSourceGetCount(src) - 1, 0)), opts as CFDictionary)
    }

    static func makeTexture(_ img: CGImage) -> MTLTexture? {
        let w = img.width, h = img.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = .shaderRead
        guard let tex = MetalContext.shared.device.makeTexture(descriptor: d) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: w * 4)
        return tex
    }
}
