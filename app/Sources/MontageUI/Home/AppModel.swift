import Foundation
import AppKit
import Observation
import UniformTypeIdentifiers
import MontageCore
import MontageEngine

/// App-level state (W12): which screen shows (Home or editor), the project library listing, modal dialogs, and every
/// project-management flow (new / open / back to home / rename / duplicate / trash / folders / import / pack).
/// One `EditorStore` (and its playback engine) is reused for every project.
@MainActor @Observable
public final class AppModel {
    public enum Screen: Equatable { case home, editor }

    public enum HomeSection: Hashable { case projects, templates }
    public enum ViewMode: String { case grid, list }

    public enum Modal: Identifiable, Equatable {
        case settings(SettingsTab)
        case shortcuts
        case newProject
        case rename(LibraryEntry)
        case details(LibraryEntry)
        case versions
        case relink
        case recovery([URL])
        case projectSettings
        case newFolder
        case renameFolder(ProjectFolder)
        public var id: String {
            switch self {
            case .settings: return "settings"
            case .shortcuts: return "shortcuts"
            case .newProject: return "newProject"
            case .rename(let e): return "rename-\(e.id)"
            case .details(let e): return "details-\(e.id)"
            case .versions: return "versions"
            case .relink: return "relink"
            case .recovery: return "recovery"
            case .projectSettings: return "projectSettings"
            case .newFolder: return "newFolder"
            case .renameFolder(let f): return "renameFolder-\(f.id)"
            }
        }
    }

    public var screen: Screen = .home
    public let store: EditorStore
    public let preferences: AppPreferences
    public var library: ProjectLibrary { libraryOverride ?? ProjectLibrary.shared }
    @ObservationIgnored var libraryOverride: ProjectLibrary?

    // Home state
    public private(set) var entries: [LibraryEntry] = []
    public private(set) var folders: [ProjectFolder] = []
    public private(set) var hasScanned = false
    public var section: HomeSection = .projects
    public var scope: LibraryScope = .all
    public var search = ""
    public var isSearching = false
    public var sort: LibrarySort = .modified
    public var ascending = false
    public var viewMode: ViewMode = .grid
    public var selectedIDs: Set<String> = []
    /// Card whose name is being edited inline.
    public var renamingID: String?
    /// Per-project cache sizes (bytes), computed lazily for the details panel.
    public private(set) var cacheSizes: [String: Int64] = [:]
    public var modal: Modal?
    public var isTransitioning = false
    /// Last trashed URLs (toast "Undo").
    public private(set) var lastTrashed: [URL] = []

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var checkedRecovery = false

    public init(store: EditorStore, preferences: AppPreferences = .shared, library: ProjectLibrary? = nil) {
        self.store = store
        self.preferences = preferences
        self.libraryOverride = library
        preferences.store = store
        preferences.apply(to: store)
        if let v = UserDefaults.standard.string(forKey: "MontageHomeViewMode"), let m = ViewMode(rawValue: v) { viewMode = m }
        if let v = UserDefaults.standard.string(forKey: "MontageHomeSort"), let s = LibrarySort(rawValue: v) { sort = s }
    }

    /// Entries shown in the main column.
    public var visibleEntries: [LibraryEntry] {
        ProjectLibrary.filter(entries, scope: scope, search: isSearching ? search : "", sort: sort, ascending: ascending)
    }

    public var trashCount: Int { entries.filter { $0.trashedAt != nil }.count }

    public func setViewMode(_ m: ViewMode) { viewMode = m; UserDefaults.standard.set(m.rawValue, forKey: "MontageHomeViewMode") }
    public func setSort(_ s: LibrarySort) {
        if sort == s { ascending.toggle() } else { sort = s; ascending = s == .name }
        UserDefaults.standard.set(s.rawValue, forKey: "MontageHomeSort")
    }

    // MARK: Library refresh

    /// Rescans the library off the main thread (cheap: summaries are cached by modification date).
    public func refresh() async {
        scanTask?.cancel()
        let lib = library
        let (list, f) = await Task.detached(priority: .userInitiated) { (lib.scan(), lib.folders) }.value
        entries = list
        folders = f
        hasScanned = true
        selectedIDs = selectedIDs.filter { id in list.contains { $0.id == id } }
        if case .folder(let id) = scope, !f.contains(where: { $0.id == id }) { scope = .all }
        if !checkedRecovery { checkedRecovery = true; checkCrashRecovery() }
    }

    public func refreshSoon() { scanTask?.cancel(); scanTask = Task { await refresh() } }

