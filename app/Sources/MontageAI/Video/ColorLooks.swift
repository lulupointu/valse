@preconcurrency import AVFoundation
import CoreGraphics
import ImageIO
import CryptoKit
import Foundation
import Vision
import MontageCore
import MontageEffects
import MontageEngine

/// AI colour looks (CL-007 Auto adjust, CL-008 Color correction, CL-009 Color match, AI-055): frame statistics →
/// a generated 33³ LUT (`ColorTransfer`) saved in `Application Support/Montage/Generated/looks/<kind>.<hash>.cube` and
/// registered as an unlisted LUT effect `ai.look.<kind>.<hash>` (one Strength param, preview = export). The clip keeps
/// one instance per kind; the strength stays editable and keyframeable.
public enum ColorLooks {
    public enum Kind: String, Sendable, CaseIterable {
        case auto, match, correct
        public var prefix: String { "ai.look.\(rawValue)." }
        var title: String { switch self { case .auto: return "Auto adjust"; case .match: return "Color match"; case .correct: return "Color correction" } }
    }

    public static var directory: URL { MontagePaths.supportDirectory.appendingPathComponent("Generated/looks", isDirectory: true) }

    public static func kind(of e: EffectInstance) -> Kind? { Kind.allCases.first { e.typeID.hasPrefix($0.prefix) } }
    public static func isLook(_ e: EffectInstance) -> Bool { e.typeID.hasPrefix("ai.look.") }

    nonisolated(unsafe) private static var loaded = false
    private static let lock = NSLock()

    /// Registers every saved look (startup, project open). Idempotent.
    public static func loadAll() {
        lock.withLock {
            guard !loaded else { return }
            loaded = true
            let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for f in files where f.hasSuffix(".cube") {
                guard let lut = try? LUT.load(directory.appendingPathComponent(f)) else { continue }
                LUTLibrary.shared.add(lut, id: "ai.look." + (f as NSString).deletingPathExtension, name: lut.title, listed: false)
            }
        }
    }

