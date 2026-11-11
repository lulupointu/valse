@preconcurrency import AVFoundation
import Foundation
import ValseCore

/// Result of translating a project into AVFoundation objects. Immutable after build.
public struct BuiltComposition: @unchecked Sendable {
    public let composition: AVComposition
    public let videoComposition: AVVideoComposition
    public let audioMix: AVAudioMix?
    public let trackMap: [ClipID: CMPersistentTrackID]
    public let duration: Time
    public let state: RenderState
    /// Live audio parameters read by the lane taps (W8, `ValseEngine/Audio`).
    public let audioState: AudioMixState
    /// Timeline ranges left out of this composition (quick cut preview); `duration` is the composition's.
    public var skip: SkipTimeMap = .identity
    /// The composition audio lanes with what their taps get (clips, gain ramps): `PreviewAudio` runs the same
    /// `LaneProcessor`s on the reader's buffers instead of taps (BUG-CUT-AUDIO-HOLE). Same order as the audio mix inputs.
    public var audioLanes: [AudioLane] = []
    /// Preview builds without taps (`PlaybackEngine`): `composition` without its audio tracks, for the AVPlayer that
    /// renders the video only (the audio is `PreviewAudio`'s). nil = play `composition`.
    public var playerAsset: AVComposition?
}

/// One composition audio track and the clips packed onto it (`CompositionBuilder.packAudio`), with its gain ramps.
public struct AudioLane: @unchecked Sendable {
    public let track: AVAssetTrack
    let clips: [Clip]
    let gains: [GainRamp]
    let skip: SkipTimeMap
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
        /// Encoded format of each audio stream (`CompositionBuilder.audioFormatKey`), parallel to `audios`.
        var audioFormats: [String] = []
        func audioFormat(_ index: Int?) -> String {
            if let index, audioFormats.indices.contains(index) { return audioFormats[index] }
            return audioFormats.first ?? ""
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
        for t in try await asset.loadTracks(withMediaType: .audio) {
            e.audios.append((t, try await t.load(.timeRange)))
            e.audioFormats.append(CompositionBuilder.audioFormatKey(try await t.load(.formatDescriptions)))
        }
        entries[url] = e
        return e
    }

    /// Drops `url` and its decode aliases (`CompositionBuilder.decodeAlias`, same file under another spelling).
    public func evict(_ url: URL) {
        let file = url.standardizedFileURL
        entries = entries.filter { $0.key.standardizedFileURL != file }
    }
}

