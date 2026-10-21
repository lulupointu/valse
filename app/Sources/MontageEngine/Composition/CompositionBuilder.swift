@preconcurrency import AVFoundation
import Foundation
import MontageCore

/// Result of translating a project into AVFoundation objects. Immutable after build.
public struct BuiltComposition: @unchecked Sendable {
    public let composition: AVComposition
    public let videoComposition: AVVideoComposition
    public let audioMix: AVAudioMix?
    public let trackMap: [ClipID: CMPersistentTrackID]
    public let duration: Time
    public let state: RenderState
    /// Live audio parameters read by the lane taps (W8, `MontageEngine/Audio`).
    public let audioState: AudioMixState
}

/// Which files back a media item in this build (preview uses proxies when ready; export uses originals).
public struct MediaSourceChoice: Sendable, Hashable {
    public var video: URL
    public var audio: URL
    public init(video: URL, audio: URL) { self.video = video; self.audio = audio }
}

public enum RenderPurpose: Sendable { case preview, export }

/// Caches opened assets and their first video/audio track (loading tracks is async and not free).
public actor AssetCache {
    public static let shared = AssetCache()
    struct Entry {
        let asset: AVURLAsset
        let video: AVAssetTrack?
        let audio: AVAssetTrack?
        let videoRange: CMTimeRange
        let audioRange: CMTimeRange
        /// Every audio stream (multi-track media, MI-014) with its range.
        var audios: [(AVAssetTrack, CMTimeRange)] = []
        /// Audio stream `index` (nil/out of range = first).
        func audioStream(_ index: Int?) -> (AVAssetTrack, CMTimeRange)? {
            if let index, audios.indices.contains(index) { return audios[index] }
            return audio.map { ($0, audioRange) }
        }
    }
    private var entries: [URL: Entry] = [:]

    func entry(_ url: URL) async throws -> Entry {
        if let e = entries[url] { return e }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let v = try await asset.loadTracks(withMediaType: .video).first
        let a = try await asset.loadTracks(withMediaType: .audio).first
        let vr = try await v?.load(.timeRange) ?? .zero
        let ar = try await a?.load(.timeRange) ?? .zero
        var e = Entry(asset: asset, video: v, audio: a, videoRange: vr, audioRange: ar)
        for t in try await asset.loadTracks(withMediaType: .audio) { e.audios.append((t, try await t.load(.timeRange))) }
        entries[url] = e
        return e
    }

    public func evict(_ url: URL) { entries[url] = nil }
}

/// Project → AVMutableComposition + AVVideoComposition (MontageCompositor) + AVAudioMix.
///
/// - Every timeline track with video media gets one composition video track; the main track gets two (A/B roll) so
///   transition overlaps can decode both sides. Each speed segment is inserted then `scaleTimeRange`d (curve speed is
///   a piecewise-constant approximation, see `Speed.segments`). Audio follows the same layout; volume/fades/volume
///   keyframes become audio-mix ramps; pitch preservation selects the time-pitch algorithm per track.
/// - A tiny black "base" track spans the whole timeline so text/stickers-only regions still produce frames.
/// - The video composition carries ONE instruction pointing at the shared `RenderState`; frames are evaluated live.
public enum CompositionBuilder {
    /// Builds are serialized: AVAssetTracks are shared through `AssetCache`, and concurrent `insertTimeRange` calls on the
    /// same source track fail intermittently (-12780).
    static let buildLock = AsyncSemaphore(limit: 1)
    /// Builds finished in this process (any outcome). A build waiting for `buildLock` behind others sees this move:
    /// tests use it to tell "queued behind other work" (keep waiting) from "stuck" (PlaybackProbe.waitReady).
    public static var finishedBuilds: Int { finishedLock.withLock { finished } }
    private nonisolated(unsafe) static var finished = 0
    private static let finishedLock = NSLock()

