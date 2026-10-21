@preconcurrency import AVFoundation
@preconcurrency import CoreML
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import Foundation
import MontageCore
import MontageEngine

/// LaMa inpainting (Core ML, 800×800). The package ships zipped; first use unzips it next to the zip and compiles it
/// into `Caches/Montage/models/LaMa.mlmodelc`. The model is loaded per job and released afterwards (≈ 600 MB).
public final class LaMaInpainter: @unchecked Sendable {
    public static let side = 800
    let model: MLModel

    public static var isAvailable: Bool { ModelCatalog.installedURL(ModelCatalog.lama) != nil }

    // One model per process (~600 MB): concurrent AI remove jobs share it, its first-use compile runs once, and
    // predictions are serialized (two clips inpainting at once used to load two models and race the compile/move of
    // LaMa.mlmodelc; under memory pressure that ended in MPSGraph crashes). Released when the last user is done.
    private static let sharedLock = NSLock()
    nonisolated(unsafe) private static var sharedInstance: LaMaInpainter?
    nonisolated(unsafe) private static var users = 0
    private static let predictLock = NSLock()

    /// The shared inpainter; pair every call with `release()`.
    public static func acquire() throws -> LaMaInpainter {
        try sharedLock.withLock {
            if let s = sharedInstance { users += 1; return s }
            let s = try LaMaInpainter()
            sharedInstance = s; users = 1
            return s
        }
    }

    public static func release() {
        sharedLock.withLock {
            users = max(0, users - 1)
            if users == 0 { sharedInstance = nil }
        }
    }

    /// Number of loaded models (tests: always ≤ 1).
    public static var loadedCount: Int { sharedLock.withLock { sharedInstance == nil ? 0 : 1 } }

    public init() throws {
        guard let zip = ModelCatalog.installedURL(ModelCatalog.lama) else { throw AIToolError.modelMissing(ModelCatalog.lama.id) }
        let compiled = MontagePaths.cacheDirectory.appendingPathComponent("models/LaMa.mlmodelc")
        let fm = FileManager.default
        if !fm.fileExists(atPath: compiled.path) {
            let pkg = zip.deletingLastPathComponent().appendingPathComponent("LaMa.mlpackage")
            if !fm.fileExists(atPath: pkg.path) {
                // unzip into a private folder, then rename the package into place (other processes may unzip too)
                let scratch = zip.deletingLastPathComponent().appendingPathComponent(".unzip-\(UUID().uuidString)", isDirectory: true)
                defer { try? fm.removeItem(at: scratch) }
                try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                p.arguments = ["-x", "-k", zip.path, scratch.path]
                try p.run(); p.waitUntilExit()
                guard p.terminationStatus == 0 else { throw AIToolError.unavailable("unzip LaMa") }
                try AtomicInstall.place(scratch.appendingPathComponent("LaMa.mlpackage"), at: pkg)
            }
            // compiled once, shared by every process: an existing copy (another process won the race) is kept
            try AtomicInstall.place(try MLModel.compileModel(at: pkg), at: compiled)
        }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all
        model = try MLModel(contentsOf: compiled, configuration: cfg)
    }

