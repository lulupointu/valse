import AppKit
import ValseCore

/// PM-014: several projects open at once, one per window. Each window is its own Valse instance (own editor, playback
/// engine and undo history — no shared state to corrupt), so File ▸ New Window / Open in New Window launch another
/// instance; a project already open in another window is brought forward instead of opened twice (`SessionLock`).
@MainActor
public enum ProjectWindows {
    /// Launch requests (nil = Home). UI tests record them instead of starting processes.
    public static var launched: [String] = []
    /// Replaced in UI tests (records instead of launching). Returns false if the launch failed.
    public static var launcher: @MainActor (URL?) -> Bool = launchInstance

    /// Starts another Valse instance on Home (`nil`) or on a project.
    @discardableResult
    public static func open(_ url: URL?) -> Bool {
        launched.append(url?.path ?? "")
        if TestAnchors.isEnabled { return true }
        return launcher(url)
    }

    /// Arguments of the new instance.
    public static func arguments(for url: URL?) -> [String] { url.map { ["--open", $0.path] } ?? [] }

    static func launchInstance(_ url: URL?) -> Bool {
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            let c = NSWorkspace.OpenConfiguration()
            c.createsNewApplicationInstance = true
            c.arguments = arguments(for: url)
            c.activates = true
            NSWorkspace.shared.openApplication(at: bundle, configuration: c) { _, _ in }
            return true
        }
        // development binary (swift build): start the executable directly
        guard let exe = Bundle.main.executableURL else { return false }
        let p = Process()
        p.executableURL = exe
        p.arguments = arguments(for: url)
        return (try? p.run()) != nil
    }

    /// Brings the instance holding `url` to the front. True when another live Valse instance holds it.
    public static func focusHolder(of url: URL) -> Bool {
        guard let pid = SessionLock.holderPID(url) else { return false }
        if !TestAnchors.isEnabled { NSRunningApplication(processIdentifier: pid)?.activate() }
        return true
    }
}
