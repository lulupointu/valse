@preconcurrency import AVFoundation
import Vision
import ImageIO
import Foundation
import ValseCore
import ValseEngine

/// Smart brush (CL-012) and brush-mask tracking (MK-004).
///
/// Both work in raw source space (decoded frames before the media's display rotation): the brush mask's strokes are
/// drawn into a "seed" coverage image, Vision foreground instance segmentation finds the objects in the frame, and the
/// objects mostly covered by the seed become the region. Regions are returned as closed contours (raw normalized
/// coordinates, y down) that the brush mask stores as filled strokes.
public enum SmartMask {
    /// Instances counted as "under the brush": the seed covers at least this fraction of the instance, or the instance
    /// holds at least `seedShare` of the seed.
    static let instanceCover = 0.25, seedShare = 0.3

    // MARK: Smart brush

    /// Region (raw contours) of the object(s) under `stroke` on the frame at source time `source` of clip `clipID`'s
    /// media; the stroke is in mask-box units of the clip's mask at `keyPath`. Falls back to people (person
    /// segmentation) when no foreground object is under the stroke. Throws `noInput` when nothing is found.
    public static func smartRegion(project p: Project, clipID: ClipID, mask keyPath: WritableKeyPath<Clip, Mask?>,
                                   stroke: MaskStroke, source: Time) async throws -> [[Vec2]] {
        guard let c = p.timeline.clip(clipID), let asset = c.mediaID.flatMap(p.asset), asset.kind == .video || asset.kind == .image
        else { throw AIToolError.noInput }
        let local = ((c.timelineTime(forSource: source) ?? c.start) - c.start).clamped(.zero, c.duration)
        guard let m = c.resolved(at: local)[keyPath: keyPath] else { throw AIToolError.noInput }
        let image = try await rawFrame(asset, at: source)
        let seed = seedMask(MaskStrokeSet(m, [stroke]), clip: c, asset: asset, width: min(image.width, 512),
                            height: min(image.width, 512) * image.height / max(image.width, 1))
        return try await detached {
            let handler = VNImageRequestHandler(cgImage: image)
            guard let region = try objects(under: seed, handler: handler) ?? people(under: seed, handler: handler) else {
                throw AIToolError.noInput
            }
            let cs = contours(region)
            if cs.isEmpty { throw AIToolError.noInput }
            return cs
        }
    }

    // MARK: Tracking (MK-004)

    /// Propagates the brush mask at `keyPath` from source time `source` in `direction`: when the brushed region covers
    /// objects, their outline is followed frame by frame (instance segmentation matched by overlap, so the shape deforms
    /// with the object); otherwise the brushed shape is moved and scaled with a Vision object track of its bounds.
    /// Shapes are sampled at ≤ 15 fps; one undo step ("Mask tracking complete").
    public static func propagate(project p: Project, clipID: ClipID, mask keyPath: WritableKeyPath<Clip, Mask?>, center: ParamKey,
                                 size: ParamKey, from source: Time, direction: MaskTracking.Direction,
                                 progress: (@Sendable (Double) -> Void)? = nil) async throws -> any EditCommand {
        guard let c = p.timeline.clip(clipID), let asset = c.mediaID.flatMap(p.asset), asset.kind == .video else { throw AIToolError.noInput }
        let local = ((c.timelineTime(forSource: source) ?? c.start) - c.start).clamped(.zero, c.duration)
        guard let m = c.resolved(at: local)[keyPath: keyPath], m.shape == .brush else { throw AIToolError.noInput }
        let set = MaskStrokeSet(m, m.strokes ?? [])
        guard set.strokes.contains(where: { !$0.erase }) else { throw AIToolError.noInput }
        let rot = asset.sourceRotation
        let range = MaskTracking.range(c, from: source, direction: direction)
        let av = AVURLAsset(url: ProxyManager.shared.readyProxyURL(for: asset) ?? asset.url)
        guard let track = try await av.loadTracks(withMediaType: .video).first else { throw AIToolError.noInput }
        let natural = try await track.load(.naturalSize)
        let k = min(1, 640 / max(natural.width, natural.height, 1))
        let dim = (max(16, Int(natural.width * k) / 2 * 2), max(16, Int(natural.height * k) / 2 * 2))
        let seed = seedMask(set, clip: c, asset: asset, width: dim.0, height: dim.1)
        guard seed.coverage > 0 else { throw AIToolError.noInput }
        let s0 = source.seconds
        let cancel = CancelFlag()
        let followed = try await withTaskCancellationHandler {
            try await detached { try followObjects(av, track: track, size: dim, seed: seed, at: s0, range: range, cancel: cancel, progress: progress) }
        } onCancel: { cancel.set() }
        var samples: [MaskShapeSample]
        if let followed { samples = followed } else {
            // no object under the brush: move / scale the painted shape with a box track of its bounds
            let shape = contours(seed)
            guard !shape.isEmpty, let b = MaskContours.bounds(shape) else { throw AIToolError.noInput }
            let box0 = NormRect(x: b.min.x, y: b.min.y, width: max(b.max.x - b.min.x, 0.02), height: max(b.max.y - b.min.y, 0.02))
            let boxes = try await ObjectTracker.track(asset, box: box0, at: s0, range: range, progress: progress)
            samples = []
            var last = -1.0
            for s in boxes where last < 0 || s.time - last >= 1.0 / 15 - 1e-3 || s.time == boxes.last?.time {
                last = s.time
                let kx = s.box.width / box0.width, ky = s.box.height / box0.height
                samples.append(MaskShapeSample(time: s.time, contours: shape.map { $0.map {
                    Vec2(s.box.x + ($0.x - box0.x) * kx, s.box.y + ($0.y - box0.y) * ky)
                } }))
            }
        }
        guard !samples.isEmpty else { throw AIToolError.noInput }
        let path = MaskKeyPath(keyPath)
        let result = samples
        return Edit("cmd.maskTrack") { p in
            try MaskContours.applyPropagation(result, clipID: clipID, mask: path.value, center: center, size: size, rotation: rot, in: &p)
        }
    }