    /// Inpaints `mask` (white = remove) in `image`: the mask's bounding box, padded ×2, is processed at 800 px and
    /// pasted back through a feathered mask, so the rest of the picture keeps its full resolution.
    public func inpaint(_ image: CGImage, mask: CGImage) throws -> CGImage {
        let W = image.width, H = image.height
        let m = Self.gray(mask, W, H)
        // mask bbox
        var x0 = W, y0 = H, x1 = -1, y1 = -1
        for y in 0..<H { for x in 0..<W where m[y * W + x] > 127 { x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y) } }
        guard x1 >= x0 else { return image }
        let bw = x1 - x0 + 1, bh = y1 - y0 + 1
        let side = min(max(W, H), max(256, max(bw, bh) * 2))
        let cx = (x0 + x1) / 2, cy = (y0 + y1) / 2
        let rx = min(max(0, cx - side / 2), max(0, W - side)), ry = min(max(0, cy - side / 2), max(0, H - side))
        let crop = CGRect(x: rx, y: ry, width: min(side, W), height: min(side, H))
        let S = Self.side
        guard let inImg = Self.bgra(image, crop: crop, S), let inMask = Self.maskBuffer(m, W, H, crop: crop, S) else { throw AIToolError.noInput }
        let input = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: inImg), "mask": MLFeatureValue(pixelBuffer: inMask)])
        let out = try Self.predictLock.withLock { try model.prediction(from: input) }
        guard let res = out.featureValue(for: "output")?.imageBufferValue else { throw AIToolError.noInput }
        // composite: original everywhere, inpainted crop through a feathered (dilated) mask
        let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: W, height: H))
        let resImg = Self.cgImage(res)
        let feather = Self.featherMask(m, W, H, radius: max(2, min(W, H) / 200))
        // CG y-up: crop rect in image (y-down) coordinates → flip
        let dst = CGRect(x: crop.minX, y: CGFloat(H) - crop.maxY, width: crop.width, height: crop.height)
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: W, height: H), mask: feather)
        if let resImg { ctx.draw(resImg, in: dst) }
        ctx.restoreGState()
        return ctx.makeImage()!
    }

    // MARK: Buffers

    static func gray(_ img: CGImage, _ w: Int, _ h: Int) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: w * h)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return px
    }

    static func bgra(_ img: CGImage, crop: CGRect, _ S: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, S, S, kCVPixelFormatType_32BGRA, nil, &pb)
        guard let pb, let sub = img.cropping(to: crop) else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: S, height: S, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(sub, in: CGRect(x: 0, y: 0, width: S, height: S))
        return pb
    }

    static func maskBuffer(_ m: [UInt8], _ W: Int, _ H: Int, crop: CGRect, _ S: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, S, S, kCVPixelFormatType_OneComponent8, nil, &pb)
        guard let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self), bpr = CVPixelBufferGetBytesPerRow(pb)
        for y in 0..<S {
            let sy = min(H - 1, Int(crop.minY) + y * Int(crop.height) / S)
            for x in 0..<S {
                let sx = min(W - 1, Int(crop.minX) + x * Int(crop.width) / S)
                base[y * bpr + x] = m[sy * W + sx] > 127 ? 255 : 0
            }
        }
        return pb
    }

    /// BGRA pixel buffer → CGImage that OWNS a copy of the pixels (a bitmap context over the buffer's memory can hand
    /// out an image still pointing at it, which the decoder / Core ML pool then recycles).
    static func cgImage(_ pb: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        let data = Data(bytes: base, count: bpr * h) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bpr, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Dilated + box-blurred mask as a CG clip mask (image orientation preserved: row 0 = top).
    static func featherMask(_ m: [UInt8], _ W: Int, _ H: Int, radius r: Int) -> CGImage {
        var a = [Float](repeating: 0, count: W * H)
        for i in 0..<(W * H) where m[i] > 127 { a[i] = 1 }
        func boxH(_ v: [Float]) -> [Float] {
            var o = v
            for y in 0..<H { var s: Float = 0; let row = y * W
                for x in 0..<min(W, r + 1) { s += v[row + x] }
                for x in 0..<W { o[row + x] = s / Float(2 * r + 1); if x + r + 1 < W { s += v[row + x + r + 1] }; if x - r >= 0 { s -= v[row + x - r] } } }
            return o
        }
        func boxV(_ v: [Float]) -> [Float] {
            var o = v
            for x in 0..<W { var s: Float = 0
                for y in 0..<min(H, r + 1) { s += v[y * W + x] }
                for y in 0..<H { o[y * W + x] = s / Float(2 * r + 1); if y + r + 1 < H { s += v[(y + r + 1) * W + x] }; if y - r >= 0 { s -= v[(y - r) * W + x] } } }
            return o
        }
        // dilate by r (box > 0), then soften
        let d = boxV(boxH(a)).map { $0 > 0.01 ? Float(1) : 0 }
        let f = boxV(boxH(d))
        var px = f.map { UInt8(min(255, $0 * 255)) }
        let ctx = CGContext(data: &px, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        return ctx.makeImage()!
    }
}

/// AI remove (AI-041): brush strokes (raw source coordinates) → mask → LaMa on an image, or on every frame of a short
/// video (static mask: logos, watermarks, still objects). Output = a processed copy the clip plays (`Clip.enhance`-like
/// swap via `Clip.removal`).
public enum ObjectRemover {
    public static let maxVideoSeconds = 30.0
    public static var directory: URL { MontagePaths.supportDirectory.appendingPathComponent("Generated/removed", isDirectory: true) }

    public static func mask(_ strokes: [RemovalStroke], width w: Int, height h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        for s in strokes {
            ctx.setStrokeColor(gray: s.erase ? 0 : 1, alpha: 1)
            ctx.setFillColor(gray: s.erase ? 0 : 1, alpha: 1)
            let r = s.radius * Double(w)
            ctx.setLineWidth(r * 2)
            let pts = s.points.map { CGPoint(x: $0.x * Double(w), y: (1 - $0.y) * Double(h)) }   // CG y-up
            if pts.count == 1 { ctx.fillEllipse(in: CGRect(x: pts[0].x - r, y: pts[0].y - r, width: 2 * r, height: 2 * r)) }
            else { ctx.addLines(between: pts); ctx.strokePath() }
        }
        return ctx.makeImage()!
    }

    static func key(_ a: MediaAsset, _ strokes: [RemovalStroke], tracking: RemovalTracking? = nil, range: TimeRange? = nil) -> String {
        var d = (try? JSONEncoder().encode(strokes)) ?? Data()
        if let tracking { d += Data(String(format: "track@%.4f", tracking.time).utf8) }
        if let range { d += Data(String(format: "range@%.3f-%.3f", range.start.seconds, range.end.seconds).utf8) }
        d += Data("t1".utf8)   // t1: temporal smoothing of the fill
        return a.contentHash + "-" + SHA256.hash(data: d).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// Track object (AI2): the object under the strokes' bounding box, tracked through the whole media from the brushed
    /// frame (Vision, ≤ 640 px). Empty when there's nothing to track.
    public static func trackedBoxes(_ a: MediaAsset, strokes: [RemovalStroke], tracking: RemovalTracking,
                                    progress: (@Sendable (Double) -> Void)? = nil) async throws -> (ref: NormRect, samples: [TrackSample])? {
        let (rw, rh) = a.sourceRotation % 180 == 0 ? (a.pixelSize.width, a.pixelSize.height) : (a.pixelSize.height, a.pixelSize.width)
        guard let ref = RemovalTracking.bounds(strokes, aspect: rw / max(rh, 1)) else { return nil }
        let samples = try await ObjectTracker.track(a, box: ref, at: tracking.time, range: TimeRange(start: .zero, duration: a.duration), progress: progress)
        return samples.isEmpty ? nil : (ref, samples)
    }

    /// Seconds of video actually inpainted for a clip: its used source range (frames outside it are copied), so a
    /// 10 s clip cut from a 10 min recording qualifies.
    public static func workRange(_ a: MediaAsset, clipSource: TimeRange?) -> TimeRange? {
        guard let r = clipSource else { return nil }
        let pad = Time(0.25)   // a little margin for trims / transitions
        let s = max(.zero, r.start - pad), e = min(a.duration, r.end + pad)
        return s <= .zero && e >= a.duration ? nil : TimeRange(start: s, end: e)
    }

    public static func canProcess(_ a: MediaAsset, clipSource: TimeRange?) -> Bool {
        if a.kind == .image { return true }
        guard a.kind == .video else { return false }
        return (workRange(a, clipSource: clipSource)?.duration.seconds ?? a.duration.seconds) <= maxVideoSeconds + 0.5
    }

    /// `range`: only frames inside it are inpainted (the clip's used part, `workRange`), the others are copied.
    public static func process(_ a: MediaAsset, strokes: [RemovalStroke], tracking: RemovalTracking? = nil, range: TimeRange? = nil,
                               progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lama = try LaMaInpainter.acquire()
        defer { LaMaInpainter.release() }
        if a.kind == .image {
            let out = directory.appendingPathComponent(key(a, strokes) + ".png")
            if FileManager.default.fileExists(atPath: out.path) { return out }
            guard let src = CGImageSourceCreateWithURL(a.url as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldAllowFloat: false] as CFDictionary) else { throw AIToolError.noInput }
            let res = try lama.inpaint(img, mask: mask(strokes, width: img.width, height: img.height))
            guard let dst = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw AIToolError.noInput }
            CGImageDestinationAddImage(dst, res, nil)
            guard CGImageDestinationFinalize(dst) else { throw AIToolError.noInput }
            progress?(1)
            return out
        }
        guard (range?.duration.seconds ?? a.duration.seconds) <= maxVideoSeconds + 0.5 else { throw AIToolError.unavailable("too long") }
        let out = directory.appendingPathComponent(key(a, strokes, tracking: tracking, range: range) + ".mov")
        if FileManager.default.fileExists(atPath: out.path) { return out }
        // moving object: track it first (30 % of the progress), then move the mask on every frame
        var track: (ref: NormRect, samples: [TrackSample])?
        if let tracking {
            track = try await trackedBoxes(a, strokes: strokes, tracking: tracking) { progress?(0.3 * $0) }
        }
        let base = track == nil ? 0.0 : 0.3
        let av = AVURLAsset(url: a.url)
        guard let vt = try await av.loadTracks(withMediaType: .video).first else { throw AIToolError.noInput }
        let natural = try await vt.load(.naturalSize), transform = try await vt.load(.preferredTransform)
        let (w, h) = (Int(natural.width) / 2 * 2, Int(natural.height) / 2 * 2)
        let m = mask(strokes, width: w, height: h)
        let tmp = directory.appendingPathComponent(".\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let writer = try AVAssetWriter(outputURL: tmp, fileType: .mov)
        var vSettings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: w, AVVideoHeightKey: h,
                                        AVVideoCompressionPropertiesKey: [AVVideoQualityKey: 0.8]]
        if !writer.canApply(outputSettings: vSettings, forMediaType: .video) {
            // an encoder without constant-quality mode (Intel / macOS 13) would make AVAssetWriterInput throw: bit rate instead
            vSettings[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey: max(4_000_000, w * h * 6)]
        }
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
        vIn.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(vIn)
        let at = try await av.loadTracks(withMediaType: .audio).first
        var aIn: AVAssetWriterInput?
        if let at {
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: try await at.load(.formatDescriptions).first)
            writer.add(i); aIn = i
        }
        let reader = try AVAssetReader(asset: av)
        let vOut = AVAssetReaderTrackOutput(track: vt, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(vOut)
        var aOut: AVAssetReaderTrackOutput?
        if let at { let o = AVAssetReaderTrackOutput(track: at, outputSettings: nil); reader.add(o); aOut = o }
        guard reader.startReading(), writer.startWriting() else { throw reader.error ?? writer.error ?? AIToolError.noInput }
        writer.startSession(atSourceTime: .zero)
        let audio: Task<Void, Error>? = (aIn != nil && aOut != nil) ? Task.detached { [i = UncheckedSendable(aIn!), o = UncheckedSendable(aOut!)] in
            while let sb = await OffPool.next(o.value) {
                while !i.value.isReadyForMoreMediaData { try Task.checkCancellation(); try await Task.sleep(nanoseconds: 2_000_000) }
                i.value.append(sb)
            }
            i.value.markAsFinished()
        } : nil
        defer { audio?.cancel() }
        let duration = max(a.duration.seconds, 0.001)
        let smoother = RemovalTemporalSmoother(width: w, height: h)
        do {
            while let sb = await OffPool.next(vOut) {
                try Task.checkCancellation()
                guard let pb = CMSampleBufferGetImageBuffer(sb), let frame = LaMaInpainter.cgImage(pb) else { continue }
                let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                var frameMask = m
                if let track, let box = RemovalTracking.box(at: pts.seconds, in: track.samples) {
                    frameMask = mask(RemovalTracking.transform(strokes, from: track.ref, to: box), width: w, height: h)
                }
                let inRange = range.map { pts.seconds >= $0.start.seconds - 0.001 && pts.seconds <= $0.end.seconds + 0.001 } ?? true
                let res = inRange ? try autoreleasepool { try lama.inpaint(frame, mask: frameMask) } : frame
                guard let outPB = adaptor.pixelBufferPool.flatMap({ pool -> CVPixelBuffer? in var b: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, pool, &b); return b }) else { throw AIToolError.noInput }
                CVPixelBufferLockBaseAddress(outPB, [])
                let ctx = CGContext(data: CVPixelBufferGetBaseAddress(outPB), width: w, height: h, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(outPB),
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
                ctx.draw(res, in: CGRect(x: 0, y: 0, width: w, height: h))
                if inRange, let base = CVPixelBufferGetBaseAddress(outPB) {
                    smoother.apply(out: base.assumingMemoryBound(to: UInt8.self), bytesPerRow: CVPixelBufferGetBytesPerRow(outPB), source: frame, mask: frameMask)
                }
                CVPixelBufferUnlockBaseAddress(outPB, [])
                while !vIn.isReadyForMoreMediaData { try Task.checkCancellation(); try await Task.sleep(nanoseconds: 2_000_000) }
                adaptor.append(outPB, withPresentationTime: pts)
                progress?(min(0.99, base + (1 - base) * pts.seconds / duration))
            }
            vIn.markAsFinished()
            try await audio?.value
        } catch { reader.cancelReading(); writer.cancelWriting(); throw error }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? AIToolError.noInput }
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.moveItem(at: tmp, to: out)
        progress?(1)
        return out
    }
}