/// Project → AVMutableComposition + AVVideoComposition (ValseCompositor) + AVAudioMix.
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
    static let buildLock = AsyncSemaphore(limit: 1)    /// Builds finished in this process (any outcome). A build waiting for `buildLock` behind others sees this move:
    /// tests use it to tell "queued behind other work" (keep waiting) from "stuck" (PlaybackProbe.waitReady).
    public static var finishedBuilds: Int { finishedLock.withLock { finished } }
    private nonisolated(unsafe) static var finished = 0
    private static let finishedLock = NSLock()

    /// `conformsAudio`: the audio will be read by an AVAssetReader at 48 kHz (export, mixdown): audio streams at another
    /// rate are inserted from their 48 kHz copy (`AudioConform`, BUG-SPLIT-AUDIO-FLAKE).
    public static func build(project: Project, purpose: RenderPurpose, renderSize: CGSize? = nil,
                             frameRate: FrameRate? = nil, state existingState: RenderState? = nil,
                             audioState existingAudioState: AudioMixState? = nil,
                             highPrecision: Bool = false, mixesAudioFormats: Bool = false, audioTaps: Bool = true,
                             skipping skipRanges: [TimeRange] = [], conformsAudio: Bool = false,
                             separatesTrackAudio: Bool = false,
                             sources: @Sendable (MediaAsset) -> MediaSourceChoice = { let u = PlayableMediaCache.shared.resolvedURL(for: $0); return MediaSourceChoice(video: u, audio: u) })
    async throws -> BuiltComposition {
        await buildLock.wait()
        defer { finishedLock.withLock { finished += 1 }; Task { await buildLock.signal() } }
        try Task.checkCancellation()
        let comp = AVMutableComposition()
        // Quick cut preview: the composition leaves `skipRanges` out; every insert / ramp / tap entry is placed in item time.
        let skip = SkipTimeMap(skipRanges, duration: project.duration)
        let duration = max(skip.item(project.duration), project.settings.frameRate.frameDuration)
        var trackMap: [ClipID: CMPersistentTrackID] = [:]
        var videoTrackIDs: [CMPersistentTrackID] = []
        var decodeRuns: [CMPersistentTrackID: DecodeRun] = [:]   // last video segment per composition track (BUG-FRAME-DROP)
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
        // Audio of every decode track (compounds' virtual tracks included), packed onto shared composition audio tracks
        // after the track loop (`packAudio`, BUG-PLAY-SILENT).
        var pendingAudio: [PendingAudio] = []
        for (group, track) in CompoundFlattening.decodeTracks(project).enumerated() {
            let mediaClips = track.clips.filter { $0.isEnabled && $0.mediaID.flatMap(project.asset) != nil }
            guard !mediaClips.isEmpty else { continue }
            // A/B lanes where neighbours overlap: the main track and overlay tracks with transitions (PiP, TR-004)
            let lanes = track.isMain || track.clips.contains(where: { $0.transitionOut != nil }) ? 2 : 1
            var vLanes: [AVMutableCompositionTrack?] = Array(repeating: nil, count: lanes)
            var auxLanes: [String: AVMutableCompositionTrack] = [:]
            var auxOrder: [CMPersistentTrackID] = []
            let clipIndex = Dictionary(track.clips.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
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
                // Segments in item time (absolute): `placed` is the clip with start 0 that `insert` lays them out from.
                let segments = place(remapSegments(mapped, asset: asset, frameRate: fr), clipStart: clip.start, skip: skip)
                mapped.start = .zero

                let sourceFrame = (asset.frameRate ?? .fps30).frameDuration
                if asset.kind == .video, asset.hasVideo, track.kind.isVisual {
                    let entry = try await AssetCache.shared.entry(videoURL)
                    if let src = entry.video {
                        if vLanes[lane] == nil { vLanes[lane] = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) }
                        if let vt = vLanes[lane] {
                            // TR-MODEL-CAPCUT: overlap transitions decode the clip's handles past its cuts
                            var videoSegments = segments
                            if let ci = clipIndex[clip.id] {
                                let ext = track.transitionExtension(of: ci)
                                if ext.head > .zero || ext.tail > .zero {
                                    var edges = mapped
                                    edges.start = .zero
                                    let hs = handleSegments(edges, head: ext.head, tail: ext.tail,
                                                            media: (Time(cmTime: entry.videoRange.start), Time(cmTime: entry.videoRange.end)),
                                                            sourceFrame: sourceFrame)
                                    videoSegments = place(hs.head, clipStart: clip.start, skip: skip) + segments
                                        + place(hs.tail, clipStart: clip.start, skip: skip)
                                }
                            }
                            let (variants, run) = decodeVariants(clip: mapped, segments: videoSegments, url: videoURL, after: decodeRuns[vt.trackID],
                                                                 tolerance: sourceFrame * 0.5)
                            let alias = variants.contains(1) ? try await AssetCache.shared.entry(decodeAlias(videoURL)).video : nil
                            try insert(clip: mapped, segments: videoSegments, from: src, alias: alias, variants: variants,
                                       sourceRange: entry.videoRange, into: vt)
                            decodeRuns[vt.trackID] = run
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
                        let (variants, run) = decodeVariants(clip: shifted, segments: segments, url: url, after: decodeRuns[at.trackID],
                                                             tolerance: sourceFrame * 0.5)
                        let alias = variants.contains(1) ? try await AssetCache.shared.entry(decodeAlias(url)).video : nil
                        try insert(clip: shifted, segments: segments, from: src, alias: alias, variants: variants,
                                   sourceRange: entry.videoRange, into: at, stretch: false)
                        decodeRuns[at.trackID] = run
                        auxMap[clip.id, default: [:]][role] = at.trackID
                    }
                }
                let audible = asset.hasAudio && clip.audio.isAudible && !track.isMuted
                    && (clip.audio.volume > 0 || clip.keyframes[ParamKey.volume.raw] != nil)
                let streamIndex = clip.reversed && reversedURL != nil ? 0 : clip.audioStreamIndex
                // (a conformed copy holds the one stream: `audioStream(streamIndex)` falls back to it)
                let processedURL = audible ? try await AudioPipeline.audioSource(clip: clip, asset: asset, original: audioURL, purpose: purpose,
                                                                               conforms: conformsAudio, streamIndex: streamIndex) : nil
                var audioEntry: AssetCache.Entry?
                if let processedURL { audioEntry = try await AssetCache.shared.entry(processedURL) }
                if let audioEntry, let (src, srcAudioRange) = audioEntry.audioStream(streamIndex),
                   let first = segments.first, let last = segments.last {
                    pendingAudio.append(PendingAudio(clip: clip, mapped: mapped, segments: segments, source: src,
                                                     sourceRange: srcAudioRange,
                                                     format: mixesAudioFormats ? "" : audioEntry.audioFormat(streamIndex)
                                                         + stretchKey(segments, clip: clip.id),
                                                     group: group, start: first.output.start, end: last.output.end))
                }
            }
            for v in vLanes.compactMap({ $0 }) { videoTrackIDs.append(v.trackID) }
            videoTrackIDs += auxOrder
        }
        var audioLanes: [AudioLane] = []
        for (laneIndex, lane) in try packAudio(pendingAudio, into: comp, sharesAcrossTracks: !separatesTrackAudio).enumerated() {
            let a = lane.params
            var volumes: [(ramps: [GainRamp], end: Time)] = []
            var floor = Time.zero
            for p in lane.placements {
                let (ramps, last) = volumeRamps(p.clip, gain: ClipAudioPlan.make(p.clip).staticGain,
                                                duck: Ducking.envelope(for: p.clip, in: project, waveforms: waveforms), skip: skip,
                                                after: floor,
                                                softIn: !pendingAudio.contains { seamless($0.clip, p.clip) },
                                                softOut: !pendingAudio.contains { seamless(p.clip, $0.clip) })
                floor = last
                volumes.append((ramps, last))
            }
            audioLanes.append(AudioLane(track: lane.track, clips: lane.placements.map(\.clip), gains: volumes.flatMap { $0.ramps }, skip: skip))
            // The clip volumes are applied by the lane tap, not by audio-mix ramps (PB-DROP, see `LaneProcessor.gains`);
            // preview and export run the same gains. The mix keeps one ramp per clip, at a constant 1: AVPlayer sends
            // ramp values to its mixer at every edit and drops some of them on a resampling output — harmless when
            // every value is 1. Measured on a 44.1 kHz output (PlaybackDeviceReproTests), other mixes left a lane's
            // mixer input muted for whole plays: no volume at all (8 plays in 12), one step or one ramp over the item
            // (1 in ~20); one 1→1 ramp per clip, the shape the old per-clip ramps had, never did. Without a tap
            // (frozen-clock recovery, tap creation failed) the mix carries the real ramps, as before.
            if audioTaps {
                a.audioTapProcessor = AudioTap.make(LaneProcessor(clips: lane.placements.map(\.clip), state: audioState, skip: skip,
                                                                  gains: volumes.flatMap { $0.ramps }, lane: laneIndex))
            }
            if a.audioTapProcessor == nil {
                a.setVolume(0, at: .zero)
                for v in volumes { apply(v.ramps, end: v.end, to: a) }
            } else {
                for v in volumes {
                    guard let first = v.ramps.first, let last = v.ramps.last else { continue }
                    a.setVolumeRamp(fromStartVolume: 1, toEndVolume: 1,
                                    timeRange: CMTimeRange(start: first.start.cmTime, duration: (last.end - first.start).cmTime))
                }
            }
            audioParams.append(a)
        }

        // Preview render cache: valid pre-rendered segments as passthrough lanes (see RenderCache).
        var cached: [(range: TimeRange, key: String, track: CMPersistentTrackID)] = []
        let size = renderSize ?? CGSize(width: project.settings.canvasSize.width, height: project.settings.canvasSize.height)
        if purpose == .preview, skip.isIdentity {   // cached segments are laid out in timeline time
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
        vc.customVideoCompositorClass = (space.isHDR || highPrecision) ? ValseHDRCompositor.self : ValseCompositor.self
        vc.frameDuration = CMTime(value: CMTimeValue(fr.denominator), timescale: fr.numerator)
        vc.renderSize = renderSize ?? CGSize(width: project.settings.canvasSize.width, height: project.settings.canvasSize.height)
        // No colour properties on the video composition (C1): when they differ from a source's, AVPlayer (preview)
        // CONVERTS the source frames to them before the compositor sees them (VideoToolbox HDR → SDR / HLG → PQ, despite
        // `supportsHDRSourceFrames`), while AVAssetReader / AVAssetImageGenerator (export, thumbnails) only re-matrix
        // the YCbCr — and both stamp the composition's tags, so the frames cannot be told apart. The renderer converts
        // from the asset's own tags, so the HLG footage was converted twice in the preview (SDR: red, crushed skin;
        // PQ: washed out). Untagged, every path delivers the decoded frames untouched; the compositor stamps its output
        // with the project's tags (`ValseCompositor.stamp`).
        vc.instructions = [ValseInstruction(timeRange: CMTimeRange(start: .zero, duration: duration.cmTime),
                                              trackIDs: videoTrackIDs, state: state, skip: skip)]
        var mix: AVMutableAudioMix?
        if !audioParams.isEmpty { mix = AVMutableAudioMix(); mix!.inputParameters = audioParams }
        var built = BuiltComposition(composition: comp, videoComposition: vc, audioMix: mix, trackMap: trackMap,
                                     duration: duration, state: state, audioState: audioState)
        built.skip = skip
        built.audioLanes = audioLanes
        if purpose == .preview, !audioTaps {
            // BUG-CUT-AUDIO-HOLE phase B: the player only renders video; `PreviewAudio` reads the audio lanes of
            // `composition` itself. Same track IDs (the video composition's instructions name them).
            let video = comp.mutableCopy() as! AVMutableComposition
            for t in video.tracks(withMediaType: .audio) { video.removeTrack(t) }
            built.playerAsset = video
        }
        return built
    }

    /// Clip-relative speed segments → absolute item-time segments with the skipped timeline ranges cut out (each
    /// segment is linear, so a kept piece takes the matching slice of its source range).
    static func place(_ segments: [(output: TimeRange, source: TimeRange)], clipStart: Time, skip: SkipTimeMap)
    -> [(output: TimeRange, source: TimeRange)] {
        var out: [(output: TimeRange, source: TimeRange)] = []
        for s in segments {
            let abs = s.output.offset(by: clipStart)
            guard !skip.isIdentity else { out.append((abs, s.source)); continue }
            let rate = s.output.duration.ticks > 0 ? s.source.duration / s.output.duration : 1
            for k in skip.kept(abs) where k.duration.ticks > Time.ticksPerSecond / 2000 {   // < 0.5 ms: nothing to play
                let src = TimeRange(start: s.source.start + (k.start - abs.start) * rate, duration: k.duration * rate)
                out.append((TimeRange(start: skip.item(k.start), duration: k.duration), src))
            }
        }
        return out
    }

    /// One clip's audio waiting for a composition audio track: segments in item time (`place`), its source stream and
    /// encoded format, the decode track it comes from (`group`) and the item range it covers.
    struct PendingAudio {
        let clip: Clip
        let mapped: Clip
        let segments: [(output: TimeRange, source: TimeRange)]
        let source: AVAssetTrack
        let sourceRange: CMTimeRange
        let format: String
        let group: Int
        let start: Time
        let end: Time
    }

    /// A composition audio track and the clips packed onto it, in time order.
    struct PackedAudioLane {
        let track: AVMutableCompositionTrack
        let params: AVMutableAudioMixInputParameters
        var placements: [PendingAudio]
    }

    /// Item range, format and decode track of a clip's audio (`audioLanePlan`'s input).
    struct AudioSpan: Equatable { let start: Time; let end: Time; let format: String; let group: Int }

    /// BUG-PLAY-SILENT: which composition audio track each clip's audio goes on (lane index per span, in `spans` order).
    /// AVPlayer starts one AudioQueue per composition audio track at every play, one after the other (~10 ms each),
    /// all synchronized to one host start time ~100 ms ahead. With many tracks the last queues start after that time
    /// ("AppendRateChange: scheduling rate change at unscaled t=0, but we previously did a conversion for t=…") and stay
    /// silent for the whole play, a different random set each time: owner project "Episode 5", 13 audio tracks (one or
    /// more per compound clip, each compound's nested tracks being decode tracks of their own) = silent output in 5–7
    /// plays of 25 while the lanes carried sound, back after pause / play, a seek, or the next clip on another track
    /// (PlaybackSilenceTests). So the audio of every decode track shares composition tracks: a clip goes on a track
    /// of its format that is free from its start — first the one its own decode track used last (butted clips, a
    /// split, stay on one track: BUG-CUT-AUDIO-ARTEFACT, contiguous source decodes and resamples as one stream), else
    /// the free one that ended latest — and a new track only when every one is busy (overlapping clips: overlays,
    /// audio tracks, music under the main track). The track count is the most audio clips (per format) at any instant.
    /// PB-QC: one format per composition track. A lane holding segments of different formats (a clip's rendered audio
    /// stage, ALAC/LPCM CAF, next to the iPhone AAC of the neighbouring clips) made AVPlayer rebuild that lane's audio
    /// chain on a seek across the formats; with an MTAudioProcessingTap on the lane the chain was left unprepared for
    /// good, the mixer waited for it forever and the audio-driven clock stopped. One format per track never reconfigures.
    /// `sharesAcrossTracks` false (tests only): the layout before BUG-PLAY-SILENT, composition tracks per decode track.
    static func audioLanePlan(_ spans: [AudioSpan], sharesAcrossTracks: Bool = true) -> [Int] {
        var lanes: [(format: String, group: Int, end: Time)] = []
        var lastOfGroup: [Int: Int] = [:]
        var out = Array(repeating: 0, count: spans.count)
        let order = spans.indices.sorted { a, b in
            spans[a].start != spans[b].start ? spans[a].start < spans[b].start : (spans[a].group, a) < (spans[b].group, b)
        }
        for i in order {
            let s = spans[i]
            func free(_ l: Int) -> Bool {
                lanes[l].format == s.format && lanes[l].end <= s.start && (sharesAcrossTracks || lanes[l].group == s.group)
            }
            var lane: Int
            if let g = lastOfGroup[s.group], free(g) {
                lane = g
            } else if let l = lanes.indices.filter(free).max(by: { lanes[$0].end < lanes[$1].end }) {
                lane = l
            } else {
                lanes.append((s.format, s.group, .zero))
                lane = lanes.count - 1
            }
            lanes[lane].end = max(lanes[lane].end, s.end)
            lastOfGroup[s.group] = lane
            out[i] = lane
        }
        return out
    }

    /// Time-pitch algorithm of the composition audio lanes. Test hook only (TapProbeTests, BUG-CUT-AUDIO-HOLE: the lane's
    /// stretcher decides how AVPlayer stamps the lane taps); ships `.spectral`.
    nonisolated(unsafe) static var laneTimePitch: AVAudioTimePitchAlgorithm = .spectral

    /// Inserts every clip's audio on shared composition audio tracks (`audioLanePlan`), in time order on each track
    /// (`insert` appends: a segment placed before a track's end would shift what follows).
    static func packAudio(_ pending: [PendingAudio], into comp: AVMutableComposition, sharesAcrossTracks: Bool = true) throws -> [PackedAudioLane] {
        let plan = audioLanePlan(pending.map { AudioSpan(start: $0.start, end: $0.end, format: $0.format, group: $0.group) },
                                 sharesAcrossTracks: sharesAcrossTracks)
        var byLane: [Int: [PendingAudio]] = [:]
        for (p, l) in zip(pending, plan) { byLane[l, default: []].append(p) }
        var out: [PackedAudioLane] = []
        for l in byLane.keys.sorted() {
            guard let at = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let params = AVMutableAudioMixInputParameters(track: at)
            params.trackID = at.trackID
            params.audioTimePitchAlgorithm = laneTimePitch
            let placements = (byLane[l] ?? []).sorted { $0.start < $1.start }
            for (i, p) in placements.enumerated() {
                // stretched clips: a tail pad where nothing follows closely (BUG-CUT-AUDIO-SWEEP, see `stretchKey`)
                var pad = Time.zero, head = Time.zero
                if p.segments.contains(where: { abs($0.source.duration / max($0.output.duration, Time(ticks: 1)) - 1) > 1e-3 }) {
                    // and a head pre-roll where the lane is empty before it (FLAKY-PB: a stretched clip starting after
                    // silence came in at 30-60 % of its level for its first ~20 ms, the stretcher's start-up — measured
                    // by CutPitchSweepTests' level check, "1x | 1.5x", "1x | 0.5x"): the start-up then happens in the
                    // pre-roll, silenced by the lane gains
                    let free = p.start - (at.timeRange.duration > .zero ? Time(cmTime: at.timeRange.end) : .zero)
                    head = free >= Time(0.1) ? Time(0.1) : .zero
                    // (a short empty edit before the next clip makes the stretcher restart: its priming then eats the next
                    // clip's first ~85 ms, so a pad only where the next clip is further than 0.2 s away)
                    if i + 1 < placements.count {
                        pad = placements[i + 1].start - p.end >= Time(0.2) ? Time(0.1) : .zero
                    } else {
                        // the lane's last clip always gets one (FLAKY-PB, CutPitchSweepTests: it never did — `room` was a
                        // fixed 0.1 s here — and the stretcher then either dropped the clip's last 50-120 ms (silence
                        // before a cut to another lane, or before the project's end) or delivered them fading out, which
                        // of the two varying run to run). A pad past the composition's end is read by nobody: export /
                        // mixdown / PreviewAudio read [0, duration), the player's asset has no audio tracks.
                        pad = Time(0.1)
                    }
                }
                try insert(clip: p.mapped, segments: p.segments, from: p.source, sourceRange: p.sourceRange, into: at,
                           headPad: head, tailPad: pad)
            }
            out.append(PackedAudioLane(track: at, params: params, placements: placements))
        }
        return out
    }

    /// BUG-CUT-AUDIO-SWEEP ("laser saber", owner): a composition audio track runs one time-pitch stretcher; where its
    /// stretch ratio changes between butted segments (2× clip then a 1× clip) the stretcher ramps from the old ratio to
    /// the new one, and the tone sweeps in pitch for ~10 ms after the cut (measured: half periods 10-20 % short, then
    /// settling; with 1.5× → 1× the following 100 ms is dropped), in the preview and in the export. So lanes are shared
    /// only between clips of the same constant stretch ratio (suffix of the lane "format"); a clip with several
    /// ratios (speed curve) keeps a lane of its own. Unscaled clips keep the plain format key (lane count unchanged).
    static func stretchKey(_ segments: [(output: TimeRange, source: TimeRange)], clip: ClipID) -> String {
        let ratios = segments.compactMap { s -> Double? in
            s.output.duration.ticks > 0 ? Double(s.source.duration.ticks) / Double(s.output.duration.ticks) : nil
        }
        guard let first = ratios.first else { return "" }
        if ratios.contains(where: { abs($0 / first - 1) > 1e-3 }) { return "-curve\(clip)" }
        return abs(first - 1) < 1e-3 ? "" : String(format: "-x%.3f", first)
    }

    /// Format identity of an audio stream: codec, sample rate, channels, channel layout.
    static func audioFormatKey(_ descriptions: [CMFormatDescription]) -> String {
        guard let d = descriptions.first else { return "" }
        let sub = CMFormatDescriptionGetMediaSubType(d)
        var key = String(sub, radix: 16)
        if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(d)?.pointee {
            key += "-\(Int(asbd.mSampleRate))-\(asbd.mChannelsPerFrame)-\(asbd.mBitsPerChannel)-\(asbd.mFormatFlags)"
        }
        var size = 0
        if let layout = CMAudioFormatDescriptionGetChannelLayout(d, sizeOut: &size), size > 0 {
            key += "-L\(layout.pointee.mChannelLayoutTag)-\(layout.pointee.mChannelBitmap.rawValue)-\(layout.pointee.mNumberChannelDescriptions)"
        }
        return key
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
    /// Video segments (clip-relative, like `remapSegments`) decoded beyond a clip's own range for the overlap
    /// transitions at its cuts (TR-MODEL-CAPCUT): `head` before its start, `tail` after its end. Each side plays its
    /// handle at the edge speed while the media lasts, then holds the media's edge frame for the rest ("duplicate
    /// frames": one source frame scaled over the remaining time, CapCut's freeze). `media` = the file's video range.
    static func handleSegments(_ clip: Clip, head: Time, tail: Time, media: (lo: Time, hi: Time), sourceFrame: Time)
    -> (head: [(output: TimeRange, source: TimeRange)], tail: [(output: TimeRange, source: TimeRange)]) {
        var h: [(output: TimeRange, source: TimeRange)] = [], t: [(output: TimeRange, source: TimeRange)] = []
        let minPiece = Time(ticks: Time.ticksPerSecond / 2000)
        if head > minPiece {
            let r = clip.edgeRate(head: true)
            let avail = max(.zero, clip.sourceStart - media.lo) / r
            let real = min(head, avail), freeze = head - real
            if freeze > minPiece {
                h.append((TimeRange(start: .zero - head, duration: freeze),
                          TimeRange(start: media.lo - clip.sourceStart, duration: sourceFrame)))
            }
            if real > minPiece {
                h.append((TimeRange(start: .zero - real, duration: real), TimeRange(start: .zero - real * r, duration: real * r)))
            }
        }
        if tail > minPiece {
            let r = clip.edgeRate(head: false)
            let srcEnd = clip.sourceStart + clip.sourceDuration
            let avail = max(.zero, media.hi - srcEnd) / r
            let real = min(tail, avail), freeze = tail - real
            if real > minPiece {
                t.append((TimeRange(start: clip.duration, duration: real), TimeRange(start: clip.sourceDuration, duration: real * r)))
            }
            if freeze > minPiece {
                t.append((TimeRange(start: clip.duration + real, duration: freeze),
                          TimeRange(start: max(media.lo, media.hi - sourceFrame) - clip.sourceStart, duration: sourceFrame)))
            }
        }
        return (h, t)
    }

    static func remapSegments(_ clip: Clip, asset: MediaAsset, frameRate: FrameRate) -> [(output: TimeRange, source: TimeRange)] {
        let fd = frameRate.frameDuration
        let phase = Time(ticks: (fd.ticks - clip.start.ticks % fd.ticks) % fd.ticks)
        let srcFrame = (asset.frameRate ?? .fps30).frameDuration
        return clip.speed.frameAccurateSegments(outputDuration: clip.duration, frameDuration: fd, firstFrame: phase,
                                                tolerance: srcFrame * 0.5, sourceFrame: (clip.sourceStart, srcFrame))
    }

    static func gcd(_ a: Int64, _ b: Int64) -> Int64 { b == 0 ? max(1, abs(a)) : gcd(b, a % b) }

    /// Inserts a clip's speed segments into a composition track at the clip's timeline position.
    /// `stretch`: when the media is shorter than the segment asks for, stretch what exists over the whole output
    /// range (main lanes: no black frame) or keep the exact rate and leave the rest empty (aux lanes: timing matters).
    /// `alias` / `variants`: the same file opened under its decode alias, and which of the two each segment reads
    /// (0 = `src`, 1 = `alias`; see `decodeVariants`). Without them every segment reads `src`.
    static func insert(clip: Clip, segments: [(output: TimeRange, source: TimeRange)], from src: AVAssetTrack,
                       alias: AVAssetTrack? = nil, variants: [Int] = [],
                       sourceRange srcRange: CMTimeRange, into dst: AVMutableCompositionTrack, stretch: Bool = true,
                       headPad: Time = .zero, tailPad: Time = .zero) throws {
        for (k, seg) in segments.enumerated() {
            let src = k < variants.count && variants[k] == 1 ? alias ?? src : src
            var at = (clip.start + seg.output.start).cmTime
            var wanted = CMTimeRange(start: (clip.sourceStart + seg.source.start).cmTime, duration: seg.source.duration.cmTime)
            var outDur = seg.output.duration.cmTime
            if (headPad > .zero && k == 0) || (tailPad > .zero && k == segments.count - 1), seg.output.duration.ticks > 0 {
                // Pads (silenced by the lane gains): source audio before the clip's start so the stretcher is primed
                // when the clip starts, and after its end so it does not drop the clip's tail. The padded segment keeps
                // EXACTLY the clip's stretch ratio (whole multiples of out / gcd ticks): a ratio off by rounding made the
                // stretcher restart at the segment's start and drop its first ~85 ms (SplitSpeedAudioTests, FLAKY-PB).
                let o = seg.output.duration.ticks, sTicks = seg.source.duration.ticks
                let g = Self.gcd(o, sTicks), unitOut = o / g, unitSrc = sTicks / g
                /// Whole units of at most `pad` (output) whose source the file has.
                func units(_ pad: Time, available: Int64) -> Int64 {
                    guard pad > .zero else { return 0 }
                    return min(pad.ticks / unitOut, max(0, available) / unitSrc)
                }
                let before = k == 0 ? units(headPad, available: Time(cmTime: CMTimeSubtract(wanted.start, srcRange.start)).ticks) : 0
                let after = k == segments.count - 1 ? units(tailPad, available: Time(cmTime: CMTimeSubtract(srcRange.end, wanted.end)).ticks) : 0
                if before > 0 {
                    wanted = CMTimeRange(start: CMTimeSubtract(wanted.start, Time(ticks: before * unitSrc).cmTime),
                                         duration: CMTimeAdd(wanted.duration, Time(ticks: before * unitSrc).cmTime))
                    at = CMTimeSubtract(at, Time(ticks: before * unitOut).cmTime)
                }
                if after > 0 { wanted.duration = CMTimeAdd(wanted.duration, Time(ticks: after * unitSrc).cmTime) }
                outDur = Time(ticks: o + (before + after) * unitOut).cmTime
            }
            let s = CMTimeRangeGetIntersection(wanted, otherRange: srcRange)
            guard s.duration > .zero else { continue }
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

    /// BUG-FRAME-DROP: AVFoundation decodes each composition track's segments from one file as one stream: when a
    /// track's next segment of the same file starts a little further on (jump cut, or the A/B lane's next clip after a
    /// split), it does not restart at the sync sample but keeps decoding from where the previous segment stopped. With
    /// iPhone HEVC (open GOPs: the B frames shown just before each CRA key frame are decoded after it, and reference the
    /// previous GOP) the frames right after such a segment start were then never delivered: the compositor got the
    /// first frame again for up to 3 frames (100 ms freeze, then a jump), in the preview and in exports — measured on
    /// the owner's project "1018 (1)": a split at 3.604 s of IMG_9081 (frame 108, CRA at 112). Only when the previous
    /// segment's decode had started in the GOP before (crossing the CRA); a decode started fresh was always right.
    /// A segment that does not continue its track's previous segment (same file, source contiguous) therefore reads
    /// the file under another spelling (`decodeAlias`): a different source URL makes AVFoundation start a fresh decode
    /// at the sync sample. Contiguous segments (one clip's speed pieces, a split kept on one track) keep the stream.
    struct DecodeRun: Equatable { var url: URL; var variant: Int; var end: Time }

    /// Same file, other URL: `dir/./name` (AVFoundation keys a track's decode by the segment URL, not the file;
    /// AVURLAsset keeps the spelling, `standardizedFileURL` maps it back).
    static func decodeAlias(_ url: URL) -> URL {
        URL(fileURLWithPath: url.deletingLastPathComponent().path + "/./" + url.lastPathComponent)
    }

    /// Which file spelling each of a clip's segments reads on a track whose last video segment was `run`, and the run
    /// after them. A segment continues the run (same variant) when it reads the same file from where the run ended
    /// (± `tolerance`); otherwise a segment of the same file switches variant, and another file starts variant 0.
    static func decodeVariants(clip: Clip, segments: [(output: TimeRange, source: TimeRange)], url: URL, after run: DecodeRun?,
                               tolerance: Time) -> (variants: [Int], run: DecodeRun?) {
        var run = run
        var variants: [Int] = []
        for seg in segments {
            let start = clip.sourceStart + seg.source.start
            let v: Int
            if let r = run, r.url == url {
                v = abs((start - r.end).ticks) <= tolerance.ticks ? r.variant : 1 - r.variant
            } else {
                v = 0
            }
            variants.append(v)
            run = DecodeRun(url: url, variant: v, end: start + seg.source.duration)
        }
        return (variants, run)
    }

    /// Linear ramp pieces per eased volume-keyframe span.
    static let volumeCurveSteps = 16

    /// Linear pieces per shaped fade: one per ~15 ms, at least 16, at most 256.
    static func fadeSampleCount(_ length: Time) -> Int { min(256, max(16, Int((length.seconds / 0.015).rounded(.up)))) }

    /// Clip gain, fades and volume keyframes as linear ramps on the lane. `floor` = where the lane's previous clip ended:
    /// ramps never start before it (AVFoundation throws on overlapping ramps, e.g. clips overlapping on a track).
    /// Returns the new floor.
    @discardableResult
    static func applyVolume(_ clip: Clip, to p: AVMutableAudioMixInputParameters, gain: Double = 1, duck: Ducking.Envelope? = nil,
                            skip: SkipTimeMap = .identity, after floor: Time = .zero) -> Time {
        let (ramps, last) = volumeRamps(clip, gain: gain, duck: duck, skip: skip, after: floor)
        apply(ramps, end: last, to: p)
        return last
    }

    /// Ramps on the audio mix, then silence from `end` (the lane's next clip, if any, sets its own ramps after it).
    static func apply(_ ramps: [GainRamp], end: Time, to p: AVMutableAudioMixInputParameters) {
        for r in ramps {
            p.setVolumeRamp(fromStartVolume: r.from, toEndVolume: r.to,
                            timeRange: CMTimeRange(start: r.start.cmTime, duration: (r.end - r.start).cmTime))
        }
        p.setVolume(0, at: end.cmTime)
    }

    /// `applyVolume`'s ramps (item time, sorted, disjoint, all after `floor`) and the new floor.
    /// BUG-CLIP-EDGE-CLICK: length of the automatic anti-click ramp at a clip's start / end. A clip that starts or stops
    /// on a non-zero sample (a cut inside speech, a trim) jumped between 0 and its level in one sample: a click, whatever
    /// fades the user set elsewhere on the clip.
    static let edgeRamp = Time(0.003)

    /// Two clips of one lane that continue each other sample for sample (a split, not a cut): no ramp between them.
    static func seamless(_ a: Clip, _ b: Clip) -> Bool {
        guard a.id != b.id, a.mediaID != nil, a.mediaID == b.mediaID, !a.reversed, !b.reversed,
              case .constant(let sa) = a.speed, case .constant(let sb) = b.speed, sa == sb,
              abs((a.end - b.start).ticks) <= 1, a.audio.volume == b.audio.volume,
              a.audio.fadeOut == .zero, b.audio.fadeIn == .zero, a.keyframes[ParamKey.volume.raw] == nil,
              b.keyframes[ParamKey.volume.raw] == nil else { return false }
        return abs((b.sourceStart - (a.sourceStart + a.duration * sa)).seconds) < 0.0005
    }

    static func volumeRamps(_ clip: Clip, gain: Double = 1, duck: Ducking.Envelope? = nil,
                            skip: SkipTimeMap = .identity, after floor: Time = .zero,
                            softIn: Bool = true, softOut: Bool = true) -> ([GainRamp], Time) {
        let start = clip.start, end = clip.end
        let edge = min(edgeRamp, clip.duration * 0.5)
        func v(_ local: Time) -> Float {
            var g = (clip.value(.volume, at: local)?.scalar ?? clip.audio.volume) * gain
            if edge > .zero {
                if softIn, local < edge { g *= max(0, local / edge) }
                if softOut, local > clip.duration - edge { g *= max(0, (clip.duration - local) / edge) }
            }
            if let duck { g *= Double(duck.gain(at: start + local)) }
            g *= clip.audio.fadeGain(at: local, clipDuration: clip.duration)
            return Float(max(0, g))
        }
        // breakpoints: start, fade ends, keyframes, end
        var points: Set<Int64> = [0, clip.duration.ticks]
        if edge > .zero {
            if softIn { points.insert(edge.ticks) }
            if softOut { points.insert((clip.duration - edge).ticks) }
        }
        let fades = clip.audio.effectiveFades(clipDuration: clip.duration)
        if fades.fadeIn > .zero { points.insert(fades.fadeIn.ticks) }
        if fades.fadeOut > .zero { points.insert((clip.duration - fades.fadeOut).ticks) }
        // shaped fades: sample the curve as short linear ramps (the mix only knows linear ramps)
        func sampleFade(from t0: Time, length: Time, shape: FadeShape) {
            guard length > .zero, shape != .linear else { return }
            let n = fadeSampleCount(length)
            for i in 1..<n { points.insert((t0 + length * (Double(i) / Double(n))).ticks) }
        }
        sampleFade(from: .zero, length: fades.fadeIn, shape: clip.audio.fadeInShape)
        sampleFade(from: clip.duration - fades.fadeOut, length: fades.fadeOut, shape: clip.audio.fadeOutShape)
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
        // skipped ranges (quick cut preview): every span is then wholly kept or wholly skipped; kept spans in item time
        for r in skip.skips where r.end > start && r.start < end {
            if r.start > start { points.insert((r.start - start).ticks) }
            if r.end < end { points.insert((r.end - start).ticks) }
        }
        let sorted = points.sorted().map { Time(ticks: $0) }
        var ramps: [GainRamp] = []
        for i in 0..<(sorted.count - 1) {
            let a = sorted[i], b = sorted[i + 1]
            if !skip.isIdentity, skip.skip(containing: start + a + (b - a) * 0.5) != nil { continue }
            var ia = skip.item(start + a), va = v(a)
            let ib = skip.item(start + b)
            guard ib > ia, ib > floor else { continue }
            if ia < floor {
                va = va + (v(b) - va) * Float((floor - ia) / (ib - ia))
                ia = floor
            }
            ramps.append(GainRamp(start: ia, end: ib, from: va, to: v(b)))
        }
        return (ramps, max(floor, skip.item(end)))
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
            h.combine(au.volume); h.combine(au.fadeIn); h.combine(au.fadeOut); h.combine(au.fadeInShape); h.combine(au.fadeOutShape); h.combine(au.isMuted); h.combine(au.preservePitch)
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