    /// Blocking (run off the cooperative pool): when the seed covers objects on its frame, follows their outline at
    /// ≤ 15 fps forward to the end of `range` and backward (1 s chunks walked in reverse) to its start. nil when the
    /// brush covers no object.
    static func followObjects(_ av: AVURLAsset, track: AVAssetTrack, size: (Int, Int), seed: MaskBuffer, at s0In: Double,
                              range: TimeRange, cancel: CancelFlag, progress: (@Sendable (Double) -> Void)?) throws -> [MaskShapeSample]? {
        let lo = range.start.seconds, hi = range.end.seconds
        let s0 = min(max(s0In, lo), hi)
        var seedFrame: CVPixelBuffer?
        try ObjectTracker.forEachFrame(av, track: track, size: size, from: max(lo, s0 - 0.05), to: min(hi, s0 + 0.2), copy: true) { t, pb, _ in
            seedFrame = pb
            return t < s0 - 1e-3
        }
        guard let frame0 = seedFrame, let region0 = try objects(under: seed, handler: VNImageRequestHandler(cvPixelBuffer: frame0)) else { return nil }

        let total = max(hi - lo, 0.001)
        var done = 0.0
        func report(_ dt: Double) throws {
            if cancel.isSet { throw CancellationError() }
            done += dt; progress?(min(0.99, done / total))
        }
        let step = 1.0 / 15
        var fwd: [MaskShapeSample] = []
        var prev = region0
        var lastT = -1.0
        try ObjectTracker.forEachFrame(av, track: track, size: size, from: s0, to: hi) { t, pb, dt in
            try report(dt)
            guard lastT < 0 || t - lastT >= step - 1e-3 || t >= hi - 1e-3 else { return true }
            lastT = t
            if let m = try follow(prev, in: pb) { prev = m }
            let cs = contours(prev)
            if !cs.isEmpty { fwd.append(MaskShapeSample(time: t, contours: cs)) }
            return true
        }
        prev = region0
        var chunkEnd = s0
        var bwd: [MaskShapeSample] = []
        var lastKept = Double.infinity
        while chunkEnd > lo + 1e-3 {
            if cancel.isSet { throw CancellationError() }
            let chunkStart = max(lo, chunkEnd - 1)
            var frames: [(Double, CVPixelBuffer)] = []
            try ObjectTracker.forEachFrame(av, track: track, size: size, from: chunkStart, to: chunkEnd, copy: true) { t, pb, _ in
                if t < chunkEnd - 1e-4 { frames.append((t, pb)) }
                return true
            }
            for (t, pb) in frames.reversed() {
                try report((chunkEnd - chunkStart) / Double(max(frames.count, 1)))
                guard lastKept.isInfinite || lastKept - t >= step - 1e-3 else { continue }
                lastKept = t
                if let m = try follow(prev, in: pb) { prev = m }
                let cs = contours(prev)
                if !cs.isEmpty { bwd.append(MaskShapeSample(time: t, contours: cs)) }
            }
            chunkEnd = chunkStart
        }
        progress?(1)
        return bwd.reversed() + fwd
    }