/// AI remove job → edit swapping the clip to the processed copy (strokes empty = restore the original).
public enum ObjectRemovalJob {
    public static func run(project p: Project, clipID: ClipID, strokes: [RemovalStroke], tracking: RemovalTracking? = nil,
                           progress: (@Sendable (Double) -> Void)? = nil) async throws -> any EditCommand {
        guard let c = p.timeline.clip(clipID), let originalID = c.removal?.original ?? c.mediaID, let original = p.asset(originalID) else { throw AIToolError.noInput }
        if strokes.isEmpty {
            return Edit("cmd.aiRemove") { p in
                guard var c = p.timeline.clip(clipID) else { throw EditError.clipNotFound }
                c.content = .media(originalID); c.removal = nil
                p.timeline[clip: clipID] = c
            }
        }
        let track = original.kind == .video ? tracking : nil
        let range = original.kind == .video ? ObjectRemover.workRange(original, clipSource: c.sourceRange) : nil
        let url = try await ObjectRemover.process(original, strokes: strokes, tracking: track, range: range, progress: progress)
        var processed = try await MediaProbe.probe(url)
        processed.name = original.name
        let asset = processed
        let info = ObjectRemovalInfo(original: originalID, strokes: strokes, tracking: track)
        return Edit("cmd.aiRemove") { p in
            guard var c = p.timeline.clip(clipID) else { throw EditError.clipNotFound }
            let id: MediaID
            if let e = p.media.first(where: { $0.contentHash == asset.contentHash }) { id = e.id } else { p.media.append(asset); id = asset.id }
            c.content = .media(id); c.removal = info
            p.timeline[clip: clipID] = c
        }
    }
}