    public static func build(project: Project, purpose: RenderPurpose, renderSize: CGSize? = nil,
                             frameRate: FrameRate? = nil, state existingState: RenderState? = nil,
                             audioState existingAudioState: AudioMixState? = nil,
                             highPrecision: Bool = false,
                             sources: @Sendable (MediaAsset) -> MediaSourceChoice = { let u = PlayableMediaCache.shared.resolvedURL(for: $0); return MediaSourceChoice(video: u, audio: u) })
    async throws -> BuiltComposition {
        await buildLock.wait()
        defer { finishedLock.withLock { finished += 1 }; Task { await buildLock.signal() } }
        try Task.checkCancellation()
        let comp = AVMutableComposition()
        let duration = max(project.duration, project.settings.frameRate.frameDuration)
        var trackMap: [ClipID: CMPersistentTrackID] = [:]
        var videoTrackIDs: [CMPersistentTrackID] = []
        var audioParams: [AVMutableAudioMixInputParameters] = []
        let audioState = existingAudioState ?? AudioMixState()
        audioState.update(project: project)
        let waveforms = await Ducking.waveforms(for: project)

        // Base track
        let blank = try await BlankVideo.url()
        if let bt = try await AssetCache.shared.entry(blank).video,
           let base = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try addBase(base, blank: bt, duration: duration)
            videoTrackIDs.append(base.trackID)
        }

