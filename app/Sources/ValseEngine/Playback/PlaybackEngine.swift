@preconcurrency import AVFoundation
@preconcurrency import Metal
import Foundation
import QuartzCore
import ValseCore

/// Preview resolution (CapCut "Preview quality").
public enum PreviewQuality: String, Codable, Sendable, CaseIterable {
    case auto, full, half, quarter
    public var nameKey: String { "preview.quality.\(rawValue)" }
}

/// Preview playback: video = AVPlayer on the project's AVComposition WITHOUT its audio tracks (`playerAsset`), frames
/// rendered by ValseCompositor; audio = `PreviewAudio` (reader → lane processing → AVSampleBufferAudioRenderer under an
/// AVSampleBufferRenderSynchronizer) on the same composition (BUG-CUT-AUDIO-HOLE phase B: AVPlayer's tap stamps are
/// mislabelled on macOS 26, exact on 13; docs/investigations/BUG-METALLIC-AUDIO.md parts 5-7).
///
/// Clock & A/V sync: the player's `sourceClock` is the output device's audio clock (the synchronizer's clock), and every
/// start (play, resume after a seek, rate change from pause) starts BOTH timebases at one host time from one item time
/// (`launch`), once the audio is primed and the video seek has landed; rate changes while playing are applied to both
/// at once; pause stops both. The two timebases then advance together (measured ≤ 1 ms apart). The player view pulls
/// the frame for each display refresh with `pixelBuffer(forHostTime:)` (AVPlayerItemVideoOutput maps host time → item
/// time), so dropped frames never drift the clock; a drift beyond `maxAVDrift` re-joins the video to the audio.
/// Structural edits while playing swap the audio gaplessly (`PreviewAudio.replace`) and re-join the new player item's
/// video to the running audio clock (`rejoinVideo`); stall recovery re-joins the same way, the audio never stops.
///
/// Edits: `update(project:)` is called on every project change.
/// - structural change (clips moved/trimmed/added, speed, audio) → the AVComposition is rebuilt off-main and the player
///   item swapped at the same time position;
/// - property change (opacity, transform, effects, text…) → no rebuild: the compositor reads the new project; when
///   paused, `onRedrawNeeded` asks the view to re-render the last decoded frame immediately (`renderCurrentFrame`).
@MainActor
public final class PlaybackEngine {
    /// Video only (its item has no audio tracks); its clock follows the audio device clock.
    public let player = AVPlayer()
    public let state: RenderState
    /// Live audio parameters (EQ, voice filter colour…) read by the preview audio lanes without rebuilding.
    public let audioState: AudioMixState
    /// Preview audio and the preview clock.
    public let audio: PreviewAudio
    public private(set) var videoOutput: AVPlayerItemVideoOutput?
    public private(set) var duration: Time = .zero
    public private(set) var project: Project
    public private(set) var renderSize: CGSize = CGSize(width: 1920, height: 1080)

    public var previewQuality: PreviewQuality = .auto { didSet { if oldValue != previewQuality { forceRebuild() } } }
    /// Chooses original vs proxy files for preview. Replace to plug in proxies; call `forceRebuild()` when it changes.
    public var sourceChooser: @Sendable (MediaAsset) -> MediaSourceChoice = PlaybackEngine.proxySources {
        didSet { requestsProxies = false }   // a custom chooser (tests, originals) manages its own sources
    }
    /// Auto proxies: media the proxy policy wants proxied (4K / high frame rate, more on 8 GB) is queued for proxy
    /// generation as soon as it is on the timeline, and the preview switches to each proxy when it is ready — no UI
    /// involvement needed. On while the default proxy chooser is in use.
    public private(set) var requestsProxies = true

    /// Preview uses the proxy when it's ready (default); converted media (GIF, sequences, FFmpeg-only) via PlayableMediaCache.
    public static let proxySources: @Sendable (MediaAsset) -> MediaSourceChoice = { a in
        let playable = PlayableMediaCache.shared.resolvedURL(for: a)
        return MediaSourceChoice(video: ProxyManager.shared.readyProxyURL(for: a) ?? playable, audio: playable)
    }
    /// Preview always decodes the originals (proxy toggle off).
    public static let originalSources: @Sendable (MediaAsset) -> MediaSourceChoice = { a in
        let playable = PlayableMediaCache.shared.resolvedURL(for: a)
        return MediaSourceChoice(video: playable, audio: playable)
    }
    /// Player "Proxy" toggle: switches `sourceChooser` and rebuilds.
    public var usesProxies = true {
        didSet {
            guard oldValue != usesProxies else { return }
            sourceChooser = usesProxies ? Self.proxySources : Self.originalSources
            requestsProxies = usesProxies
            forceRebuild()
        }
    }

    /// Playhead updates (≈30 Hz while playing, and after seeks).
    public var onTimeUpdate: ((Time) -> Void)?
    /// Paused + property edit: re-render the current frame now.
    public var onRedrawNeeded: (() -> Void)?
    /// A new player item is in place (view should reset its frame cache).
    public var onItemReplaced: (() -> Void)?
    public var onPlayStateChange: ((Bool) -> Void)?

    private var structureKey: Int?
    private let structureCache = StructureKeyCache()
    private var buildTask: Task<Void, Never>?
    /// A composition build is queued or running (it ends with an installed item or `lastBuildError`).
    public private(set) var isBuilding = false
    /// Why the last composition build failed (nil after a successful one).
    public private(set) var lastBuildError: Error?
    private var timeObserver: Any?
    private var rateObservation: NSKeyValueObservation?
    private var seekInFlight = false
    private var pendingSeek: (Time, Bool)?
    /// Last requested playhead position (authoritative while seeking / before an item exists).
    public private(set) var requestedTime: Time = .zero

