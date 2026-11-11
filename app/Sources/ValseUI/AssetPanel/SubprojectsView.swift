import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ValseCore
import ValseEngine
import Perception

/// Media ▸ Subprojects (TL-022 / MI-019): the project's compound clips as re-usable items — ⊕ adds one at the playhead,
/// double-click renames, [Import project…] brings another project in as subprojects.
struct SubprojectsView: View {
    @Perception.Bindable var store: EditorStore
    @State private var renaming: CompoundID?
    @State private var name = ""

    var body: some View {
        WithPerceptionTracking {
            let comps = store.project.compounds ?? []
            let uses = Subprojects.useCounts(store.project)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button { store.importSubprojectPanel() } label: {
                        HStack(spacing: 4) { Image(systemName: "square.and.arrow.down"); Text(loc: "subprojects.import") }
                    }
                    .buttonStyle(SecondaryButtonStyle()).controlSize(.small).testID("subprojects.import")
                    Spacer()
                }
                if comps.isEmpty {
                    Text(loc: "subprojects.empty").font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .center).padding(.top, 40).testID("subprojects.empty")
                }
                PanelScrollView(tab: "media", store: store) {   // BUG-PANEL-SELECT: blank space deselects
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                        ForEach(Array(comps.enumerated()), id: \.element.id) { i, c in
                            WithPerceptionTracking {
                                card(c, index: i, uses: uses[c.id] ?? 0).testID("subprojects.card.\(i)")
                            }
                        }
                    }
                    let presets = CompoundPresetLibrary.shared.presets
                    if !presets.isEmpty {
                        Text(loc: "preset.section").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 14)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                            ForEach(Array(presets.enumerated()), id: \.element.id) { i, pr in
                                WithPerceptionTracking {
                                    presetCard(pr).testID("preset.card.\(i)")
                                }
                            }
                        }
                    }
                }
            }
            .padding(12)
            .testID("subprojects")
        }
    }

    /// Selected card (BUG-PANEL-SELECT): `AssetPanelState.cursor[cursorKey]` = "sub.<id>" / "preset.<id>".
    static let cursorKey = "media.subprojects"
    func isSelected(_ key: String) -> Bool { AssetPanelState.shared.cursor[Self.cursorKey] == key }
    func select(_ key: String) { AssetPanelState.shared.cursor[Self.cursorKey] = key }

    func presetCard(_ pr: CompoundPreset) -> some View {
        let key = "preset.\(pr.id)"
        let sel = isSelected(key)
        return VStack(alignment: .leading, spacing: 4) {
            RoundedRectangle(cornerRadius: 6).fill(Theme.inset)
                .overlay(Image(systemName: "square.stack.3d.down.right").font(.system(size: 22)).foregroundStyle(Theme.accent.opacity(0.7)))
                .frame(height: 60)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(sel ? Theme.accent : .clear, lineWidth: 2))
                .overlay(alignment: .bottomTrailing) {
                    Button { store.addCompoundPreset(pr) } label: {
                        Image(systemName: "plus.circle.fill").font(.system(size: 18)).foregroundStyle(Theme.accent)
                            .frame(width: 22, height: 22).contentShape(Circle())
                    }
                    .buttonStyle(.plain).padding(4).testID("preset.add")
                }
            Text(verbatim: pr.name).font(.system(size: 11.5)).foregroundStyle(Theme.textPrimary).lineLimit(1)
        }
        .contentShape(Rectangle())
        .assetTap(key, single: { select(key) }, double: { store.addCompoundPreset(pr) })
        .contextMenu {
            Button(tr("asset.addToTrack")) { store.addCompoundPreset(pr) }
            Button(tr("preset.delete")) { CompoundPresetLibrary.shared.delete(pr.id) }
        }
    }

    func card(_ c: CompoundClip, index: Int, uses: Int) -> some View {
        let key = "sub.\(c.id)"
        let sel = isSelected(key)
        return VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 6).fill(Theme.inset)
                    .overlay(Image(systemName: "square.stack.3d.up").font(.system(size: 22)).foregroundStyle(Theme.textTertiary))
                    .frame(height: 80)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(sel ? Theme.accent : .clear, lineWidth: 2))
                Text(verbatim: Timecode.shortDuration(c.duration)).font(.system(size: 10, weight: .medium).monospacedDigit())
                    .padding(.horizontal, 4).padding(.vertical, 1).background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(Theme.textPrimary).padding(4)
            }
            .overlay(alignment: .bottomTrailing) {
                Button { store.addSubproject(c.id) } label: {
                    Image(systemName: "plus.circle.fill").font(.system(size: 18)).foregroundStyle(Theme.accent)
                        .frame(width: 22, height: 22).contentShape(Circle())
                }
                .buttonStyle(.plain).padding(4).help(tr("asset.addToTrack")).testID("subprojects.add.\(index)")
            }
            if renaming == c.id {
                TextField("", text: $name).textFieldStyle(ValseFieldStyle()).font(.system(size: 11.5))
                    .onSubmit { store.renameSubproject(c.id, to: name); renaming = nil }
                    .testID("subprojects.renameField")
            } else {
                Text(verbatim: c.name).font(.system(size: 11.5)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    // the name selects like the card; its double-click renames (TL-022) instead of adding
                    .assetTap(key, single: { select(key) }, double: { name = c.name; renaming = c.id })
            }
            Text(verbatim: trCount("subprojects.uses", uses)).font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary)
        }
        .contentShape(Rectangle())
        // click selects; double-click adds (on the name, double-click keeps renaming: TL-022)
        .assetTap(key, single: { select(key) }, double: { store.addSubproject(c.id) })
        .contextMenu {
            Button(tr("asset.addToTrack")) { store.addSubproject(c.id) }
            Button(tr("subprojects.rename")) { name = c.name; renaming = c.id }
        }
    }
}

extension EditorStore {
    /// ⊕ on a subproject: another compound clip of it at the playhead.
    public func addSubproject(_ cid: CompoundID) {
        let t = playhead
        let box = ResultBox(ClipID())
        if edit("cmd.addSubproject", { p in box.value = try Subprojects.insert(cid, at: t, in: &p) }) { selection = [box.value] }
    }

    public func renameSubproject(_ cid: CompoundID, to name: String) {
        edit("cmd.renameSubproject") { p in try Subprojects.rename(cid, to: name, in: &p) }
    }

    /// File ▸ Import project as subproject… (MI-019).
    public func importSubprojectPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ProjectPackage.contentTypes
        panel.treatsFilePackagesAsDirectories = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importSubproject(from: url)
    }

    public func importSubproject(from url: URL) {
        do {
            let src = try ProjectPackage.load(from: url)
            let name = src.name.isEmpty ? url.deletingPathExtension().lastPathComponent : src.name
            if edit("cmd.importSubproject", { p in try Subprojects.importProject(src, name: name, into: &p) }) {
                showToast(tr("subprojects.imported", name))
                AssetPanelState.shared.nav["media"] = "subprojects"
                Task { await ProxyManager.shared.request(project.media) }
            }
        } catch {
            showToast(tr("subprojects.importFailed"), error: true)
        }
    }
}
