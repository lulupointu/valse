import AppKit
import ValseCore
import ValseEngine

/// System Settings panes error messages send the user to (BUG-ERROR-COPY, style guide UX.md "Error messages"):
/// the button opens the pane, the text explains why. UI tests never open another app: the request is recorded in
/// `lastRequested` (state dump `ui.systemSettings`) instead.
public enum SystemSettingsPane: String, Sendable {
    case storage

    var url: URL {
        switch self {
        case .storage: return URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!
        }
    }

    @MainActor public static var lastRequested: SystemSettingsPane?

    @MainActor public func open() {
        Self.lastRequested = self
        guard !TestAnchors.isEnabled else { return }
        NSWorkspace.shared.open(url)
    }
}

/// "Copy Details" of an error (export row, …): the technical detail goes to the pasteboard (and the log), never into
/// the message itself.
@MainActor
enum ErrorDetails {
    static func copy(_ detail: String) {
        let info = ProcessInfo.processInfo
        let text = detail + "\nmacOS " + info.operatingSystemVersionString
            + "\nValse " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
        AppPasteboard.general.clearContents()
        AppPasteboard.general.setString(text, forType: .string)
    }
}
