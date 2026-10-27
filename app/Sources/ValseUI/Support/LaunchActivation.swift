import AppKit

/// How the app process is activated at launch (main.swift). Pure decision, unit-tested (LaunchActivationTests).
///
/// VALSE-HOME bug 1 (also on main): a normal launch (`open`, Finder, Dock) showed the window but left the previous app
/// active (menu bar kept its name, first click only activated). main.swift called `setActivationPolicy(.regular)` on
/// every launch BEFORE `NSApp.run()`, i.e. after LaunchServices had checked the process in with "come forward at
/// registration" and before `finishLaunching` performs that launch activation. Changing the activation policy in that
/// window is the documented trap (activation / menu bar not taken until the user switches apps; FB7743313, Eclipse SWT
/// 552063 / 570428), and under macOS 14+ cooperative activation the later `NSApp.activate()` is only a request the
/// system may refuse once the launch activation was lost. A bundled app is already `.regular` from its Info.plist (no
/// `LSUIElement`), so the call was redundant: now normal bundled launches never touch the policy; only headless runs set
/// `.accessory` (before `run`, so they never get a Dock icon or activation) and the unbundled `swift build` binary,
/// which has no Info.plist, becomes `.regular` once launching has finished.
public enum LaunchActivation {
    public enum Policy: Equatable, Sendable { case regular, accessory }

    public struct Plan: Equatable, Sendable {
        /// Set before `NSApp.run()` (nil = leave the Info.plist policy alone).
        public var policyBeforeRun: Policy?
        /// Set in `applicationDidFinishLaunching`, before the window is shown (nil = none).
        public var policyAfterLaunch: Policy?
        /// Bring the window front, make it key and activate the app.
        public var activates: Bool
    }

    /// Runs that must never take focus on the shared machine: UI tests, screenshots, offscreen windows, demo libraries.
    public static let headlessFlags: Set<String> = ["--uitest", "--background", "--snapshot", "--offscreen", "--home-demo"]

    public static func isHeadless(_ arguments: [String]) -> Bool { arguments.dropFirst().contains(where: headlessFlags.contains) }

    public static func plan(arguments: [String], isAppBundle: Bool) -> Plan {
        if isHeadless(arguments) { return Plan(policyBeforeRun: .accessory, policyAfterLaunch: nil, activates: false) }
        return Plan(policyBeforeRun: nil, policyAfterLaunch: isAppBundle ? nil : .regular, activates: true)
    }

    @MainActor public static var current: Plan {
        plan(arguments: CommandLine.arguments, isAppBundle: Bundle.main.bundleURL.pathExtension == "app")
    }

    /// Makes `window` key and front and asks for activation (cooperative `activate()` on macOS 14+: honoured at launch,
    /// when the launching app / LaunchServices yields to us).
    @MainActor public static func activate(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
    }
}

extension LaunchActivation.Policy {
    public var appKit: NSApplication.ActivationPolicy { self == .regular ? .regular : .accessory }
}
