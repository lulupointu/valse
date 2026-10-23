import AppKit
import Perception
import MontageCore

/// SE-017 keyboard navigation between panels: View ▸ Next panel (⌥⌘]) / Previous panel (⌥⌘[) moves keyboard focus
/// Media → Player → Inspector → Timeline (in that order, skipping detached panels), draws an accent focus ring around
/// the focused panel and tells VoiceOver which panel it is. A mouse click hides the ring (focus follows the click).
@MainActor @Perceptible
public final class PanelFocus {
    public static let shared = PanelFocus()
    public static let order: [DetachablePanel] = [.assets, .player, .inspector, .timeline]

    /// Panel with the keyboard focus ring (nil = no ring).
    public private(set) var current: DetachablePanel?
    @PerceptionIgnored private var hosts: [DetachablePanel: WeakView] = [:]
    @PerceptionIgnored private var monitor: Any?

    final class WeakView { weak var view: NSView?; init(_ v: NSView) { view = v } }

    func register(_ host: NSView, for panel: DetachablePanel) { hosts[panel] = WeakView(host) }
    /// The hosting view of a panel (TL-048: clicks in the player don't close the Quick cut popover).
    func host(_ panel: DetachablePanel) -> NSView? { hosts[panel]?.view }

    /// `step` +1 = next panel, −1 = previous one.
    public func move(_ step: Int, detached: Set<DetachablePanel> = EditorLayout.shared.detached) {
        let panels = Self.order.filter { !detached.contains($0) }
        guard !panels.isEmpty else { return }
        let i = current.flatMap { panels.firstIndex(of: $0) } ?? (step > 0 ? -1 : panels.count)
        let next = panels[((i + step) % panels.count + panels.count) % panels.count]
        focus(next)
    }

    public func focus(_ p: DetachablePanel) {
        current = p
        installMonitor()
        guard let host = hosts[p]?.view, let window = host.window else { return }
        // AppKit panels (timeline / player) take the keyboard themselves; SwiftUI panels via their hosting view, from
        // where Tab walks their controls
        let inner = Self.firstView(in: host) { $0 is TimelineView || ($0.acceptsFirstResponder && $0.accessibilityIdentifier() == "player") }
        window.makeFirstResponder(inner ?? host)
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: tr("ax.panel.\(p.rawValue)"), .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    public func clear() { current = nil }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            MainActor.assumeIsolated { self?.current = nil }
            return e
        }
    }

    static func firstView(in v: NSView, where match: (NSView) -> Bool) -> NSView? {
        if match(v) { return v }
        for s in v.subviews { if let f = firstView(in: s, where: match) { return f } }
        return nil
    }
}
