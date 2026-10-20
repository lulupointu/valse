import SwiftUI
import AppKit
import MontageCore
import Perception

/// Window content: Home or the editor (cross-fade), plus the app-level modal dialogs (Settings, shortcut editor,
/// new project, version history, relink, recovery…) drawn as CapCut-style centred cards over a dimmed backdrop.
public struct RootView: View {
    @Perception.Bindable var app: AppModel
    private let locale = LocaleState.shared

    public init(app: AppModel) { self.app = app }

    public var body: some View {
        WithPerceptionTracking {
            ZStack {
                switch app.screen {
                case .home:
                    HomeView(app: app)
                        .id(locale.revision)  // live language switch (EditorView rebuilds itself)
                        .transition(.opacity)
                case .editor:
                    EditorView(store: app.store)
                        .transition(.opacity.combined(with: .scale(scale: 0.985)))
                }
                if let modal = app.modal {
                    Color.black.opacity(0.55).ignoresSafeArea()
                        .onTapGesture { if modal.dismissesOnBackdrop { app.modal = nil } }
                        .transition(.opacity)
                    ModalHost(app: app, modal: modal)
                        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { SnapshotRegistry.shared.modal = ($0, 0.55) }
                        .onDisappear { if app.modal == nil { SnapshotRegistry.shared.modal = nil } }
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                        .id("\(modal.id)-\(locale.revision)")
                }
            }
            .animation(.easeOut(duration: 0.2), value: app.screen)
            .animation(.easeOut(duration: 0.15), value: app.modal?.id)
            .background(app.screen == .home ? Theme.home : Theme.window)
            .preferredColorScheme(.dark)
        }
    }
}

extension AppModel.Modal {
    var dismissesOnBackdrop: Bool {
        switch self {
        case .recovery, .settings, .shortcuts: return false
        default: return true
        }
    }
}

/// Picks the dialog for a modal.
struct ModalHost: View {
    @Perception.Bindable var app: AppModel
    let modal: AppModel.Modal
    var body: some View {
        WithPerceptionTracking {
            switch modal {
            case .settings(let tab): SettingsView(app: app, initialTab: tab)
            case .shortcuts: ShortcutEditorView(app: app)
            case .newProject: NewProjectDialog(app: app)
            case .rename(let e): TextPromptDialog(title: tr("home.rename"), initial: e.name) { app.rename(e, to: $0) } onClose: { app.modal = nil }
            case .details(let e): ProjectDetailsDialog(app: app, entry: e)
            case .versions: VersionHistoryDialog(app: app)
            case .relink: RelinkDialog(app: app)
            case .recovery(let urls): RecoveryDialog(app: app, urls: urls)
            case .projectSettings: ProjectSettingsSheet(store: app.store, isPresented: Binding.perceived(get: { true }, set: { if !$0 { app.modal = nil } }))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            case .newFolder: TextPromptDialog(title: tr("home.folder.create"), initial: tr("home.folder.new")) { app.createFolder(named: $0) } onClose: { app.modal = nil }
            case .renameFolder(let f): TextPromptDialog(title: tr("home.folder.rename"), initial: f.name) { app.renameFolder(f, to: $0) } onClose: { app.modal = nil }
            }
        }
    }
}

/// Card chrome shared by the dialogs: title bar, body, radius 10, `bg.panel`, soft shadow (UX.md §1.4).
struct DialogCard<Content: View>: View {
    let title: String
    var width: CGFloat = 512
    var onClose: (() -> Void)?
    @ViewBuilder let content: Content
    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(verbatim: title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    Spacer()
                    if let onClose {
                        Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                            .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).help(tr("common.close"))
                            .keyboardShortcut(.cancelAction)
                            .testID("dialog.close")
                    }
                }
                .padding(.horizontal, 16).frame(height: 44)
                Rectangle().fill(Theme.separator).frame(height: 1)
                content
            }
            .frame(width: width)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.06)))
            // CPU-rendered blur makes offscreen test snapshots take seconds: no shadow under UI tests
            .shadow(color: .black.opacity(TestAnchors.isEnabled ? 0 : 0.5), radius: TestAnchors.isEnabled ? 0 : 30, y: 10)
        }
    }
}

/// CapCut footer: [Cancel] [Save] sharing the width, 28–32 pt high.
struct DialogFooter: View {
    var cancelTitle = tr("common.cancel")
    var okTitle = tr("common.save")
    var okEnabled = true
    let onCancel: () -> Void
    let onOK: () -> Void
    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 12) {
                Button(action: onCancel) {
                    Text(verbatim: cancelTitle).font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity, minHeight: 32)
                        .background(Theme.buttonSecondary, in: RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle())
                }
                .buttonStyle(.plain).keyboardShortcut(.cancelAction)
                .testID("dialog.cancel")
                Button(action: onOK) {
                    Text(verbatim: okTitle).font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity, minHeight: 32)
                        .background(Theme.accent.opacity(okEnabled ? 1 : 0.4), in: RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle())
                }
                .buttonStyle(.plain).keyboardShortcut(.defaultAction).disabled(!okEnabled)
                .testID("dialog.ok")
            }
            .foregroundStyle(.white)
        }
    }
}

/// One-field prompt (rename project / folder).
struct TextPromptDialog: View {
    let title: String
    let initial: String
    let onCommit: (String) -> Void
    let onClose: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        WithPerceptionTracking {
            DialogCard(title: title, width: 360) {
                VStack(spacing: 16) {
                    TextField("", text: $text)
                        .textFieldStyle(.plain).font(.system(size: 13))
                        .padding(.horizontal, 10).frame(height: 30)
                        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 4))
                        .focused($focused)
                        .onSubmit(commit)
                        .testID("dialog.field")
                    DialogFooter(okTitle: tr("common.ok"), okEnabled: !text.trimmingCharacters(in: .whitespaces).isEmpty, onCancel: onClose, onOK: commit)
                }
                .padding(16)
            }
            .onAppear { text = initial; focused = true }
        }
    }
    func commit() {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        onClose()
        onCommit(t)
    }
}

/// PM-004: "Montage quit unexpectedly. Do you want to recover the unsaved project?"
struct RecoveryDialog: View {
    @Perception.Bindable var app: AppModel
    let urls: [URL]
    var body: some View {
        WithPerceptionTracking {
            DialogCard(title: tr("recovery.title"), width: 420) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 22)).foregroundStyle(Color(hex: 0xE8B33A))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(loc: "recovery.message").font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(urls, id: \.self) { u in
                                WithPerceptionTracking {
                                    Text(verbatim: "• " + (ProjectPackage.summary(of: u)?.name ?? u.deletingPathExtension().lastPathComponent))
                                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                                }
                            }
                            Text(loc: "recovery.hint").font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    DialogFooter(cancelTitle: tr("recovery.notNow"), okTitle: tr("recovery.recover"),
                                 onCancel: { app.dismissRecovery(urls) }, onOK: { if let u = urls.first { app.dismissRecovery(Array(urls.dropFirst())); app.recover(u) } })
                }
                .padding(16)
            }
        }
    }
}
