import SwiftUI
import MontageCore

/// PM-009 external-drive warnings: the Save-to folder on an external / network drive, or on a drive that isn't connected.
enum StorageWarningText {
    static let warningColor = Color(hex: 0xE8A93C)

    /// Settings ▸ Project ▸ Save to line (nil = internal disk, no warning).
    static func settingsLine(_ l: StorageLocation) -> String? {
        switch l {
        case .internalDisk: return nil
        case .external(let n): return tr("pm.drive.external", n)
        case .network(let n): return tr("pm.drive.network", n)
        case .unavailable(let n): return tr("pm.drive.unavailable", n, (MontagePaths.defaultDraftsDirectory.path as NSString).abbreviatingWithTildeInPath)
        }
    }
}

/// Orange warning line under a path setting.
struct StorageWarningLine: View {
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "externaldrive.badge.exclamationmark").font(.system(size: 11, weight: .semibold))
                .accessibilityHidden(true)
            Text(verbatim: text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(StorageWarningText.warningColor)
        .accessibilityElement(children: .combine)
        .testID("settings.saveTo.warning")
    }
}

/// Home banner while the Save-to folder's drive is disconnected (new projects go to the default folder meanwhile).
struct SaveFolderBanner: View {
    @Bindable var app: AppModel
    var body: some View {
        if case .unavailable(let name)? = app.saveFolderWarning {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.badge.xmark").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(StorageWarningText.warningColor).accessibilityHidden(true)
                Text(verbatim: tr("pm.drive.banner", name, (MontagePaths.defaultDraftsDirectory.path as NSString).abbreviatingWithTildeInPath))
                    .font(.system(size: 12)).foregroundStyle(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(tr("pm.drive.openSettings")) { app.modal = .settings(.project) }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
                    .testID("home.driveBanner.settings")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(StorageWarningText.warningColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(StorageWarningText.warningColor.opacity(0.45), lineWidth: 1))
            .accessibilityElement(children: .contain)
            .testID("home.driveBanner")
        }
    }
}