        let fr = frameRate ?? project.settings.frameRate
        var auxMap: [ClipID: [AuxRole: CMPersistentTrackID]] = [:]
        for track in CompoundFlattening.decodeTracks(project) {
            let mediaClips = track.clips.filter { $0.isEnabled && $0.mediaID.flatMap(project.asset) != nil }
            guard !mediaClips.isEmpty else { continue }
            // A/B lanes where neighbours overlap: the main track and overlay tracks with transitions (PiP, TR-004)
            let lanes = track.isMain || track.clips.contains(where: { $0.transitionOut != nil }) ? 2 : 1
            var vLanes: [AVMutableCompositionTrack?] = Array(repeating: nil, count: lanes)
            var aLanes: [(AVMutableCompositionTrack, AVMutableAudioMixInputParameters)?] = Array(repeating: nil, count: lanes)
            var auxLanes: [String: AVMutableCompositionTrack] = [:]
            var auxOrder: [CMPersistentTrackID] = []
            var laneClips: [[Clip]] = Array(repeating: [], count: lanes)
            for (i, clip) in mediaClips.enumerated() {
                guard let asset = clip.mediaID.flatMap(project.asset) else { continue }
                let lane = lanes == 2 ? i % 2 : 0
                let choice = sources(asset)
                // Reverse: play the reversed render forwards from the mirrored in-point (same remap, frame exact).
                var videoURL = choice.video, audioURL = choice.audio
                var mapped = clip
                var reversedURL: URL?
                if clip.reversed {
                    reversedURL = purpose == .export ? try await ReverseManager.shared.ensure(asset) : ReverseManager.shared.readyURL(for: asset)
                    if let r = reversedURL {
                        videoURL = r; audioURL = r
                        mapped.sourceStart = max(.zero, asset.duration - clip.sourceStart - clip.sourceDuration)
                    } else {
                        EngineLog.info("reversed render not ready (clip \(clip.id.short)): showing forwards")
                    }
                }
                let segments = remapSegments(mapped, asset: asset, frameRate: fr)

                if asset.kind == .video, asset.hasVideo, track.kind.isVisual {
                    let entry = try await AssetCache.shared.entry(videoURL)
                    if let src = entry.video {
                        if vLanes[lane] == nil { vLanes[lane] = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) }
                        if let vt = vLanes[lane] {
                            try insert(clip: mapped, segments: segments, from: src, sourceRange: entry.videoRange, into: vt)
                            trackMap[clip.id] = vt.trackID
                        }
                    }
                    // Aux lanes: same output layout, shifted source (blend/motion-blur frames) or another file (matte).
                    for (role, url, shift) in try await auxInputs(clip, asset: asset, videoURL: videoURL, reversed: reversedURL != nil, purpose: purpose, frameRate: fr) {
                        let entry = try await AssetCache.shared.entry(url)
                        guard let src = entry.video else { continue }
                        let key = "\(lane)-\(role)"
                        if auxLanes[key] == nil, let t = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                            auxLanes[key] = t; auxOrder.append(t.trackID)
                        }
                        guard let at = auxLanes[key] else { continue }
                        var shifted = mapped
                        shifted.sourceStart = mapped.sourceStart + shift
                        try insert(clip: shifted, segments: segments, from: src, sourceRange: entry.videoRange, into: at, stretch: false)
                        auxMap[clip.id, default: [:]][role] = at.trackID
                    }
                }
                let audible = asset.hasAudio && clip.audio.isAudible && !track.isMuted
                    && (clip.audio.volume > 0 || clip.keyframes[ParamKey.volume.raw] != nil)
                let processedURL = audible ? try await AudioPipeline.audioSource(clip: clip, asset: asset, original: audioURL, purpose: purpose) : nil
                var audioEntry: AssetCache.Entry?
                if let processedURL { audioEntry = try await AssetCache.shared.entry(processedURL) }
                if let audioEntry, let (src, srcAudioRange) = audioEntry.audioStream(clip.reversed && reversedURL != nil ? 0 : clip.audioStreamIndex) {
                    if aLanes[lane] == nil, let at = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                        let p = AVMutableAudioMixInputParameters(track: at)
                        p.trackID = at.trackID
                        p.audioTimePitchAlgorithm = .spectral
                        p.setVolume(0, at: .zero)
                        aLanes[lane] = (at, p)
                    }
                    if let (at, p) = aLanes[lane] {
                        try insert(clip: mapped, segments: segments, from: src, sourceRange: srcAudioRange, into: at)
                        applyVolume(clip, to: p, gain: ClipAudioPlan.make(clip).staticGain,
                                    duck: Ducking.envelope(for: clip, in: project, waveforms: waveforms))
                        laneClips[lane].append(clip)
                    }
                }
            }
            for v in vLanes.compactMap({ $0 }) { videoTrackIDs.append(v.trackID) }
            videoTrackIDs += auxOrder
            for (l, a) in aLanes.enumerated() {
                guard let a else { continue }
                a.1.audioTapProcessor = AudioTap.make(LaneProcessor(clips: laneClips[l], state: audioState))
                audioParams.append(a.1)
            }
        }

        // Preview render cache: valid pre-rendered segments as passthrough lanes (see RenderCache).
        var cached: [(range: TimeRange, key: String, track: CMPersistentTrackID)] = []
        let size = renderSize ?? CGSize(width: project.settings.canvasSize.width, height: project.settings.canvasSize.height)
        if purpose == .preview {
            for seg in RenderCache.shared.validSegments(project, size: size) {
                guard let src = try await AssetCache.shared.entry(seg.url).video,
                      let ct = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                let fileRange = try await src.load(.timeRange)
                try ct.insertTimeRange(fileRange, of: src, at: seg.range.start.cmTime)
                cached.append((seg.range, seg.key, ct.trackID))
                videoTrackIDs.append(ct.trackID)
            }
        }

        let state = existingState ?? RenderState(project: project, keepsRecentSources: purpose == .preview)
        state.update(project: project)
        state.update(trackMap: trackMap)
        state.update(auxMap: auxMap)
        state.update(cachedSegments: cached, renderSize: size)

        let vc = AVMutableVideoComposition()
        let space = project.settings.colorSpace
        // `highPrecision`: 16-bit compositor buffers for SDR too (10-bit HEVC / ProRes export).
        vc.customVideoCompositorClass = (space.isHDR || highPrecision) ? MontageHDRCompositor.self : MontageCompositor.self
        vc.frameDuration = CMTime(value: CMTimeValue(fr.denominator), timescale: fr.numerator)
        vc.renderSize = renderSize ?? CGSize(width: project.settings.canvasSize.width, height: project.settings.canvasSize.height)
        // No colour properties on the video composition (C1): when they differ from a source's, AVPlayer (preview)
        // CONVERTS the source frames to them before the compositor sees them (VideoToolbox HDR → SDR / HLG → PQ, despite
        // `supportsHDRSourceFrames`), while AVAssetReader / AVAssetImageGenerator (export, thumbnails) only re-matrix
        // the YCbCr — and both stamp the composition's tags, so the frames cannot be told apart. The renderer converts
        // from the asset's own tags, so the HLG footage was converted twice in the preview (SDR: red, crushed skin;
        // PQ: washed out). Untagged, every path delivers the decoded frames untouched; the compositor stamps its output
        // with the project's tags (`MontageCompositor.stamp`).
        vc.instructions = [MontageInstruction(timeRange: CMTimeRange(start: .zero, duration: duration.cmTime),
                                              trackIDs: videoTrackIDs, state: state)]
        var mix: AVMutableAudioMix?
        if !audioParams.isEmpty { mix = AVMutableAudioMix(); mix!.inputParameters = audioParams }
        return BuiltComposition(composition: comp, videoComposition: vc, audioMix: mix, trackMap: trackMap,
                                duration: duration, state: state, audioState: audioState)
    }

    /// The base track covers `[0, duration)` with copies of the blank file, back to back and unscaled (B1). It used to
    /// be the blank's first second STRETCHED to the duration (`scaleTimeRange`): for about one duration in three
    /// (32.735 s = owner clip IMG_9079, 32.7, 45.123, 61.01 s …) an AVAssetReader whose `timeRange` starts inside the
    /// stretched samples never delivered a composed frame (AVFoundation; Apple's own compositor too), so range exports
    /// starting mid-project hung while full / from-0 exports worked.
    static func addBase(_ base: AVMutableCompositionTrack, blank: AVAssetTrack, duration: Time) throws {
        let piece = Time(Double(BlankVideo.seconds))
        var at = Time.zero
        while at < duration {
            let len = min(piece, duration - at)
            try base.insertTimeRange(CMTimeRange(start: .zero, duration: len.cmTime), of: blank, at: at.cmTime)
            at = at + len
        }
    }

    /// Aux lanes a clip needs: (role, file, source shift).
    static func auxInputs(_ clip: Clip, asset: MediaAsset, videoURL: URL, reversed: Bool, purpose: RenderPurpose,
                          frameRate: FrameRate = .fps30) async throws -> [(AuxRole, URL, Time)] {
        var out: [(AuxRole, URL, Time)] = []
        let sfd = (asset.frameRate ?? .fps30).frameDuration
        if clip.smoothSlowMo != nil, FrameUpconversion.needsInterpolation(rate: FrameUpconversion.minRate(clip.speed),
                                                                           sourceRate: asset.frameRate, projectRate: frameRate) {
            out.append((.nextFrame, videoURL, sfd))
        }
        if let mb = clip.motionBlur, mb.amount > 0 {
            // CV-014: .previousFrame(k) holds source frame −k (negative k = a following frame for forward / both ways)
            for off in mb.frameOffsets { out.append((.previousFrame(-off), videoURL, Time(ticks: sfd.ticks * Int64(off)))) }
        }
        if let m = clip.matte, clip.usesMatteLane, let matte = MatteStore.shared.readyMatteVideo(media: asset, kind: m.kind) {
            if reversed {
                let key = MatteStore.shared.reverseKey(media: asset, kind: m.kind)
                let r = purpose == .export ? try await ReverseManager.shared.ensure(source: matte, key: key)
                                           : ReverseManager.shared.readyURL(key: key)
                if let r { out.append((.matte, r, .zero)) } else { _ = await ReverseManager.shared.request(source: matte, key: key) }
            } else {
                out.append((.matte, matte, .zero))
            }
        }
        // Relight (AI2): depth matte + person matte (People / Background targets), same reverse handling as the matte.
        if let rl = clip.relight {
            var lanes: [(AuxRole, String)] = [(.depth, RelightOps.depthKind)]
            if rl.target.usesPersonMatte { lanes.append((.relightMask, RelightOps.personKind)) }
            for (role, kind) in lanes {
                guard let file = MatteStore.shared.readyMatteVideo(media: asset, kind: kind) else { continue }
                if reversed {
                    let key = MatteStore.shared.reverseKey(media: asset, kind: kind)
                    let r = purpose == .export ? try await ReverseManager.shared.ensure(source: file, key: key)
                                               : ReverseManager.shared.readyURL(key: key)
                    if let r { out.append((role, r, .zero)) } else { _ = await ReverseManager.shared.request(source: file, key: key) }
                } else {
                    out.append((role, file, .zero))
                }
            }
        }
        return out
    }

    static func hasSlowSection(_ s: Speed) -> Bool {
        switch s {
        case .constant(let v): return v < 0.999
        case .curve(let c): return c.points.contains { $0.v < 0.999 }
        }
    }

    /// Frame-accurate speed segments for a clip (see `Speed.frameAccurateSegments`): boundaries on the output frame
    /// grid of this build; every composed frame lands in the same source frame as the exact remap.
    static func remapSegments(_ clip: Clip, asset: MediaAsset, frameRate: FrameRate) -> [(output: TimeRange, source: TimeRange)] {
        let fd = frameRate.frameDuration
        let phase = Time(ticks: (fd.ticks - clip.start.ticks % fd.ticks) % fd.ticks)
        let srcFrame = (asset.frameRate ?? .fps30).frameDuration
        return clip.speed.frameAccurateSegments(outputDuration: clip.duration, frameDuration: fd, firstFrame: phase,
                                                tolerance: srcFrame * 0.5, sourceFrame: (clip.sourceStart, srcFrame))
    }

    /// Inserts a clip's speed segments into a composition track at the clip's timeline position.
    /// `stretch`: when the media is shorter than the segment asks for, stretch what exists over the whole output
    /// range (main lanes: no black frame) or keep the exact rate and leave the rest empty (aux lanes: timing matters).
    static func insert(clip: Clip, segments: [(output: TimeRange, source: TimeRange)], from src: AVAssetTrack,
                       sourceRange srcRange: CMTimeRange, into dst: AVMutableCompositionTrack, stretch: Bool = true) throws {
        for seg in segments {
            var at = (clip.start + seg.output.start).cmTime
            let wanted = CMTimeRange(start: (clip.sourceStart + seg.source.start).cmTime, duration: seg.source.duration.cmTime)
            let s = CMTimeRangeGetIntersection(wanted, otherRange: srcRange)
            guard s.duration > .zero else { continue }
            var outDur = seg.output.duration.cmTime
            if !stretch, s != wanted {
                let rate = seg.source.duration / seg.output.duration
                at = CMTimeAdd(at, Time(Time(cmTime: CMTimeSubtract(s.start, wanted.start)).seconds / rate).cmTime)
                outDur = Time(Time(cmTime: s.duration).seconds / rate).cmTime
            }
            let end = dst.timeRange.end
            if dst.timeRange.duration > .zero, CMTimeCompare(end, at) < 0 {
                dst.insertEmptyTimeRange(CMTimeRange(start: end, end: at))
            }
            // Keep the timeline layout exact even if the source is shorter than expected.
            try dst.insertTimeRange(s, of: src, at: at)
            if CMTimeCompare(s.duration, outDur) != 0 {
                dst.scaleTimeRange(CMTimeRange(start: at, duration: s.duration), toDuration: outDur)
            }
        }
    }

    /// Linear ramp pieces per eased volume-keyframe span.
    static let volumeCurveSteps = 16

    /// Clip gain, fades and volume keyframes as linear ramps on the lane.
    static func applyVolume(_ clip: Clip, to p: AVMutableAudioMixInputParameters, gain: Double = 1, duck: Ducking.Envelope? = nil) {
        let start = clip.start, end = clip.end
        func v(_ local: Time) -> Float {
            var g = (clip.value(.volume, at: local)?.scalar ?? clip.audio.volume) * gain
            if let duck { g *= Double(duck.gain(at: start + local)) }
            if clip.audio.fadeIn > .zero, local < clip.audio.fadeIn { g *= local / clip.audio.fadeIn }
            if clip.audio.fadeOut > .zero, local > clip.duration - clip.audio.fadeOut {
                g *= max(0, (clip.duration - local) / clip.audio.fadeOut)
            }
            return Float(max(0, g))
        }
        // breakpoints: start, fade ends, keyframes, end
        var points: Set<Int64> = [0, clip.duration.ticks]
        if clip.audio.fadeIn > .zero { points.insert(min(clip.audio.fadeIn, clip.duration).ticks) }
        if clip.audio.fadeOut > .zero { points.insert(max(.zero, clip.duration - clip.audio.fadeOut).ticks) }
        let vks = clip.keyframes[ParamKey.volume.raw]?.keyframes ?? []
        for k in vks where k.time > .zero && k.time < clip.duration {
            points.insert(k.time.ticks)
        }
        // eased spans between volume keyframes: sample the curve (the timeline draws `KeyframeTrack.value`, C3b)
        for (a, b) in zip(vks, vks.dropFirst()) where a.easing != .linear && b.time > a.time {
            for i in 1..<volumeCurveSteps {
                let t = a.time + (b.time - a.time) * (Double(i) / Double(volumeCurveSteps))
                if t > .zero && t < clip.duration { points.insert(t.ticks) }
            }
        }
        if let duck {
            // ducking breakpoints only where the envelope moves
            var prev: Float = -1
            for (i, g) in duck.gains.enumerated() where abs(g - prev) > 0.002 || i == duck.gains.count - 1 {
                let t = Time(Double(i) * duck.step)
                if t > .zero && t < clip.duration { points.insert(t.ticks) }
                prev = g
            }
        }
        let sorted = points.sorted().map { Time(ticks: $0) }
        for i in 0..<(sorted.count - 1) {
            let a = sorted[i], b = sorted[i + 1]
            p.setVolumeRamp(fromStartVolume: v(a), toEndVolume: v(b),
                            timeRange: CMTimeRange(start: (start + a).cmTime, duration: (b - a).cmTime))
        }
        p.setVolume(0, at: end.cmTime)
    }

    /// Hash of everything that requires rebuilding the AVComposition (vs. live property edits).
    /// Hot path: `StructureKeyCache` (same result, incremental per track).
    public static func structureKey(_ project: Project, sources: (MediaAsset) -> MediaSourceChoice) -> Int {
        var h = Hasher()
        h.combine(project.settings.canvasSize)
        h.combine(project.settings.frameRate)
        h.combine(project.settings.colorSpace)
        let lookup = project.mediaLookup
        for t in CompoundFlattening.decodeTracks(project) {
            h.combine(t.id); h.combine(t.kind); h.combine(t.isMain); h.combine(t.isMuted)
            for c in t.clips {
                guard let id = c.mediaID, let a = lookup[id] else { continue }
                h.combine(c.id); h.combine(id); h.combine(c.start); h.combine(c.duration); h.combine(c.sourceStart)
                h.combine(c.speed); h.combine(c.reversed); h.combine(c.isEnabled); h.combine(c.audioStreamIndex)
                AudioPipeline.combineStructure(c, asset: a, into: &h)
                h.combine(c.keyframes[ParamKey.volume.raw])
                h.combine(sources(a))
                h.combine(c.smoothSlowMo); h.combine(c.motionBlur?.clampedSamples); h.combine(c.motionBlur?.direction); h.combine(c.matte?.kind); h.combine(c.usesMatteLane)
                if c.reversed { h.combine(ReverseManager.shared.readyURL(for: a) != nil) }
                if let m = c.matte { h.combine(MatteStore.shared.readyMatteVideo(media: a, kind: m.kind) != nil) }
                if let rl = c.relight {
                    h.combine(rl.target.usesPersonMatte)
                    h.combine(MatteStore.shared.readyMatteVideo(media: a, kind: RelightOps.depthKind) != nil)
                    if rl.target.usesPersonMatte { h.combine(MatteStore.shared.readyMatteVideo(media: a, kind: RelightOps.personKind) != nil) }
                }
            }
        }
        return h.finalize()
    }
}


