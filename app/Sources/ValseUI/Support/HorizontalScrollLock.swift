import AppKit
import SwiftUI

extension View {
    /// U1-2 (owner: "Settings: we can scroll left to right everywhere"): put inside a vertical `ScrollView`'s content.
    /// The enclosing AppKit scroll view gets no sideways rubber-band and no horizontal scroller, and any horizontal
    /// offset (a trackpad swipe, a momentarily wider layout while the dialog switches tabs) snaps back to 0, so the
    /// content only ever moves up / down. The content itself must fit the width (wrap / truncate).
    func lockHorizontalScroll() -> some View {
        background(HorizontalScrollLock().allowsHitTesting(false).accessibilityHidden(true))
    }
}

struct HorizontalScrollLock: NSViewRepresentable {
    func makeNSView(context: Context) -> HorizontalScrollLockView { HorizontalScrollLockView() }
    func updateNSView(_ v: HorizontalScrollLockView, context: Context) { v.attach() }
}

final class HorizontalScrollLockView: NSView {
    private weak var scrollView: NSScrollView?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach() }

    func attach() {
        guard let sv = enclosingScrollView, sv !== scrollView else { return }
        if let old = scrollView { NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: old.contentView) }
        scrollView = sv
        Self.lock(sv)
        sv.contentView.postsBoundsChangedNotifications = true
        // selector-based: removed automatically when this view goes away
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification,
                                               object: sv.contentView)
    }

    @objc private func boundsChanged(_ n: Notification) { if let sv = scrollView { Self.clamp(sv) } }

    static func lock(_ sv: NSScrollView) {
        sv.horizontalScrollElasticity = .none
        sv.hasHorizontalScroller = false
        clamp(sv)
    }

    private static var clamping = false
    /// Back to x = 0 when the clip view moved sideways by more than a point (keeps the vertical position). SwiftUI's
    /// scroll view rests a hair off 0 (−0.01 pt after a swipe) and re-commits its own offset on every bounds change:
    /// below a point it is left alone, and the re-entrant notification is ignored (fighting it recursed forever).
    static func clamp(_ sv: NSScrollView) {
        let clip = sv.contentView
        guard !clamping, abs(clip.bounds.origin.x) > 1 else { return }
        clamping = true
        defer { clamping = false }
        clip.setBoundsOrigin(CGPoint(x: 0, y: clip.bounds.origin.y))
        sv.reflectScrolledClipView(clip)
    }
}
