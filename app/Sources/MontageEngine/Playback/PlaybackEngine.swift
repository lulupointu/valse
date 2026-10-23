@preconcurrency import AVFoundation
@preconcurrency import Metal
import Foundation
import QuartzCore
import MontageCore

/// Preview resolution (CapCut "Preview quality").
public enum PreviewQuality: String, Codable, Sendable, CaseIterable {
    case auto, full, half, quarter
    public var nameKey: String { "preview.quality.\(rawValue)" }
}

/// Preview playback: AVPlayer on the project's AVComposition, frames rendered by MontageCompositor.
///
/// Clock & A/V sync: AVPlayer is the master clock (driven by the audio device). The player view pulls the frame for
/// each display refresh with `pixelBuffer(forHostTime:)` (AVPlayerItemVideoOutput maps host time → item time), so video
/// is presented in sync with audio and dropped frames never drift the clock.
///
/// Edits: `update(project:)` is called on every project change.
/// - structural change (clips moved/trimmed/added, speed, audio) → the AVComposition is rebuilt off-main and the player
///   item swapped at the same time position;
/// - property change (opacity, transform, effects, text…) → no rebuild: the compositor reads the new project; when
///   paused, `onRedrawNeeded` asks the view to re-render the last decoded frame immediately (`renderCurrentFrame`).
@MainActor
public final class PlaybackEngine {
    public let player = AVPlayer()
    public let state: RenderState
    /// Live audio parameters (EQ, voice filter colour…) read by the audio taps without rebuilding.
    public let audioState = AudioMixState()
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
    /// Skipped ranges of the INSTALLED item (the requested ones once their build is in place).
    public private(set) var itemSkip: SkipTimeMap = .identity
    /// Timeline time of a player-item time.
    private func timeline(_ t: CMTime) -> Time { itemSkip.timeline(Time(cmTime: t)) }
    /// Duration of the installed item (the timeline's, less the skipped ranges).
    private var itemDuration: Time { itemSkip.item(project.duration) }
    private var endObserver: (any NSObjectProtocol)?
    private var proxyObserver: (any NSObjectProtocol)?
    /// Emulated reverse shuttle (when the item can't play backwards): negative rate, driven by a timer.
    public private(set) var reverseShuttleRate: Float = 0
    private var reverseTimer: Timer?
    /// Frame shown while hovering the timeline (preview axis) without moving the playhead; nil = follow the playhead.
    public private(set) var hoverTime: Time?

