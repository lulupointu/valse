import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MontageCore
import MontageEffects
import MontageEngine

/// FX-018 Effects ▸ Custom: import an effect package (folder / ZIP), create one from a template and edit its Metal
/// shader in any text editor (Reload picks the changes up), export a ZIP to share, delete. See `CustomEffectLibrary`.
@MainActor @Observable
final class CustomEffectsState {
    static let shared = CustomEffectsState()
    /// Bumped after every library change so the grid re-lists.
    private(set) var revision = 0
    /// Last import / reload problem (compiler message), shown under the buttons.
    var problem: String?

    func changed(_ ids: [String] = []) {
        for id in ids { EffectThumbnails.shared.forget(id) }
        revision += 1
    }
}

extension EditorStore {
    func importCustomEffect(_ url: URL) {
        let st = CustomEffectsState.shared
        do {
            let e = try CustomEffectLibrary.shared.importPackage(url)
            st.problem = nil
            st.changed([e.effectID])
            showToast(tr("fx.custom.imported", CustomEffectLibrary.descriptor(e).nameKey))
        } catch {
            st.problem = CustomEffectLibrary.message(error)
            showToast(tr("fx.custom.importFailed"), error: true)
        }
    }

    func importCustomEffectPanel() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = true
        p.treatsFilePackagesAsDirectories = false
        p.allowedContentTypes = [.zip, .folder, .directory, UTType(filenameExtension: CustomEffectLibrary.packageExtension) ?? .folder]
        p.message = tr("fx.custom.import.message")
        if p.runModal() == .OK, let u = p.url { importCustomEffect(u) }
    }

    func newCustomEffect() {
        let st = CustomEffectsState.shared
        do {
            let e = try CustomEffectLibrary.shared.createTemplate()
            st.problem = nil
            st.changed([e.effectID])
            showToast(tr("fx.custom.created"))
            if !TestAnchors.isEnabled { NSWorkspace.shared.activateFileViewerSelecting([e.folder.appendingPathComponent(e.manifest.shader ?? "effect.metal")]) }
        } catch {
            st.problem = CustomEffectLibrary.message(error)
        }
    }

    func reloadCustomEffects() {
        let ids = CustomEffectLibrary.shared.all.map(\.effectID)
        let failures = CustomEffectLibrary.shared.loadAll(compile: true)
        let st = CustomEffectsState.shared
        st.problem = failures.isEmpty ? nil : failures.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        st.changed(ids + CustomEffectLibrary.shared.all.map(\.effectID))
        engine.forceRebuild()   // clips using an edited effect re-render
        showToast(failures.isEmpty ? tr("fx.custom.reloaded") : tr("fx.custom.importFailed"), error: !failures.isEmpty)
    }
}

/// Buttons + format help above the Custom grid.
struct CustomEffectsHeader: View {
    let store: EditorStore
    let isEmpty: Bool
    var body: some View {
        let st = CustomEffectsState.shared
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button { store.importCustomEffectPanel() } label: { Label(tr("fx.custom.import"), systemImage: "square.and.arrow.down") }
                    .testID("fx.custom.import")
                Button { store.newCustomEffect() } label: { Label(tr("fx.custom.new"), systemImage: "plus") }
                    .testID("fx.custom.new")
                Button { store.reloadCustomEffects() } label: { Label(tr("fx.custom.reload"), systemImage: "arrow.clockwise") }
                    .testID("fx.custom.reload")
                Button { NSWorkspace.shared.activateFileViewerSelecting([CustomEffectLibrary.shared.directory]) } label: {
                    Image(systemName: "folder")
                }
                .help(tr("fx.custom.folder")).accessibilityLabel(Text(verbatim: tr("fx.custom.folder")))
                .testID("fx.custom.folder")
            }
            .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
            if isEmpty {
                Text(verbatim: tr("fx.custom.empty")).font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .testID("fx.custom.empty")
            }
            if let p = st.problem {
                Text(verbatim: p).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Color(hex: 0xE8A93C))
                    .lineLimit(6).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .testID("fx.custom.problem")
            }
        }
        .padding(.horizontal, 12)
    }
}

/// Extra context-menu items on a custom effect card.
struct CustomEffectMenuItems: View {
    let effectID: String
    var body: some View {
        Divider()
        Button(tr("fx.custom.showInFinder")) {
            if let e = CustomEffectLibrary.shared.entry(effectID) { NSWorkspace.shared.activateFileViewerSelecting([e.folder]) }
        }
        Button(tr("fx.custom.export")) {
            guard let e = CustomEffectLibrary.shared.entry(effectID) else { return }
            let p = NSSavePanel()
            p.allowedContentTypes = [.zip]
            p.nameFieldStringValue = "\(e.manifest.id).zip"
            if p.runModal() == .OK, let u = p.url { try? CustomEffectLibrary.shared.exportZIP(effectID, to: u) }
        }
        Button(tr("fx.custom.delete"), role: .destructive) {
            CustomEffectLibrary.shared.remove(effectID)
            CustomEffectsState.shared.changed([effectID])
        }
    }
}