    /// Saves + registers a generated LUT, returns the effect id (content addressed).
    public static func register(_ lut: LUT, kind: Kind) throws -> String {
        let text = lut.cubeText()
        let hash = SHA256.hash(data: Data(text.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        let name = "\(kind.rawValue).\(hash)"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).cube")
        if !FileManager.default.fileExists(atPath: url.path) { try text.write(to: url, atomically: true, encoding: .utf8) }
        return LUTLibrary.shared.add(lut, id: "ai.look." + name, name: lut.title, listed: false)
    }

    // MARK: Statistics

    /// Pixels of `count` frames spread over a clip's source range (≤ 160 px decodes), or of an image.
    public static func pixels(_ asset: MediaAsset, range: TimeRange?, count: Int = 8) async throws -> [SIMD3<Float>] {
        try await frames(asset, range: range, count: count).flatMap(rgb)
    }

    /// `count` frames spread over a clip's source range (≤ `maxSize` px decodes), or the image.
    public static func frames(_ asset: MediaAsset, range: TimeRange?, count: Int = 8, maxSize: Int = 160) async throws -> [CGImage] {
        var images: [CGImage] = []
        if asset.kind == .image {
            guard let src = CGImageSourceCreateWithURL(asset.url as CFURL, nil),
                  let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceThumbnailMaxPixelSize: maxSize,
                                                                         kCGImageSourceCreateThumbnailFromImageAlways: true] as CFDictionary)
            else { throw AIToolError.noInput }
            images = [img]
        } else {
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: asset.url))
            g.maximumSize = CGSize(width: maxSize, height: maxSize)
            g.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10); g.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
            let r = range ?? TimeRange(start: .zero, duration: asset.duration)
            for i in 0..<count {
                try Task.checkCancellation()
                let t = r.start.seconds + r.duration.seconds * (Double(i) + 0.5) / Double(count)
                if let img = try? await g.image(at: CMTime(seconds: t, preferredTimescale: 600)).image { images.append(img) }
            }
        }
        return images
    }

    public static func pixels(of image: CGImage) -> [SIMD3<Float>] {
        let k = min(1, 160 / Double(max(image.width, image.height, 1)))
        let w = max(1, Int(Double(image.width) * k)), h = max(1, Int(Double(image.height) * k))
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return rgb(ctx.makeImage()!)
    }

    static func rgb(_ img: CGImage) -> [SIMD3<Float>] {
        let w = img.width, h = img.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(w * h)
        for i in 0..<(w * h) { out.append(SIMD3(Float(buf[i * 4]), Float(buf[i * 4 + 1]), Float(buf[i * 4 + 2])) / 255) }
        return out
    }

    /// Pixels of the inner cheek / nose area of every face Vision finds in `img` (empty without faces).
    public static func skinPixels(_ img: CGImage) -> [SIMD3<Float>] {
        let req = VNDetectFaceRectanglesRequest()
        guard (try? VNImageRequestHandler(cgImage: img).perform([req])) != nil else { return [] }
        let faces = (req.results ?? []).filter { $0.confidence > 0.4 }
        guard !faces.isEmpty else { return [] }
        let px = rgb(img), w = img.width, h = img.height
        var out: [SIMD3<Float>] = []
        for f in faces {
            let b = f.boundingBox   // normalized, origin bottom-left
            let x0 = Int((b.minX + b.width * 0.25) * Double(w)), x1 = Int((b.maxX - b.width * 0.25) * Double(w))
            let yTop = 1 - (b.minY + b.height * 0.7), yBot = 1 - (b.minY + b.height * 0.15)   // eyes … mouth, y down
            let y0 = Int(yTop * Double(h)), y1 = Int(yBot * Double(h))
            for y in max(0, y0)..<min(h, max(y0 + 1, y1)) {
                for x in max(0, x0)..<min(w, max(x0 + 1, x1)) { out.append(px[y * w + x]) }
            }
        }
        return out
    }

    // MARK: Jobs → one undoable edit each

    /// Auto adjust / Color correction on a clip.
    public static func autoAdjust(project p: Project, clipID: ClipID, kind: Kind = .auto, strength: Double = 0.8) async throws -> any EditCommand {
        guard let c = p.timeline.clip(clipID), let a = c.mediaID.flatMap(p.asset) else { throw AIToolError.noInput }
        let imgs = try await frames(a, range: c.sourceRange, maxSize: kind == .correct ? 360 : 160)
        let stats = ColorStats.of(imgs.flatMap(rgb))
        // Color correction (CL-008): white balance from the faces' skin when there are faces
        let skin = kind == .correct ? ColorTransfer.skinMean(imgs.flatMap(skinPixels)) : nil
        let id = try register(ColorTransfer.autoAdjustLUT(stats, title: kind.title, skin: skin), kind: kind)
        return Edit(kind == .auto ? "cmd.autoAdjust" : "cmd.colorCorrect") { p in try set(id, kind: kind, strength: strength, on: clipID, in: &p) }
    }

    /// Color match of a clip to reference pixels (a frame of another clip or an imported image).
    public static func match(project p: Project, clipID: ClipID, reference: [SIMD3<Float>], strength: Double = 1) async throws -> any EditCommand {
        guard let c = p.timeline.clip(clipID), let a = c.mediaID.flatMap(p.asset), !reference.isEmpty else { throw AIToolError.noInput }
        let s = ColorStats.of(try await pixels(a, range: c.sourceRange)), r = ColorStats.of(reference)
        let id = try register(ColorTransfer.matchLUT(source: s, reference: r), kind: .match)
        return Edit("cmd.colorMatch") { p in try set(id, kind: .match, strength: strength, on: clipID, in: &p) }
    }

    /// Replaces the clip's look of `kind` (keeps its strength when there was one). Looks go first in the stack.
    public static func set(_ id: String, kind: Kind, strength: Double, on clipID: ClipID, in p: inout Project) throws {
        guard var c = p.timeline.clip(clipID), let d = Registries.effects[id] else { throw EditError.clipNotFound }
        let old = c.effects.firstIndex { ColorLooks.kind(of: $0) == kind }
        var inst = d.makeInstance()
        inst.params["intensity"] = old.flatMap { c.effects[$0].params["intensity"] } ?? .scalar(strength)
        if let old { c.effects[old] = inst } else { c.effects.insert(inst, at: 0) }
        p.timeline[clip: clipID] = c
    }

    public static func remove(_ kind: Kind, from clipID: ClipID, in p: inout Project) {
        p.timeline[clip: clipID]?.effects.removeAll { ColorLooks.kind(of: $0) == kind }
    }
}
