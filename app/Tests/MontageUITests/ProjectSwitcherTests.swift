import Testing
import Foundation
import AppKit
import MontageCore
import MontageEngine
@testable import MontageUI

/// P1 project switcher: safe switching in `AppModel.open` (every check before the current project closes, the previous
/// project comes back when the open fails), the switcher's rows / keys / actions, and the red close button → Home.
@MainActor @Suite(.serialized) struct ProjectSwitcherTests {
    func appModel() -> (AppModel, ProjectLibrary) {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("montage-p1-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let lib = ProjectLibrary(root: d.appendingPathComponent("Drafts"), indexURL: d.appendingPathComponent("library.json"))
        let store = EditorStore()
        store.autosaveEnabled = false
        return (AppModel(store: store, preferences: AppPreferences(url: nil), library: lib), lib)
    }

    func waitUntil(timeout: Double = 30, _ cond: @MainActor () -> Bool) async throws {   // hang bound (load)
        let end = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > end { Issue.record("timed out"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func same(_ a: URL?, _ b: URL) -> Bool { a?.standardizedFileURL.path == b.standardizedFileURL.path }

    /// A live process that isn't Montage, registered as a Montage-like lock holder (another window).
    func liveHolder() throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["60"]
        try p.run()
        SessionLock.registerTestHolder(p.processIdentifier)
        return p
    }

    func openA(_ app: AppModel, _ a: URL) async throws {
        app.open(a)
        try await waitUntil { app.screen == .editor && self.same(app.store.packageURL, a) }
        #expect(SessionLock.lockPID(a) == getpid())
    }

    @Test func aFailedCheckNeverClosesTheCurrentProject() async throws {
        let (app, lib) = appModel()
        let a = try lib.create(Project(name: "A")), held = try lib.create(Project(name: "Held"))
        let gone = try lib.create(Project(name: "Gone")), offline = try lib.create(Project(name: "Offline"))
        try await openA(app, a)
        // held by another running Montage window → focus it, A stays open (its lock is still ours = never closed)
        let holder = try liveHolder()
        defer { SessionLock.unregisterTestHolder(holder.processIdentifier); holder.terminate() }
        try "\(holder.processIdentifier)".write(to: held.appendingPathComponent(SessionLock.fileName), atomically: true, encoding: .utf8)
        app.open(held)
        #expect(app.store.toast?.message == tr("pm.window.alreadyOpen"))
        // summary unreadable (deleted / trashed elsewhere)
        try FileManager.default.removeItem(at: gone)
        app.open(gone)
        #expect(app.store.toast?.message == tr("error.unreadable"))
        // drive not connected
        StorageLocation.testOverrides[offline.standardizedFileURL.path] = .unavailable(name: "SSD")
        defer { StorageLocation.testOverrides[offline.standardizedFileURL.path] = nil }
        app.open(offline)
        #expect(app.store.toast?.message == tr("pm.drive.projectOffline", "SSD"))
        try await Task.sleep(for: .milliseconds(200))
        #expect(app.screen == .editor && same(app.store.packageURL, a))
        #expect(SessionLock.lockPID(a) == getpid())       // closeProject would have released it
        // the same project: nothing happens
        app.open(a)
        #expect(same(app.store.packageURL, a))
    }

    @Test func aFailedOpenRestoresThePreviousProject() async throws {
        let (app, lib) = appModel()
        let a = try lib.create(Project(name: "A")), broken = try lib.create(Project(name: "Broken"))
        // summary.json is fine (passes the checks) but project.json is corrupt: the open fails after A was closed
        try Data("{ not json".utf8).write(to: broken.appendingPathComponent(ProjectPackage.projectFileName))
        try await openA(app, a)
        app.open(broken)
        try await waitUntil { app.store.toast?.isError == true }
        #expect(app.screen == .editor)
        #expect(same(app.store.packageURL, a))
        #expect(app.store.projectName == "A")
        #expect(SessionLock.lockPID(a) == getpid())
        #expect(SessionLock.lockPID(broken) == nil)
    }

    @Test func switchingSavesAndShowsTheToast() async throws {
        let (app, lib) = appModel()
        let a = try lib.create(Project(name: "A")), b = try lib.create(Project(name: "B"))
        try await openA(app, a)
        _ = app.store.perform(Edit("cmd.rename") { $0.name = "A edited" })
        app.open(b)
        try await waitUntil { self.same(app.store.packageURL, b) }
        #expect(app.store.toast?.message == tr("home.savedToProject"))
        #expect(try ProjectPackage.load(from: a).name == "A edited")   // saved on close
        #expect(SessionLock.lockPID(a) == nil && SessionLock.lockPID(b) == getpid())
    }

    @Test func switcherRowsKeysAndActions() async throws {
        let (app, lib) = appModel()
        let a = try lib.create(Project(name: "Alpha")), _ = try lib.create(Project(name: "Interview Léa")), _ = try lib.create(Project(name: "Zed"))
        await app.refresh()
        let sw = app.switcher
        sw.open()
        #expect(!sw.isOpen)                               // Home: no switcher
        try await openA(app, a)
        await app.refresh()
        sw.open()
        #expect(sw.isOpen)
        #expect(sw.rows.count == 3 && sw.rows[0].isCurrent && sw.rows[0].entry.name == "Alpha")
        #expect(sw.selected == 1)
        func key(_ code: UInt16, _ chars: String = "", _ mods: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0, context: nil,
                             characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        }
        #expect(sw.handle(key(125)))                      // ↓
        #expect(sw.selected == 2)
        #expect(sw.handle(key(125)))                      // wraps
        #expect(sw.selected == 0)
        #expect(sw.handle(key(126)))
        #expect(sw.selected == 2)
        sw.query = "lea"
        #expect(sw.rows.map(\.entry.name) == ["Interview Léa"] && sw.selected == 0)
        #expect(sw.handle(key(0, "x")))                   // typing goes to the search even without a focused field
        #expect(sw.query == "leax" && sw.rows.isEmpty && sw.selected == nil)
        #expect(sw.handle(key(53)))                       // esc clears the search…
        #expect(sw.isOpen && sw.query.isEmpty)
        #expect(sw.handle(key(53)))                       // …then closes
        #expect(!sw.isOpen)
        // ⌘↩ opens the selection in a new window (recorded), the current project stays
        var launched: [URL?] = []
        let saved = ProjectWindows.launcher
        defer { ProjectWindows.launcher = saved }
        ProjectWindows.launcher = { launched.append($0); return true }
        sw.open()
        #expect(sw.handle(key(36, "\r", .command)))
        #expect(launched.count == 1 && !sw.isOpen && same(app.store.packageURL, a))
        // no switching in the middle of a drag
        app.store.beginGesture("cmd.move")
        sw.toggle()
        #expect(!sw.isOpen)
        app.store.endGesture()
        // All projects = Home
        sw.open()
        sw.showHome()
        try await waitUntil { app.screen == .home }
        #expect(!sw.isOpen)
    }

    @Test func relativeEditedDates() {
        let saved = L10n.shared.language
        defer { L10n.shared.setLanguageForSession(saved) }
        L10n.shared.setLanguageForSession("en")
        let cal = Calendar.current
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 15))!
        #expect(ProjectSwitcher.edited(cal.date(byAdding: .hour, value: -1, to: now)!, now: now).hasPrefix("Edited today "))
        #expect(ProjectSwitcher.edited(cal.date(byAdding: .day, value: -1, to: now)!, now: now) == "Edited yesterday")
        #expect(ProjectSwitcher.edited(cal.date(from: DateComponents(year: 2026, month: 10, day: 14))!, now: now) == "Edited Oct 14")
        L10n.shared.setLanguageForSession("fr")
        #expect(ProjectSwitcher.edited(cal.date(byAdding: .day, value: -1, to: now)!, now: now) == "Modifié hier")
        #expect(ProjectSwitcher.edited(cal.date(byAdding: .hour, value: -1, to: now)!, now: now).hasPrefix("Modifié aujourd'hui à "))
    }

    /// Opt-in hand check on real projects: `MONTAGE_P1_PROJECTS=<folder with COPIES of 1018.montage + 1019.montage>`.
    /// 1019's lock is rewritten to a live non-Montage pid (the stale lock a killed run leaves once its pid is reused):
    /// it must open normally; then 1019 → 1018 → 1019 through the switcher, with the toast and no data loss.
    @Test func realProjectsSwitch() async throws {
        guard let dir = ProcessInfo.processInfo.environment["MONTAGE_P1_PROJECTS"] else { return }
        let root = URL(fileURLWithPath: dir)
        let lib = ProjectLibrary(root: root, indexURL: root.appendingPathComponent("library-p1.json"))
        let store = EditorStore()
        store.autosaveEnabled = false
        let app = AppModel(store: store, preferences: AppPreferences(url: nil), library: lib)
        let a = root.appendingPathComponent("1019.montage"), b = root.appendingPathComponent("1018.montage")
        let other = try Process.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["60"])
        defer { other.terminate() }
        try "\(other.processIdentifier)".write(to: a.appendingPathComponent(SessionLock.fileName), atomically: true, encoding: .utf8)
        #expect(SessionLock.holderPID(a) == nil && CrashRecovery.hasStaleLock(a))
        await app.refresh(checkRecovery: false)
        let before = (try ProjectPackage.load(from: a).timeline.allClips.count, try ProjectPackage.load(from: b).timeline.allClips.count)
        let t0 = Date()
        app.open(a)
        try await waitUntil(timeout: 20) { self.same(app.store.packageURL, a) && app.screen == .editor }
        print("P1 real: opened 1019 in \(Int(Date().timeIntervalSince(t0) * 1000)) ms, toast \(app.store.toast?.message ?? "-")")
        app.switcher.open()
        print("P1 real rows: \(app.switcher.rows.map { "\($0.entry.name)[\($0.status.rawValue)]" })")
        app.switcher.query = "1018"
        let i = try #require(app.switcher.rows.firstIndex { $0.entry.name == "1018" })
        let t1 = Date()
        app.switcher.activate(i)
        try await waitUntil(timeout: 20) { self.same(app.store.packageURL, b) }
        print("P1 real: switched 1019 → 1018 in \(Int(Date().timeIntervalSince(t1) * 1000)) ms, toast \(app.store.toast?.message ?? "-")")
        #expect(app.store.toast?.message == tr("home.savedToProject"))
        #expect(SessionLock.lockPID(a) == nil && SessionLock.lockPID(b) == getpid())
        app.switcher.open()
        #expect(app.switcher.rows.first?.entry.name == "1018" && app.switcher.rows[1].entry.name == "1019")
        app.switcher.submit(newWindow: false)   // initial selection = 1019 (last opened)
        try await waitUntil(timeout: 20) { self.same(app.store.packageURL, a) }
        #expect(app.store.project.timeline.allClips.count == before.0)
        await app.store.closeProject()
        #expect(try ProjectPackage.load(from: b).timeline.allClips.count == before.1)
    }

    /// CapCut parity: the red close button in the editor goes back to Home instead of quitting.
    @Test func closeButtonGoesBackHome() async throws {
        let (app, lib) = appModel()
        let a = try lib.create(Project(name: "A"))
        #expect(app.windowShouldClose())                  // Home: the window closes (quits)
        try await openA(app, a)
        #expect(!app.windowShouldClose())
        try await waitUntil { app.screen == .home }
        try await waitUntil { app.store.toast?.message == tr("home.savedToProject") }
        #expect(SessionLock.lockPID(a) == nil)
    }
}
