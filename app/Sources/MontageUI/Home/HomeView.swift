import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MontageCore

/// Home screen (UX.md §2.1, [02]): sidebar (Home, Templates, folders, Trash), the "New project" hero, and the project
/// grid/list with search, sort, view toggle, hover "…" menus, multi-selection, drag & drop import, empty state.
struct HomeView: View {
    @Bindable var app: AppModel

    var body: some View {
        HStack(spacing: 0) {
            HomeSidebar(app: app).frame(width: 215)
            ZStack(alignment: .top) {
                switch app.section {
                case .projects: ProjectsColumn(app: app)
                case .templates: TemplatesPlaceholder(app: app)
                }
                HomeTopBar(app: app)
            }
        }
        .background(Theme.home)
        .overlay(alignment: .top) { ToastView(toast: app.store.toast).padding(.top, 54) }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            HomeDrop.load(providers) { urls in
                let projects = urls.filter { ["montage", "zip"].contains($0.pathExtension.lowercased()) }
                if !projects.isEmpty { app.importProjects(projects) }
            }
            return true
        }
        .task { if !app.hasScanned { await app.refresh() } }
    }
}

enum HomeDrop {
    static func load(_ providers: [NSItemProvider], _ done: @escaping @MainActor ([URL]) -> Void) {
        let box = URLBox()
        let group = DispatchGroup()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { u, _ in if let u { box.append(u) }; group.leave() }
        }
        group.notify(queue: .main) { MainActor.assumeIsolated { done(box.urls) } }
    }
}

nonisolated final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [URL] = []
    func append(_ u: URL) { lock.withLock { _urls.append(u) } }
    var urls: [URL] { lock.withLock { _urls } }
}

// MARK: - Sidebar

struct HomeSidebar: View {
    @Bindable var app: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 7).fill(LinearGradient(colors: [Color(hex: 0x6CC9DD), Color(hex: 0x4FB4C9)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 28, height: 28)
                    .overlay(Image(systemName: "film.stack").font(.system(size: 13, weight: .semibold)).foregroundStyle(.black.opacity(0.8)))
                Text(verbatim: "Montage").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            }
            .padding(.top, 44).padding(.bottom, 20).padding(.leading, 6)
            Text(loc: "home.videoEditing").font(.system(size: 11)).foregroundStyle(Theme.textTertiary).padding(.leading, 6).padding(.bottom, 4)
            NavItem(symbol: "house", title: tr("home.nav.home"), selected: app.section == .projects && app.scope == .all) {
                app.section = .projects; app.scope = .all
            }
            NavItem(symbol: "clock", title: tr("home.nav.recents"), selected: app.section == .projects && app.scope == .recents) {
                app.section = .projects; app.scope = .recents
            }
            NavItem(symbol: "rectangle.stack", title: tr("home.nav.templates"), selected: app.section == .templates) { app.section = .templates }
            Rectangle().fill(Theme.separator).frame(height: 1).padding(.vertical, 10)
            HStack {
                Text(loc: "home.folders").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                Spacer()
                Button { app.modal = .newFolder } label: { Image(systemName: "plus").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).help(tr("home.folder.create"))
            }
            .padding(.horizontal, 6).padding(.bottom, 2)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(app.folders) { f in
                        NavItem(symbol: "folder", title: f.name, selected: app.section == .projects && app.scope == .folder(f.id),
                                badge: app.entries.filter { $0.folderID == f.id && $0.trashedAt == nil }.count) {
                            app.section = .projects; app.scope = .folder(f.id)
                        }
                        .contextMenu {
                            Button(tr("home.folder.rename")) { app.modal = .renameFolder(f) }
                            Button(tr("home.folder.delete")) { app.deleteFolder(f) }
                        }
                        .dropDestination(for: String.self) { ids, _ in
                            app.move(app.entries.filter { ids.contains($0.id) }, to: f.id); return true
                        }
                    }
                    if app.folders.isEmpty {
                        Text(loc: "home.folders.empty").font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6).padding(.vertical, 4)
                    }
                }
            }
            Spacer(minLength: 8)
            NavItem(symbol: "trash", title: tr("home.nav.trash"), selected: app.section == .projects && app.scope == .trash,
                    badge: app.trashCount) { app.section = .projects; app.scope = .trash }
                .dropDestination(for: String.self) { ids, _ in app.trash(app.entries.filter { ids.contains($0.id) }); return true }
            NavItem(symbol: "gearshape", title: tr("menu.settings"), selected: false) { app.modal = .settings(.general) }
                .padding(.bottom, 14)
        }
        .padding(.horizontal, 16)
        .background(Theme.home)
    }
}

