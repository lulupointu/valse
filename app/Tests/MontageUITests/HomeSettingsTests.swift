import Testing
import Foundation
import AppKit
import MontageCore
import MontageEngine
@testable import MontageUI

/// W12: keymap (presets, conflicts, overrides, persistence), app preferences (export defaults, new-project defaults),
/// Home formatting (localized sizes, plurals) and the AppModel project flows over a temporary library.
@MainActor @Suite(.serialized) struct HomeSettingsTests {
    func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("montage-w12-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    // MARK: Keymap

    @Test(arguments: KeymapPreset.allCases) func presetsHaveNoConflicts(_ preset: KeymapPreset) {
        let k = Keymap(url: nil)
        k.selectPreset(preset)
        for e in k.entries {
            guard let b = k.binding(for: e.id) else { continue }
            let c = k.conflicts(for: b, excluding: e.id)
            #expect(c.isEmpty, "\(preset): \(b.display) on \(e.id) also bound to \(c.map(\.id))")
        }
    }

    @Test func presetsDifferFromCapCut() {
        let k = Keymap(url: nil)
        #expect(k.binding(for: "split") == KeyBinding(key: "b", modifiers: .command))
        #expect(k.binding(for: "deleteLeft") == KeyBinding(key: "q"))
        k.selectPreset(.premiere)
        #expect(k.binding(for: "split") == KeyBinding(key: "k", modifiers: .command))
        k.selectPreset(.finalCut)
        #expect(k.binding(for: "deleteLeft") == KeyBinding(key: "[", modifiers: .option))
    }

    @Test func conflictDetectionAndOverride() {
        let k = Keymap(url: nil)
        let cmdB = KeyBinding(key: "b", modifiers: .command)
        #expect(k.conflicts(for: cmdB, excluding: "deleteLeft").map(\.id).contains("split"))
        #expect(k.conflicts(for: KeyBinding(key: "k", modifiers: [.command, .option, .control]), excluding: "split").isEmpty)
        k.assign(cmdB, to: "deleteLeft")  // "Override": the old owner loses the key
        #expect(k.binding(for: "deleteLeft") == cmdB)
        #expect(k.binding(for: "split") == nil)
        #expect(k.isModified)
        k.reset("split")
        #expect(k.binding(for: "split") == cmdB)
        k.resetAll()
        #expect(!k.isModified && k.binding(for: "deleteLeft") == KeyBinding(key: "q"))
    }

    @Test func registryShortcutsFollowTheKeymap() {
        let k = Keymap(url: nil)
        let split = ShortcutRegistry.all.first { $0.id == "split" }!
        #expect(k.matches(split, KeyBinding(key: "b", modifiers: .command)))
        k.set("split", KeyBinding(key: "x", modifiers: [.command, .option]))
        #expect(!k.matches(split, KeyBinding(key: "b", modifiers: .command)))
        #expect(k.matches(split, KeyBinding(key: "x", modifiers: [.command, .option])))
    }

    @Test func keymapPersists() {
        let url = tempDir().appendingPathComponent("keymap.json")
        let k = Keymap(url: url)
        k.selectPreset(.finalCut)
        k.set("marker", KeyBinding(key: "m", modifiers: [.control]))
        k.set("inPoint", nil)
        let again = Keymap(url: url)
        #expect(again.preset == .finalCut)
        #expect(again.binding(for: "marker") == KeyBinding(key: "m", modifiers: [.control]))
        #expect(again.binding(for: "inPoint") == nil)
        #expect(again.binding(for: "outPoint") == KeyBinding(key: "o"))
    }

    @Test func copyAndAdoptStageEdits() {
        let k = Keymap(url: nil)
        let draft = k.copy()
        draft.set("marker", KeyBinding(key: "j", modifiers: [.command, .shift]))
        #expect(k.binding(for: "marker") == KeyBinding(key: "m"))  // Cancel: nothing applied
        k.adopt(draft)
        #expect(k.binding(for: "marker") == KeyBinding(key: "j", modifiers: [.command, .shift]))
    }

    // MARK: Preferences

    @Test func exportDefaultsFollowSettingsAndProject() {
        var s = AppSettings()
        var p = Project()
        p.settings.canvasSize = Size2(1080, 1920)
        p.settings.frameRate = .fps25
        var e = AppPreferences.exportDefaults(s, for: p)
        #expect(e.resolution == .p1080)       // follows the project's short side
        #expect(e.frameRate == .fps25)
        #expect(e.codec == .h264)
        s.exportResolution = 720
        s.exportFrameRate = 60
        s.exportCodec = "hevc"
        s.hardwareEncoding = false
        e = AppPreferences.exportDefaults(s, for: p)
        #expect(e.resolution == .p720 && e.frameRate.fps == 60 && e.codec == .hevc && !e.preferHardware)
        // EX-016: "Faster exporting" only applies with the hardware encoder
        s.fastExport = true
        #expect(!AppPreferences.exportDefaults(s, for: p).fastEncoding)
        s.hardwareEncoding = true
        #expect(AppPreferences.exportDefaults(s, for: p).fastEncoding)
    }

    @Test func firstExportUsesSettingsDefaults() {
        let saved = ExportDialogModel.firstExportDefaults
        defer { ExportDialogModel.firstExportDefaults = saved }
        let folder = tempDir()
        var s = AppSettings(); s.exportResolution = 720; s.exportCodec = "hevc"
        ExportDialogModel.firstExportDefaults = { [s] p in (AppPreferences.exportDefaults(s, for: p), folder) }
        let suite = "montage.w12.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let m = ExportDialogModel(project: Project(), title: "t", selection: [], defaults: d)
        #expect(m.remembered.video.resolution == .p720)
        #expect(m.remembered.video.codec == .hevc)
        #expect(m.folder.standardizedFileURL == folder.standardizedFileURL)
        // once the dialog remembered choices, they win over the settings defaults
        m.remembered.video.resolution = .p1080
        m.save(defaults: d)
        let again = ExportDialogModel(project: Project(), title: "t", selection: [], defaults: d)
        #expect(again.remembered.video.resolution == .p1080)
    }

    @Test func preferencesPersistAndApplyEditDefaults() {
        let url = tempDir().appendingPathComponent("settings.json")
        let prefs = AppPreferences(url: url)
        let before = EditDefaults.current
        defer { EditDefaults.current = before }
        prefs.edit { $0.imageDuration = 3; $0.stepFrames = 5; $0.defaultRatio = "9:16" }
        #expect(EditDefaults.current.imageDuration == Time(3))
        #expect(EditDefaults.current.stepFrames == 5)
        #expect(AppSettings.load(from: url).imageDuration == 3)
        let s = prefs.newProjectSettings()
        #expect(s.aspectPreset == "9:16" && s.canvasSize.height > s.canvasSize.width)
    }

    // MARK: Formatting

    @Test func sizesAndPluralsAreLocalized() {
        MontageBootstrap.registerResources()
        let lang = L10n.shared.language
        defer { L10n.shared.setLanguageForSession(lang) }
        L10n.shared.setLanguageForSession("en")
        #expect(HomeFormat.bytes(0) == "0 bytes")
        #expect(HomeFormat.bytes(1_500_000) == "1.5 MB")
        #expect(trCount("home.trashed", 1) == "Moved 1 project to the Trash")
        #expect(trCount("home.trashed", 3) == "Moved 3 projects to the Trash")
        L10n.shared.setLanguageForSession("fr")
        #expect(HomeFormat.bytes(0) == "0 octet")
        #expect(HomeFormat.bytes(31_200_000) == "31 Mo")
        #expect(HomeFormat.bytes(1_500_000) == "1,5 Mo")
        #expect(trCount("home.trashed", 1) == "1 projet placé dans la corbeille")
        #expect(trCount("home.trashed", 2) == "2 projets placés dans la corbeille")
    }

    @Test func homeDurations() {
        #expect(HomeFormat.duration(Time(7)) == "00:07")
        #expect(HomeFormat.duration(Time(183)) == "03:03")
        #expect(HomeFormat.duration(Time(3725)) == "1:02:05")
    }

    // MARK: AppModel flows

    func appModel() -> (AppModel, ProjectLibrary) {
        let d = tempDir()
        let lib = ProjectLibrary(root: d.appendingPathComponent("Drafts"), indexURL: d.appendingPathComponent("library.json"))
        let store = EditorStore()
        store.autosaveEnabled = false
        let app = AppModel(store: store, preferences: AppPreferences(url: nil), library: lib)
        return (app, lib)
    }

    @Test func newProjectOpensTheEditorWithCapCutDefaults() async throws {
        let (app, _) = appModel()
        await app.refresh()
        #expect(app.screen == .home && app.entries.isEmpty)
        app.newProject()
        #expect(app.screen == .editor)
        #expect(app.store.packageURL != nil)              // saved from the start (no "Not saved yet")
        #expect(app.store.project.name.count >= 4)        // MMDD
        #expect(app.store.project.settings.aspectPreset == "original")
        await app.store.closeProject()
        await app.refresh()
        #expect(app.entries.count == 1)
    }

    /// F4 PM-014: Open in new window launches another instance with `--open`; a project open in another window is
    /// brought forward instead of opened twice.
    @Test func openInNewWindowLaunchesOrFocuses() async throws {
        let (app, lib) = appModel()
        let a = try lib.create(Project(name: "A")), b = try lib.create(Project(name: "B"))
        await app.refresh()
        var launched: [URL?] = []
        let saved = ProjectWindows.launcher
        defer { ProjectWindows.launcher = saved }
        ProjectWindows.launcher = { launched.append($0); return true }
        #expect(ProjectWindows.arguments(for: a) == ["--open", a.path])
        #expect(ProjectWindows.arguments(for: nil).isEmpty)
        app.openInNewWindow(a)
        app.newWindow()
        #expect(launched.count == 2 && launched[0] == a && launched[1] == nil)
        try "1".write(to: b.appendingPathComponent(SessionLock.fileName), atomically: true, encoding: .utf8)   // pid 1: alive
        #expect(SessionLock.holderPID(b) == 1)
        app.openInNewWindow(b)
        #expect(launched.count == 2)                       // focused, not launched
        app.open(b)
        #expect(app.screen == .home)                       // not opened twice
        SessionLock.release(b)
        #expect(SessionLock.holderPID(b) == nil)
    }

    @Test func trashUndoAndFolders() async throws {
        let (app, lib) = appModel()
        for n in ["A", "B", "C"] { _ = try lib.create(Project(name: n)) }
        await app.refresh()
        #expect(app.visibleEntries.count == 3)
        app.selectedIDs = [app.visibleEntries.first { $0.name == "B" }!.id]
        app.trashOrDeleteSelection()
        try await waitUntil { app.trashCount == 1 }
        #expect(app.visibleEntries.map(\.name).sorted() == ["A", "C"])
        app.undoTrash()
        try await waitUntil { app.trashCount == 0 }
        app.createFolder(named: "Clients")
        try await waitUntil { app.folders.count == 1 }
        app.move(app.entries.filter { $0.name == "A" }, to: app.folders[0].id)
        try await waitUntil { app.entries.first { $0.name == "A" }?.folderID != nil }
        app.scope = .folder(app.folders[0].id)
        #expect(app.visibleEntries.map(\.name) == ["A"])
        app.scope = .all
        app.isSearching = true
        app.search = "c"
        #expect(app.visibleEntries.map(\.name) == ["C"])
    }

    @Test func crashedProjectsPromptRecovery() async throws {
        let (app, lib) = appModel()
        let url = try lib.create(Project(name: "Crashed"))
        try "99999999".write(to: url.appendingPathComponent(SessionLock.fileName), atomically: true, encoding: .utf8)
        await app.refresh()
        guard case .recovery(let urls) = app.modal else { Issue.record("no recovery prompt"); return }
        #expect(urls.map(\.standardizedFileURL.path) == [url.standardizedFileURL.path])
        app.dismissRecovery([url])
        #expect(app.modal == nil)
        #expect(!CrashRecovery.hasStaleLock(url))
    }

    func waitUntil(timeout: Double = 5, _ cond: @MainActor () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > end { Issue.record("timed out"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
