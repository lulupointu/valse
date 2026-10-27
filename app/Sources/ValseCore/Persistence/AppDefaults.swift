import Foundation

/// The UserDefaults every app setting is read from / written to (language preference, recent fonts, layout, export
/// choices, remembered folders…). Normally `UserDefaults.standard`. A UI-test process (`--uitest`, ValseApp/main.swift
/// calls `isolateForUITest()` first thing) gets a PRIVATE, empty per-process domain instead, so test apps running at
/// the same time (scripts/uitest.sh `--jobs`, other checkouts' runs) or one after another never see each other's
/// settings, and never touch the user's. The argument domain (`-key value`, volatile overrides set by the driver /
/// HomeSandbox) is still searched first, as with `.standard`. AppKit's own keys (e.g. `NSInitialToolTipDelay`) stay on
/// `.standard`: AppKit reads them there.
public enum AppDefaults {
    public nonisolated(unsafe) private(set) static var store: UserDefaults = .standard
    /// Suffix that makes a UI-test suite name private to this process ("" outside UI tests).
    public nonisolated(unsafe) private(set) static var processSuffix = ""

    /// Prefix of every per-process UI-test domain; scripts/uitest.sh deletes `<prefix>*.<pid>.plist` after each app.
    public static let uitestDomainPrefix = "valse.uitest."

    public static func isolateForUITest() {
        processSuffix = ".\(ProcessInfo.processInfo.processIdentifier)"
        store = suite("valse.uitest.app")
    }

    /// A fresh (emptied) suite named `<name>.<pid>` in a UI-test process, `<name>` otherwise.
    public static func suite(_ name: String) -> UserDefaults {
        let full = name + processSuffix
        UserDefaults.standard.removePersistentDomain(forName: full)
        return UserDefaults(suiteName: full) ?? .standard
    }
}