struct NavItem: View {
    let symbol: String
    let title: String
    let selected: Bool
    var badge: Int = 0
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 13)).frame(width: 18)
                Text(verbatim: title).font(.system(size: 13, weight: selected ? .medium : .regular)).lineLimit(1)
                Spacer(minLength: 0)
                if badge > 0 { Text(verbatim: "\(badge)").font(.system(size: 11)).foregroundStyle(Theme.textTertiary) }
            }
            .foregroundStyle(selected ? .white : Theme.textSecondary)
            .padding(.horizontal, 10).frame(height: 36)
            .background(selected ? Color(hex: 0x1E2829) : (hover ? Color.white.opacity(0.04) : .clear), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Top bar

struct HomeTopBar: View {
    @Bindable var app: AppModel
    var body: some View {
        HStack(spacing: 14) {
            Spacer()
            IconButton("square.and.arrow.down", help: tr("home.importProject")) { app.importProjectPanel() }
            IconButton("keyboard", help: tr("menu.shortcuts")) { app.modal = .shortcuts }
            IconButton("gearshape", help: tr("menu.settings")) { app.modal = .settings(.general) }
        }
        .padding(.horizontal, 20)
        .frame(height: 40)
        .padding(.top, 2)
    }
}

// MARK: - Main column

struct ProjectsColumn: View {
    @Bindable var app: AppModel

    var body: some View {
        let list = app.visibleEntries
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if app.scope == .all || app.scope == .recents {
                    NewProjectHero(app: app)
                    HomeFeatureRow(app: app)
                }
                ProjectsHeader(app: app, count: list.count)
                if !app.hasScanned {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 30)
                } else if list.isEmpty {
                    EmptyProjects(app: app)
                } else if app.viewMode == .grid {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 170), spacing: 24, alignment: .top)], alignment: .leading, spacing: 22) {
                        ForEach(list) { e in ProjectCard(app: app, entry: e, all: list) }
                    }
                } else {
                    ProjectListHeader(app: app)
                    LazyVStack(spacing: 0) {
                        ForEach(list) { e in ProjectRow(app: app, entry: e, all: list) }
                    }
                }
            }
            .padding(.horizontal, 32).padding(.top, 44).padding(.bottom, 40)
        }
        .scrollIndicators(.automatic)
        .background(Theme.home)
        .contentShape(Rectangle())
        .onTapGesture { app.selectedIDs = []; app.renamingID = nil }
        .overlay(alignment: .bottom) { if app.selectedIDs.count > 1 { SelectionBar(app: app) } }
        .background(DeleteKeyCatcher { app.trashOrDeleteSelection() })
    }
}

extension AppModel {
    var selectedEntries: [LibraryEntry] { visibleEntries.filter { selectedIDs.contains($0.id) } }

    /// ⌫ on Home: move the selection to the Trash (in the Trash: delete permanently).
    func trashOrDeleteSelection() {
        let items = selectedEntries
        guard !items.isEmpty, renamingID == nil, modal == nil, screen == .home else { return }
        if scope == .trash { deletePermanently(items) } else { trash(items) }
    }

    /// Click handling: plain click opens, ⌘-click toggles, ⇧-click extends the selection.
    func click(_ e: LibraryEntry, in list: [LibraryEntry]) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            if selectedIDs.contains(e.id) { selectedIDs.remove(e.id) } else { selectedIDs.insert(e.id) }
        } else if mods.contains(.shift), let anchor = list.firstIndex(where: { selectedIDs.contains($0.id) }),
                  let i = list.firstIndex(of: e) {
            selectedIDs = Set(list[min(anchor, i)...max(anchor, i)].map(\.id))
        } else if scope == .trash {
            selectedIDs = [e.id]
        } else {
            open(e.url)
        }
    }

    /// The items a card's menu acts on: the selection if the card is in it, else the card.
    func targets(_ e: LibraryEntry) -> [LibraryEntry] { selectedIDs.contains(e.id) && selectedIDs.count > 1 ? selectedEntries : [e] }
}

