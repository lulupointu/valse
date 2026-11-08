import AppKit

/// The window the player full screen may put into native macOS full screen (its own Space). Abstracted so the
/// enter / exit bookkeeping is unit-testable without a real window (BUG-PLAYER-FULLSCREEN-EXIT).
public protocol NativeFullscreenWindow: AnyObject {
    var isNativeFullscreen: Bool { get }
    func toggleNativeFullscreen()
}

extension NSWindow: NativeFullscreenWindow {
    public var isNativeFullscreen: Bool { styleMask.contains(.fullScreen) }
    public func toggleNativeFullscreen() { toggleFullScreen(nil) }
}

/// Player full screen (PB-006) ↔ native window full screen. Entering the player full screen also puts the window in
/// native full screen when it is not already; leaving it only undoes what it did itself, so a window that was already
/// in its own Space stays there (owner bug BUG-PLAYER-FULLSCREEN-EXIT).
/// When the user leaves native full screen themselves (green button, ⌃⌘F) while the player full screen owns it, the
/// two were one mode: the player full screen ends too. If the window was already full screen, the player keeps
/// filling the (now windowed) window until esc.
public final class PlayerFullscreenCoordinator {
    /// The player full screen put the window into native full screen and must take it out again on exit.
    public private(set) var ownsNativeFullscreen = false
    private weak var window: (any NativeFullscreenWindow)?
    private var exitObserver: NSObjectProtocol?
    /// Called when the user leaves the native full screen the player full screen had entered.
    var onNativeFullscreenLeftByUser: (() -> Void)?
    /// Tests: the window to use instead of the app's main window.
    var windowProvider: (() -> (any NativeFullscreenWindow)?)?

    public init() {}

    /// Player full screen starts. Takes the window into native full screen unless it already is.
    func enter() {
        detach()
        guard let w = windowProvider.map({ $0() }) ?? Self.appWindow() else { return }
        window = w
        if let nw = w as? NSWindow {
            exitObserver = NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification,
                                                                  object: nw, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.nativeFullscreenDidExit() }
            }
        }
        guard !w.isNativeFullscreen else { return }
        ownsNativeFullscreen = true
        w.toggleNativeFullscreen()
    }

    /// Player full screen ends. Leaves native full screen only if `enter()` entered it.
    func exit() {
        let w = window, owned = ownsNativeFullscreen
        detach()
        if owned, let w, w.isNativeFullscreen { w.toggleNativeFullscreen() }
    }

    /// The window left native full screen (our own `exit()` has already cleared `ownsNativeFullscreen`).
    func nativeFullscreenDidExit() {
        guard ownsNativeFullscreen else { return }
        ownsNativeFullscreen = false
        onNativeFullscreenLeftByUser?()
    }

    private func detach() {
        if let o = exitObserver { NotificationCenter.default.removeObserver(o) }
        exitObserver = nil
        window = nil
        ownsNativeFullscreen = false
    }

    /// The editor window, only in a regular (on-screen) app: UI tests run offscreen as an accessory app and never
    /// touch native full screen.
    private static func appWindow() -> NSWindow? {
        guard NSApp.activationPolicy() == .regular,
              let w = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }), w.isVisible else { return nil }
        return w
    }
}
