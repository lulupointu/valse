import SwiftUI
import AppKit
import MontageCore
import MontageEngine
import Perception

/// "New project" with settings (PM-002): name, ratio, resolution, frame rate, colour space. The hero button itself
/// skips this dialog (CapCut: one click → editor, defaults from Settings ▸ Edit).
struct NewProjectDialog: View {
    @Perception.Bindable var app: AppModel
    @State private var name = ""
    @State private var ratio = "original"
    @State private var short = 1080
    @State private var fps = FrameRate.fps30
    @State private var colorSpace = ProjectColorSpace.sdr709

    var body: some View {
        WithPerceptionTracking {
            DialogCard(title: tr("newProject.title"), onClose: { app.modal = nil }) {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        SettingsRow(tr("details.name")) {
                            TextField("", text: $name).textFieldStyle(.plain).font(.system(size: 12))
                                .padding(.horizontal, 8).frame(height: 28)
                                .background(IStyle.dropdown, in: RoundedRectangle(cornerRadius: 4))
                                .testID("newProject.name")
                        }
                        SettingsRow(tr("details.ratio")) {
                            Dropdown(items: ProjectSettingsSheet.ratios.map { ($0, ProjectSettingsSheet.ratioTitle($0)) }, selection: ratio) { ratio = $0 }
                        }
                        if ratio == "original" {
                            HintText(text: tr("newProject.originalHint"))
                        }
                        SettingsRow(tr("details.resolution")) {
                            Dropdown(items: ProjectSettingsSheet.resolutions.map { r in
                                let sz = ProjectSettingsSheet.size(ratio: ratio == "original" ? "16:9" : ratio, short: r, original: nil)
                                return (r, "\(r)p (\(Int(sz.width))×\(Int(sz.height)))")
                            }, selection: short) { short = $0 }
                        }
                        SettingsRow(tr("details.frameRate")) {
                            Dropdown(items: FrameRate.common.map { ($0, HomeFormat.fps($0)) }, selection: fps) { fps = $0 }
                        }
                        SettingsRow(tr("details.colorSpace")) {
                            Dropdown(items: ProjectColorSpace.allCases.map { ($0, tr($0.nameKey)) }, selection: colorSpace) { colorSpace = $0 }
                        }
                    }
                    .padding(16)
                    .background(Theme.inset.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                }
                .padding([.top, .horizontal], 16)
            } footer: {
                DialogFooter(okTitle: tr("newProject.create"), onCancel: { app.modal = nil }, onOK: create)
            }
            .onAppear {
                let names = Set(app.entries.filter { $0.trashedAt == nil }.map(\.name))
                name = ProjectLibrary.defaultName(existing: names)
                let s = app.preferences.newProjectSettings()
                ratio = ProjectSettingsSheet.ratios.contains(s.aspectPreset) ? s.aspectPreset : "original"
                fps = s.frameRate
            }
        }
    }

    func create() {
        var s = app.preferences.newProjectSettings()
        s.aspectPreset = ratio
        s.canvasSize = ProjectSettingsSheet.size(ratio: ratio == "original" ? "16:9" : ratio, short: short, original: nil)
        s.frameRate = fps
        s.colorSpace = colorSpace
        app.modal = nil
        app.newProject(settings: s, name: name)
    }
}

/// Project details (PM-012) + per-project cache with sizes and "Clear cache" (PM-010).
struct ProjectDetailsDialog: View {
    @Perception.Bindable var app: AppModel
    let entry: LibraryEntry
    var body: some View {
        WithPerceptionTracking {
            let s = entry.summary
            DialogCard(title: tr("home.details"), width: 440, onClose: { app.modal = nil }, footerSpacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 14) {
                        CoverView(entry: entry).frame(width: 120, height: 120).clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 2) {
                            DetailRow(label: tr("details.name"), value: entry.name)
                            DetailRow(label: tr("home.col.duration"), value: HomeFormat.duration(s.duration))
                            DetailRow(label: tr("details.resolution"), value: "\(Int(s.canvasSize.width))×\(Int(s.canvasSize.height))")
                            DetailRow(label: tr("details.frameRate"), value: HomeFormat.fps(s.frameRate))
                        }
                    }
                    Rectangle().fill(Theme.separator).frame(height: 1)
                    DetailRow(label: tr("home.details.media"), value: "\(s.mediaCount)")
                    DetailRow(label: tr("home.details.clips"), value: "\(s.clipCount)")
                    DetailRow(label: tr("home.col.size"), value: HomeFormat.bytes(entry.sizeBytes))
                    DetailRow(label: tr("home.details.created"), value: HomeFormat.date(s.createdAt))
                    DetailRow(label: tr("home.col.modified"), value: HomeFormat.date(s.modifiedAt))
                    DetailRow(label: tr("details.saved"), value: entry.url.path)
                    HStack(spacing: 8) {
                        DetailRow(label: tr("home.details.cache"), value: app.cacheSizes[entry.id].map(HomeFormat.bytes) ?? "…")
                        Button { app.clearCache(entry) } label: { Image(systemName: "trash").font(.system(size: 12)) }
                            .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                            .frame(width: 28, height: 28).background(Theme.stepper, in: RoundedRectangle(cornerRadius: 4))
                            .help(tr("cache.clear"))
                            .disabled((app.cacheSizes[entry.id] ?? 0) == 0)
                    }
                }
                .padding([.top, .horizontal], 16)
            } footer: {
                HStack {
                    Button(tr("home.showInFinder")) { app.revealInFinder(entry) }.buttonStyle(SecondaryButtonStyle())
                    Spacer()
                    Button(tr("home.open")) { app.modal = nil; app.open(entry.url) }.buttonStyle(AccentButtonStyle())
                }
                .padding(.top, 4)
            }
            .onAppear { app.computeCacheSize(entry) }
        }
    }
}

