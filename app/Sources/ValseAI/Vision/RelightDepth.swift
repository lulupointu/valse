@preconcurrency import AVFoundation
@preconcurrency import CoreML
import Vision
import ImageIO
import Accelerate
import Foundation
import ValseCore
import ValseEngine

/// Depth pass of Relight (AI2, AI-024 / CL-020): writes the media's "depth" matte (near = white, normalised with a
/// slowly adapting range so it doesn't flicker) through `MatteVideoWriter` / `MatteStore.setStill`, plus the Vision
/// person matte when the target is People / Background. Depth Anything V2 Small (Core ML, model manager) when
/// installed; otherwise a pseudo-depth from the person matte + vertical position + smoothed luma, so Relight works
/// without any download. Frames are decoded at ≤ 518 px and sampled at ≤ 12 fps (depth changes slowly; the matte
/// video holds each frame until the next one). The model is loaded per job and released afterwards (~300 MB).
public enum RelightDepth {
    public static let maxSide: CGFloat = 518
    public static let maxFPS: Double = 12

    public static var hasModel: Bool { ModelCatalog.installedDepthPackage != nil }

    public static func isDepthReady(_ a: MediaAsset) -> Bool {
        a.kind == .image ? MatteStore.shared.hasStill(media: a, kind: RelightOps.depthKind)
                         : MatteStore.shared.readyMatteVideo(media: a, kind: RelightOps.depthKind) != nil
    }

    /// Everything the relight of `settings` needs is cached.
    public static func isReady(_ a: MediaAsset, _ settings: RelightSettings) -> Bool {
        isDepthReady(a) && (!settings.target.usesPersonMatte || MatteGenerator.isReady(a, .person))
    }

    /// Runs the missing passes (depth, then the person matte if needed). `progress` 0…1.
    public static func generate(_ a: MediaAsset, settings: RelightSettings, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let needsPerson = settings.target.usesPersonMatte && !MatteGenerator.isReady(a, .person)
        let split = needsPerson ? 0.6 : 1.0
        if !isDepthReady(a) {
            // Loading the Core ML model (ANE compile through the system's shared `aned` on a cold cache) is one opaque
            // blocking call that took 18 s to > 90 s on a loaded machine: keep it off Swift's cooperative pool, and
            // report a first step once it is done so progress observers can tell "model loaded" from "stuck".
            let estimator = try await OffPool.run { _ in UncheckedSendable(try DepthEstimator()) }.value
            progress?(0.01 * split)
            if a.kind == .image {
                guard let src = CGImageSourceCreateWithURL(a.url as CFURL, nil),
                      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw AIToolError.noInput }
                var norm = DepthNormalizer()
                let d = try estimator.depth(cgImage: img)
                MatteStore.shared.setStill(norm.normalize(d).cgImage(), media: a, kind: RelightOps.depthKind)
            } else {
                try await video(a, estimator: estimator) { progress?($0 * split) }
            }
        }
        if needsPerson {
            try await MatteGenerator.generate(a, mode: .person) { progress?(split + (1 - split) * $0) }
        }
        progress?(1)
    }

    static func video(_ asset: MediaAsset, estimator: DepthEstimator, progress: (@Sendable (Double) -> Void)?) async throws {
        let av = AVURLAsset(url: asset.url)
        guard let track = try await av.loadTracks(withMediaType: .video).first else { throw AIToolError.noInput }
        let natural = try await track.load(.naturalSize)
        let total = max(try await av.load(.duration).seconds, 0.001)
        let k = min(1, maxSide / max(natural.width, natural.height, 1))
        let w = max(16, Int(natural.width * k) / 2 * 2), h = max(16, Int(natural.height * k) / 2 * 2)
        let reader = try AVAssetReader(asset: av)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()])
        out.alwaysCopiesSampleData = false
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? AIToolError.noInput }
        defer { reader.cancelReading() }
        let writer = try MatteVideoWriter(media: asset, kind: RelightOps.depthKind, size: CGSize(width: w, height: h))
        var finished = false
        defer { if !finished { writer.cancel() } }
        var norm = DepthNormalizer()
        var previous: DepthMap?
        var next = -Double.infinity
        while let sb = await OffPool.next(out) {
            try Task.checkCancellation()
            let t = CMSampleBufferGetPresentationTimeStamp(sb)
            guard t.seconds >= next, let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            next = t.seconds + 1 / maxFPS - 0.002
            var d = try autoreleasepool { try estimator.depth(pixelBuffer: pb) }
            d = norm.normalize(d)
            if let p = previous, p.width == d.width, p.height == d.height { d.blend(towards: p, keep: 0.4) }
            previous = d
            try await writer.append(d.cgImage(), at: Time(cmTime: t))
            progress?(min(0.99, max(0.01, t.seconds / total)))
        }
        if reader.status == .failed { throw reader.error ?? AIToolError.noInput }
        try await writer.finish()
        finished = true
    }
}

