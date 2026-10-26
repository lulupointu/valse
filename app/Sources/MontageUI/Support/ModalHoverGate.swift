import AppKit
import SwiftUI

/// FB-07: an in-window modal (Settings and the other app dialogs, export, crop, cover, recorder) owns the pointer.
///
/// AppKit tracking areas keep firing for views covered by SwiftUI content (they are not hit-tested), so while a dialog
/// is up the timeline, canvas and splitters underneath kept switching the cursor (resize, pointing hand, blade) and the
/// editor's tooltips popped up under the dialog. General rule instead of per-view fixes:
/// - a modal marks its card with `.modalHoverShield()`; while one is on screen, only points inside the topmost card may
///   change the cursor or show a tooltip (`ModalHoverGate.isBlocked(_:in:)`);
/// - cursor code calls `NSCursor.setUnlessCovered(at:in:)` (or guards its hover handler with `isBlocked`);
/// - `TooltipCenter` ignores anchors outside the card;
/// - safety net for anything else (AppKit cursor rects of covered text fields…): while a shield is up, a mouse move
///   outside the card resets the arrow after AppKit has dispatched the event.
@MainActor
enum ModalHoverGate {
    private static let shields = NSHashTable<ModalShieldView>.weakObjects()
    private static var order: [ObjectIdentifier] = []
    private static var monitor: Any?

    /// Topmost shield (last registered) in `window`; any window when nil.
    static func activeShield(in window: NSWindow?) -> ModalShieldView? {
        let live = shields.allObjects.filter { $0.window != nil && (window == nil || $0.window === window) }
        return order.reversed().lazy.compactMap { id in live.first { ObjectIdentifier($0) == id } }.first
    }

    /// Whether a modal is up in `window` (state dump / tests).
    static func isActive(in window: NSWindow? = nil) -> Bool { activeShield(in: window) != nil }

    /// True when a modal card covers the window and `point` (window coordinates) is outside it; nil point = blocked
    /// whenever a modal is up.
    static func isBlocked(_ point: CGPoint?, in window: NSWindow?) -> Bool {
        guard let s = activeShield(in: window) else { return false }
        guard let point, let r = s.windowRect else { return true }
        return !r.contains(point)
    }

    static func register(_ s: ModalShieldView) {
        shields.add(s)
        order.removeAll { $0 == ObjectIdentifier(s) }
        order.append(ObjectIdentifier(s))
        installMonitor()
        NSCursor.arrow.set()   // drop a resize / hand cursor set by the view now covered
        TooltipCenter.shared.modalDidAppear()
        HoverReset.post("modal")   // views now covered never get their exit (HoverReset)
    }

    static func unregister(_ s: ModalShieldView) {
        shields.remove(s)
        order.removeAll { $0 == ObjectIdentifier(s) }
        let alive = Set(shields.allObjects.map(ObjectIdentifier.init))
        order.removeAll { !alive.contains($0) }
    }

    private static func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .cursorUpdate]) { e in
            MainActor.assumeIsolated {
                if ModalHoverGate.isBlocked(e.locationInWindow, in: e.window) {
                    // after AppKit dispatched the event (tracking areas, cursor rects of the covered views)
                    DispatchQueue.main.async { if ModalHoverGate.isActive() { NSCursor.arrow.set() } }
                }
            }
            return e
        }
    }
}

extension NSCursor {
    /// FB-07: `set()` unless an in-window modal covers `point` (window coordinates; nil = anywhere).
    @MainActor func setUnlessCovered(at point: CGPoint?, in window: NSWindow?) {
        guard !ModalHoverGate.isBlocked(point, in: window) else { return }
        set()
    }
}

/// Invisible view behind a modal card: its frame is the card, it registers with `ModalHoverGate` while in a window.
final class ModalShieldView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { ModalHoverGate.register(self) } else { ModalHoverGate.unregister(self) }
    }

    /// Card rect in window coordinates (nil when not in a window).
    var windowRect: CGRect? {
        guard window != nil, !isHiddenOrHasHiddenAncestor else { return nil }
        return convert(bounds, to: nil)
    }
}

struct ModalShield: NSViewRepresentable {
    func makeNSView(context: Context) -> ModalShieldView { ModalShieldView() }
    func updateNSView(_ v: ModalShieldView, context: Context) {}
    static func dismantleNSView(_ v: ModalShieldView, coordinator: ()) { ModalHoverGate.unregister(v) }
}

extension View {
    /// FB-07: this view is a modal card: while it is on screen, the views it covers stop changing the cursor and
    /// showing tooltips (see `ModalHoverGate`).
    func modalHoverShield() -> some View {
        background(ModalShield().allowsHitTesting(false).accessibilityHidden(true))
    }
}
