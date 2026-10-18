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
    }
    private var entries: [URL: Entry] = [:]

    func entry(_ url: URL) async throws -> Entry {
        if let e = entries[url] { return e }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let v = try await asset.loadTracks(withMediaType: .video).first
        let a = try await asset.loadTracks(withMediaType: .audio).first
        let vr = try await v?.load(.timeRange) ?? .zero
        let ar = try await a?.load(.timeRange) ?? .zero
        let e = Entry(asset: asset, video: v, audio: a, videoRange: vr, audioRange: ar)
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

    public static func build(project: Project, purpose: RenderPurpose, renderSize: CGSize? = nil,
                             frameRate: FrameRate? = nil, state existingState: RenderState? = nil,
                             sources: @Sendable (MediaAsset) -> MediaSourceChoice = { MediaSourceChoice(video: $0.url, audio: $0.url) })
    async throws -> BuiltComposition {
        await buildLock.wait()
        defer { Task { await buildLock.signal() } }
        try Task.checkCancellation()
        let comp = AVMutableComposition()
        let duration = max(project.duration, project.settings.frameRate.frameDuration)
        var trackMap: [ClipID: CMPersistentTrackID] = [:]
        var videoTrackIDs: [CMPersistentTrackID] = []
        var audioParams: [AVMutableAudioMixInputParameters] = []

        // Base track
        let blank = try await BlankVideo.url()
        if let bt = try await AssetCache.shared.entry(blank).video,
           let base = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let one = CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1))
            try base.insertTimeRange(one, of: bt, at: .zero)
            base.scaleTimeRange(CMTimeRange(start: .zero, duration: one.duration), toDuration: duration.cmTime)
            videoTrackIDs.append(base.trackID)
        }

        let fr = frameRate ?? project.settings.frameRate
        var auxMap: [ClipID: [AuxRole: CMPersistentTrackID]] = [:]
        for track in project.timeline.tracks {
            let mediaClips = track.clips.filter { $0.isEnabled && $0.mediaID.flatMap(project.asset) != nil }
            guard !mediaClips.isEmpty else { continue }
            let lanes = track.isMain ? 2 : 1
            var vLanes: [AVMutableCompositionTrack?] = Array(repeating: nil, count: lanes)
            var aLanes: [(AVMutableCompositionTrack, AVMutableAudioMixInputParameters)?] = Array(repeating: nil, count: lanes)
            var auxLanes: [String: AVMutableCompositionTrack] = [:]
            var auxOrder: [CMPersistentTrackID] = []
            for (i, clip) in mediaClips.enumerated() {
                guard let asset = clip.mediaID.flatMap(project.asset) else { continue }
                let lane = track.isMain ? i % 2 : 0
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
                    for (role, url, shift) in try await auxInputs(clip, asset: asset, videoURL: videoURL, reversed: reversedURL != nil, purpose: purpose) {
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
                let audible = asset.hasAudio && !clip.audio.isMuted && !track.isMuted && clip.audio.volume > 0
                let audioEntry = audible ? try await AssetCache.shared.entry(audioURL) : nil
                if let audioEntry, let src = audioEntry.audio {
                    if aLanes[lane] == nil, let at = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                        let p = AVMutableAudioMixInputParameters(track: at)
                        p.trackID = at.trackID
                        p.audioTimePitchAlgorithm = .spectral
                        p.setVolume(0, at: .zero)
                        aLanes[lane] = (at, p)
                    }
                    if let (at, p) = aLanes[lane] {
                        try insert(clip: mapped, segments: segments, from: src, sourceRange: audioEntry.audioRange, into: at)
                        applyVolume(clip, to: p)
                        if !clip.audio.preservePitch && !clip.speed.isNormal { p.audioTimePitchAlgorithm = .varispeed }
                    }
                }
            }
            for v in vLanes.compactMap({ $0 }) { videoTrackIDs.append(v.trackID) }
            videoTrackIDs += auxOrder
            for a in aLanes.compactMap({ $0 }) { audioParams.append(a.1) }
        }

        let state = existingState ?? RenderState(project: project, keepsRecentSources: purpose == .preview)
        state.update(project: project)
        state.update(trackMap: trackMap)
        state.update(auxMap: auxMap)

        let vc = AVMutableVideoComposition()
        let space = project.settings.colorSpace
        vc.customVideoCompositorClass = space.isHDR ? MontageHDRCompositor.self : MontageCompositor.self
        vc.frameDuration = CMTime(value: CMTimeValue(fr.denominator), timescale: fr.numerator)
        vc.renderSize = renderSize ?? CGSize(width: project.settings.canvasSize.width, height: project.settings.canvasSize.height)
        let tags = ColorTags(space)
        vc.colorPrimaries = tags.primaries
        vc.colorTransferFunction = tags.transfer
        vc.colorYCbCrMatrix = tags.matrix
        vc.instructions = [MontageInstruction(timeRange: CMTimeRange(start: .zero, duration: duration.cmTime),
                                              trackIDs: videoTrackIDs, state: state)]
        var mix: AVMutableAudioMix?
        if !audioParams.isEmpty { mix = AVMutableAudioMix(); mix!.inputParameters = audioParams }
        return BuiltComposition(composition: comp, videoComposition: vc, audioMix: mix, trackMap: trackMap,
                                duration: duration, state: state)
    }

    /// Aux lanes a clip needs: (role, file, source shift).
    static func auxInputs(_ clip: Clip, asset: MediaAsset, videoURL: URL, reversed: Bool, purpose: RenderPurpose)
    async throws -> [(AuxRole, URL, Time)] {
        var out: [(AuxRole, URL, Time)] = []
        let sfd = (asset.frameRate ?? .fps30).frameDuration
        if clip.smoothSlowMo != nil, Self.hasSlowSection(clip.speed) { out.append((.nextFrame, videoURL, sfd)) }
        if let mb = clip.motionBlur, mb.amount > 0 {
            for k in 1..<mb.clampedSamples { out.append((.previousFrame(k), videoURL, Time(ticks: -sfd.ticks * Int64(k)))) }
        }
        if let m = clip.matte, let matte = MatteStore.shared.readyMatteVideo(media: asset, kind: m.kind) {
            if reversed {
                let key = MatteStore.shared.reverseKey(media: asset, kind: m.kind)
                let r = purpose == .export ? try await ReverseManager.shared.ensure(source: matte, key: key)
                                           : ReverseManager.shared.readyURL(key: key)
                if let r { out.append((.matte, r, .zero)) } else { _ = await ReverseManager.shared.request(source: matte, key: key) }
            } else {
                out.append((.matte, matte, .zero))
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

    /// Clip gain, fades and volume keyframes as linear ramps on the lane.
    static func applyVolume(_ clip: Clip, to p: AVMutableAudioMixInputParameters) {
        let start = clip.start, end = clip.end
        func v(_ local: Time) -> Float {
            var g = clip.value(.volume, at: local)?.scalar ?? clip.audio.volume
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
        for k in clip.keyframes[ParamKey.volume.raw]?.keyframes ?? [] where k.time > .zero && k.time < clip.duration {
            points.insert(k.time.ticks)
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
    public static func structureKey(_ project: Project, sources: (MediaAsset) -> MediaSourceChoice) -> Int {
        var h = Hasher()
        h.combine(project.settings.canvasSize)
        h.combine(project.settings.frameRate)
        h.combine(project.settings.colorSpace)
        for t in project.timeline.tracks {
            h.combine(t.id); h.combine(t.kind); h.combine(t.isMain); h.combine(t.isMuted)
            for c in t.clips {
                guard let id = c.mediaID, let a = project.asset(id) else { continue }
                h.combine(c.id); h.combine(id); h.combine(c.start); h.combine(c.duration); h.combine(c.sourceStart)
                h.combine(c.speed); h.combine(c.reversed); h.combine(c.isEnabled); h.combine(c.audio)
                h.combine(c.keyframes[ParamKey.volume.raw])
                h.combine(sources(a))
                h.combine(c.smoothSlowMo); h.combine(c.motionBlur?.clampedSamples); h.combine(c.matte?.kind)
                if c.reversed { h.combine(ReverseManager.shared.readyURL(for: a) != nil) }
                if let m = c.matte { h.combine(MatteStore.shared.readyMatteVideo(media: a, kind: m.kind) != nil) }
            }
        }
        return h.finalize()
    }
}
