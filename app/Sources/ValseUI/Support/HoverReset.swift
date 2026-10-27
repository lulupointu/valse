import AppKit

/// App-wide "every hover is over" signal for SwiftUI hover state (`.valseHover`, Home).
///
/// AppKit only sends a tracking area's exit when the pointer moves out of it while the app gets mouse events. These
/// cases never deliver one, so a hover flag set on enter stayed true (a lifted card / spun "+" after the pointer had
/// gone): the app or window deactivating mid-hover (another app, an open panel), a menu's tracking loop (context menu,
/// "…" menu) swallowing the moves, content scrolling under a still pointer, an in-window modal covering the view.
/// Each posts this reset; hover handlers drop to false and the next real pointer move re-asserts the truth
/// (`onContinuousHover` reports every move inside), so hover state converges whatever the event order.
@MainActor
public enum HoverReset {
    public static let notification = Notification.Name("ValseHoverReset")
    /// Number of resets posted (tests).
    public private(set) static var generation = 0
    private static var installed = false
    private static var scrollMonitor: Any?

    public static func post(_ reason: String) {
        generation += 1
        NotificationCenter.default.post(name: notification, object: nil, userInfo: ["reason": reason])
    }

    /// Idempotent; called by the first hover tracker that appears.
    public static func install() {
        guard !installed else { return }
        installed = true
        let nc = NotificationCenter.default
        let sources: [(Notification.Name, String)] = [
            (NSApplication.didResignActiveNotification, "app.resignActive"),
            (NSWindow.didResignKeyNotification, "window.resignKey"),
            // end, not begin: the "…" menu button lives on the hovered card and must stay while its menu is open
            (NSMenu.didEndTrackingNotification, "menu.endTracking"),
        ]
        for (name, reason) in sources {
            nc.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated { post(reason) } }
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
            MainActor.assumeIsolated { post("scroll") }
            return e
        }
    }
}
