import AppKit
import Perception
import ValseCore

/// Visibility of the full-screen transport overlay (PB-006b, spec §4). Shown on a pointer move (≥ 3 pt dead-band),
/// hidden after `idleTimeout` without movement, pinned (never times out) while the pointer is over the bar, a drag or
/// the timecode field is active, or VoiceOver runs. Leaving the window hides at once. A key that moves the playhead
/// while hidden flashes a thin progress line for `flashDuration` (owner Q3 = B). The clock and the timer are
/// injectable so the state machine is unit-tested without waiting (FullscreenTransportTests).
@Perceptible
public final class FullscreenControlsModel {
    public enum Visibility: String, Sendable { case hidden, visible, pinned }
    public enum Pin: String, Hashable, Sendable { case hover, drag, timecode, voiceOver, focus }

    /// 1.5 s (was 3 s): long enough to read the timecode after a pointer stop, short enough that the picture is clear
    /// quickly (QuickTime-style). The bar stays pinned while hovered / dragged, so a faster hide never interrupts use.
    public static let defaultIdle: TimeInterval = 1.5
    public static let flashDuration: TimeInterval = 1.5
    /// Pointer movement (pt, cumulative since the last hide) that wakes the bar.
    public static let deadBand: CGFloat = 3

    /// Bar shown (visible or pinned).
    public private(set) var isShown = false
    public private(set) var pins: Set<Pin> = []
    /// Thin progress line shown after a key while the bar is hidden.
    public private(set) var isFlashing = false
    /// Monotonic counters (UI scripts wait on them instead of on timing).
    public private(set) var showCount = 0
    public private(set) var flashCount = 0

    // Hover over the seek bar (tooltip + thumbnail)
    public var hoverTime: Time?
    /// Pointer x in the scrubber's track coordinates.
    public var hoverX: CGFloat = 0
    public var hoverLabel: String?
    /// Drag on the bar in progress, and its fine-scrub label (nil = plain).
    public var isScrubbing = false
    var fineScrub: FineScrubLabel?
    /// Hover thumbnails (owner Q2 = B).
    let thumbnails = FullscreenThumbnailLoader()

    public var visibility: Visibility { !isShown ? .hidden : (pins.isEmpty ? .visible : .pinned) }