/// Big gradient banner (cyan → teal), "+ New project": one click → editor. The ⚙ chip opens the settings dialog.
struct NewProjectHero: View {
    @Bindable var app: AppModel
    @State private var hover = false
    var body: some View {
        Button { app.newProject() } label: {
            ZStack {
                LinearGradient(colors: [Color(hex: 0x6CC9DD), Color(hex: 0x57BECB), Color(hex: 0x4FB4C9)], startPoint: .leading, endPoint: .trailing)
                RadialGradient(colors: [.white.opacity(hover ? 0.35 : 0.22), .clear], center: .init(x: 0.62, y: 0.2), startRadius: 0, endRadius: 420)
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.85)).frame(width: 22, height: 22)
                        .overlay(Image(systemName: "plus").font(.system(size: 13, weight: .bold)).foregroundStyle(Color(hex: 0x6CC9DD)))
                    Text(loc: "home.newProject").font(.system(size: 17, weight: .semibold)).foregroundStyle(Color.black.opacity(0.85))
                }
            }
            .frame(height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .scaleEffect(hover ? 1.003 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .overlay(alignment: .bottomTrailing) {
            Button { app.modal = .newProject } label: {
                HStack(spacing: 5) {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 11, weight: .semibold))
                    Text(loc: "home.newProject.custom").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Color.black.opacity(0.8))
                .padding(.horizontal, 10).frame(height: 26)
                .background(Color.white.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help(tr("home.newProject.customHelp"))
            .padding(12)
        }
        .accessibilityLabel(Text(loc: "home.newProject"))
    }
}

/// Feature cards (CapCut's Agent Hub / Video Studio row): Templates entry point, Import project.
struct HomeFeatureRow: View {
    @Bindable var app: AppModel
    var body: some View {
        HStack(spacing: 14) {
            FeatureCard(symbol: "rectangle.stack.badge.play", title: tr("home.nav.templates"), subtitle: tr("home.templates.subtitle")) { app.section = .templates }
            FeatureCard(symbol: "square.and.arrow.down.on.square", title: tr("home.importProject"), subtitle: tr("home.importProject.subtitle")) { app.importProjectPanel() }
            Spacer(minLength: 0)
        }
    }
}

