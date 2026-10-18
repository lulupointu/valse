@preconcurrency import AVFoundation
import Vision
import ImageIO
import Foundation
import MontageCore
import MontageEngine

/// What the cutout keeps.
public enum CutoutMode: Sendable, Equatable {
    /// People (Vision person segmentation, temporally smoothed). "Auto cutout ▸ People".
    case person
    /// Every salient foreground object (Vision foreground instance mask). "Auto cutout ▸ Main subject".
    case subject
    /// Objects chosen with clicks / brush strokes on one frame, propagated through the video ("Customized").
    case custom(CutoutSelection)

    /// `ClipMatte.kind` / `MatteStore` key.
    public var kind: String {
        switch self {
        case .person: return "person"
        case .subject: return "subject"
        case .custom(let s): return "custom.\(s.id)"
        }
    }
}

/// A brush stroke on the source frame. Coordinates are normalised **raw source** coordinates (0…1, origin top-left,
/// before the media's display rotation), so they line up with decoded frames and mattes.
public struct BrushStroke: Hashable, Codable, Sendable {
    public var points: [Vec2]
    /// Radius as a fraction of the frame width.
    public var radius: Double
    public var erase: Bool
    public init(points: [Vec2], radius: Double, erase: Bool = false) { self.points = points; self.radius = radius; self.erase = erase }
}

/// Customized cutout: strokes painted on the frame at media time `time`. Objects under keep-strokes are selected
/// (instance segmentation, "Quick brush"); erase-strokes deselect objects. `id` changes with every new selection so
/// each applied selection gets its own cached matte.
public struct CutoutSelection: Hashable, Codable, Sendable {
    public var id: String
    public var time: Time
    public var strokes: [BrushStroke]
    public init(id: String = UUID().uuidString.prefix(8).lowercased(), time: Time, strokes: [BrushStroke]) {
        self.id = id; self.time = time; self.strokes = strokes
    }
}

/// Builds AI mattes (CK-002/003/004) and hands them to the compositor through the render team's matte API
/// (`MatteVideoWriter` for videos, `MatteStore.setStill` for images). Video mattes are aligned with the whole media
/// (frame at media time t = matte of the source frame at t), so trims, splits and speed changes reuse them.
/// Runs in a background job: frames are decoded at ≤ 960 px, Vision runs on the ANE/GPU, one frame in flight.
public enum MatteGenerator {
    public static let maxDecodeSide: CGFloat = 960

    /// Matte already cached for this media/mode?
    public static func isReady(_ asset: MediaAsset, _ mode: CutoutMode) -> Bool {
        asset.kind == .image ? MatteStore.shared.hasStill(media: asset, kind: mode.kind)
                             : MatteStore.shared.readyMatteVideo(media: asset, kind: mode.kind) != nil
    }