/// Float depth map, larger = nearer (any range until normalised).
struct DepthMap {
    var width: Int, height: Int
    var values: [Float]

    mutating func blend(towards o: DepthMap, keep: Float) {
        for i in values.indices { values[i] = values[i] * (1 - keep) + o.values[i] * keep }
    }

    /// Grey image (values clamped to 0…1).
    func cgImage() -> CGImage {
        var bytes = values.map { UInt8(max(0, min(255, $0 * 255 + 0.5))) }
        let ctx = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        return ctx.makeImage()!
    }

    func value(atX x: Double, y: Double) -> Float {
        let xi = min(max(Int(x * Double(width)), 0), width - 1), yi = min(max(Int(y * Double(height)), 0), height - 1)
        return values[yi * width + xi]
    }
}

/// Maps raw depth to 0…1 with the 2nd–98th percentile range, adapted slowly across frames (no flicker).
struct DepthNormalizer {
    private var lo: Float?, hi: Float?

    mutating func normalize(_ d: DepthMap) -> DepthMap {
        let sorted = stride(from: 0, to: d.values.count, by: max(1, d.values.count / 4096)).map { d.values[$0] }.sorted()
        guard let first = sorted.first else { return d }
        let l = sorted[Int(Double(sorted.count - 1) * 0.02)], h = sorted[Int(Double(sorted.count - 1) * 0.98)]
        _ = first
        lo = lo.map { $0 * 0.8 + l * 0.2 } ?? l
        hi = hi.map { $0 * 0.8 + h * 0.2 } ?? h
        let a = lo!, span = max(hi! - a, 1e-6)
        var out = d
        for i in out.values.indices { out.values[i] = min(max((out.values[i] - a) / span, 0), 1) }
        return out
    }
}

/// Depth Anything V2 Small through Vision (scales the input to the model's 518×392), or the pseudo-depth fallback.
final class DepthEstimator {
    private let request: VNCoreMLRequest?
    private let person: VNGeneratePersonSegmentationRequest

    /// The pseudo-depth estimator (no model), e.g. for tests.
    static func fallback() throws -> DepthEstimator { try DepthEstimator(useModel: false) }

    init(useModel: Bool = true) throws {
        person = VNGeneratePersonSegmentationRequest()
        person.qualityLevel = .balanced
        person.outputPixelFormat = kCVPixelFormatType_OneComponent8
        if useModel, let pkg = ModelCatalog.installedDepthPackage {
            let compiled = try Self.compiled(pkg)
            let cfg = MLModelConfiguration()
            cfg.computeUnits = .all
            let model = try VNCoreMLModel(for: MLModel(contentsOf: compiled, configuration: cfg))
            let r = VNCoreMLRequest(model: model)
            r.imageCropAndScaleOption = .scaleFill
            request = r
        } else {
            request = nil
        }
    }

    var usesModel: Bool { request != nil }

    /// Compiled once into Caches/Valse/models (recompiled when the package changes).
    static func compiled(_ pkg: URL) throws -> URL {
        let dst = ValsePaths.cacheDirectory.appendingPathComponent("models/DepthAnythingV2SmallF16.mlmodelc", isDirectory: true)
        let fm = FileManager.default
        let stamp = (try? fm.attributesOfItem(atPath: pkg.appendingPathComponent("Data/com.apple.CoreML/weights/weight.bin").path))?[.modificationDate] as? Date
        let built = (try? fm.attributesOfItem(atPath: dst.path))?[.modificationDate] as? Date
        if let built, let stamp, built >= stamp, fm.fileExists(atPath: dst.path) { return dst }
        let tmp = try MLModel.compileModel(at: pkg)
        // atomic: concurrent processes share this cache (an outdated copy is renamed aside, never deleted under a reader)
        return try AtomicInstall.place(tmp, at: dst, replace: fm.fileExists(atPath: dst.path))
    }

    func depth(cgImage: CGImage) throws -> DepthMap {
        try depth(handler: VNImageRequestHandler(cgImage: cgImage), luma: { Self.luma(cgImage: cgImage) })
    }

    func depth(pixelBuffer pb: CVPixelBuffer) throws -> DepthMap {
        try depth(handler: VNImageRequestHandler(cvPixelBuffer: pb), luma: { Self.luma(bgra: pb) })
    }

