@preconcurrency import AVFoundation
@preconcurrency import Metal
import Foundation
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
    public private(set) var videoOutput: AVPlayerItemVideoOutput?
    public private(set) var duration: Time = .zero
    public private(set) var project: Project
    public private(set) var renderSize: CGSize = CGSize(width: 1920, height: 1080)

    public var previewQuality: PreviewQuality = .auto { didSet { if oldValue != previewQuality { forceRebuild() } } }
    /// Chooses original vs proxy files for preview. Replace to plug in proxies; call `forceRebuild()` when it changes.
    public var sourceChooser: @Sendable (MediaAsset) -> MediaSourceChoice = { a in
        MediaSourceChoice(video: ProxyManager.shared.readyProxyURL(for: a) ?? a.url, audio: a.url)
    }

    /// Playhead updates (≈30 Hz while playing, and after seeks).
    public var onTimeUpdate: ((Time) -> Void)?
    /// Paused + property edit: re-render the current frame now.
    public var onRedrawNeeded: (() -> Void)?
    /// A new player item is in place (view should reset its frame cache).
    public var onItemReplaced: (() -> Void)?
    public var onPlayStateChange: ((Bool) -> Void)?

    private var structureKey: Int?
    private var buildTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var rateObservation: NSKeyValueObservation?
    private var seekInFlight = false
    private var pendingSeek: (Time, Bool)?
    /// Last requested playhead position (authoritative while seeking / before an item exists).
    public private(set) var requestedTime: Time = .zero

    public init(project: Project) {
        self.project = project
        state = RenderState(project: project)
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = false
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, self.player.rate != 0 else { return }
                self.requestedTime = Time(cmTime: t)
                self.onTimeUpdate?(self.requestedTime)
            }
        }
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] p, _ in
            let playing = p.rate != 0
            Task { @MainActor in self?.onPlayStateChange?(playing) }
        }
        update(project: project, force: true)
    }

    // MARK: Project updates

    public func update(project: Project, force: Bool = false) {
        self.project = project
        state.update(project: project)
        let size = Self.previewSize(canvas: project.settings.canvasSize, quality: previewQuality)
        var h = Hasher()
        h.combine(CompositionBuilder.structureKey(project, sources: sourceChooser))
        h.combine(size.width); h.combine(size.height)
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

    /// Rebuilds are debounced (40 ms) so continuous drags (trim/move) coalesce into few builds.
    private func rebuild(_ project: Project, debounce: Bool) {
        buildTask?.cancel()
        let size = renderSize, chooser = sourceChooser, state = self.state
        buildTask = Task { [weak self] in
            do {
                if debounce { try await Task.sleep(for: .milliseconds(40)) }
                let built = try await CompositionBuilder.build(project: project, purpose: .preview, renderSize: size,
                                                               state: state, sources: chooser)
                guard !Task.isCancelled else { return }
                self?.install(built)
            } catch is CancellationError {
            } catch {
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
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true])
        item.add(out)
        videoOutput = out
        duration = project.duration
        player.replaceCurrentItem(with: item)
        state.clearRecent()
        onItemReplaced?()
        seekInFlight = false
        performSeek(min(t, max(.zero, project.duration)), exact: true)
        if wasPlaying { player.play() }
    }

    // MARK: Transport

    public var isPlaying: Bool { player.rate != 0 }

    public var currentTime: Time { isPlaying ? Time(cmTime: player.currentTime()) : requestedTime }

    public func play() {
        if currentTime >= duration - project.settings.frameRate.frameDuration { seek(to: .zero) }
        player.playImmediately(atRate: 1)
    }

    public func pause() {
        player.pause()
        requestedTime = Time(cmTime: player.currentTime())
        onTimeUpdate?(requestedTime)
    }

    public func togglePlay() { isPlaying ? pause() : play() }

    /// J/K/L shuttle: negative rates play backwards when the item supports it.
    public func setRate(_ rate: Float) {
        guard rate != 0 else { pause(); return }
        if rate < 0, player.currentItem?.canPlayReverse != true { return }
        player.rate = rate
    }

    /// Coalesced seek: at most one in flight; the latest request wins. `exact: false` = keyframe-tolerant
    /// (fast scrub while dragging); finish a drag with an exact seek.
    public func seek(to t: Time, exact: Bool = true) {
        let target = t.clamped(.zero, max(project.duration, .zero))
        requestedTime = target
        onTimeUpdate?(target)
        if seekInFlight { pendingSeek = (target, exact); return }
        performSeek(target, exact: exact)
    }

    public func step(frames: Int) {
        if isPlaying { pause() }
        let fd = project.settings.frameRate.frameDuration
        let f = project.settings.frameRate.frame(containing: requestedTime + Time(ticks: 1))
        seek(to: project.settings.frameRate.time(ofFrame: f + Int64(frames)).clamped(.zero, max(.zero, project.duration - fd)))
    }

    private func performSeek(_ t: Time, exact: Bool) {
        guard player.currentItem != nil else { return }
        seekInFlight = true
        let tol = exact ? CMTime.zero : CMTime(value: 1, timescale: 10)
        player.seek(to: t.cmTime, toleranceBefore: tol, toleranceAfter: tol) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seekInFlight = false
                if let (pt, pe) = self.pendingSeek {
                    self.pendingSeek = nil
                    self.performSeek(pt, exact: pe)
                }
            }
        }
    }

    // MARK: Frames for the view

    /// Frame to show at a display host time (CACurrentMediaTime base). Returns nil if no new frame.
    public func pixelBuffer(forHostTime host: CFTimeInterval) -> (CVPixelBuffer, Time)? {
        guard let out = videoOutput else { return nil }
        let itemTime = out.itemTime(forHostTime: host)
        guard out.hasNewPixelBuffer(forItemTime: itemTime) else { return nil }
        var shown = CMTime.invalid
        guard let pb = out.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &shown) else { return nil }
        return (pb, Time(cmTime: shown))
    }

    /// Re-renders the frame at the playhead from the last decoded sources with the LATEST project (paused edits).
    /// Encodes into `output` (bgra8Unorm render target). Returns false if no decoded sources are available yet.
    public func renderCurrentFrame(into output: MTLTexture, commandBuffer: MTLCommandBuffer) -> Bool {
        let t = requestedTime
        let frame = FrameEvaluator.evaluate(project, at: t)
        let sources = state.sourceProvider(near: t) ?? DictionarySourceProvider([:])
        if sources.buffers.isEmpty && !frame.mediaLayers.isEmpty { return false }
        let media = Dictionary(uniqueKeysWithValues: project.media.map { ($0.id, $0) })
        FrameRenderer.shared.encode(frame, media: media, sources: sources, output: output,
                                    commandBuffer: commandBuffer)
        return true
    }

    /// Preview render size for a canvas: capped by quality and the machine's memory class.
    public static func previewSize(canvas: Size2, quality: PreviewQuality) -> CGSize {
        let short = min(canvas.width, canvas.height)
        let maxH: Double
        switch quality {
        case .auto: maxH = MemoryBudget.isLowMemoryMachine ? 720 : 1080
        case .full: maxH = min(short, 2160)
        case .half: maxH = short / 2
        case .quarter: maxH = short / 4
        }
        let k = min(1, maxH / max(short, 1))
        func even(_ v: Double) -> Double { max(2, (v * k / 2).rounded() * 2) }
        return CGSize(width: even(canvas.width), height: even(canvas.height))
    }
}