/// Incremental `CompositionBuilder.structureKey` for the playback engine (perf, W14 round 2): a property drag on a
/// 500-clip timeline otherwise rehashes every clip on every tick. The project-only part of each track's hash is cached
/// against the track's clip array buffer (retained here, so an unchanged buffer means unchanged clips: copy-on-write
/// copies on any mutation); the media list is checked the same way. Parts that depend on background state (proxy /
/// playable sources, reversed media, mattes, rendered audio stages) are re-evaluated every time, per distinct media and
/// for the few clips that need them. Equal inputs → equal key as `structureKey` would give for change detection.
public final class StructureKeyCache: @unchecked Sendable {
    private struct Entry {
        let clips: [Clip]
        let pure: Int
        let media: [MediaID]
        let external: [(Clip, MediaAsset)]
    }
    private let lock = NSLock()
    private var media: [MediaAsset] = []
    private var entries: [TrackID: Entry] = [:]

    public init() {}

    private static func same<T>(_ a: [T], _ b: [T]) -> Bool {
        guard a.count == b.count else { return false }
        if a.isEmpty { return true }
        return a.withUnsafeBufferPointer { pa in b.withUnsafeBufferPointer { pb in pa.baseAddress == pb.baseAddress } }
    }

    public func key(_ project: Project, sources: (MediaAsset) -> MediaSourceChoice) -> Int {
        lock.lock(); defer { lock.unlock() }
        if !Self.same(media, project.media) { media = project.media; entries.removeAll() }
        let lookup = project.mediaLookup
        var h = Hasher()
        h.combine(project.settings.canvasSize)
        h.combine(project.settings.frameRate)
        h.combine(project.settings.colorSpace)
        var seen = Set<MediaID>(), used: [MediaAsset] = []
        var live: Set<TrackID> = []
        for t in CompoundFlattening.decodeTracks(project) {
            h.combine(t.id); h.combine(t.kind); h.combine(t.isMain); h.combine(t.isMuted)
            live.insert(t.id)
            let e: Entry
            if let c = entries[t.id], Self.same(c.clips, t.clips) { e = c } else {
                e = Self.entry(t.clips, lookup: lookup)
                entries[t.id] = e
            }
            h.combine(e.pure)
            for id in e.media where seen.insert(id).inserted { if let a = lookup[id] { used.append(a) } }
            for (c, a) in e.external {
                if c.reversed { h.combine(ReverseManager.shared.readyURL(for: a) != nil) }
                if let m = c.matte { h.combine(MatteStore.shared.readyMatteVideo(media: a, kind: m.kind) != nil) }
                let spec = ClipAudioPlan.make(c).render
                if !spec.isIdentity { h.combine(AudioRenderCache.shared.readyURL(for: a, spec: spec) != nil) }
            }
        }
        if entries.count > live.count { entries = entries.filter { live.contains($0.key) } }
        for a in used { h.combine(a.id); h.combine(sources(a)) }
        return h.finalize()
    }