struct FeatureCard: View {
    let symbol: String
    let title: String
    let subtitle: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(Theme.accent).frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    Text(verbatim: subtitle).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(width: 300, height: 72)
            .background(LinearGradient(colors: [Color(hex: 0x274759).opacity(hover ? 1 : 0.85), Color(hex: 0x1E3440)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// "Projects" caption + search, sort, grid/list toggle (36×28 buttons, `#29292D`).
struct ProjectsHeader: View {
    @Bindable var app: AppModel
    let count: Int
    @FocusState private var searchFocused: Bool

    var title: String {
        switch app.scope {
        case .all: return tr("home.projects")
        case .recents: return tr("home.nav.recents")
        case .trash: return tr("home.nav.trash")
        case .folder(let id): return app.folders.first { $0.id == id }?.name ?? tr("home.projects")
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            if app.hasScanned { Text(verbatim: "\(count)").font(.system(size: 12)).foregroundStyle(Theme.textTertiary) }
            if app.scope == .trash {
                Text(loc: "home.trash.hint", ProjectLibrary.trashRetentionDays).font(Theme.Fonts.hint).foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            if app.scope == .trash, count > 0 {
                Button(tr("home.trash.empty")) { app.emptyTrash() }.buttonStyle(SecondaryButtonStyle())
            }
            if app.isSearching {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    TextField(tr("home.search.placeholder"), text: $app.search)
                        .textFieldStyle(.plain).font(.system(size: 12)).focused($searchFocused)
                        .onExitCommand { app.search = ""; app.isSearching = false }
                    Button { app.search = ""; app.isSearching = false } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 8).frame(width: 220, height: 28)
                .background(Color(hex: 0x29292D), in: RoundedRectangle(cornerRadius: 6))
                .onAppear { searchFocused = true }
            } else {
                HeaderButton(symbol: "magnifyingglass", help: tr("home.search")) { app.isSearching = true }
                    .keyboardShortcut("f", modifiers: .command)
            }
            Menu {
                ForEach(LibrarySort.allCases.filter { $0 != .opened || app.scope == .recents }, id: \.self) { s in
                    Button { app.setSort(s) } label: {
                        if app.sort == s { Label(tr(s.nameKey), systemImage: app.ascending ? "chevron.up" : "chevron.down") } else { Text(verbatim: tr(s.nameKey)) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.arrow.down").font(.system(size: 11))
                    Text(verbatim: tr(app.sort.nameKey)).font(.system(size: 12))
                }
                .foregroundStyle(Theme.textPrimary)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .padding(.horizontal, 10).frame(height: 28)
            .background(Color(hex: 0x29292D), in: RoundedRectangle(cornerRadius: 6))
            .help(tr("home.sort"))
            HStack(spacing: 0) {
                HeaderButton(symbol: "square.grid.2x2", help: tr("home.view.grid"), active: app.viewMode == .grid) { app.setViewMode(.grid) }
                HeaderButton(symbol: "list.bullet", help: tr("home.view.list"), active: app.viewMode == .list) { app.setViewMode(.list) }
            }
            .background(Color(hex: 0x29292D), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

struct HeaderButton: View {
    let symbol: String
    let help: String
    var active = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12))
                .foregroundStyle(active ? Theme.accent : Theme.textPrimary)
                .frame(width: 36, height: 28)
                .background(Color(hex: 0x29292D), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct EmptyProjects: View {
    @Bindable var app: AppModel
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: app.scope == .trash ? "trash" : (app.isSearching && !app.search.isEmpty ? "magnifyingglass" : "film"))
                .font(.system(size: 30, weight: .light)).foregroundStyle(Theme.textTertiary)
            Text(verbatim: message).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            if app.scope == .all && !(app.isSearching && !app.search.isEmpty) {
                Button(tr("home.importProject")) { app.importProjectPanel() }.buttonStyle(SecondaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity).padding(.top, 40)
    }
    var message: String {
        if app.isSearching && !app.search.isEmpty { return tr("home.empty.search", app.search) }
        switch app.scope {
        case .trash: return tr("home.empty.trash")
        case .folder: return tr("home.empty.folder")
        case .recents: return tr("home.empty.recents")
        case .all: return tr("home.empty")
        }
    }
}

/// Bottom pill when several projects are selected.
struct SelectionBar: View {
    @Bindable var app: AppModel
    var body: some View {
        HStack(spacing: 10) {
            Text(loc: "home.selected", app.selectedIDs.count).font(.system(size: 12)).foregroundStyle(.white)
            if app.scope == .trash {
                Button(tr("home.restore")) { app.restore(app.selectedEntries) }.buttonStyle(SecondaryButtonStyle())
                Button(tr("home.deleteForever")) { app.deletePermanently(app.selectedEntries) }.buttonStyle(SecondaryButtonStyle())
            } else {
                MoveToFolderMenu(app: app, items: app.selectedEntries)
                Button(tr("home.duplicate")) { app.duplicate(app.selectedEntries) }.buttonStyle(SecondaryButtonStyle())
                Button(tr("home.delete")) { app.trash(app.selectedEntries) }.buttonStyle(SecondaryButtonStyle())
            }
            Button { app.selectedIDs = [] } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).help(tr("common.cancel"))
        }
        .padding(.horizontal, 14).frame(height: 44)
        .background(Theme.menu, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.4), radius: 16)
        .padding(.bottom, 20)
    }
}

struct MoveToFolderMenu: View {
    @Bindable var app: AppModel
    let items: [LibraryEntry]
    var body: some View {
        Menu(tr("home.moveTo")) { MoveToFolderItems(app: app, items: items) }
            .menuStyle(.borderlessButton).fixedSize()
            .padding(.horizontal, 10).frame(height: 26)
            .background(Theme.buttonSecondary, in: RoundedRectangle(cornerRadius: 4))
    }
}

struct MoveToFolderItems: View {
    @Bindable var app: AppModel
    let items: [LibraryEntry]
    var body: some View {
        Button(tr("home.folder.none")) { app.move(items, to: nil) }
        if !app.folders.isEmpty { Divider() }
        ForEach(app.folders) { f in Button(f.name) { app.move(items, to: f.id) } }
        Divider()
        Button(tr("home.folder.create") + "…") { app.modal = .newFolder }
    }
}

/// Card / row context menu (UX.md §2.1 [04]: Rename · Duplicate · Delete, plus Montage's extra entries).
struct ProjectMenuItems: View {
    @Bindable var app: AppModel
    let entry: LibraryEntry
    var body: some View {
        let items = app.targets(entry)
        if entry.trashedAt != nil {
            Button(tr("home.restore")) { app.restore(items) }
            Button(tr("home.deleteForever")) { app.deletePermanently(items) }
        } else {
            Button(tr("home.open")) { app.open(entry.url) }
            Button(tr("home.rename")) { app.renamingID = entry.id }.disabled(items.count > 1)
            Button(tr("home.duplicate")) { app.duplicate(items) }
            Menu(tr("home.moveTo")) { MoveToFolderItems(app: app, items: items) }
            Divider()
            Button(tr("menu.packProject") + "…") { app.packPanel(entry) }.disabled(items.count > 1)
            Button(tr("home.showInFinder")) { app.revealInFinder(entry) }
            Button(tr("home.details")) { app.modal = .details(entry) }.disabled(items.count > 1)
            Divider()
            Button(tr("home.delete")) { app.trash(items) }
        }
    }
}

// MARK: - Card (grid)

struct ProjectCard: View {
    @Bindable var app: AppModel
    let entry: LibraryEntry
    let all: [LibraryEntry]
    @State private var hover = false

    var body: some View {
        let selected = app.selectedIDs.contains(entry.id)
        VStack(alignment: .leading, spacing: 6) {
            CoverView(entry: entry)
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Theme.accent : Color.white.opacity(hover ? 0.18 : 0), lineWidth: selected ? 2 : 1))
                .overlay(alignment: .bottomTrailing) {
                    if hover || selected {
                        Menu { ProjectMenuItems(app: app, entry: entry) } label: {
                            Image(systemName: "ellipsis").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 24, height: 20)
                                .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .padding(6)
                        .help(tr("home.more"))
                    }
                }
                .overlay(alignment: .topLeading) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 16)).foregroundStyle(Theme.accent, .white).padding(6)
                    }
                }
            if app.renamingID == entry.id {
                InlineRenameField(initial: entry.name) { app.rename(entry, to: $0) } onCancel: { app.renamingID = nil }
            } else {
                Text(verbatim: entry.name).font(.system(size: 13)).foregroundStyle(.white).lineLimit(1).truncationMode(.middle)
                    .onTapGesture(count: 2) { if entry.trashedAt == nil { app.renamingID = entry.id } }
            }
            Text(verbatim: "\(CacheManager.format(entry.sizeBytes)) | \(HomeFormat.duration(entry.summary.duration))")
                .font(.system(size: 12)).foregroundStyle(Theme.textTertiary).lineLimit(1)
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { app.click(entry, in: all) }
        .contextMenu { ProjectMenuItems(app: app, entry: entry) }
        .draggable(entry.id)
        .help(entry.trashedAt == nil ? tr("home.card.help", HomeFormat.date(entry.modifiedAt)) : tr("home.card.trashedHelp"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: entry.name))
    }
}

struct InlineRenameField: View {
    let initial: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain).font(.system(size: 13))
            .padding(.horizontal, 4).frame(height: 20)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.accent))
            .focused($focused)
            .onSubmit { onCommit(text) }
            .onExitCommand(perform: onCancel)
            .onAppear { text = initial; focused = true }
            .onChange(of: focused) { _, f in if !f { onCommit(text) } }
    }
}