    private func depth(handler: VNImageRequestHandler, luma: () -> DepthMap?) throws -> DepthMap {
        if let request {
            try handler.perform([request])
            if let obs = request.results?.first as? VNPixelBufferObservation, let d = Self.map(obs.pixelBuffer) { return d }
            if let obs = request.results?.first as? VNCoreMLFeatureValueObservation, let arr = obs.featureValue.multiArrayValue,
               let d = Self.map(arr) { return d }
            throw AIToolError.unavailable("depth output")
        }
        // fallback: person matte (near), lower = nearer, smoothed luma (lit = nearer, weak)
        try handler.perform([person])
        let m = person.results?.first.flatMap { MaskBuffer($0.pixelBuffer) }
        guard var y = luma() else { throw AIToolError.noInput }
        let w = y.width, h = y.height
        for j in 0..<h {
            let v = Float(j) / Float(max(h - 1, 1))
            for i in 0..<w {
                var pm: Float = 0
                if let m { pm = Float(m.pixels[min(j * m.height / h, m.height - 1) * m.width + min(i * m.width / w, m.width - 1)]) / 255 }
                let k = j * w + i
                y.values[k] = 0.45 * pm + 0.3 * v + 0.25 * y.values[k]
            }
        }
        return y
    }

    /// Depth from the model's output buffer (OneComponent 8/16F/32F or BGRA → red).
    static func map(_ pb: CVPixelBuffer) -> DepthMap? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
        var v = [Float](repeating: 0, count: w * h)
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        for y in 0..<h {
            let src = base.advanced(by: y * row)
            for x in 0..<w {
                switch fmt {
                case kCVPixelFormatType_OneComponent32Float: v[y * w + x] = src.assumingMemoryBound(to: Float.self)[x]
                case kCVPixelFormatType_OneComponent16Half:
                    #if arch(arm64)
                    v[y * w + x] = Float(src.assumingMemoryBound(to: Float16.self)[x])
                    #else
                    v[y * w + x] = Half.float(src.assumingMemoryBound(to: UInt16.self)[x])
                    #endif
                case kCVPixelFormatType_OneComponent16: v[y * w + x] = Float(src.assumingMemoryBound(to: UInt16.self)[x]) / 65535
                case kCVPixelFormatType_32BGRA, kCVPixelFormatType_32ARGB, kCVPixelFormatType_32RGBA:
                    v[y * w + x] = Float(src.assumingMemoryBound(to: UInt8.self)[x * 4 + (fmt == kCVPixelFormatType_32BGRA ? 2 : 1)]) / 255
                default: v[y * w + x] = Float(src.assumingMemoryBound(to: UInt8.self)[x]) / 255
                }
            }
        }
        return DepthMap(width: w, height: h, values: v)
    }

    static func map(_ a: MLMultiArray) -> DepthMap? {
        let shape = a.shape.map(\.intValue)
        guard shape.count >= 2 else { return nil }
        let h = shape[shape.count - 2], w = shape[shape.count - 1]
        var v = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) { v[i] = a[i].floatValue }
        return DepthMap(width: w, height: h, values: v)
    }

    /// Box-blurred luma (0…1) at ≤ 128 px.
    static func luma(bgra pb: CVPixelBuffer) -> DepthMap? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb), CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA else { return nil }
        let w0 = CVPixelBufferGetWidth(pb), h0 = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
        let s = max(1, max(w0, h0) / 128), w = max(1, w0 / s), h = max(1, h0 / s)
        var v = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let src = base.advanced(by: y * s * row).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w {
                let p = x * s * 4
                v[y * w + x] = (0.0722 * Float(src[p]) + 0.7152 * Float(src[p + 1]) + 0.2126 * Float(src[p + 2])) / 255
            }
        }
        return blurred(DepthMap(width: w, height: h, values: v))
    }

    static func luma(cgImage img: CGImage) -> DepthMap? {
        let s = max(1, max(img.width, img.height) / 128), w = max(1, img.width / s), h = max(1, img.height / s)
        var bytes = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return blurred(DepthMap(width: w, height: h, values: bytes.map { Float($0) / 255 }))
    }

    static func blurred(_ d: DepthMap, radius r: Int = 4) -> DepthMap {
        var out = d
        let w = d.width, h = d.height
        var tmp = d.values
        for y in 0..<h { for x in 0..<w {
            var a: Float = 0, n: Float = 0
            for k in max(0, x - r)...min(w - 1, x + r) { a += d.values[y * w + k]; n += 1 }
            tmp[y * w + x] = a / n
        } }
        for y in 0..<h { for x in 0..<w {
            var a: Float = 0, n: Float = 0
            for k in max(0, y - r)...min(h - 1, y + r) { a += tmp[k * w + x]; n += 1 }
            out.values[y * w + x] = a / n
        } }
        return out
    }
}

/// Relight job → nothing to apply on the project (the settings were set when ticked); the mattes land in MatteStore.
public enum RelightJob {
    public static func run(_ asset: MediaAsset, settings: RelightSettings, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        try await RelightDepth.generate(asset, settings: settings, progress: progress)
    }
}