    /// Loop playback (PB-009): when set, playing past `end` jumps back to `start`.
    public var loopRange: TimeRange? { didSet { if oldValue != loopRange { installLoopObserver() } } }
    private var loopObserver: Any?
    /// Quick cut preview (TL-048): sorted, disjoint ranges that playback runs over (the project is unchanged).
    /// PB-QC: they are left out of the preview composition (no seek at each one: seamless, audio included); the
    /// engine maps item time ↔ timeline time with `itemSkip`. `play()` from inside one starts at its end.
    public var skipRanges: [TimeRange] = [] {
        didSet { if oldValue != skipRanges { rebuild(project, debounce: true) } }   // slider drags coalesce
    }
    /// Non-EDR screens (set by the player view): an HDR project is previewed in Rec.709 SDR, every layer converted
    /// straight to SDR like an SDR / still export (SDR sources keep their code values, HDR footage gets the
    /// Apple-matched tone map), instead of tone-mapping the composed HLG / PQ frame — which showed SDR clips, text and
    /// stills at HLG reference white ≈ 60 % grey (BUG-SDR-IN-HDR). EDR screens keep the HDR frames (false).
    public var rendersHDRAsSDR = false { didSet { if oldValue != rendersHDRAsSDR { forceRebuild() } } }
    /// Colour space of the preview frames (`videoOutput`).
    public var previewColorSpace: ProjectColorSpace { rendersHDRAsSDR ? .sdr709 : project.settings.colorSpace }
    /// The project as the preview composes it (`rendersHDRAsSDR` overrides the colour space only).
    private func rendered(_ p: Project) -> Project {
        guard rendersHDRAsSDR, p.settings.colorSpace.isHDR else { return p }
        var q = p
        q.settings.colorSpace = .sdr709
        return q
    }
    /// Skipped ranges of the INSTALLED item (the requested ones once their build is in place).
    public private(set) var itemSkip: SkipTimeMap = .identity
    /// Timeline time of a player-item time.
    private func timeline(_ t: CMTime) -> Time { itemSkip.timeline(Time(cmTime: t)) }
    /// Duration of the installed item (the timeline's, less the skipped ranges).
    private var itemDuration: Time { itemSkip.item(project.duration) }
    private var endObserver: (any NSObjectProtocol)?
    private var proxyObserver: (any NSObjectProtocol)?
    private var textRefineObserver: (any NSObjectProtocol)?
    /// Emulated reverse shuttle (when the item can't play backwards): negative rate, driven by a timer.
    public private(set) var reverseShuttleRate: Float = 0
    private var reverseTimer: Timer?
    /// Frame shown while hovering the timeline (preview axis) without moving the playhead; nil = follow the playhead.
    public private(set) var hoverTime: Time?

