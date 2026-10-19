import Foundation

/// App-wide hover tooltip timing (C3-4). AppKit waits ~1–1.5 s before showing a tooltip (`.help()` in SwiftUI,
/// `toolTip` in AppKit); CapCut shows its hints after a short pause. `NSInitialToolTipDelay` (milliseconds) is read by
/// AppKit's tooltip manager for every tooltip of the process, so registering it once at launch covers the whole app.
/// It goes into the registration domain: nothing is written to the user's defaults and a user override still wins.
public enum Tooltips {
    /// Delay before a hover tooltip appears (CapCut ≈ 0.3–0.5 s).
    public static let initialDelayMilliseconds = 400
    static let defaultsKey = "NSInitialToolTipDelay"

    /// Call before `NSApplication.run()` (MontageApp/main.swift).
    public static func install(_ defaults: UserDefaults = .standard) {
        defaults.register(defaults: [defaultsKey: initialDelayMilliseconds])
    }

    /// Effective delay in milliseconds (what AppKit will use).
    public static func currentDelayMilliseconds(_ defaults: UserDefaults = .standard) -> Int {
        defaults.object(forKey: defaultsKey) == nil ? 1000 : defaults.integer(forKey: defaultsKey)
    }
}