/// Async cover thumbnail (`cover.jpg`), cached; placeholder = dark tile with a film glyph.
struct CoverView: View {
    let entry: LibraryEntry
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            Rectangle().fill(Color(hex: 0x1B1B1C))
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: entry.summary.clipCount == 0 ? "plus.rectangle.on.rectangle" : "film")
                    .font(.system(size: 20, weight: .light)).foregroundStyle(Theme.textTertiary.opacity(0.6))
            }
        }
        .clipped()
        .task(id: "\(entry.id)|\(entry.modifiedAt.timeIntervalSince1970)") { image = await CoverCache.shared.image(for: entry) }
    }
}

@MainActor
final class CoverCache {
    static let shared = CoverCache()
    private let cache = NSCache<NSString, NSImage>()
    init() { cache.countLimit = 400 }

    func image(for e: LibraryEntry) async -> NSImage? {
        guard let url = e.coverURL else { return nil }
        let key = "\(url.path)|\(e.modifiedAt.timeIntervalSince1970)" as NSString
        if let i = cache.object(forKey: key) { return i }
        let img = await Task.detached(priority: .utility) { () -> NSImage? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                       kCGImageSourceThumbnailMaxPixelSize: 400] as CFDictionary)
            else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        if let img { cache.setObject(img, forKey: key) }
        return img
    }
}

