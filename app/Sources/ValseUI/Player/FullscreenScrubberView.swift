import AppKit
import SwiftUI
import Perception
import ValseCore
import ValseEngine

/// What the full-screen seek bar spans (PB-006b §7): the timeline being played (inside a compound: the compound's own
/// timeline, owner Q5 = A), or the library item during a preview (its own range, no markers).
@MainActor
struct ScrubSource {
    var duration: Time
    var now: Time
    var rate: FrameRate
    var markers: [Marker]
    var inPoint: Time?
    var outPoint: Time?
    var loop: TimeRange?
    var snapping: Bool
    var isPreview: Bool
    var previewStart: Time

    init(_ store: EditorStore) {
        let ui = store.playerUI
        rate = store.projectSettings.frameRate
        if let pv = ui.preview {
            duration = pv.range.duration
            now = (ui.previewTime - pv.range.start).clamped(.zero, pv.range.duration)
            markers = []; inPoint = nil; outPoint = nil; loop = nil; snapping = false
            isPreview = true; previewStart = pv.range.start
        } else {
            let tl = store.project.timeline
            duration = store.projectDuration
            now = store.transport.playhead
            markers = tl.markers.sorted { $0.time < $1.time }
            inPoint = tl.inPoint; outPoint = tl.outPoint
            loop = ui.loopEnabled ? store.engine.loopRange : nil
            snapping = tl.snapping
            isPreview = false; previewStart = .zero
        }
    }

    /// Seeks the player (the preview's own playhead during a library preview: `store.seek` would end the preview).
    func seek(_ store: EditorStore, _ t: Time, exact: Bool) {
        if isPreview { store.engine.seek(to: previewStart + t, exact: exact) } else { store.seek(to: t, exact: exact) }
    }

    var snapTargets: [Time] { markers.map(\.time) + [inPoint, outPoint].compactMap { $0 } + [.zero, duration] }
}

/// The seek bar (spec §3, §5.1): AppKit for precise mouse-down / drag / up with ⌥ / ⌘ flags, scroll events and the AX
/// slider; drawn with Core Graphics. The view is 32 pt tall: 4 pt above + a 28 pt hit row centred on the track.
final class FullscreenScrubberView: NSView {
    static let height: CGFloat = 32
    static let trackY: CGFloat = 18
    static let cream = NSColor(srgbRed: 0xF3 / 255.0, green: 0xE9 / 255.0, blue: 0xC8 / 255.0, alpha: 1)
    static let teal = NSColor(srgbRed: 0x2B / 255.0, green: 0xAF / 255.0, blue: 0x90 / 255.0, alpha: 1)
    static let mint = NSColor(srgbRed: 0xA1 / 255.0, green: 0xD4 / 255.0, blue: 0xB1 / 255.0, alpha: 1)

    let store: EditorStore
    private var model: FullscreenControlsModel { store.playerUI.fullscreenControls }
    private var observing = false
    private var monitor: Any?
    private(set) var hovering = false
    private var stepper = ScrollFrameStepper()

    // drag state
    private var drag: ScrubDrag?
    private var dragStart: CGPoint = .zero
    private var moved = false
    private var wasPlaying = false
    private var timeBefore: Time = .zero
    private var cancelled = false
    private var requested: Time?
    private var snapped = false

    init(store: EditorStore) {
        self.store = store
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel(tr("fullscreen.scrubber"))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Hidden bar = not hit-testable (clicks reach the picture).
    override func hitTest(_ point: NSPoint) -> NSView? { model.isShown && !store.isPlayerEmpty ? super.hitTest(point) : nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        guard window != nil else { return }
        if !observing { observing = true; store.observe { [weak self] in self?.observeState() } }
        // hover: every pointer move in the window (the bar's own tracking would miss moves while SwiftUI owns the
        // pointer; UI tests deliver moves to the hit view only)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] e in
            if let self, e.window === self.window { self.pointerMoved(self.convert(e.locationInWindow, from: nil)) }
            return e
        }
    }

