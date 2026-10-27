@preconcurrency import AVFoundation
import Vision
import Foundation
import ValseCore
import ValseEngine
import ValseEffects

/// Face cover stickers (ST-006, CapCut "Face cover stickers"): every face is detected (Vision face rectangles, ≤ 5 per
/// frame, ≤ 10 faces in all), associated over time into per-face tracks (IoU / centre distance, held through short
/// drop-outs), then covered by a sticker clip per face whose position / scale keyframes follow it — a white circle, a
/// white heart or any sticker. The sticker clips are linked to the clip (move with it) and marked `faceCoverOf`.
public enum FaceTracker {
    public static let maxPerFrame = 5
    public static let maxFaces = 10

    /// Face tracks of `asset` over the media range (raw source coordinates, y down), detection at ≈ 10 fps on a ≤ 640 px
    /// decode. Stills: one detection, one sample per face.
    public static func analyze(_ asset: MediaAsset, range: TimeRange, progress: (@Sendable (Double) -> Void)? = nil) async throws -> [[TrackSample]] {
        if asset.kind == .image {
            guard let src = CGImageSourceCreateWithURL(asset.url as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw AIToolError.noInput }
            let req = VNDetectFaceRectanglesRequest()
            try VNImageRequestHandler(cgImage: img).perform([req])
            return Array(detections(req).prefix(maxFaces)).map { [TrackSample(time: 0, box: $0)] }
        }
        let av = AVURLAsset(url: ProxyManager.shared.readyProxyURL(for: asset) ?? asset.url)
        guard let track = try await av.loadTracks(withMediaType: .video).first else { throw AIToolError.noInput }
        let natural = try await track.load(.naturalSize)
        let k = min(1, 640 / max(natural.width, natural.height, 1))
        let size = (max(16, Int(natural.width * k) / 2 * 2), max(16, Int(natural.height * k) / 2 * 2))
        let lo = range.start.seconds, hi = range.end.seconds
        var assoc = Associator()
        var lastDetect = -1.0
        // blocking read loop: off the cooperative pool (OffPool)
        try await OffPool.run { ctx in
            try ObjectTracker.forEachFrame(av, track: track, size: size, from: lo, to: hi, ctx: ctx) { t, pb, _ in
                guard t - lastDetect >= 0.1 - 1e-4 else { return true }
                lastDetect = t
                let req = VNDetectFaceRectanglesRequest()
                try VNImageRequestHandler(cvPixelBuffer: pb).perform([req])
                assoc.update(time: t, boxes: Array(detections(req).prefix(maxPerFrame)))
                progress?(min(0.99, (t - lo) / max(hi - lo, 0.001)))
                return true
            }
        }
        progress?(1)
        return assoc.tracks()
    }

    static func detections(_ req: VNDetectFaceRectanglesRequest) -> [NormRect] {
        (req.results ?? []).filter { $0.confidence > 0.4 }.sorted { $0.boundingBox.width > $1.boundingBox.width }.map {
            NormRect(x: Double($0.boundingBox.minX), y: 1 - Double($0.boundingBox.maxY), width: Double($0.boundingBox.width), height: Double($0.boundingBox.height))
        }
    }

    /// Greedy IoU / distance association of per-frame detections into tracks (SORT-like, no motion model).
    struct Associator {
        struct Track { var samples: [TrackSample]; var missed = 0 }
        var live: [Track] = []
        var done: [Track] = []
        static let maxMissed = 6   // ≈ 0.6 s at 10 fps

        static func iou(_ a: NormRect, _ b: NormRect) -> Double {
            let x0 = max(a.x, b.x), y0 = max(a.y, b.y), x1 = min(a.x + a.width, b.x + b.width), y1 = min(a.y + a.height, b.y + b.height)
            let i = max(0, x1 - x0) * max(0, y1 - y0)
            return i / max(a.width * a.height + b.width * b.height - i, 1e-9)
        }

        mutating func update(time: Double, boxes: [NormRect]) {
            var free = Array(boxes.indices)
            for ti in live.indices {
                guard let last = live[ti].samples.last?.box else { continue }
                let best = free.max { a, b in score(last, boxes[a]) < score(last, boxes[b]) }
                if let bi = best, score(last, boxes[bi]) > 0.15 {
                    // light smoothing of jitter
                    let b = boxes[bi]
                    let s = NormRect(x: last.x * 0.3 + b.x * 0.7, y: last.y * 0.3 + b.y * 0.7,
                                     width: last.width * 0.3 + b.width * 0.7, height: last.height * 0.3 + b.height * 0.7)
                    live[ti].samples.append(TrackSample(time: time, box: s)); live[ti].missed = 0
                    free.removeAll { $0 == bi }
                } else {
                    live[ti].missed += 1
                }
            }
            for (i, t) in live.enumerated().reversed() where t.missed > Self.maxMissed { done.append(t); live.remove(at: i) }
            for bi in free where live.count + done.count < FaceTracker.maxFaces * 3 {
                live.append(Track(samples: [TrackSample(time: time, box: boxes[bi])]))
            }
        }

        /// IoU, or a centre-distance score when boxes don't overlap (fast motion).
        func score(_ a: NormRect, _ b: NormRect) -> Double {
            let i = Self.iou(a, b)
            if i > 0 { return 0.2 + i }
            let d = (a.center - b.center).length / max(max(a.width, a.height), 0.02)
            return d < 1.5 ? 0.2 - d * 0.1 : 0
        }

        /// Tracks with ≥ 2 samples (single false positives dropped unless only stills), longest first, ≤ maxFaces.
        func tracks() -> [[TrackSample]] {
            let all = (done + live).map(\.samples)
            return Array(all.filter { $0.count >= 2 }.sorted { $0.count > $1.count }.prefix(FaceTracker.maxFaces))
        }
    }
}

