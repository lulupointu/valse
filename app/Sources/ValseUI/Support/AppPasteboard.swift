import AppKit
import ValseCore

/// The pasteboard copy / paste uses: the system one normally; in a UI-test process (AppDefaults isolated, `--uitest`)
/// a private named pasteboard, so concurrent test apps never paste each other's clips and never clobber the user's
/// clipboard.
@MainActor
public enum AppPasteboard {
    public static let general: NSPasteboard = AppDefaults.processSuffix.isEmpty
        ? .general : NSPasteboard(name: .init("valse.uitest.pasteboard" + AppDefaults.processSuffix))
}