    override func removeFromSuperview() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        super.removeFromSuperview()
    }

    private func observeState() {
        let ui = store.playerUI
        _ = (store.transport.playhead, store.projectDuration, ui.preview, ui.previewTime, ui.loopEnabled, model.isShown)
        if ui.preview == nil { _ = (store.project.timeline.markers, store.project.timeline.inPoint, store.project.timeline.outPoint) }
        needsDisplay = true
        setAccessibilityValue(Timecode.display(ScrubSource(store).now, rate: store.projectSettings.frameRate))
    }

    private var track: ScrubTrack {
        let s = ScrubSource(store)
        return ScrubTrack(width: bounds.width, duration: s.duration, rate: s.rate)
    }

    // MARK: Hover

    private func pointerMoved(_ p: CGPoint) {
        guard drag == nil else { return }
        let inside = model.isShown && !store.isPlayerEmpty && bounds.contains(p) && !isHiddenOrHasHiddenAncestor
        if inside { hover(at: p.x) } else if hovering { endHover() }
    }

    private func hover(at x: CGFloat) {
        hovering = true
        let s = ScrubSource(store), tr = ScrubTrack(width: bounds.width, duration: s.duration, rate: s.rate)
        let t = tr.time(atX: x)
        model.hoverX = min(max(x, 0), bounds.width)
        model.hoverTime = t
        model.hoverLabel = label(s, tr, x: x)
        if s.isPreview { model.thumbnails.clear() }
        else { model.thumbnails.request(project: store.project, revision: store.session.revision, at: t) }
        needsDisplay = true
    }

    private func endHover() {
        hovering = false
        model.hoverTime = nil; model.hoverLabel = nil
        model.thumbnails.clear()
        needsDisplay = true
    }

    /// Marker names under the pointer (merged ticks list every label).
    private func label(_ s: ScrubSource, _ tr: ScrubTrack, x: CGFloat) -> String? {
        let names = tr.near(s.markers.map(\.time), x: x).map { s.markers[$0].label }.filter { !$0.isEmpty }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    // MARK: Drag (spec §5.1: jump on press, hold playback while dragging, resume on release, esc cancels)

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let s = ScrubSource(store), tr = ScrubTrack(width: bounds.width, duration: s.duration, rate: s.rate)
        guard s.duration > .zero else { return }
        wasPlaying = store.engine.isPlaying
        timeBefore = s.now
        moved = false; cancelled = false; snapped = false
        dragStart = p
        var d = ScrubDrag(x: p.x, track: tr)
        _ = d.update(x: p.x, distanceAbove: Self.trackY - p.y, option: e.modifierFlags.contains(.option), track: tr)
        drag = d
        requested = d.time
        s.seek(store, d.time, exact: false)
        if !s.isPreview { store.scrubAudio(at: d.time) }
        model.isScrubbing = true
        model.pin(.drag)
        model.cancelDrag = { [weak self] in self?.cancelDrag() ?? false }
        model.thumbnails.clear()
        showDragTooltip(d, tr, s)
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        guard var d = drag, !cancelled else { return }
        let p = convert(e.locationInWindow, from: nil)
        if !moved, hypot(p.x - dragStart.x, p.y - dragStart.y) >= 3 {
            moved = true
            if wasPlaying { store.engine.pause() }   // hold playback under the pointer
        }
        let s = ScrubSource(store), tr = ScrubTrack(width: bounds.width, duration: s.duration, rate: s.rate)
        let snapOn = s.snapping && !e.modifierFlags.contains(.command)
        let r = d.update(x: p.x, distanceAbove: Self.trackY - p.y, option: e.modifierFlags.contains(.option), track: tr,
                         snapTargets: snapOn ? s.snapTargets : [])
        drag = d
        snapped = r.snapped
        if r.time != requested {
            requested = r.time
            s.seek(store, r.time, exact: false)
            if !s.isPreview { store.scrubAudio(at: r.time) }
        }
        showDragTooltip(d, tr, s)
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        defer { endDrag() }
        guard let d = drag, !cancelled else { return }
        let s = ScrubSource(store)
        s.seek(store, d.time, exact: true)
        if moved && wasPlaying { store.engine.play() }
    }

    /// Esc during a drag: back to the time and play state from before the press; full screen stays.
    func cancelDrag() -> Bool {
        guard drag != nil, !cancelled else { return false }
        cancelled = true
        let s = ScrubSource(store)
        s.seek(store, timeBefore, exact: true)
        if moved && wasPlaying { store.engine.play() }
        model.isScrubbing = false
        model.fineScrub = nil
        model.unpin(.drag)
        model.hoverTime = nil
        needsDisplay = true
        return true
    }

    private func endDrag() {
        drag = nil; requested = nil; snapped = false
        model.isScrubbing = false
        model.fineScrub = nil
        model.cancelDrag = nil
        model.unpin(.drag)
        model.hoverTime = nil
        cancelled = false
        let p = window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) }
        if let p, bounds.contains(p), !TestAnchors.isEnabled {
            hover(at: p.x)
        } else {
            hovering = false
        }
        needsDisplay = true
    }

    private func showDragTooltip(_ d: ScrubDrag, _ tr: ScrubTrack, _ s: ScrubSource) {
        let x = tr.x(of: d.time)
        model.hoverX = x
        model.hoverTime = d.time
        model.hoverLabel = label(s, tr, x: x)
        model.fineScrub = d.label
    }

    // MARK: Scroll: two-finger swipe / wheel over the bar steps frames (owner Q4)

    override func scrollWheel(with e: NSEvent) {
        if e.phase == .began || e.phase == .ended { stepper.reset() }
        let n = stepper.frames(dx: e.scrollingDeltaX, dy: e.scrollingDeltaY, precise: e.hasPreciseScrollingDeltas)
        guard n != 0, ScrubSource(store).duration > .zero else { return }
        store.engine.step(frames: n)
        model.wake()   // keeps the bar up while swiping
    }

    // MARK: Accessibility (VoiceOver: ±1 s)

    override func accessibilityPerformIncrement() -> Bool { nudge(1) }
    override func accessibilityPerformDecrement() -> Bool { nudge(-1) }

    private func nudge(_ seconds: Double) -> Bool {
        let s = ScrubSource(store), tr = ScrubTrack(width: bounds.width, duration: s.duration, rate: s.rate)
        guard s.duration > .zero else { return false }
        s.seek(store, tr.clamp(s.now + Time(seconds: seconds)), exact: true)
        return true
    }

    // MARK: Drawing (spec §3.1-3.2)

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let s = ScrubSource(store), tr = ScrubTrack(width: bounds.width, duration: s.duration, rate: s.rate)
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let active = hovering || drag != nil
        let h: CGFloat = active ? 6 : 4
        let cy = Self.trackY
        let w = bounds.width
        let now = drag.map { _ in requested ?? s.now } ?? s.now   // the knob shows the requested time, not the presented one
        let kx = tr.x(of: now)

        func bar(_ x0: CGFloat, _ x1: CGFloat, _ color: NSColor) {
            guard x1 > x0 else { return }
            ctx.setFillColor(color.cgColor)
            ctx.addPath(CGPath(roundedRect: CGRect(x: x0, y: cy - h / 2, width: x1 - x0, height: h), cornerWidth: min(h / 2, (x1 - x0) / 2),
                               cornerHeight: h / 2, transform: nil))
            ctx.fillPath()
        }
        bar(0, w, NSColor.white.withAlphaComponent(contrast ? 0.4 : 0.25))
        if hovering, drag == nil, let ht = model.hoverTime {
            let hx = tr.x(of: ht)
            bar(min(kx, hx), max(kx, hx), NSColor.white.withAlphaComponent(0.45))
        }
        bar(0, kx, Self.cream.withAlphaComponent(0.95))

        // in / out band above the track
        if s.inPoint != nil || s.outPoint != nil {
            let a = tr.x(of: s.inPoint ?? .zero), b = tr.x(of: s.outPoint ?? s.duration)
            let y = cy - h / 2 - 4
            ctx.setFillColor(Self.teal.withAlphaComponent(0.35).cgColor)
            ctx.fill(CGRect(x: a, y: y, width: max(0, b - a), height: 2))
            ctx.setFillColor(Self.teal.cgColor)
            if s.inPoint != nil { ctx.fill(CGRect(x: a, y: y - 3, width: 1, height: 8)) }
            if s.outPoint != nil { ctx.fill(CGRect(x: b - 1, y: y - 3, width: 1, height: 8)) }
        }
        // loop range (when it is not the whole bar): dashed mint line under the track
        if let l = s.loop, l.start > .zero || l.end < s.duration {
            ctx.saveGState()
            ctx.setStrokeColor(Self.mint.cgColor); ctx.setLineWidth(1); ctx.setLineDash(phase: 0, lengths: [3, 2])
            let y = cy + h / 2 + 3.5
            ctx.strokeLineSegments(between: [CGPoint(x: tr.x(of: l.start), y: y), CGPoint(x: tr.x(of: l.end), y: y)])
            ctx.restoreGState()
        }
        // markers: 2 pt ticks in their own colour (ticks closer than 2 pt land on the same pixels = merged)
        let mh = h + 4
        for m in s.markers {
            let x = (tr.x(of: m.time) - 1).rounded()
            ctx.setFillColor(NSColor(srgbRed: m.color.r, green: m.color.g, blue: m.color.b, alpha: 1).cgColor)
            ctx.fill(CGRect(x: min(max(x, 0), w - 2), y: cy - mh / 2, width: 2, height: mh))
        }
        // knob = the playhead (cream), on hover / drag only
        if active {
            let r: CGFloat = drag != nil ? 7 : 6
            if snapped {
                ctx.setFillColor(Self.teal.cgColor)
                ctx.fill(CGRect(x: kx - 0.5, y: cy - r - 6, width: 1, height: 4))
            }
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 2, color: NSColor.black.withAlphaComponent(0.4).cgColor)
            ctx.setFillColor(Self.cream.cgColor)
            ctx.fillEllipse(in: CGRect(x: kx - r, y: cy - r, width: 2 * r, height: 2 * r))
            ctx.restoreGState()
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.25).cgColor)
            ctx.setLineWidth(1)
            ctx.strokeEllipse(in: CGRect(x: kx - r + 0.5, y: cy - r + 0.5, width: 2 * r - 1, height: 2 * r - 1))
        }
    }
}