public enum FaceStickers {
    public static let circleID = "valse.sticker.shape.circle.white"
    public static let heartID = "valse.sticker.shape.heart.white"

    /// Face sticker clips covering `clipID`.
    public static func covers(of clipID: ClipID, in tl: Timeline) -> [Clip] { tl.allClips.filter { $0.faceCoverOf == clipID } }

    /// Replaces the face stickers of `clipID` with one `stickerID` clip per face track. `size` = sticker side / face
    /// height (1.6 covers the head); keyframes ≤ 15 / s.
    public static func apply(_ tracks: [[TrackSample]], sticker stickerID: String, size: Double = 1.6, opacity: Double = 1,
                             to clipID: ClipID, in p: inout Project) throws {
        remove(from: clipID, in: &p)
        guard let ref = p.timeline.clip(clipID), let asset = ref.mediaID.flatMap(p.asset) else { throw EditError.clipNotFound }
        let canvas = p.settings.canvasSize
        let rot = asset.sourceRotation
        let nominal = canvas.height * 0.35   // sticker side at scale 1 (FrameEvaluator.layer)
        var lanes: [(track: TrackID, end: Time)] = []
        var added = 0
        for samples in tracks {
            // timeline placement of each sample
            var placed: [(t: Time, center: Vec2, side: Double)] = []
            for s in samples.sorted(by: { $0.time < $1.time }) {
                let t: Time? = asset.kind == .image ? ref.start : ref.timelineTime(forSource: Time(s.time))
                guard let t, t >= ref.start, t < ref.end, let l = MotionTracking.layer(of: clipID, in: p, at: t) else { continue }
                let c = MotionTracking.canvasPoint(MotionTracking.rawToDisplay(s.box.center, rotation: rot), layer: l, canvas: canvas)
                let top = MotionTracking.canvasPoint(MotionTracking.rawToDisplay(Vec2(s.box.center.x, s.box.y), rotation: rot), layer: l, canvas: canvas)
                let bottom = MotionTracking.canvasPoint(MotionTracking.rawToDisplay(Vec2(s.box.center.x, s.box.y + s.box.height), rotation: rot), layer: l, canvas: canvas)
                placed.append((t, c, (bottom - top).length * size))
            }
            guard let first = placed.first, let last = placed.last else { continue }
            let start = first.t
            let end = asset.kind == .image ? ref.end : min(ref.end, max(last.t + Time(0.2), start + Time(0.3)))
            var c = Clip(content: .sticker(id: stickerID), start: start, duration: end - start)
            c.linkedTo = clipID
            c.faceCoverOf = clipID
            c.opacity = opacity
            func pos(_ v: Vec2) -> Vec2 { Vec2((v.x - canvas.width / 2) / canvas.width, (v.y - canvas.height / 2) / canvas.height) }
            func scl(_ side: Double) -> Vec2 { let k = max(side / nominal, 0.02); return Vec2(k, k) }
            c.transform.position = pos(first.center)
            c.transform.scale = scl(first.side)
            if placed.count > 1 {
                var pk: [Keyframe] = [], sk: [Keyframe] = []
                var lastT = -1.0
                for (i, q) in placed.enumerated() {
                    let local = q.t - start
                    if local.seconds - lastT < 1.0 / 15 - 1e-6 && i != placed.count - 1 { continue }
                    lastT = local.seconds
                    pk.append(Keyframe(time: local, value: .vec2(pos(q.center))))
                    sk.append(Keyframe(time: local, value: .vec2(scl(q.side))))
                }
                c.keyframes[ParamKey.position.raw] = KeyframeTrack(pk)
                c.keyframes[ParamKey.scale.raw] = KeyframeTrack(sk)
            }
            // greedy lanes: reuse a face-sticker track when the previous sticker on it has ended
            if let li = lanes.firstIndex(where: { $0.end <= start }) {
                try TimelineOps.insert(c, into: &p, target: .track(lanes[li].track))
                lanes[li].end = end
            } else {
                try TimelineOps.insert(c, into: &p, target: .newTrack)
                if let loc = p.timeline.locate(c.id) { lanes.append((p.timeline.tracks[loc.track].id, end)) }
            }
            added += 1
        }
        if added == 0 { throw EditError.nothingToDo }
    }

    /// Updates opacity of the face stickers (no re-analysis).
    public static func setOpacity(_ v: Double, of clipID: ClipID, in p: inout Project) {
        for c in covers(of: clipID, in: p.timeline) { p.timeline[clip: c.id]?.opacity = v }
    }

    public static func remove(from clipID: ClipID, in p: inout Project) {
        let ids = covers(of: clipID, in: p.timeline).map(\.id)
        guard !ids.isEmpty else { return }
        var emptied: Set<TrackID> = []
        for id in ids {
            if let loc = p.timeline.locate(id) { emptied.insert(p.timeline.tracks[loc.track].id) }
            p.timeline[clip: id] = nil
        }
        p.timeline.tracks.removeAll { emptied.contains($0.id) && !$0.isMain && $0.clips.isEmpty }
    }
}

/// Face tracks per media range, kept for the session so restyling / resizing face stickers is instant.
public final class FaceTrackCache: @unchecked Sendable {
    public static let shared = FaceTrackCache()
    private let lock = NSLock()
    private var tracks: [String: [[TrackSample]]] = [:]
    public static func key(_ asset: MediaAsset, _ range: TimeRange) -> String {
        "\(asset.id)|\(range.start.ticks)|\(range.duration.ticks)"
    }
    public subscript(_ key: String) -> [[TrackSample]]? {
        get { lock.withLock { tracks[key] } }
        set { lock.withLock { tracks[key] = newValue } }
    }
}