    /// Generates (or reuses) the matte. `progress` 0…1.
    public static func generate(_ asset: MediaAsset, mode: CutoutMode, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        if isReady(asset, mode) { progress?(1); return }
        if asset.kind == .image {
            guard let src = CGImageSourceCreateWithURL(asset.url as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldAllowFloat: false] as CFDictionary)
            else { throw AIToolError.noInput }
            let m = try still(img, mode: mode)
            MatteStore.shared.setStill(m, media: asset, kind: mode.kind)
            progress?(1)
            return
        }
        try await video(asset, mode: mode, progress: progress)
    }

    // MARK: Stills

    /// Matte of a still image (white = keep), same size as the mask Vision produces.
    public static func still(_ image: CGImage, mode: CutoutMode) throws -> CGImage {
        let handler = VNImageRequestHandler(cgImage: image)
        switch mode {
        case .person:
            let req = personRequest(.accurate)
            try handler.perform([req])
            guard let pb = req.results?.first?.pixelBuffer, let m = MaskBuffer(pb) else { throw AIToolError.noInput }
            return m.cgImage()
        case .subject, .custom:
            let req = VNGenerateForegroundInstanceMaskRequest()
            try handler.perform([req])
            guard let obs = req.results?.first else { return MaskBuffer(width: 16, height: 16).cgImage() }   // nothing found: empty matte
            var picked = obs.allInstances
            if case .custom(let sel) = mode { picked = pick(sel.strokes, in: obs) }
            guard !picked.isEmpty else { return MaskBuffer(width: 16, height: 16).cgImage() }
            let pb = try obs.generateScaledMaskForImage(forInstances: picked, from: handler)
            guard let m = MaskBuffer(pb) else { throw AIToolError.noInput }
            return m.cgImage()
        }
    }

    // MARK: Video

    static func personRequest(_ q: VNGeneratePersonSegmentationRequest.QualityLevel) -> VNGeneratePersonSegmentationRequest {
        let r = VNGeneratePersonSegmentationRequest()
        r.qualityLevel = q
        r.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return r
    }

    static func video(_ asset: MediaAsset, mode: CutoutMode, progress: (@Sendable (Double) -> Void)?) async throws {
        let av = AVURLAsset(url: asset.url)
        guard let track = try await av.loadTracks(withMediaType: .video).first else { throw AIToolError.noInput }
        let natural = try await track.load(.naturalSize)
        let total = max(try await av.load(.duration).seconds, 0.001)
        let k = min(1, maxDecodeSide / max(natural.width, natural.height, 1))
        let w = max(16, Int(natural.width * k) / 2 * 2), h = max(16, Int(natural.height * k) / 2 * 2)
        let reader = try AVAssetReader(asset: av)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()])
        out.alwaysCopiesSampleData = false
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? AIToolError.noInput }
        defer { reader.cancelReading() }

        let writer = try MatteVideoWriter(media: asset, kind: mode.kind, size: CGSize(width: w, height: h))
        var finished = false
        defer { if !finished { writer.cancel() } }

        let personReq = personRequest(.balanced)
        let sequence = VNSequenceRequestHandler()
        var previous: MaskBuffer?
        var tracker: InstanceTracker?
        if case .custom(let sel) = mode {
            tracker = try await InstanceTracker(seed: sel, asset: av, track: track, size: CGSize(width: w, height: h))
        }
        while let sb = out.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let t = CMSampleBufferGetPresentationTimeStamp(sb)
            let mask: MaskBuffer? = try autoreleasepool {
                switch mode {
                case .person:
                    try sequence.perform([personReq], on: pb)
                    return (personReq.results?.first?.pixelBuffer).flatMap { MaskBuffer($0) }
                case .subject:
                    let handler = VNImageRequestHandler(cvPixelBuffer: pb)
                    let req = VNGenerateForegroundInstanceMaskRequest()
                    try handler.perform([req])
                    guard let obs = req.results?.first, !obs.allInstances.isEmpty else { return MaskBuffer(width: 64, height: 64) }
                    return MaskBuffer(try obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler))
                case .custom:
                    return try tracker?.mask(for: pb)
                }
            }
            var m = mask ?? MaskBuffer(width: 64, height: 64)
            // temporal smoothing: damps flicker of per-frame masks (CapCut's video matting is temporally stable)
            if let prev = previous, prev.width == m.width, prev.height == m.height { m.blend(towards: prev, keep: 0.65) }
            previous = m
            try await writer.append(m.cgImage(), at: Time(cmTime: t))
            progress?(min(0.99, t.seconds / total))
        }
        if reader.status == .failed { throw reader.error ?? AIToolError.noInput }
        try await writer.finish()
        finished = true
        progress?(1)
    }

    /// Instances of a foreground-instance observation under keep-strokes and not under erase-strokes.
    static func pick(_ strokes: [BrushStroke], in obs: VNInstanceMaskObservation) -> IndexSet {
        let labels = MaskBuffer(obs.instanceMask)
        guard let labels else { return [] }
        var keep = IndexSet(), drop = IndexSet()
        for s in strokes {
            for l in labels.labels(under: s) where l != 0 { if s.erase { drop.insert(l) } else { keep.insert(l) } }
        }
        return keep.subtracting(drop).intersection(obs.allInstances)
    }
}

/// Follows the objects picked on the seed frame through the video: each frame's instance labels are matched to the
/// previous frame's matte by overlap (IoU-style), so the selection survives the objects moving.
final class InstanceTracker {
    private var previous: MaskBuffer?
    private let seed: CutoutSelection