/// SwiftUI host of the seek bar.
struct FullscreenScrubber: NSViewRepresentable {
    let store: EditorStore
    func makeNSView(context: Context) -> FullscreenScrubberView { FullscreenScrubberView(store: store) }
    func updateNSView(_ v: FullscreenScrubberView, context: Context) { v.needsDisplay = true }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FullscreenScrubberView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 100, height: FullscreenScrubberView.height)
    }
}

/// Full-window input layer over the picture in full screen (owner Q1 = A): a click plays / pauses, a double-click leaves
/// full screen, nothing reaches the canvas (no selection / handles). Also the pointer source of the visibility model:
/// moves wake the bar, the bottom 96 pt (scrubber + control row + 8 pt) pin it, leaving the window hides it at once.
final class FullscreenInputView: NSView {
    /// Height of the bottom region that pins the bar while the pointer is in it.
    static let pinHeight: CGFloat = 96

    let store: EditorStore
    private var model: FullscreenControlsModel { store.playerUI.fullscreenControls }
    private var monitor: Any?
    private var tracking: NSTrackingArea?
    private var resignObserver: NSObjectProtocol?

    init(store: EditorStore) {
        self.store = store
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        teardown()
        guard let w = window else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] e in
            if let self, e.window === self.window { self.pointer(self.convert(e.locationInWindow, from: nil), in: e.locationInWindow) }
            return e
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if !TestAnchors.isEnabled { self?.model.pointerLeft() } }
        }
    }

    override func removeFromSuperview() { teardown(); super.removeFromSuperview() }

    private func teardown() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        if let o = resignObserver { NotificationCenter.default.removeObserver(o); resignObserver = nil }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        // .activeAlways: moves must wake the bar even when the window is not key (second display)
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    private func pointer(_ p: CGPoint, in windowPoint: CGPoint) {
        model.pointerMoved(to: windowPoint)
        if model.isShown, bounds.contains(p), p.y >= bounds.height - Self.pinHeight { model.pin(.hover) } else { model.unpin(.hover) }
    }

    override func mouseMoved(with e: NSEvent) {}   // handled by the monitor (sees moves over the SwiftUI bar too)
    override func mouseExited(with e: NSEvent) { model.pointerLeft() }

    override func mouseDown(with e: NSEvent) {
        guard !store.isPlayerEmpty else { model.wake(); return }
        model.wake()
        if e.clickCount >= 2 {
            store.togglePlay()   // undo the first click's play / pause (YouTube), then leave
            store.exitViewingFullscreen()
        } else {
            store.togglePlay()
        }
    }

    override func rightMouseDown(with e: NSEvent) { model.wake() }
    override func menu(for event: NSEvent) -> NSMenu? { nil }
}

struct FullscreenInput: NSViewRepresentable {
    let store: EditorStore
    func makeNSView(context: Context) -> FullscreenInputView {
        let v = FullscreenInputView(store: store)
        v.setAccessibilityIdentifier("fullscreen.picture")
        return v
    }
    func updateNSView(_ v: FullscreenInputView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FullscreenInputView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 10, height: 10))
    }
}