// MARK: - List

struct ProjectListHeader: View {
    @Bindable var app: AppModel
    var body: some View {
        HStack(spacing: 0) {
            col(tr("home.col.name"), .name).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 70)
            col(tr("home.col.modified"), .modified).frame(width: 160, alignment: .leading)
            col(tr("home.col.duration"), .duration).frame(width: 90, alignment: .leading)
            col(tr("home.col.size"), .size).frame(width: 90, alignment: .leading)
            Text(loc: "home.col.format").frame(width: 110, alignment: .leading)
        }
        .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, 8)
    }
    func col(_ t: String, _ s: LibrarySort) -> some View {
        Button { app.setSort(s) } label: {
            HStack(spacing: 3) {
                Text(verbatim: t)
                if app.sort == s { Image(systemName: app.ascending ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold)) }
            }
        }
        .buttonStyle(.plain)
    }
}

struct ProjectRow: View {
    @Bindable var app: AppModel
    let entry: LibraryEntry
    let all: [LibraryEntry]
    @State private var hover = false
    var body: some View {
        let selected = app.selectedIDs.contains(entry.id)
        HStack(spacing: 0) {
            CoverView(entry: entry).frame(width: 54, height: 32).clipShape(RoundedRectangle(cornerRadius: 4)).padding(.trailing, 16)
            Group {
                if app.renamingID == entry.id {
                    InlineRenameField(initial: entry.name) { app.rename(entry, to: $0) } onCancel: { app.renamingID = nil }
                } else {
                    Text(verbatim: entry.name).font(.system(size: 13)).foregroundStyle(.white).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: HomeFormat.date(entry.modifiedAt)).frame(width: 160, alignment: .leading)
            Text(verbatim: HomeFormat.duration(entry.summary.duration)).frame(width: 90, alignment: .leading)
            Text(verbatim: CacheManager.format(entry.sizeBytes)).frame(width: 90, alignment: .leading)
            Text(verbatim: HomeFormat.format(entry.summary)).frame(width: 110, alignment: .leading)
        }
        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 8).frame(height: 44)
        .background(selected ? Theme.accentDim.opacity(0.5) : (hover ? Color.white.opacity(0.04) : .clear), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { app.click(entry, in: all) }
        .contextMenu { ProjectMenuItems(app: app, entry: entry) }
        .draggable(entry.id)
    }
}

enum HomeFormat {
    /// CapCut card duration "00:00" (mm:ss, h:mm:ss beyond an hour).
    static func duration(_ t: Time) -> String {
        let s = Int(t.seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }
    static func date(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = L10n.shared.locale
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: d)
    }
    static func format(_ s: ProjectSummary) -> String {
        "\(Int(s.canvasSize.width))×\(Int(s.canvasSize.height)) · \(fps(s.frameRate))"
    }
    static func fps(_ r: FrameRate) -> String {
        r.denominator == 1 ? "\(r.numerator) fps" : String(format: "%.2f fps", r.fps)
    }
}

/// ⌫ / ⌦ on Home when no text field has focus.
struct DeleteKeyCatcher: NSViewRepresentable {
    let action: @MainActor () -> Void
    func makeNSView(context: Context) -> NSView {
        let v = CatcherView()
        v.action = action
        return v
    }
    func updateNSView(_ v: NSView, context: Context) { (v as? CatcherView)?.action = action }
    final class CatcherView: NSView {
        var action: (@MainActor () -> Void)?
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                let m = e.modifierFlags.intersection([.command, .option, .control, .shift])
                guard let self, e.window === self.window, e.keyCode == 51 || e.keyCode == 117, m.isEmpty || m == .command,
                      !(e.window?.firstResponder is NSText) else { return e }
                MainActor.assumeIsolated { self.action?() }
                return nil
            }
        }
        override func removeFromSuperview() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            super.removeFromSuperview()
        }
    }
}

/// Templates entry point (content arrives with the templates workstream).
struct TemplatesPlaceholder: View {
    @Bindable var app: AppModel
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.stack.badge.play").font(.system(size: 40, weight: .light)).foregroundStyle(Theme.accent)
            Text(loc: "home.templates.title").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
            Text(loc: "home.templates.soon").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            Button(tr("home.newProject")) { app.newProject() }.buttonStyle(AccentButtonStyle()).padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.home)
    }
}