    /// Seconds without movement before the bar hides. UI tests: never (scripts set `fsIdle=<s>` through `playerState`),
    /// so a loaded machine cannot hide the bar between two steps.
    @PerceptionIgnored public var idleTimeout: TimeInterval = ValseMotion.isStaticRun ? .infinity : defaultIdle {
        didSet { if isShown { restartTimer() } }
    }
    @PerceptionIgnored var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Runs `body` after `delay` seconds (tests: capture or ignore and call `tick()`).
    @PerceptionIgnored var schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, body in
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            body()
        }
    }
    /// Hides the cursor with the bar (off in tests: never touch the user's real cursor).
    @PerceptionIgnored var hidesCursor = !ValseMotion.isStaticRun && !TestAnchors.isEnabled
    /// Called by Esc while a drag is in progress: cancels it (true = handled, full screen stays).
    @PerceptionIgnored var cancelDrag: (() -> Bool)?

    @PerceptionIgnored private(set) var hideDeadline: TimeInterval?
    @PerceptionIgnored private var flashDeadline: TimeInterval?
    @PerceptionIgnored private var moved: CGFloat = 0
    @PerceptionIgnored private var lastPoint: CGPoint?
    @PerceptionIgnored private var active = false

    public init() {}

    // MARK: Lifecycle

    /// Full screen starts: the bar shows once (so the user sees it exists), then times out.
    func enter(voiceOver: Bool = NSWorkspace.shared.isVoiceOverEnabled) {
        active = true
        pins = voiceOver ? [.voiceOver] : []
        lastPoint = nil
        moved = 0
        show()
    }

    /// Full screen ends.
    func exit() {
        active = false
        isShown = false; isFlashing = false; pins = []
        hideDeadline = nil; flashDeadline = nil
        hoverTime = nil; hoverLabel = nil; isScrubbing = false; fineScrub = nil
        cancelDrag = nil
        thumbnails.reset()
    }

    // MARK: Events

    /// Pointer moved inside the full-screen window (window coordinates). Wakes the bar past the dead-band.
    func pointerMoved(to p: CGPoint) {
        guard active else { return }
        if let l = lastPoint { moved += hypot(p.x - l.x, p.y - l.y) }
        lastPoint = p
        if isShown {
            if moved >= Self.deadBand { moved = 0; restartTimer() }
        } else if moved >= Self.deadBand {
            moved = 0
            show()
        }
    }

    /// Pointer left the window / screen, or the window resigned key: hide at once (not while dragging).
    func pointerLeft() {
        guard active, !pins.contains(.drag) else { return }
        pins.remove(.hover)
        hoverTime = nil
        guard pins.isEmpty else { return }
        hide(idle: false)
    }

    /// A click on the picture also wakes the bar (owner Q1 = A: and plays / pauses).
    func wake() { guard active else { return }; show() }

    func pin(_ p: Pin) {
        guard active else { return }
        if !pins.contains(p) { pins.insert(p) }
        if !isShown { show() }
    }

    func unpin(_ p: Pin) {
        guard pins.contains(p) else { return }
        pins.remove(p)
        if pins.isEmpty { restartTimer() }
    }

    /// A transport key acted (Space, J/K/L, arrows, marker jumps): flash the progress line if the bar is hidden.
    func keyActed() {
        guard active, !isShown else { return }
        isFlashing = true
        flashCount += 1
        let d = now() + Self.flashDuration
        flashDeadline = d
        schedule(Self.flashDuration) { [weak self] in self?.tick() }
    }

    /// Esc: cancels a drag first (true = consumed; full screen stays).
    func handleEscape() -> Bool { isScrubbing ? (cancelDrag?() ?? false) : false }

    /// Evaluates the timers (called by the scheduler; tests call it after moving the clock).
    func tick() {
        let t = now()
        if let d = flashDeadline, t >= d - 0.001 { flashDeadline = nil; isFlashing = false }
        if isShown, pins.isEmpty, let d = hideDeadline, t >= d - 0.001 { hide(idle: true) }
    }

    // MARK: Private

    private func show() {
        if !isShown { isShown = true; showCount += 1 }
        isFlashing = false; flashDeadline = nil
        restartTimer()
    }

    private func hide(idle: Bool) {
        isShown = false
        hideDeadline = nil
        hoverTime = nil; hoverLabel = nil
        thumbnails.clear()
        moved = 0
        if idle && hidesCursor { NSCursor.setHiddenUntilMouseMoves(true) }
    }

    private func restartTimer() {
        guard idleTimeout.isFinite else { hideDeadline = nil; return }
        let d = now() + idleTimeout
        hideDeadline = d
        schedule(idleTimeout) { [weak self] in self?.tick() }
    }
}

extension PlayerUIState {
    /// Full screen of either kind: the editor's player full screen (⇧⌘F) or the detached player window in native full
    /// screen (owner Q8 = A). Both are viewing modes (owner Q1 = A).
    public var isViewingFullscreen: Bool { isFullscreen || isDetachedFullscreen }
}

extension EditorStore {
    /// Esc / ⤡ / double-click in full screen: leaves whichever full screen is on.
    public func exitViewingFullscreen() {
        if playerUI.isFullscreen { setPlayerFullscreen(false) }
        else if playerUI.isDetachedFullscreen { DetachedPanelsController.shared.leaveFullscreen(.player) }
    }

    /// Esc in full screen: cancels a seek-bar drag first, else leaves full screen.
    func fullscreenEscape() {
        if playerUI.fullscreenControls.handleEscape() { return }
        exitViewingFullscreen()
    }
}
