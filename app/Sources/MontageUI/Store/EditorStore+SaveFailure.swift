import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Perception
import MontageCore
import MontageEngine

/// Why the project couldn't be saved, in user terms (BUG-ERROR-COPY, style guide UX.md "Error messages"): work is at
/// risk, so it is a persistent banner (not a 2.5 s toast) saying what happened, that the changes are kept while Montage
/// stays open, and the one action that helps.
public enum SaveFailure: Equatable, Sendable {
    case diskFull
    /// The project's external drive isn't connected (its name).
    case driveOffline(String)
    case other

    public static func classify(_ error: Error, url: URL) -> SaveFailure {
        if let drive = FileErrorKind.offlineVolumeName(for: url) { return .driveOffline(drive) }
        return FileErrorKind.classify(error) == .diskFull ? .diskFull : .other
    }

    public func message(project: String) -> String {
        switch self {
        case .diskFull: return tr("save.failed.diskFull", project)
        case .driveOffline(let drive): return tr("save.failed.driveOffline", project, drive)
        case .other: return tr("save.failed.other", project)
        }
    }

    /// The banner's button: free space for a full disk, else save a copy elsewhere.
    var actionKey: String { self == .diskFull ? "action.openStorageSettings" : "action.saveAs" }

    var dumpName: String {
        switch self { case .diskFull: return "diskFull"; case .driveOffline: return "driveOffline"; case .other: return "other" }
    }
}

extension EditorStore {
    func reportSaveFailure(_ error: Error, url: URL) {
        EngineLog.error("save \(url.lastPathComponent) failed: \(String(describing: error))")
        saveFailure = SaveFailure.classify(error, url: url)
    }

    public func dismissSaveFailure() { saveFailure = nil }

    /// Banner button.
    public func runSaveFailureAction() {
        guard let f = saveFailure else { return }
        if f == .diskFull { SystemSettingsPane.storage.open(); return }
        saveCopyWithPanel()
    }

    /// "Save As…": the project goes on at the chosen location (the failing one is released).
    public func saveCopyWithPanel() {
        guard !TestAnchors.isEnabled else { return }   // UI tests never open a panel
        let panel = NSSavePanel()
        panel.nameFieldStringValue = projectName + "." + ProjectPackage.fileExtension
        if let t = UTType(filenameExtension: ProjectPackage.fileExtension) { panel.allowedContentTypes = [t] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveAs(url)
    }
}

/// Top-of-editor banner shown while `store.saveFailure` is set.
struct SaveFailureBanner: View {
    let store: EditorStore
    var body: some View {
        WithPerceptionTracking {
            if let f = store.saveFailure {
                // VALSE-APP: a flat dark card (panel) with an orange 1.5 pt border: cream message 15.4:1, light-orange
                // action 6.9:1, orange warning glyph; no system red, no glow
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
                    Text(verbatim: f.message(project: store.projectName))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .testID("saveFailure.message")
                    Button { store.runSaveFailureAction() } label: {
                        Text(verbatim: tr(f.actionKey)).font(.system(size: 12, weight: .semibold)).underline()
                            .foregroundStyle(Theme.dangerText)
                    }
                    .buttonStyle(.plain).testID("saveFailure.action")
                    Button { store.dismissSaveFailure() } label: { Image(systemName: "xmark").foregroundStyle(Theme.textSecondary) }
                        .buttonStyle(.plain).help(tr("action.dismiss")).testID("saveFailure.dismiss")
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .frame(maxWidth: 560)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.danger, lineWidth: 1.5))
                .testID("saveFailure.banner")
            }
        }
    }
}