    /// The previous region's objects in a new frame (instances overlapping it), nil when lost.
    static func follow(_ prev: MaskBuffer, in pb: CVPixelBuffer) throws -> MaskBuffer? {
        // macOS 13: no instance segmentation; `followObjects` never gets here (`objects` returns nil)
        guard #available(macOS 14, *) else { return nil }
        let handler = VNImageRequestHandler(cvPixelBuffer: pb)
        let req = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([req])
        guard let obs = req.results?.first, let labels = MaskBuffer(obs.instanceMask) else { return nil }
        var hit: [Int: Int] = [:], tot: [Int: Int] = [:]
        for y in 0..<labels.height {
            for x in 0..<labels.width {
                let l = Int(labels[x, y]); guard l != 0 else { continue }
                tot[l, default: 0] += 1
                if prev[x * prev.width / labels.width, y * prev.height / labels.height] > 127 { hit[l, default: 0] += 1 }
            }
        }
        var picked = IndexSet()
        for (l, n) in tot where n > 0 && Double(hit[l] ?? 0) / Double(n) > 0.3 { picked.insert(l) }
        picked = picked.intersection(obs.allInstances)
        guard !picked.isEmpty else { return nil }
        return MaskBuffer(try obs.generateScaledMaskForImage(forInstances: picked, from: handler))
    }

    // MARK: Segmentation

    /// Union of the foreground instances "under" the seed coverage, nil when none.
    static func objects(under seed: MaskBuffer, handler: VNImageRequestHandler) throws -> MaskBuffer? {
        // macOS 13: no instance segmentation → callers use their fallbacks (people under the brush / box tracking)
        guard #available(macOS 14, *) else { return nil }
        let req = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([req])
        guard let obs = req.results?.first, let labels = MaskBuffer(obs.instanceMask) else { return nil }
        let picked = pick(labels: labels, seed: seed).intersection(obs.allInstances)
        guard !picked.isEmpty else { return nil }
        return MaskBuffer(try obs.generateScaledMaskForImage(forInstances: picked, from: handler))
    }

    /// Labels covered by the seed (see `instanceCover` / `seedShare`).
    static func pick(labels: MaskBuffer, seed: MaskBuffer) -> IndexSet {
        var hit: [Int: Int] = [:], tot: [Int: Int] = [:]
        var seedTotal = 0
        for y in 0..<labels.height {
            for x in 0..<labels.width {
                let s = seed[x * seed.width / labels.width, y * seed.height / labels.height] > 127
                if s { seedTotal += 1 }
                let l = Int(labels[x, y]); guard l != 0 else { continue }
                tot[l, default: 0] += 1
                if s { hit[l, default: 0] += 1 }
            }
        }
        var out = IndexSet()
        for (l, n) in tot {
            let h = Double(hit[l] ?? 0)
            if h > 0 && (h / Double(n) >= instanceCover || h / Double(max(seedTotal, 1)) >= seedShare) { out.insert(l) }
        }
        return out
    }

    /// People under the seed (person segmentation), nil when the seed isn't mostly on a person.
    static func people(under seed: MaskBuffer, handler: VNImageRequestHandler) throws -> MaskBuffer? {
        let req = VNGeneratePersonSegmentationRequest()
        req.qualityLevel = .accurate
        req.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try handler.perform([req])
        guard let pb = req.results?.first?.pixelBuffer, let m = MaskBuffer(pb) else { return nil }
        var on = 0, all = 0
        for y in 0..<seed.height { for x in 0..<seed.width where seed[x, y] > 127 {
            all += 1
            if m[x * m.width / seed.width, y * m.height / seed.height] > 127 { on += 1 }
        } }
        return all > 0 && Double(on) / Double(all) >= 0.5 ? m : nil
    }