    private static func entry(_ clips: [Clip], lookup: MediaLookup) -> Entry {
        var h = Hasher()
        var media: [MediaID] = [], seen = Set<MediaID>(), external: [(Clip, MediaAsset)] = []
        for c in clips {
            guard let id = c.mediaID, let a = lookup[id] else { continue }
            h.combine(c.id); h.combine(id); h.combine(c.start); h.combine(c.duration); h.combine(c.sourceStart)
            h.combine(c.speed); h.combine(c.reversed); h.combine(c.isEnabled); h.combine(c.audioStreamIndex)
            let au = c.audio
            h.combine(au.volume); h.combine(au.fadeIn); h.combine(au.fadeOut); h.combine(au.isMuted); h.combine(au.preservePitch)
            h.combine(au.loudness); h.combine(au.ducking)
            let spec = ClipAudioPlan.make(c).render
            h.combine(spec)
            h.combine(c.keyframes[ParamKey.volume.raw])
            h.combine(c.smoothSlowMo); h.combine(c.motionBlur?.clampedSamples); h.combine(c.motionBlur?.direction); h.combine(c.matte?.kind)
            if seen.insert(id).inserted { media.append(id) }
            if c.reversed || c.matte != nil || !spec.isIdentity { external.append((c, a)) }
        }
        return Entry(clips: clips, pure: h.finalize(), media: media, external: external)
    }
}