/// File ▸ Version history: snapshots newest first, "Save version", "Restore" (undoable).
struct VersionHistoryDialog: View {
    @Perception.Bindable var app: AppModel
    @State private var versions: [ProjectVersions.Version] = []
    @State private var selected: ProjectVersions.Version?
    var body: some View {
        WithPerceptionTracking {
            DialogCard(title: tr("version.title"), width: 460, onClose: { app.modal = nil }, bodyScrolls: false, footerSpacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(loc: "version.hint").font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(versions.enumerated()), id: \.element.id) { i, v in
                                WithPerceptionTracking {
                                    HStack {
                                        Image(systemName: icon(v.kind)).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).frame(width: 18)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(verbatim: HomeFormat.date(v.date)).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                                            Text(verbatim: tr(v.kind.nameKey)).font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary)
                                        }
                                        Spacer()
                                        Text(verbatim: v.date.formatted(.relative(presentation: .named).locale(L10n.shared.locale)))
                                            .font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary)
                                    }
                                    .padding(.horizontal, 10).frame(height: 40)
                                    .background(selected == v ? Theme.accentDim.opacity(0.6) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                                    .contentShape(Rectangle())
                                    .onTapGesture { selected = v }
                                    .onTapGesture(count: 2) { restore(v) }
                                    .testID("version.row.\(i)")
                                }
                            }
                            if versions.isEmpty {
                                Text(loc: "version.empty").font(.system(size: 12)).foregroundStyle(Theme.textTertiary).padding(.vertical, 30)
                            }
                        }
                    }
                    .frame(minHeight: 80, idealHeight: 280, maxHeight: 280)   // BUG-OVERSIZED-SHEETS: shrinks to fit
                    .background(Theme.inset.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                }
                .padding([.top, .horizontal], 16)
            } footer: {
                HStack {
                    Button(tr("version.saveNow")) { app.store.saveVersionNow(); reloadSoon() }.buttonStyle(SecondaryButtonStyle()).testID("version.saveNow")
                    Spacer()
                    Button(tr("version.restore")) { if let selected { restore(selected) } }
                        .buttonStyle(AccentButtonStyle()).disabled(selected == nil).opacity(selected == nil ? 0.5 : 1).testID("version.restore")
                }
            }
            .onAppear(perform: reload)
        }
    }

    func icon(_ k: ProjectVersions.Kind) -> String {
        switch k {
        case .auto: return "clock.arrow.circlepath"
        case .manual: return "bookmark"
        case .close: return "door.left.hand.closed"
        case .beforeRestore: return "arrow.uturn.backward"
        }
    }
    func reload() { versions = app.store.versions }
    func reloadSoon() { Task { try? await Task.sleep(for: .milliseconds(300)); reload() } }
    func restore(_ v: ProjectVersions.Version) { app.store.restoreVersion(v); app.modal = nil }
}

/// Missing media (MI-006 UI): shown when an opened project has media that can't be found. "Locate…" one file
/// (others in the same folder are found too) or "Search folder…" for all; the project still opens without them.
struct RelinkDialog: View {
    @Perception.Bindable var app: AppModel
    var body: some View {
        WithPerceptionTracking {
            let missing = app.store.missingMedia
            DialogCard(title: tr("relink.title"), width: 480, onClose: { app.modal = nil }, bodyScrolls: false, footerSpacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(verbatim: trCount("relink.message", missing.count)).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(missing) { a in
                                WithPerceptionTracking {
                                    HStack(spacing: 10) {
                                        Image(systemName: a.kind == .audio ? "waveform" : (a.kind == .image ? "photo" : "film"))
                                            .font(.system(size: 12)).foregroundStyle(Color(hex: 0xE8B33A)).frame(width: 18)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(verbatim: a.name).font(.system(size: 12, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                                            Text(verbatim: a.url.deletingLastPathComponent().path).font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary)
                                                .lineLimit(1).truncationMode(.head)
                                        }
                                        Spacer()
                                        Button(tr("relink.locate")) { locate(a) }.buttonStyle(SecondaryButtonStyle())
                                    }
                                    .padding(.horizontal, 10).frame(height: 44)
                                }
                            }
                            if missing.isEmpty {
                                Label(tr("relink.allFound"), systemImage: "checkmark.circle.fill").font(.system(size: 12))
                                    .foregroundStyle(Theme.accent).padding(.vertical, 20)
                            }
                        }
                    }
                    .frame(maxHeight: 260)   // shrinks when the window is small (BUG-OVERSIZED-SHEETS)
                    .background(Theme.inset.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                }
                .padding([.top, .horizontal], 16)
            } footer: {
                HStack {
                    Button(tr("relink.searchFolder")) { searchFolder() }.buttonStyle(SecondaryButtonStyle()).disabled(missing.isEmpty)
                    Spacer()
                    Button(missing.isEmpty ? tr("common.done") : tr("relink.later")) { app.modal = nil }.buttonStyle(AccentButtonStyle()).testID("relink.close")
                }
            }
        }
    }

    func locate(_ a: MediaAsset) {
        let p = NSOpenPanel()
        p.message = tr("relink.locateMessage", a.name)
        p.directoryURL = a.url.deletingLastPathComponent()
        p.allowedContentTypes = [.movie, .audio, .image]
        if p.runModal() == .OK, let u = p.url { app.store.linkMedia(a.id, to: u) }
    }

    func searchFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.message = tr("relink.searchMessage")
        if p.runModal() == .OK, let u = p.url { app.store.relinkMissing(searching: u) }
    }
}
