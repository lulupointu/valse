import SwiftUI
import MontageCore
import Perception

/// Settings ▸ About: "Keep Montage up to date" switch (SE-015).
struct AutoUpdateSettings: View {
    let updates: UpdateController
    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 10) {
                SwitchButton(isOn: Binding.perceived(get: { updates.automaticallyChecks }, set: { updates.automaticallyChecks = $0 }),
                             id: "autoUpdate", label: tr("about.updates.auto"))
                Text(loc: "about.updates.auto").font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary)
            }
        }
    }
}

/// Settings ▸ About: what the updater is doing (inline result of "Check now").
struct UpdateStatusLine: View {
    let updates: UpdateController
    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 8) {
                switch updates.state {
                case .ready(let v):
                    Text(verbatim: tr("about.updates.ready", v)).font(Theme.Fonts.hint).foregroundStyle(Theme.textSecondary)
                    Button(tr("update.restart")) { updates.installNow() }
                        .buttonStyle(.plain).font(Theme.Fonts.hint).foregroundStyle(Theme.accent).testID("about.updates.restart")
                default:
                    Text(verbatim: text).font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary)
                }
            }
            .testID("about.updates.status")
        }
    }

    var text: String {
        switch updates.state {
        case .checking: return tr("about.updates.checking")
        case .downloading(let v, let p): return p.map { tr("about.updates.downloadingPct", v, Int(($0 * 100).rounded())) } ?? tr("about.updates.downloading", v)
        case .failed(let m): return tr("about.updates.failed", m)
        case .upToDate: return tr("about.updates.upToDate") + lastChecked
        case .idle, .ready: return tr(updates.automaticallyChecks ? "about.updates.autoHint" : "about.updates.offHint") + lastChecked
        }
    }

    var lastChecked: String {
        guard let d = updates.lastCheck else { return "" }
        let f = DateFormatter()
        f.locale = L10n.shared.locale
        f.dateStyle = Calendar.current.isDateInToday(d) ? .none : .medium
        f.timeStyle = .short
        return " · " + tr("about.updates.lastChecked", f.string(from: d))
    }
}

/// "Montage x is ready · Later · Restart to update": a small card at the window's top-right corner, over Home and the
/// editor, once an update is downloaded. "Later" hides it for that version (it still installs when Montage quits).
/// Restart waits while an export runs (quitting would cancel it).
struct UpdateBanner: View {
    let updates: UpdateController
    var body: some View {
        WithPerceptionTracking {
            if updates.showsBanner, case .ready(let v) = updates.state {
                let exporting = !(AppShutdown.store?.exports.queue.active.isEmpty ?? true)
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 16)).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: tr("update.banner.title", v)).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        Text(loc: exporting ? "update.banner.exporting" : "update.banner.hint").font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary)
                    }
                    Button(tr("update.later")) { updates.bannerDismissedFor = v }
                        .buttonStyle(SecondaryButtonStyle()).controlSize(.small).testID("update.later")
                    Button(tr("update.restart")) { updates.installNow() }
                        .buttonStyle(AccentButtonStyle()).controlSize(.small).disabled(exporting).testID("update.restart")
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.separator))
                .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
                .padding(.top, 44).padding(.trailing, 14)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .testID("update.banner")
            }
        }
    }
}