    // MARK: Crash recovery (PM-004)

    func checkCrashRecovery() {
        let urls = entries.filter { $0.trashedAt == nil }.map(\.url)
        let crashed = CrashRecovery.crashedProjects(in: urls)
        if !crashed.isEmpty, modal == nil { modal = .recovery(crashed) }
    }

    public func recover(_ url: URL) {
        modal = nil
        open(url)
    }

    public func dismissRecovery(_ urls: [URL]) {
        modal = nil
        for u in urls { CrashRecovery.dismiss(u) }
    }

    // MARK: Open / new / close

    /// CapCut "New project": one click → empty editor (name MMDD, settings from Settings ▸ Edit).
    public func newProject(settings: ProjectSettings? = nil, name: String? = nil) {
        let names = Set(entries.filter { $0.trashedAt == nil }.map(\.name))
        var p = Project(name: name.flatMap { $0.isEmpty ? nil : $0 } ?? ProjectLibrary.defaultName(existing: names),
                        settings: settings ?? preferences.newProjectSettings())
        p.modifiedAt = Date()
        let folder: UUID? = { if case .folder(let id) = scope { return id }; return nil }()
        do {
            let url = try library.create(p, folder: folder)
            enterEditor { $0.store.load(project: p, packageURL: url) }
        } catch {
            store.showToast(tr("toast.saveFailed"), error: true)
        }
    }

    /// Opens a project package in the editor (Home card, File ▸ Open, Finder, recovery).
    public func open(_ url: URL) {
        if store.packageURL?.standardizedFileURL == url.standardizedFileURL, screen == .editor { return }
        if SessionLock.isHeldByOtherProcess(url) { store.showToast(tr("error.openElsewhere"), error: true); return }
        let lib = library
        Task {
            if screen == .editor { await store.closeProject() }
            do {
                try store.open(url)
                lib.noteOpened(url)
                enterEditor { _ in }
                if !store.missingMedia.isEmpty { modal = .relink }
            } catch let e as PersistenceError {
                store.showToast(tr(e.messageKey), error: true)
            } catch {
                store.showToast(tr("error.unreadable"), error: true)
            }
        }
    }

    /// Shows an already loaded project (demo, tests).
    public func showEditor() { enterEditor { _ in } }

    private func enterEditor(_ load: (AppModel) -> Void) {
        load(self)
        store.persistsPreferences = true
        preferences.apply(to: store)
        isTransitioning = true
        screen = .editor
        selectedIDs = []
        Task { try? await Task.sleep(for: .milliseconds(250)); isTransitioning = false }
    }

    /// Montage ▸ Back to home page: saves (toast "Saved to project"), refreshes the cover, shows Home.
    public func backToHome() {
        guard screen == .editor else { return }
        let hadProject = store.packageURL != nil
        Task {
            await store.closeProject()
            store.load(project: Project())
            screen = .home
            await refresh()
            if hadProject { store.showToast(tr("home.savedToProject")) }
        }
    }

    // MARK: Project operations (Home)

    func run(_ body: @escaping @Sendable (ProjectLibrary) throws -> Void) {
        let lib = library
        Task {
            do { try await Task.detached { try body(lib) }.value } catch let e as PersistenceError {
                store.showToast(tr(e.messageKey), error: true)
            } catch {
                store.showToast(tr("home.error.fileOperation"), error: true)
            }
            await refresh()
        }
    }

    public func rename(_ e: LibraryEntry, to name: String) {
        let url = e.url
        renamingID = nil
        guard name != e.name, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        run { lib in try lib.rename(url, to: name) }
    }

    public func duplicate(_ items: [LibraryEntry]) {
        let urls = items.map(\.url)
        run { lib in for u in urls { try lib.duplicate(u) } }
    }

    /// Delete = move to Trash with an Undo toast (no confirmation, UX.md §2.1).
    public func trash(_ items: [LibraryEntry]) {
        let urls = items.map(\.url)
        let lib = library
        Task {
            do {
                lastTrashed = try await Task.detached { try lib.moveToTrash(urls) }.value
                store.showToast(tr("home.trashed", urls.count))
            } catch {
                store.showToast(tr("home.error.fileOperation"), error: true)
            }
            selectedIDs = []
            await refresh()
        }
    }

    public func undoTrash() {
        let urls = lastTrashed
        lastTrashed = []
        run { lib in for u in urls { try lib.restore(u) } }
    }

    public func restore(_ items: [LibraryEntry]) {
        let urls = items.map(\.url)
        run { lib in for u in urls { try lib.restore(u) } }
    }

