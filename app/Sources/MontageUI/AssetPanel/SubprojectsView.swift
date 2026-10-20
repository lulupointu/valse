import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MontageCore
import MontageEngine
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
                ScrollView {
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

    func presetCard(_ pr: CompoundPreset) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            RoundedRectangle(cornerRadius: 6).fill(Theme.inset)
                .overlay(Image(systemName: "square.stack.3d.down.right").font(.system(size: 22)).foregroundStyle(Theme.accent.opacity(0.7)))
                .frame(height: 60)
                .overlay(alignment: .bottomTrailing) {
                    Button { store.addCompoundPreset(pr) } label: {
                        Image(systemName: "plus.circle.fill").font(.system(size: 18)).foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain).padding(4).testID("preset.add")
                }
            Text(verbatim: pr.name).font(.system(size: 11.5)).foregroundStyle(Theme.textPrimary).lineLimit(1)
        }
        .contextMenu {
            Button(tr("asset.addToTrack")) { store.addCompoundPreset(pr) }
            Button(tr("preset.delete")) { CompoundPresetLibrary.shared.delete(pr.id) }
        }
    }

    func card(_ c: CompoundClip, index: Int, uses: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 6).fill(Theme.inset)
                    .overlay(Image(systemName: "square.stack.3d.up").font(.system(size: 22)).foregroundStyle(Theme.textTertiary))
                    .frame(height: 80)
                Text(verbatim: Timecode.shortDuration(c.duration)).font(.system(size: 10, weight: .medium).monospacedDigit())
                    .padding(.horizontal, 4).padding(.vertical, 1).background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(.white).padding(4)
            }
            .overlay(alignment: .bottomTrailing) {
                Button { store.addSubproject(c.id) } label: {
                    Image(systemName: "plus.circle.fill").font(.system(size: 18)).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain).padding(4).help(tr("asset.addToTrack")).testID("subprojects.add.\(index)")
            }
            if renaming == c.id {
                TextField("", text: $name).textFieldStyle(.roundedBorder).font(.system(size: 11.5))
                    .onSubmit { store.renameSubproject(c.id, to: name); renaming = nil }
                    .testID("subprojects.renameField")
            } else {
                Text(verbatim: c.name).font(.system(size: 11.5)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    .onTapGesture(count: 2) { name = c.name; renaming = c.id }
            }
            Text(verbatim: trCount("subprojects.uses", uses)).font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary)
        }
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
        panel.allowedContentTypes = [UTType(filenameExtension: ProjectPackage.fileExtension) ?? .package]
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