    public init(project: Project) {
        self.project = project
        state = RenderState(project: project)
        let mixState = AudioMixState()
        audioState = mixState
        audio = PreviewAudio(audioState: mixState)
        MemoryPressure.shared.start()
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = false   // (also required by setRate(_:time:atHostTime:))
        player.isMuted = true   // no audio tracks in its items; belt and braces
        installDeviceClock(nil)
        audio.volume = 1
        audio.onReanchor = { [weak self] in Task { @MainActor in self?.reanchor() } }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                // a requested seek owns the playhead until it lands (the clock must not overwrite the target)
                guard let self, self.player.rate != 0, !self.seekInFlight else { return }
                self.requestedTime = self.timeline(t)
                self.onTimeUpdate?(self.requestedTime)
            }
        }
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] p, _ in
            let playing = p.rate != 0
            Task { @MainActor in
                guard let self else { return }
                // stopped by itself (end of item): the playhead is where the player stopped, and the audio stops too
                if !playing, self.player.rate == 0, !self.seekInFlight, self.reverseShuttleRate == 0, self.resumeRate == nil {
                    self.requestedTime = self.timeline(self.player.currentTime())
                    self.audio.pause()
                }
                // a seek while playing holds the rate at 0 for a moment: still "playing" for the UI
                self.onPlayStateChange?(self.isPlaying)
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil,
                                                             queue: .main) { [weak self] n in
            let item = UncheckedSendable(n.object as AnyObject?)
            MainActor.assumeIsolated {
                guard let self, item.value === self.player.currentItem, let r = self.loopRange else { return }
                self.seek(to: r.start)
                self.resume(atRate: 1)
            }
        }
        proxyObserver = NotificationCenter.default.addObserver(forName: ProxyManager.proxyReadyNotification, object: nil,
                                                               queue: .main) { [weak self] n in
            let hash = n.userInfo?["hash"] as? String
            MainActor.assumeIsolated {
                guard let self, self.requestsProxies, let hash, self.project.media.contains(where: { $0.contentHash == hash }) else { return }
                self.forceRebuild()
            }
        }
        // BUG-BUBBLE-TEXT-LAG: an exact text raster replaced a scaled stand-in drawn while editing → redraw
        textRefineObserver = NotificationCenter.default.addObserver(forName: TextRasterizer.refinedNotification, object: nil,
                                                                    queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self, !self.isPlaying { self.onRedrawNeeded?() } }
        }
        ReverseManager.shared.onReady = { [weak self] _ in self?.forceRebuild() }
        StabilizationStore.shared.onReady = { [weak self] _ in self?.onRedrawNeeded?() }
        MatteStore.shared.onMatteReady = { [weak self] _, _ in self?.forceRebuild() }
        RenderCache.shared.onReady = { [weak self] _ in self?.forceRebuild() }
        AudioRenderCache.shared.onReady = { [weak self] hash in
            // only rebuild when the finished render belongs to this project (variants are "<hash>~<suffix>")
            guard let self, self.project.media.contains(where: { hash.hasPrefix($0.contentHash) }) else { return }
            self.forceRebuild()
        }
        update(project: project, force: true)
    }

    // MARK: Project updates

    /// HLG projects: ambient viewing environment of the footage for the EDR preview layer (C1, `HDRViewingMetadata`);
    /// nil = plain HLG. Changes call `onRedrawNeeded`.
    public private(set) var hlgAmbientViewingEnvironment: Data?
    private var ambientKey: [MediaID]?

    private func refreshAmbient(_ project: Project) {
        let assets = project.settings.colorSpace == .hdrHLG ? HDRViewingMetadata.hlgAssets(project) : []
        let key = assets.map(\.id)
        guard key != ambientKey else { return }
        ambientKey = key
        if assets.isEmpty { hlgAmbientViewingEnvironment = nil; return }
        Task { [weak self] in
            let v = await HDRViewingMetadata.shared.ambientViewingEnvironment(for: project)
            guard let self, self.ambientKey == key, v != self.hlgAmbientViewingEnvironment else { return }
            self.hlgAmbientViewingEnvironment = v
            self.onRedrawNeeded?()
        }
    }

    public func update(project: Project, force: Bool = false) {
        self.project = project
        refreshAmbient(project)
        let structure = structureCache.key(project, sources: sourceChooser)
        requestDerivedMedia(project, structure: structure)
        EffectPipelines.shared.prewarm(project)
        state.update(project: rendered(project))
        audioState.update(project: project)
        let size = Self.previewSize(canvas: project.settings.canvasSize, quality: previewQuality)
        var h = Hasher()
        h.combine(structure)
        h.combine(size.width); h.combine(size.height)
        h.combine(previewColorSpace)
        // a newly finished (or invalidated → re-rendered) cache segment changes the lanes
        for s in RenderCache.shared.validSegments(rendered(project), size: size) { h.combine(s.key) }
        let key = h.finalize()
        if force || key != structureKey {
            structureKey = key
            renderSize = size
            rebuild(project, debounce: !force)
        } else if !isPlaying {
            onRedrawNeeded?()
        }
    }

    public func forceRebuild() { update(project: project, force: true) }

    /// Background renders the project needs (reversed media, stabilization analysis, decoder-budget proxies);
    /// each is idempotent and rebuilds/redraws the preview when ready. Clip ids are job subjects so the timeline can
    /// show progress on the clip.
    /// Inputs of the decoder-budget proxy decision when it last ran (perf: it walks every clip and sorts decode events;
    /// a property drag on a 500-clip timeline changes none of them).
    private var proxyBudgetKey: Int?
    /// Clips that may need a derived render (reversed / stabilized), per track — recomputed only for changed tracks.
    private let derivedCandidates = TrackMemo<[Clip]> { $0.filter { $0.mediaID != nil && ($0.reversed || $0.stabilization != nil) } }

    private func requestDerivedMedia(_ project: Project, structure: Int) {
        var reverse: [(MediaAsset, ClipID)] = [], stabilize: [(MediaAsset, ClipID)] = []
        let lookup = project.mediaLookup
        for cands in derivedCandidates.values(project.timeline.tracks) {
            for c in cands {
                guard let id = c.mediaID, let a = lookup[id], a.kind == .video else { continue }
                if c.reversed, ReverseManager.shared.readyURL(for: a) == nil, ReverseManager.shared.pendingJob(for: a) == nil {
                    reverse.append((a, c.id))
                }
                if c.stabilization != nil, !StabilizationStore.shared.isAnalyzed(a), !StabilizationStore.shared.isPending(a) {
                    stabilize.append((a, c.id))
                }
            }
        }
        var bk = Hasher()
        bk.combine(structure); bk.combine(ProxyManager.shared.policy)
        for t in project.timeline.tracks { bk.combine(t.isHidden) }
        let budgetKey = bk.finalize()
        var heavy: [MediaAsset] = [], wanted: [MediaAsset] = []
        if budgetKey != proxyBudgetKey {
            proxyBudgetKey = budgetKey
            heavy = DecoderBudget.mediaNeedingProxies(project)
            if requestsProxies {
                let pm = ProxyManager.shared
                wanted = project.media.filter { $0.kind == .video && pm.shouldGenerate($0) && pm.readyProxyURL(for: $0) == nil && !pm.isPending($0) }
            }
        }
        guard !reverse.isEmpty || !stabilize.isEmpty || !heavy.isEmpty || !wanted.isEmpty else { return }
        Task {
            for (a, c) in reverse { await ReverseManager.shared.request(a, subject: c.description) }
            for (a, c) in stabilize { await StabilizationStore.shared.request(a, subject: c.description) }
            if !heavy.isEmpty { await ProxyManager.shared.request(heavy, force: true) }
            if !wanted.isEmpty { await ProxyManager.shared.request(wanted) }
        }
    }

    /// Rebuilds are debounced (40 ms) so continuous drags (trim/move) coalesce into few builds.
    private func rebuild(_ project0: Project, debounce: Bool) {
        let project = rendered(project0)
        buildTask?.cancel()
        let size = renderSize, chooser = sourceChooser, state = self.state, audioState = self.audioState
        let mixes = mixesAudioFormatsForTesting, skips = skipRanges
        let separates = separatesTrackAudioForTesting
        isBuilding = true
        buildTask = Task { [weak self] in
            do {
                if debounce { try await Task.sleep(for: .milliseconds(40)) }
                let built = try await CompositionBuilder.build(project: project, purpose: .preview, renderSize: size,
                                                               state: state, audioState: audioState, mixesAudioFormats: mixes,
                                                               audioTaps: false, skipping: skips,   // PreviewAudio
                                                               separatesTrackAudio: separates, sources: chooser)
                guard !Task.isCancelled else { return }
                self?.isBuilding = false
                self?.lastBuildError = nil
                self?.install(built)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self?.isBuilding = false
                self?.lastBuildError = error
                EngineLog.error("composition build failed: \(error)")
            }
        }
    }

    private func install(_ built: BuiltComposition) {
        let wasPlaying = isPlaying
        // Edit while playing steadily on the same item timeline: the audio goes on (gapless swap), the new item's video
        // joins its clock. Otherwise (paused, starting, quick-cut ranges changed): both restart from the playhead.
        let gapless = wasPlaying && player.rate > 0 && audio.isRunning && !seekInFlight && resumeRate == nil
            && reverseShuttleRate == 0 && built.skip == itemSkip
        let rate0 = player.rate
        let t = gapless ? timeline(CMTime(seconds: audio.currentTime, preferredTimescale: 48000)) : requestedTime
        let item = AVPlayerItem(asset: built.playerAsset ?? built.composition)
        item.videoComposition = built.videoComposition
        if built.playerAsset == nil {   // (a build with audio in the player: not the engine's own builds)
            item.audioMix = built.audioMix
            item.audioTimePitchAlgorithm = .spectral
        }
        // HDR projects: keep the compositor's half-float HLG / PQ code values (8-bit would band, EDR preview needs them).
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: previewColorSpace.isHDR ? kCVPixelFormatType_64RGBAHalf : kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true])
        item.add(out)
        videoOutput = out
        duration = project.duration
        player.rate = 0
        player.replaceCurrentItem(with: item)
        state.clearRecent()
        onItemReplaced?()
        lastShownTime = .invalid; stallWatch = nil; driftPolls = 0
        seekInFlight = false
        pendingSeek = nil
        itemSkip = built.skip
        if gapless {
            requestedTime = t
            audio.replace(built)
            rejoinVideo(rate: rate0)
        } else {
            let rate = resumeRate ?? (rate0 != 0 ? rate0 : 1)
            resumeRate = nil
            let target = min(t, max(.zero, project.duration))
            audio.load(built, at: itemSkip.item(target).seconds)
            performSeek(target, exact: true, seeksAudio: false)
            if wasPlaying && reverseShuttleRate == 0 { resume(atRate: rate) }
        }
        installLoopObserver()
    }

    // MARK: Transport

    public var isPlaying: Bool { player.rate != 0 || reverseShuttleRate != 0 || resumeRate != nil }

    /// The playhead: the player's clock while it runs; the audio clock while the video re-joins it; else the request.
    public var currentTime: Time {
        if player.rate != 0 { return timeline(player.currentTime()) }
        if resumeRate != nil, audio.isRunning { return timeline(CMTime(seconds: audio.currentTime, preferredTimescale: 48000)) }
        return requestedTime
    }

    /// Monitor volume (Settings ▸ Audio), 0…1; silenced in tests.
    public var volume: Float {
        get { audio.volume }
        set { audio.volume = newValue }
    }
    /// Mutes the preview (voice-over recording with "mute the project").
    public var isMuted: Bool {
        get { audio.isMuted }
        set { audio.isMuted = newValue }
    }
    /// Preview output device (Settings ▸ Audio); nil = the system default, followed when it changes.
    public var outputDeviceUID: String? {
        get { audio.outputDeviceUID }
        set {
            guard newValue != audio.outputDeviceUID else { return }
            installDeviceClock(newValue)
            audio.outputDeviceUID = newValue   // the renderer posts an output change → `reanchor`
            if isPlaying, reverseShuttleRate == 0 { seek(to: currentTime) }   // restart both on the new clock
        }
    }

    /// The video's clock = the output device's clock (the audio synchronizer's): no drift between the two timebases.
    private func installDeviceClock(_ uid: String?) {
        var clock: CMClock?
        let st = CMAudioDeviceClockCreate(allocator: kCFAllocatorDefault, deviceUID: uid as CFString?, clockOut: &clock)
        if st == noErr, let clock { player.sourceClock = clock } else { EngineLog.error("audio device clock unavailable (\(st)): video on the host clock") }
    }

    /// The audio had to restart (output device / route / format change, renderer failure): its clock is stopped;
    /// restart audio and video together from the playhead.
    private func reanchor() {
        guard player.currentItem != nil else { return }
        if isPlaying, reverseShuttleRate == 0 {
            seek(to: currentTime)   // held, both resume once the seek lands and the audio is primed
        } else {
            audio.seek(to: itemSkip.item(requestedTime).seconds)
        }
    }

    public func play() {
        stopReverseShuttle()
        if let r = loopRange, !r.contains(currentTime) { seek(to: r.start) }
        else if currentTime >= duration - project.settings.frameRate.frameDuration { seek(to: .zero) }
        if let r = skipRange(containing: requestedTime) { seek(to: r.end) }
        resume(atRate: 1)
    }

    /// The skip range playback at `t` is inside (nil when none).
    func skipRange(containing t: Time) -> TimeRange? {
        var lo = 0, hi = skipRanges.count
        while lo < hi { let m = (lo + hi) / 2; if skipRanges[m].end <= t { lo = m + 1 } else { hi = m } }
        guard lo < skipRanges.count else { return nil }
        let r = skipRanges[lo]
        // a hair before the start counts (the boundary fires a little early), the last frame before the end does not
        return t >= r.start - Time(0.02) && t < r.end - Time(0.02) ? r : nil
    }

    /// PB-RESUME holds by construction: pause stops both clocks and keeps the audio already enqueued past the pause
    /// point (no flush), and resume starts both from the paused time.
    public func pause() {
        if reverseShuttleRate != 0 { stopReverseShuttle(); onTimeUpdate?(requestedTime); return }
        // Only a running clock is news: when already paused, `requestedTime` is authoritative and the player may still be
        // mid-seek (reading it back raced the seek and moved the playhead — flaky library preview test).
        let rejoining = player.rate == 0 && resumeRate != nil && audio.isRunning
        if player.rate != 0 || rejoining { requestedTime = currentTime }
        let held = resumeRate != nil
        resumeRate = nil
        startToken &+= 1
        player.pause()
        audio.pause()
        if held { onPlayStateChange?(false) }   // rate was already 0 (seek in flight / priming): no KVO change
        onTimeUpdate?(requestedTime)
        // the re-joining video was sought ahead of the audio: bring it back to the paused time
        if rejoining { seek(to: requestedTime) }
    }

    public func togglePlay() { isPlaying ? pause() : play() }

    /// J/K/L shuttle: negative rates play backwards when the item supports it (silent: the audio stops).
    /// When the item can't play in reverse (custom-compositor compositions usually can't), reverse is emulated with
    /// keyframe-tolerant seeks stepping back at `rate` (video only, like CapCut's reverse shuttle).
    public func setRate(_ rate: Float) {
        guard rate != 0 else { pause(); return }
        if rate < 0, player.currentItem?.canPlayReverse != true {
            if player.rate != 0 { requestedTime = timeline(player.currentTime()); player.pause() }
            audio.pause()
            resumeRate = nil   // a seek in flight must not restart forward playback
            startToken &+= 1
            startReverseShuttle(rate)
            return
        }
        stopReverseShuttle()
        // Setting both rates directly while running desynchronised them by up to 0.5 s (AVPlayer applies a rate change
        // to its timebase late, measured): stop both and re-launch them together from one (time, host time) pair. The
        // audio queued past the clock is kept (no flush): the gap is the start lead, ≈ 12 ms.
        if player.rate != 0 { requestedTime = timeline(player.currentTime()); player.rate = 0 }
        audio.pause()
        resume(atRate: rate)
    }

    /// Current shuttle rate (negative = backwards), including the emulated reverse.
    public var shuttleRate: Float { reverseShuttleRate != 0 ? reverseShuttleRate : (player.rate != 0 ? player.rate : resumeRate ?? 0) }

    private func startReverseShuttle(_ rate: Float) {
        let wasRunning = reverseShuttleRate != 0
        reverseShuttleRate = rate
        if !wasRunning { onPlayStateChange?(true) }
        guard reverseTimer == nil else { return }
        var last = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = CACurrentMediaTime()
                let dt = now - last; last = now
                let next = self.requestedTime - Time(dt * Double(-self.reverseShuttleRate))
                let floor = self.loopRange?.start ?? .zero
                if next <= floor {
                    if let r = self.loopRange { self.seekKeepingShuttle(r.end - self.project.settings.frameRate.frameDuration) }
                    else { self.stopReverseShuttle(); self.seek(to: .zero) }
                } else {
                    self.seekKeepingShuttle(next)
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        reverseTimer = t
    }

    private func seekKeepingShuttle(_ t: Time) {
        let target = t.clamped(.zero, max(project.duration, .zero))
        requestedTime = target
        onTimeUpdate?(target)
        if seekInFlight { pendingSeek = (target, false); return }
        performSeek(target, exact: false)
    }

    private func stopReverseShuttle() {
        guard reverseShuttleRate != 0 || reverseTimer != nil else { return }
        reverseTimer?.invalidate(); reverseTimer = nil
        reverseShuttleRate = 0
        if player.rate == 0 && resumeRate == nil { onPlayStateChange?(false) }
    }

    private func installLoopObserver() {
        if let o = loopObserver { player.removeTimeObserver(o); loopObserver = nil }
        guard let r = loopRange, !r.isEmpty else { return }
        // Fire a frame before the end so the wrap happens before the item reaches its end and pauses.
        let end = itemSkip.item(max(r.start, r.end - project.settings.frameRate.frameDuration))
        loopObserver = player.addBoundaryTimeObserver(forTimes: [NSValue(time: end.cmTime)], queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.player.rate > 0, let r = self.loopRange else { return }
                self.seek(to: r.start)   // keeps playing at the same rate once the seek lands
            }
        }
    }

    /// Preview-axis hover: show the frame at `t` without moving the playhead (`nil` returns to the playhead).
    /// Ignored while playing.
    public func previewHover(_ t: Time?) {
        guard !isPlaying, hoverTime != t else { return }
        hoverTime = t
        let target = (t ?? requestedTime).clamped(.zero, max(project.duration, .zero))
        if seekInFlight { pendingSeek = (target, t == nil); return }
        performSeek(target, exact: t == nil)
    }

    /// Coalesced seek: at most one in flight; the latest request wins. `exact: false` = keyframe-tolerant
    /// (fast scrub while dragging); finish a drag with an exact seek.
    public func seek(to t: Time, exact: Bool = true) {
        if reverseShuttleRate != 0 { stopReverseShuttle() }
        hoverTime = nil
        framesSinceSeek = 0
        let target = t.clamped(.zero, max(project.duration, .zero))
        requestedTime = target
        onTimeUpdate?(target)
        if seekInFlight {
            pendingSeek = (target, exact)
            audio.pause()   // (a video re-join in flight leaves the audio running: the request owns the playhead now)
            if seekLooksStuck { restartStuckSeek() }
            return
        }
        performSeek(target, exact: exact)
    }

    // MARK: Stuck seek (PB-SEEK-LAG)

    /// Seconds a seek may stay in flight before a new request (seek, play) stops waiting for it.
    static let stuckSeekSeconds = 2.0
    /// Seeks restarted because the previous one never completed (diagnostics / tests).
    public private(set) var stuckSeekRestarts = 0
    private var seekStartedAt: CFTimeInterval = 0
    /// Tests only: the player is never asked to seek (a seek AVFoundation never completes).
    var ignoresSeeksForTesting = false

    /// The in-flight seek will not complete: the clock runs although every seek holds it (the player went on playing
    /// from where it was, so the request was not honoured), or it has been pending for `stuckSeekSeconds`.
    /// Owner (PB-SEEK-LAG, lagging preview): clicks on the timeline while playing were all queued behind such a seek —
    /// the playhead kept advancing from where it was, as if nothing was clicked, until pause + play.
    private var seekLooksStuck: Bool {
        seekInFlight && (player.rate != 0 || CACurrentMediaTime() - seekStartedAt > Self.stuckSeekSeconds)
    }

    /// Drops the stuck seek (its completion is ignored: new generation) and performs the latest request now.
    private func restartStuckSeek() {
        stuckSeekRestarts += 1
        EngineLog.error("seek stuck for \(String(format: "%.1f", CACurrentMediaTime() - seekStartedAt)) s (rate \(player.rate)): restarting it")
        player.currentItem?.cancelPendingSeeks()
        seekInFlight = false
        let (t, exact) = pendingSeek ?? (requestedTime, true)
        pendingSeek = nil
        unfinishedSeekRetries = 0
        performSeek(t, exact: exact)
    }

    public func step(frames: Int) {
        if isPlaying { pause() }
        hoverTime = nil
        let fd = project.settings.frameRate.frameDuration
        let f = project.settings.frameRate.frame(containing: requestedTime + Time(ticks: 1))
        seek(to: project.settings.frameRate.time(ofFrame: f + Int64(frames)).clamped(.zero, max(.zero, project.duration - fd)))
    }

    /// Seeks the video (and the audio, unless `seeksAudio` is false or `rejoin`).
    /// - Audio: stopped at once (its clock stands at the target, so the playhead and the video follow it), re-read
    ///   from the target. Keyframe-tolerant seeks while paused (scrub drags, hover, reverse shuttle) leave the audio
    ///   where it is: `launch` re-seeks it to the video's position before playing, if they still differ.
    /// - `rejoin`: the audio keeps playing; once the video lands it starts at the host time the audio clock reaches
    ///   the landed time (`joinAudio`).
    private func performSeek(_ t: Time, exact: Bool, seeksAudio: Bool = true, rejoin: Bool = false) {
        guard player.currentItem != nil else { return }
        seekInFlight = true
        // Seeking while playing: hold the clock for the seek and resume when the last coalesced seek lands. Seeking with
        // the timebase running (rate 1, `automaticallyWaitsToMinimizeStalling` off) sometimes left the custom-compositor
        // video pipeline without a preroll: AVPlayer stopped requesting frames for seconds while audio and the clock ran
        // on (frozen preview, C3-5; `PlaybackStressTests`).
        if player.rate != 0 { resumeRate = player.rate; player.rate = 0 }
        startToken &+= 1   // a start waiting for the audio waits for this seek instead
        seekGeneration &+= 1
        let gen = seekGeneration
        let tol = exact ? CMTime.zero : CMTime(value: 1, timescale: 10)
        let target = itemSkip.item(t).cmTime
        if !rejoin {
            audio.pause()
            if seeksAudio, exact || resumeRate != nil { audio.seek(to: target.seconds) }
        }
        seekTarget = CMTimeSubtract(target, tol)
        seekStartedAt = CACurrentMediaTime()
        if ignoresSeeksForTesting { return }
        player.seek(to: target, toleranceBefore: tol, toleranceAfter: tol) { [weak self] finished in
            Task { @MainActor in
                guard let self, gen == self.seekGeneration else { return }   // superseded (item replaced)
                self.seekInFlight = false
                if let (pt, pe) = self.pendingSeek {
                    self.pendingSeek = nil
                    self.unfinishedSeekRetries = 0
                    self.performSeek(pt, exact: pe)
                    return
                }
                // PB-SEEK-LAG: AVFoundation can end a seek unfinished (interrupted inside the player, e.g. while its
                // pipeline is struggling) without moving: resuming then plays on from where the click found it, while
                // the playhead shows the target. Re-issue the request (bounded) before resuming.
                if !finished, self.unfinishedSeekRetries < Self.maxUnfinishedSeekRetries {
                    self.unfinishedSeekRetries += 1
                    self.seekRetries += 1
                    self.performSeek(t, exact: exact, seeksAudio: false, rejoin: rejoin)
                    return
                }
                self.unfinishedSeekRetries = 0
                // a tolerant seek can land after its target: frames start where it landed
                let landed = self.player.currentTime()
                if landed.isValid, CMTimeCompare(landed, self.seekTarget) > 0 { self.seekTarget = landed }
                if let r = self.resumeRate {
                    if rejoin { self.joinAudio(rate: r, at: landed) } else { self.startWhenPrimed() }
                }
            }
        }
    }
    /// Rate to resume once the in-flight seek(s) complete and the audio is primed (play requested); nil = paused or running.
    private var resumeRate: Float?
    private var seekGeneration = 0
    /// Invalidates `whenPrimed` starts that a pause / seek / newer start superseded.
    private var startToken = 0
    /// Consecutive re-issues of the current seek after AVFoundation ended it unfinished.
    private var unfinishedSeekRetries = 0
    static let maxUnfinishedSeekRetries = 2
    /// Seeks re-issued because AVFoundation ended them unfinished (diagnostics / tests).
    public private(set) var seekRetries = 0

    /// Starts playback at `rate`, after the in-flight seek when there is one (see `performSeek`) and once the audio is
    /// primed (`launch`).
    private func resume(atRate rate: Float) {
        if seekLooksStuck { restartStuckSeek() }
        let was = isPlaying
        resumeRate = rate
        if !was { onPlayStateChange?(true) }
        if !seekInFlight { startWhenPrimed() }
    }

    /// Launches once `PreviewAudio` has `prime` of audio queued at its clock (≈ 0.1-0.2 s after a seek, at once after
    /// a pause in place).
    private func startWhenPrimed() {
        startToken &+= 1
        let token = startToken
        audio.whenPrimed { [weak self] in Task { @MainActor in self?.launch(token) } }
    }

    /// Host-time lead of a start: both timebases get the same (item time, host time) pair, a little in the future, and
    /// never closer than the output latency (BUG-AIRPODS-SILENT: a nearer audio start stays silent on Bluetooth).
    var startLead: CMTime { CMTime(seconds: audio.startLead, preferredTimescale: 1_000_000) }
    /// Starts done by `launch` (diagnostics / tests).
    public private(set) var launches = 0
    /// Host time (CACurrentMediaTime base) the last scheduled video start takes effect: before it the player reports a
    /// rate but its clock holds (tests: A/V comparisons start after it).
    public private(set) var scheduledStartHost: CFTimeInterval = 0

    /// Starts the video and the audio together: the player's item time `t` at host time `h`, for both.
    private func launch(_ token: Int) {
        guard token == startToken, let r = resumeRate, !seekInFlight, player.currentItem != nil, reverseShuttleRate == 0 else { return }
        let t = player.currentTime()
        guard t.isNumeric else { startWhenPrimed(); return }
        // the audio stands elsewhere (tolerant seek landed off its target, scrub while paused, rejoin then pause):
        // the video's frame is what the user sees, the audio follows it
        if r > 0, abs(audio.currentTime - t.seconds) > 0.005 {
            audio.seek(to: t.seconds)
            startWhenPrimed()
            return
        }
        resumeRate = nil
        let h = CMClockGetTime(CMClockGetHostTimeClock()) + startLead
        player.setRate(r, time: t, atHostTime: h)
        scheduledStartHost = h.seconds
        audio.start(rate: Double(r), time: t.seconds, atHostTime: h)   // (r < 0: native reverse, audio stays silent)
        seekTarget = t
        stallWatch = nil; driftPolls = 0
        launches += 1
    }

    // MARK: Video re-join (edits while playing, stall recovery, drift)

    /// Video re-joins after a new item / stall / drift (diagnostics / tests).
    public private(set) var videoRejoins = 0
    private var rejoinAttempts = 0

    /// Re-starts the video on the RUNNING audio clock without touching the audio: seek the player `lead` (media
    /// seconds × rate) ahead of the audio clock, then start it at the host time the audio reaches the landed time.
    private func rejoinVideo(rate: Float, lead: Double = 0.25) {
        guard player.currentItem != nil else { return }
        guard rate > 0, audio.isRunning else {
            // no running audio clock to join (reverse, stopped): restart both
            resumeRate = rate
            performSeek(currentTime, exact: true)
            return
        }
        videoRejoins += 1
        let now = audio.currentTime
        let end = itemDuration.seconds
        let target = min(now + lead * Double(rate), end)
        resumeRate = rate
        if target >= end - 0.05 {   // too close to the end to join: the end handling stops both
            performSeek(timeline(CMTime(seconds: now, preferredTimescale: 48000)), exact: true)
            return
        }
        performSeek(timeline(CMTime(seconds: target, preferredTimescale: 48000)), exact: true, rejoin: true)
    }

    /// The re-joining video landed at `landed`: start it when the audio clock gets there; when the audio already passed
    /// it (slow seek), try again further ahead, then fall back to restarting both.
    private func joinAudio(rate: Float, at landed: CMTime) {
        guard audio.isRunning, landed.isNumeric else { startWhenPrimed(); return }
        let host = CMClockGetHostTimeClock()
        let h = CMSyncConvertTime(landed, from: audio.timebase, to: host)
        let now = CMClockGetTime(host)
        if (h - now).seconds > 0.004 {
            rejoinAttempts = 0
            resumeRate = nil
            player.setRate(rate, time: landed, atHostTime: h)
            scheduledStartHost = h.seconds
            seekTarget = landed
            stallWatch = nil; driftPolls = 0
            return
        }
        if rejoinAttempts < 2 {
            rejoinAttempts += 1
            rejoinVideo(rate: rate, lead: 0.25 * Double(1 << rejoinAttempts))
            return
        }
        rejoinAttempts = 0
        EngineLog.error("video could not re-join the audio clock: restarting both")
        performSeek(timeline(CMTime(seconds: audio.currentTime, preferredTimescale: 48000)), exact: true)
    }

    // MARK: Frames for the view

    /// Frames handed to the view since the last `seek` request, and the item time of the latest one (UI tests:
    /// `ui.playback` — a frozen preview keeps `framesSinceSeek` at 0 while the clock runs).
    public private(set) var framesSinceSeek = 0
    public private(set) var lastFrameTime: Time = .zero

    /// Frame to show at a display host time (CACurrentMediaTime base). Returns nil if no new frame.
    public func pixelBuffer(forHostTime host: CFTimeInterval) -> (CVPixelBuffer, Time)? {
        guard let out = videoOutput else { return nil }
        let itemTime = out.itemTime(forHostTime: host)
        watchDrift(itemTime, host: host)
        if presentsOneFrameInForTesting > 1 {   // lagging preview: the view gets 1 frame in N (dropped-frames warning)
            framePollsForTesting += 1
            if framePollsForTesting % presentsOneFrameInForTesting != 0 { return nil }
        }
        guard !withholdsFramesForTesting, out.hasNewPixelBuffer(forItemTime: itemTime) else { watchForStall(itemTime); return nil }
        var shown = CMTime.invalid
        guard let pb = out.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &shown) else { watchForStall(itemTime); return nil }
        framesSinceSeek += 1
        lastFrameTime = timeline(shown)
        // the output can hand back the frame it already showed (same display time): the preview is still frozen, so
        // that must not reset the stall watch (the watchdog then never fired: C3b, 8 s freeze under load)
        if shown.isValid, shown == lastShownTime { watchForStall(itemTime) } else { stallWatch = nil; futilePrimes = 0 }
        lastShownTime = shown
        return (pb, lastFrameTime)
    }

    // MARK: A/V drift

    /// Audio clock − video clock (item seconds) at the last display poll while both ran (diagnostics / tests).
    public private(set) var lastAVDrift: Double = 0
    /// Largest |drift| seen since the last start (diagnostics / tests).
    public private(set) var maxAVDrift: Double = 0
    /// Re-joins done because the video clock drifted from the audio (diagnostics / tests).
    public private(set) var driftRejoins = 0
    private var driftPolls = 0
    /// Drift (s) beyond which the video is re-joined to the audio clock, and for how many consecutive display polls.
    static let driftLimit = 0.045
    static let driftPollLimit = 12

    /// Both timebases run on the output device clock from one (time, host time) start, so they should never drift;
    /// if they do (an AVPlayer re-sync of its own, a device clock switch), the video re-joins the audio.
    private func watchDrift(_ itemTime: CMTime, host: CFTimeInterval) {
        guard player.rate > 0, !seekInFlight, resumeRate == nil, reverseShuttleRate == 0, audio.isRunning, itemTime.isNumeric,
              seekTarget.isNumeric, CMTimeCompare(itemTime, seekTarget) > 0 else { driftPolls = 0; return }
        let a = CMSyncConvertTime(CMTime(seconds: host, preferredTimescale: 1_000_000_000), from: CMClockGetHostTimeClock(), to: audio.timebase)
        guard a.isNumeric else { return }
        let d = a.seconds - itemTime.seconds
        lastAVDrift = d
        maxAVDrift = max(maxAVDrift, abs(d))
        guard abs(d) > Self.driftLimit, itemDuration.seconds - itemTime.seconds > 0.3 else { driftPolls = 0; return }
        driftPolls += 1
        guard driftPolls >= Self.driftPollLimit else { return }
        driftPolls = 0
        driftRejoins += 1
        EngineLog.error(String(format: "video drifted %+.0f ms from the audio clock at %.2f s: re-joining", d * 1000, itemTime.seconds))
        rejoinVideo(rate: player.rate)
    }

    /// Resets `maxAVDrift` (tests: measure one phase).
    public func resetAVDriftStats() { maxAVDrift = 0 }

    // MARK: Stalled video pipeline (C3 round 2)

    /// Item time when the view last asked for a frame and got none while playing (nil = frames are flowing).
    private var stallWatch: CMTime?
    /// Times the engine re-primed a stalled video pipeline (diagnostics / tests).
    public private(set) var stallRecoveries = 0
    /// Times a re-prime did not bring frames back and the engine rebuilt the player item instead (diagnostics / tests).
    public private(set) var stallRebuilds = 0
    /// Re-primes since the last new frame; after `maxFutilePrimes` the item is rebuilt (fresh video pipeline).
    private var futilePrimes = 0
    static let maxFutilePrimes = 2
    /// Display time of the last frame handed to the view (a repeat is not a new frame).
    private var lastShownTime = CMTime.invalid
    /// Item time the clock was last (re)started from: the last seek's target less its tolerance (then where it landed),
    /// or the current time when playback starts without a seek. No frame exists before it: see `watchForStall`.
    private var seekTarget = CMTime.invalid
    /// Item-time span without a new frame, while playing, that counts as a frozen preview.
    static let stallSpan = 0.3

    /// AVPlayer sometimes stops requesting compositions from our custom compositor after a seek (scrub, rapid seeks,
    /// even with the rate held during the seek): the clock runs on, but no video frame is composed any more — the
    /// preview freezes on the pre-seek frame for seconds. It is internal to AVFoundation's video-composition pipeline;
    /// neither ordering (hold → seek → play) nor `preroll` (never completes with a custom compositor) prevents it. The
    /// view polls for frames every display refresh, so the engine sees the stall as it happens: when the item clock
    /// advanced `stallSpan` with no new frame and no seek in flight, it re-primes the video pipeline with an exact seek
    /// ahead of the audio clock and re-joins it (`rejoinVideo`: the audio plays on) — the preview recovers within
    /// ~0.3–0.5 s instead of freezing. If re-seeks don't bring a frame back (`maxFutilePrimes`), the player item is
    /// rebuilt: a fresh video pipeline at the same time (the audio swaps gaplessly).
    ///
    /// PB-LATENCY (AVPlayer with audio started its item clock before the target by the output latency): the watch
    /// starts at the clock's start time (`seekTarget`), no frame exists before it.
    private func watchForStall(_ itemTime: CMTime) {
        guard player.rate > 0, !seekInFlight, resumeRate == nil, reverseShuttleRate == 0, itemTime.isValid,
              !(seekTarget.isValid && CMTimeCompare(itemTime, seekTarget) < 0) else {
            stallWatch = nil; return
        }
        guard let since = stallWatch else { stallWatch = itemTime; return }
        let span = CMTimeSubtract(itemTime, since).seconds
        if span < 0 { stallWatch = itemTime; return }
        guard span >= Self.stallSpan, itemDuration.seconds - itemTime.seconds > 0.2 else { return }
        stallWatch = nil
        requestedTime = timeline(itemTime).clamped(.zero, max(project.duration, .zero))
        if futilePrimes >= Self.maxFutilePrimes {
            // re-seeking did not wake the pipeline: a new player item at the same time (install keeps playing)
            futilePrimes = 0
            stallRebuilds += 1
            forceRebuild()
            return
        }
        futilePrimes += 1
        stallRecoveries += 1
        rejoinVideo(rate: player.rate)
    }

    /// Tests only: build with the pre-PB-QC audio lane layout (formats mixed on a lane).
    var mixesAudioFormatsForTesting = false
    /// Tests only: build with the pre-BUG-PLAY-SILENT audio layout (composition audio tracks per decode track).
    var separatesTrackAudioForTesting = false
    /// Tests only: the view gets no new frame (a lagging / stalled video pipeline, as the watchdogs see it).
    var withholdsFramesForTesting = false
    /// Tests / UI scripts (`playerState: "lag=N"`): the view gets one display poll in N (a lagging preview: frames
    /// arrive late, PlaybackHealth shows its dropped-frames warning). 0 = off.
    public var presentsOneFrameInForTesting = 0
    private var framePollsForTesting = 0

    /// Re-renders the frame at the playhead from the last decoded sources with the LATEST project (paused edits).
    /// Encodes into `output` (bgra8Unorm render target). Returns false if no decoded sources are available yet.
    /// An interactive frame (BUG-BUBBLE-TEXT-LAG): a slow text raster at a new size is drawn from its raster at the
    /// previous size, scaled, while the exact one is built off the main thread (then `onRedrawNeeded`).
    public func renderCurrentFrame(into output: MTLTexture, commandBuffer: MTLCommandBuffer) -> Bool {
        let t = hoverTime ?? requestedTime
        let frame = FrameEvaluator.evaluate(project, at: t)
        let sources = state.sourceProvider(near: t) ?? DictionarySourceProvider([:])
        if sources.buffers.isEmpty && !frame.mediaLayers.isEmpty { return false }
        let media = Dictionary(uniqueKeysWithValues: project.media.map { ($0.id, $0) })
        FrameRenderer.shared.encode(frame, media: media, sources: sources, output: output,
                                    commandBuffer: commandBuffer, interactive: true)
        return true
    }

    /// Settings ▸ Performance ▸ "Performance priority" (PB-004): Auto preview quality caps at 720p on every machine.
    public static var performancePriority = false

    /// Preview render size for a canvas: capped by quality and the machine's memory class.
    public static func previewSize(canvas: Size2, quality: PreviewQuality) -> CGSize {
        let short = min(canvas.width, canvas.height)
        let maxH: Double
        switch quality {
        case .auto: maxH = MemoryBudget.isLowMemoryMachine || performancePriority ? 720 : 1080
        case .full: maxH = min(short, 2160)
        case .half: maxH = short / 2
        case .quarter: maxH = short / 4
        }
        let k = min(1, maxH / max(short, 1))
        func even(_ v: Double) -> Double { max(2, (v * k / 2).rounded() * 2) }
        return CGSize(width: even(canvas.width), height: even(canvas.height))
    }
}