    public func deletePermanently(_ items: [LibraryEntry]) {
        let urls = items.map(\.url)
        run { lib in for u in urls { try lib.deletePermanently(u) } }
    }

    public func emptyTrash() { run { lib in lib.emptyTrash() } }

    public func move(_ items: [LibraryEntry], to folder: UUID?) {
        let urls = items.map(\.url)
        run { lib in lib.move(urls, to: folder) }
    }

    public func createFolder(named name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        let lib = library
        Task {
            let f = await Task.detached { lib.createFolder(named: n.isEmpty ? tr("home.folder.new") : n) }.value
            await refresh()
            scope = .folder(f.id)
        }
    }

    public func renameFolder(_ f: ProjectFolder, to name: String) { let id = f.id; run { lib in lib.renameFolder(id, to: name) } }
    public func deleteFolder(_ f: ProjectFolder) {
        let id = f.id
        if scope == .folder(id) { scope = .all }
        run { lib in lib.deleteFolder(id) }
    }

    public func revealInFinder(_ e: LibraryEntry) { NSWorkspace.shared.activateFileViewerSelecting([e.url]) }

    /// Home ▸ Import project (a `.montage` package or a packed `.zip`).
    public func importProjectPanel() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [UTType(filenameExtension: ProjectPackage.fileExtension) ?? .package, .zip]
        p.allowsMultipleSelection = true
        p.canChooseDirectories = true
        p.treatsFilePackagesAsDirectories = false
        guard p.runModal() == .OK else { return }
        importProjects(p.urls)
    }

    public func importProjects(_ urls: [URL]) {
        let lib = library
        Task {
            var ok = 0
            for u in urls {
                if (try? await Task.detached { try lib.importProject(from: u) }.value) != nil { ok += 1 }
            }
            if ok > 0 { store.showToast(tr("home.imported", ok)) } else { store.showToast(tr("home.error.import"), error: true) }
            await refresh()
        }
    }

    /// Pack project (current editor project, or a Home card).
    public func packPanel(_ entry: LibraryEntry? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = tr("pack.choose")
        panel.message = tr("pack.message")
        let zipBox = NSButton(checkboxWithTitle: tr("pack.zip"), target: nil, action: nil)
        zipBox.state = .on
        panel.accessoryView = zipBox
        panel.isAccessoryViewDisclosed = true
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let zip = zipBox.state == .on
        if let entry, !(screen == .editor && store.packageURL?.standardizedFileURL == entry.url) {
            let url = entry.url
            Task {
                let box = PackBox()
                let id = await JobQueue.shared.enqueue(titleKey: "job.pack", priority: 1) { progress in
                    let p = try ProjectPackage.load(from: url)
                    box.url = try ProjectPacker.pack(p, from: url, into: dir, zip: zip) { progress.report($0) }
                }
                if await JobQueue.shared.wait(id) == .done, let u = box.url {
                    store.showToast(tr("toast.packed", u.lastPathComponent))
                    NSWorkspace.shared.activateFileViewerSelecting([u])
                } else {
                    store.showToast(tr("toast.packFailed"), error: true)
                }
            }
        } else {
            store.packProject(to: dir, zip: zip)
        }
    }

    // MARK: Cache (per project)

    public func computeCacheSize(_ e: LibraryEntry) {
        let url = e.url, id = e.id
        Task {
            let size = await Task.detached(priority: .utility) { () -> Int64 in
                guard let p = try? ProjectPackage.load(from: url) else { return 0 }
                return CacheManager().size(forHashes: Set(p.media.map(\.contentHash)))
            }.value
            cacheSizes[id] = size
        }
    }

    public func clearCache(_ e: LibraryEntry) {
        let url = e.url, id = e.id
        Task {
            let hashes = await Task.detached { (try? ProjectPackage.load(from: url)).map { Set($0.media.map(\.contentHash)) } ?? [] }.value
            CacheCleaner.clear(project: hashes)
            cacheSizes[id] = 0
            store.showToast(tr("cache.cleared"))
        }
    }

    // MARK: Open panels

    public func openPanel() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [UTType(filenameExtension: ProjectPackage.fileExtension) ?? .package]
        p.treatsFilePackagesAsDirectories = false
        p.canChooseDirectories = true
        if p.runModal() == .OK, let u = p.url {
            if u.pathExtension == ProjectPackage.fileExtension { open(u) } else { store.showToast(tr("error.notAPackage"), error: true) }
        }
    }
}