    public init(project: Project) {
        self.project = project
        state = RenderState(project: project)
        MemoryPressure.shared.start()
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = false
        player.volume = AudioOutput.volume(player.volume)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, self.player.rate != 0 else { return }
                self.requestedTime = self.timeline(t)
                self.onTimeUpdate?(self.requestedTime)
            }
        }
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] p, _ in
            let playing = p.rate != 0
            Task { @MainActor in
                guard let self else { return }
                // stopped by itself (end of item): the playhead is where the player stopped
                if !playing, !self.seekInFlight, self.reverseShuttleRate == 0, self.resumeRate == nil { self.requestedTime = self.timeline(self.player.currentTime()) }
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
        state.update(project: project)
        audioState.update(project: project)
        let size = Self.previewSize(canvas: project.settings.canvasSize, quality: previewQuality)
        var h = Hasher()
        h.combine(structure)
        h.combine(size.width); h.combine(size.height)
        // a newly finished (or invalidated → re-rendered) cache segment changes the lanes
        for s in RenderCache.shared.validSegments(project, size: size) { h.combine(s.key) }
        let key = h.finalize()
        if force || key != structureKey {
            if key != structureKey { audioTapsDisabled = false }   // new structure: live audio taps again (see watchClock)
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
    private func rebuild(_ project: Project, debounce: Bool) {
        buildTask?.cancel()
        let size = renderSize, chooser = sourceChooser, state = self.state, audioState = self.audioState
        let mixes = mixesAudioFormatsForTesting, taps = !audioTapsDisabled, skips = skipRanges
        isBuilding = true
        buildTask = Task { [weak self] in
            do {
                if debounce { try await Task.sleep(for: .milliseconds(40)) }
                let built = try await CompositionBuilder.build(project: project, purpose: .preview, renderSize: size,
                                                               state: state, audioState: audioState, mixesAudioFormats: mixes,
                                                               audioTaps: taps, skipping: skips, sources: chooser)
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
        let t = requestedTime
        let item = AVPlayerItem(asset: built.composition)
        item.videoComposition = built.videoComposition
        item.audioMix = built.audioMix
        item.audioTimePitchAlgorithm = .spectral
        // HDR projects: keep the compositor's half-float HLG / PQ code values (8-bit would band, EDR preview needs them).
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: project.settings.colorSpace.isHDR ? kCVPixelFormatType_64RGBAHalf : kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true])
        item.add(out)
        videoOutput = out
        duration = project.duration
        player.replaceCurrentItem(with: item)
        state.clearRecent()
        onItemReplaced?()
        lastShownTime = .invalid; stallWatch = nil; clockWatch = nil
        seekInFlight = false
        pendingSeek = nil
        let rate = resumeRate ?? (player.rate != 0 ? player.rate : 1)
        resumeRate = nil
        itemSkip = built.skip
        performSeek(min(t, max(.zero, project.duration)), exact: true)
        if wasPlaying && reverseShuttleRate == 0 { resume(atRate: rate) }
        installLoopObserver()
    }

    // MARK: Transport

    public var isPlaying: Bool { player.rate != 0 || reverseShuttleRate != 0 || resumeRate != nil }

    public var currentTime: Time { player.rate != 0 ? timeline(player.currentTime()) : requestedTime }

    public func play() {
        stopReverseShuttle()
        if let r = loopRange, !r.contains(currentTime) { seek(to: r.start) }
        else if currentTime >= duration - project.settings.frameRate.frameDuration { seek(to: .zero) }
        if let r = skipRange(containing: requestedTime) { seek(to: r.end) }
        primeIfPausedInPlace()
        resume(atRate: 1)
    }

    /// Paused while playing and not sought since.
    private var pausedInPlace = false

    /// PB-RESUME: AVPlayer resumes a paused item by restarting its clock AT ONCE while its audio chain re-renders from
    /// a little after the pause point (the audio it had queued past that point is flushed): the first ~150 ms of
    /// sound were lost on every pause → play. After a seek it instead holds the clock until the audio is primed from
    /// before the target (a seek → play was gapless). So resuming in place first re-primes with an exact seek to the
    /// paused time; `resume` then starts once it lands, like every seek while playing.
    private func primeIfPausedInPlace() {
        guard pausedInPlace, !seekInFlight, player.currentItem != nil else { return }
        performSeek(requestedTime, exact: true)
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

    public func pause() {
        if reverseShuttleRate != 0 { stopReverseShuttle(); onTimeUpdate?(requestedTime); return }
        // Only a playing player's clock is news: when already paused, `requestedTime` is authoritative and the player
        // may still be mid-seek (reading it back raced the seek and moved the playhead — flaky library preview test).
        if player.rate != 0 { requestedTime = timeline(player.currentTime()); pausedInPlace = true }
        let held = resumeRate != nil
        resumeRate = nil
        player.pause()
        if held { onPlayStateChange?(false) }   // rate was already 0 (seek in flight): no KVO change
        onTimeUpdate?(requestedTime)
    }

    public func togglePlay() { isPlaying ? pause() : play() }

    /// J/K/L shuttle: negative rates play backwards when the item supports it.
    /// When the item can't play in reverse (custom-compositor compositions usually can't), reverse is emulated with
    /// keyframe-tolerant seeks stepping back at `rate` (video only, like CapCut's reverse shuttle).
    public func setRate(_ rate: Float) {
        guard rate != 0 else { pause(); return }
        if rate < 0, player.currentItem?.canPlayReverse != true {
            if player.rate != 0 { player.pause(); requestedTime = timeline(player.currentTime()) }
            resumeRate = nil   // a seek in flight must not restart forward playback
            startReverseShuttle(rate)
            return
        }
        stopReverseShuttle()
        if player.rate == 0 { primeIfPausedInPlace() }
        if seekInFlight { resume(atRate: rate) } else { player.rate = rate }
    }

    /// Current shuttle rate (negative = backwards), including the emulated reverse.
    public var shuttleRate: Float { reverseShuttleRate != 0 ? reverseShuttleRate : player.rate }

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
        if player.rate == 0 { onPlayStateChange?(false) }
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
        if seekInFlight { pendingSeek = (target, exact); return }
        performSeek(target, exact: exact)
    }

    public func step(frames: Int) {
        if isPlaying { pause() }
        hoverTime = nil
        let fd = project.settings.frameRate.frameDuration
        let f = project.settings.frameRate.frame(containing: requestedTime + Time(ticks: 1))
        seek(to: project.settings.frameRate.time(ofFrame: f + Int64(frames)).clamped(.zero, max(.zero, project.duration - fd)))
    }

    private func performSeek(_ t: Time, exact: Bool) {
        guard player.currentItem != nil else { return }
        seekInFlight = true
        pausedInPlace = false
        // Seeking while playing: hold the clock for the seek and resume when the last coalesced seek lands. Seeking with
        // the timebase running (rate 1, `automaticallyWaitsToMinimizeStalling` off) sometimes left the custom-compositor
        // video pipeline without a preroll: AVPlayer stopped requesting frames for seconds while audio and the clock ran
        // on (frozen preview, C3-5; `PlaybackStressTests`).
        if player.rate != 0 { resumeRate = player.rate; player.rate = 0 }
        seekGeneration &+= 1
        let gen = seekGeneration
        let tol = exact ? CMTime.zero : CMTime(value: 1, timescale: 10)
        player.seek(to: itemSkip.item(t).cmTime, toleranceBefore: tol, toleranceAfter: tol) { [weak self] _ in
            Task { @MainActor in
                guard let self, gen == self.seekGeneration else { return }   // superseded (item replaced)
                self.seekInFlight = false
                if let (pt, pe) = self.pendingSeek {
                    self.pendingSeek = nil
                    self.performSeek(pt, exact: pe)
                } else if let r = self.resumeRate {
                    self.resumeRate = nil
                    self.player.playImmediately(atRate: r)
                    self.stallWatch = nil
                }
            }
        }
    }
    /// Rate to resume once the in-flight seek(s) complete (seek requested while playing); nil = stay paused.
    private var resumeRate: Float?
    private var seekGeneration = 0

    /// Starts playback at `rate`, after the in-flight seek when there is one (see `performSeek`).
    private func resume(atRate rate: Float) {
        if seekInFlight {
            let was = isPlaying
            resumeRate = rate
            if !was { onPlayStateChange?(true) }
        } else {
            player.playImmediately(atRate: rate)
        }
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
        watchClock(itemTime, host: host)
        guard out.hasNewPixelBuffer(forItemTime: itemTime) else { watchForStall(itemTime); return nil }
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
    /// Item-time span without a new frame, while playing, that counts as a frozen preview.
    static let stallSpan = 0.3

    /// AVPlayer sometimes stops requesting compositions from our custom compositor after a seek (scrub, rapid seeks,
    /// even with the rate held during the seek): the clock and the audio run on, the buffers are full
    /// (`timeControlStatus` playing, likely to keep up), but no video frame is composed any more — the preview freezes
    /// on the pre-seek frame for seconds. It is internal to AVFoundation's video-composition pipeline; neither
    /// ordering (hold → seek → play) nor `preroll` (never completes with a custom compositor) prevents it. The view polls
    /// for frames every display refresh, so the engine sees the stall as it happens: when the item clock advanced
    /// `stallSpan` with no new frame and no seek in flight, it re-primes the pipeline with an exact seek to the current
    /// time (rate held, then resumed) — the preview recovers within ~0.3–0.5 s instead of freezing. If re-seeks don't
    /// bring a frame back (`maxFutilePrimes`), the player item is rebuilt: a fresh video pipeline at the same time.
    private func watchForStall(_ itemTime: CMTime) {
        guard player.rate > 0, !seekInFlight, resumeRate == nil, reverseShuttleRate == 0, itemTime.isValid else {
            stallWatch = nil; return
        }
        guard let since = stallWatch else { stallWatch = itemTime; return }
        let span = CMTimeSubtract(itemTime, since).seconds
        if span < 0 { stallWatch = itemTime; return }
        guard span >= Self.stallSpan, itemDuration.seconds - itemTime.seconds > 0.2 else { return }
        stallWatch = nil
        let t = timeline(itemTime).clamped(.zero, max(project.duration, .zero))
        requestedTime = t
        if futilePrimes >= Self.maxFutilePrimes {
            // re-seeking did not wake the pipeline: a new player item at the same time (install keeps playing)
            futilePrimes = 0
            stallRebuilds += 1
            forceRebuild()
            return
        }
        futilePrimes += 1
        stallRecoveries += 1
        performSeek(t, exact: true)
    }

    // MARK: Frozen clock (PB-QC)

    /// Item time and display host time when the item clock last moved while playing (nil = not watching).
    private var clockWatch: (item: CMTime, host: CFTimeInterval)?
    /// Times the engine replaced a player item whose clock had stopped while playing (diagnostics / tests).
    public private(set) var clockRebuilds = 0
    /// Wall-clock seconds the item clock may stand still at rate > 0, "playing", before the item is replaced.
    static let frozenClockSeconds = 1.5
    /// Tests only: build with the pre-PB-QC audio lane layout (formats mixed on a lane) to exercise the recovery.
    var mixesAudioFormatsForTesting = false

    /// Preview builds without the lanes' processing taps (live EQ / voice colour / channel edits not heard) after the
    /// clock froze; cleared by the next structural change.
    public private(set) var audioTapsDisabled = false

    /// The item clock follows the audio device: it only stands still while playing when the audio render chain is
    /// wedged (PB-QC: a lane's processing tap left unprepared after a seek — sound gone, then play did nothing, and no
    /// seek brought it back). Nothing inside the item recovers from that, and the same composition wedges again, so
    /// the item is rebuilt at the same time WITHOUT the audio taps (the wedge needs a tap; install keeps playing).
    /// Wall time is fine here: a loaded machine slows decoding, never the audio clock.
    private func watchClock(_ itemTime: CMTime, host: CFTimeInterval) {
        guard player.rate > 0, player.timeControlStatus == .playing, !seekInFlight, resumeRate == nil, reverseShuttleRate == 0,
              !isBuilding, itemTime.isValid, itemDuration.seconds - itemTime.seconds > 0.25 else { clockWatch = nil; return }
        guard let w = clockWatch, w.item == itemTime else { clockWatch = (itemTime, host); return }
        guard host - w.host >= Self.frozenClockSeconds else { return }
        clockWatch = nil
        clockRebuilds += 1
        audioTapsDisabled = true
        EngineLog.error("playback clock frozen at \(String(format: "%.2f", itemTime.seconds)) s while playing: rebuilding the player item without audio taps")
        requestedTime = timeline(itemTime).clamped(.zero, max(project.duration, .zero))
        forceRebuild()
    }

    /// Re-renders the frame at the playhead from the last decoded sources with the LATEST project (paused edits).
    /// Encodes into `output` (bgra8Unorm render target). Returns false if no decoded sources are available yet.
    public func renderCurrentFrame(into output: MTLTexture, commandBuffer: MTLCommandBuffer) -> Bool {
        let t = hoverTime ?? requestedTime
        let frame = FrameEvaluator.evaluate(project, at: t)
        let sources = state.sourceProvider(near: t) ?? DictionarySourceProvider([:])
        if sources.buffers.isEmpty && !frame.mediaLayers.isEmpty { return false }
        let media = Dictionary(uniqueKeysWithValues: project.media.map { ($0.id, $0) })
        FrameRenderer.shared.encode(frame, media: media, sources: sources, output: output,
                                    commandBuffer: commandBuffer)
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