    /// Closed contours of a mask's white region (normalized, y down), simplified; tiny specks dropped.
    static func contours(_ m: MaskBuffer) -> [[Vec2]] {
        let req = VNDetectContoursRequest()
        req.detectsDarkOnLight = false
        req.contrastAdjustment = 1
        req.maximumImageDimension = 512
        let handler = VNImageRequestHandler(cgImage: m.cgImage())
        guard (try? handler.perform([req])) != nil, let obs = req.results?.first else { return [] }
        var out: [[Vec2]] = []
        func walk(_ c: VNContour) {
            let simple = (try? c.polygonApproximation(epsilon: 0.003)) ?? c
            let pts = simple.normalizedPoints.map { Vec2(Double($0.x), 1 - Double($0.y)) }
            if pts.count >= 3, abs(area(pts)) > 0.0002 { out.append(pts) }
            for child in c.childContours { walk(child) }
        }
        for c in obs.topLevelContours { walk(c) }
        return out
    }

    static func area(_ p: [Vec2]) -> Double {
        var a = 0.0
        for i in 0..<p.count { let q = p[(i + 1) % p.count]; a += p[i].x * q.y - q.x * p[i].y }
        return a / 2
    }

    // MARK: Seed

    /// A brush mask's box + the strokes to draw.
    struct MaskStrokeSet: @unchecked Sendable {
        let mask: Mask
        let strokes: [MaskStroke]
        init(_ m: Mask, _ s: [MaskStroke]) { mask = m; strokes = s }
    }

    /// The strokes drawn in raw source space at `width` × `height` (white = brushed), like the renderer draws them in
    /// layer space.
    static func seedMask(_ set: MaskStrokeSet, clip c: Clip, asset: MediaAsset, width w: Int, height h: Int) -> MaskBuffer {
        let rot = asset.sourceRotation
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return MaskBuffer(width: w, height: h) }
        ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)   // y down
        let displayH = Double((rot % 180 + 180) % 180 == 0 ? h : w)
        let layerH = displayH * max(1 - c.crop.top - c.crop.bottom, 0.01) * abs(set.mask.size.y)
        func px(_ p: Vec2) -> CGPoint {
            let r = MaskContours.boxToRaw(p, mask: set.mask, clip: c, rotation: rot)
            return CGPoint(x: r.x * Double(w), y: r.y * Double(h))
        }
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        for st in set.strokes {
            if let region = st.region {
                let path = CGMutablePath()
                for cs in region where cs.count >= 3 { path.addLines(between: cs.map(px)); path.closeSubpath() }
                ctx.setFillColor(gray: st.erase ? 0 : 1, alpha: 1)
                ctx.addPath(path); ctx.fillPath(using: .evenOdd)
                continue
            }
            guard !st.points.isEmpty else { continue }
            ctx.setStrokeColor(gray: st.erase ? 0 : 1, alpha: 1)
            ctx.setLineWidth(CGFloat(max(st.radius, 0.001) * 2 * layerH))
            let pts = st.points.map(px)
            ctx.move(to: pts[0])
            if pts.count == 1 { ctx.addLine(to: pts[0]) } else { for q in pts.dropFirst() { ctx.addLine(to: q) } }
            ctx.strokePath()
        }
        var m = MaskBuffer(width: w, height: h)
        if let data = ctx.data {
            m.pixels = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: w * h))
        }
        return m
    }

    // MARK: Frames

    /// The raw (unrotated) source frame at `t` (≤ 1280 px); stills are read without their orientation.
    static func rawFrame(_ asset: MediaAsset, at t: Time) async throws -> CGImage {
        if asset.kind == .image {
            guard let src = CGImageSourceCreateWithURL(asset.url as CFURL, nil),
                  let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                         kCGImageSourceThumbnailMaxPixelSize: 1280,
                                                                         kCGImageSourceCreateThumbnailWithTransform: false] as CFDictionary)
            else { throw AIToolError.noInput }
            return img
        }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: ProxyManager.shared.readyProxyURL(for: asset) ?? asset.url))
        gen.appliesPreferredTrackTransform = false
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
        gen.maximumSize = CGSize(width: 1280, height: 1280)
        return try await gen.image(at: t.cmTime).image
    }

    /// Runs blocking work on a GCD queue (never on the cooperative pool: AVFoundation reads + Vision block).
    static func detached<T: Sendable>(_ f: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async { cont.resume(with: Result { try f() }) }
        }
    }
}

/// Cancellation seen by blocking work on a GCD thread (no task there).
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    func set() { lock.withLock { v = true } }
    var isSet: Bool { lock.withLock { v } }
}