    init(seed: CutoutSelection, asset: AVURLAsset, track: AVAssetTrack, size: CGSize) async throws {
        self.seed = seed
        // seed mask from the frame the user painted on
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = false
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
        gen.maximumSize = size
        let (img, _) = try await gen.image(at: seed.time.cmTime)
        let handler = VNImageRequestHandler(cgImage: img)
        let req = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([req])
        if let obs = req.results?.first {
            let picked = MatteGenerator.pick(seed.strokes, in: obs)
            if !picked.isEmpty { previous = MaskBuffer(try obs.generateScaledMaskForImage(forInstances: picked, from: handler)) }
        }
        if previous == nil { throw AIToolError.noInput }
    }

    func mask(for pb: CVPixelBuffer) throws -> MaskBuffer? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pb)
        let req = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([req])
        guard let obs = req.results?.first, let labels = MaskBuffer(obs.instanceMask), let prev = previous else { return previous }
        // overlap of each label with the previous matte
        var overlap: [Int: (hit: Int, total: Int)] = [:]
        for y in 0..<labels.height {
            for x in 0..<labels.width {
                let l = Int(labels[x, y]); guard l != 0 else { continue }
                let px = x * prev.width / labels.width, py = y * prev.height / labels.height
                var e = overlap[l] ?? (0, 0)
                e.total += 1
                if prev[px, py] > 127 { e.hit += 1 }
                overlap[l] = e
            }
        }
        var picked = IndexSet()
        for (l, e) in overlap where e.total > 0 && Double(e.hit) / Double(e.total) > 0.3 { picked.insert(l) }
        picked = picked.intersection(obs.allInstances)
        guard !picked.isEmpty else { return previous }   // object lost for a frame: hold the last matte
        let m = MaskBuffer(try obs.generateScaledMaskForImage(forInstances: picked, from: handler))
        if let m { previous = m }
        return m
    }
}

/// 8-bit single-channel mask in CPU memory (top-left origin). Small (Vision masks are ≤ 1 MP), so CPU blending is
/// cheaper than a GPU round trip.
struct MaskBuffer {
    var width: Int
    var height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int, fill: UInt8 = 0) { self.width = width; self.height = height; pixels = .init(repeating: fill, count: width * height) }

    /// From a OneComponent8 / OneComponent32Float pixel buffer.
    init?(_ pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        width = CVPixelBufferGetWidth(pb); height = CVPixelBufferGetHeight(pb)
        let row = CVPixelBufferGetBytesPerRow(pb)
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        pixels = .init(repeating: 0, count: width * height)
        let w = width
        pixels.withUnsafeMutableBufferPointer { dst in
            for y in 0..<height {
                let src = base.advanced(by: y * row)
                switch fmt {
                case kCVPixelFormatType_OneComponent32Float:
                    let f = src.assumingMemoryBound(to: Float.self)
                    for x in 0..<w { dst[y * w + x] = UInt8(max(0, min(255, f[x] * 255))) }
                default:
                    let b = src.assumingMemoryBound(to: UInt8.self)
                    for x in 0..<w { dst[y * w + x] = b[x] }
                }
            }
        }
    }

    subscript(x: Int, y: Int) -> UInt8 { pixels[min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)] }

    /// Labels found under a stroke (normalised coordinates).
    func labels(under s: BrushStroke) -> Set<Int> {
        var out = Set<Int>()
        let r = max(1, Int(s.radius * Double(width)))
        for p in s.points {
            let cx = Int(p.x * Double(width)), cy = Int(p.y * Double(height))
            for dy in stride(from: -r, through: r, by: max(1, r / 4)) {
                for dx in stride(from: -r, through: r, by: max(1, r / 4)) where dx * dx + dy * dy <= r * r {
                    out.insert(Int(self[cx + dx, cy + dy]))
                }
            }
        }
        return out
    }

    /// `self = self·(1−keep) + other·keep`.
    mutating func blend(towards other: MaskBuffer, keep: Float) {
        let a = UInt16(max(0, min(255, (1 - keep) * 256))), b = 256 - a
        for i in pixels.indices { pixels[i] = UInt8((UInt16(pixels[i]) * a + UInt16(other.pixels[i]) * b) >> 8) }
    }

    func cgImage() -> CGImage {
        let data = Data(pixels) as CFData
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }

    /// Mean value 0…1 (tests).
    var coverage: Double { Double(pixels.reduce(0) { $0 + Int($1) }) / Double(max(pixels.count, 1)) / 255 }
}
