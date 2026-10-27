import Testing
import Foundation
@testable import ValseCore

/// P1 project switcher: ordering, search, selection wrap, row status from injected providers, the pre-close check
/// order and the stale-lock rule (only another running Valse process holds a lock).
@Suite struct ProjectSwitcherModelTests {
    let t0 = Date(timeIntervalSince1970: 1_768_478_400)

    func entry(_ name: String, modified: Double, opened: Double? = nil, trashed: Bool = false, dir: String = "/lib") -> LibraryEntry {
        var p = Project(name: name)
        p.modifiedAt = t0.addingTimeInterval(modified)
        return LibraryEntry(url: URL(fileURLWithPath: "\(dir)/\(name).valse"), summary: ProjectSummary(p), sizeBytes: 0, folderID: nil,
                            lastOpened: opened.map { t0.addingTimeInterval($0) }, trashedAt: trashed ? t0 : nil, coverURL: nil)
    }

    var sample: [LibraryEntry] {
        [entry("Old never opened", modified: -900), entry("New never opened", modified: -100),
         entry("Opened long ago", modified: -50, opened: -5000), entry("Opened recently", modified: -800, opened: -10),
         entry("Current", modified: -2000, opened: -9000), entry("Trashed", modified: 0, opened: 0, trashed: true),
         entry("Interview Léa", modified: -300)]
    }

    @Test func orderingCurrentFirstThenLastOpenedThenModified() {
        let current = URL(fileURLWithPath: "/lib/Current.valse")
        let names = ProjectSwitcherModel.ordered(sample, current: current).map(\.name)
        #expect(names == ["Current", "Opened recently", "Opened long ago", "New never opened", "Interview Léa", "Old never opened"])
        #expect(!names.contains("Trashed"))
    }

    @Test func searchIsCaseAndDiacriticInsensitive() {
        #expect(ProjectSwitcherModel.ordered(sample, current: nil, search: "lea").map(\.name) == ["Interview Léa"])
        #expect(ProjectSwitcherModel.ordered(sample, current: nil, search: "OPENED").count == 4)
        #expect(ProjectSwitcherModel.ordered(sample, current: nil, search: "zzz").isEmpty)
    }

    @Test func selectionStartsAfterCurrentAndWraps() {
        let current = URL(fileURLWithPath: "/lib/Current.valse")
        let rows = ProjectSwitcherModel.rows(sample, current: current, heldElsewhere: { _ in false }, offline: { _ in false })
        #expect(ProjectSwitcherModel.initialSelection(rows) == 1)
        #expect(ProjectSwitcherModel.move(5, by: 1, count: 6) == 0)
        #expect(ProjectSwitcherModel.move(0, by: -1, count: 6) == 5)
        #expect(ProjectSwitcherModel.move(nil, by: 1, count: 6) == 0)
        #expect(ProjectSwitcherModel.move(nil, by: -1, count: 6) == 5)
        #expect(ProjectSwitcherModel.move(2, by: 1, count: 0) == nil)
        let only = ProjectSwitcherModel.rows([entry("Current", modified: 0)], current: current, heldElsewhere: { _ in false }, offline: { _ in false })
        #expect(ProjectSwitcherModel.initialSelection(only) == 0)
        #expect(ProjectSwitcherModel.initialSelection([]) == nil)
    }

    @Test func rowStatusFromInjectedProviders() {
        let current = URL(fileURLWithPath: "/lib/Current.valse")
        let rows = ProjectSwitcherModel.rows(sample, current: current,
                                             heldElsewhere: { $0.lastPathComponent == "Opened recently.valse" },
                                             offline: { $0.lastPathComponent == "Interview Léa.valse" })
        let status = Dictionary(uniqueKeysWithValues: rows.map { ($0.entry.name, $0.status) })
        #expect(status["Current"] == .current)
        #expect(status["Opened recently"] == .otherWindow)
        #expect(status["Interview Léa"] == .offline)
        #expect(status["Old never opened"] == .normal)
        #expect(rows.first?.isCurrent == true)
    }

    @Test func duplicateNamesShowWhereTheyLive() {
        let a = entry("1018", modified: 0, dir: "/lib"), b = entry("1018", modified: -10, dir: "/Volumes/SSD")
        let rows = ProjectSwitcherModel.rows([a, b, entry("Other", modified: -20)], current: nil, heldElsewhere: { _ in false }, offline: { _ in false })
        #expect(rows.map(\.disambiguation) == ["lib", "SSD", nil])
    }

    /// The checks run in the spec order and never touch the current project (the UI calls `closeProject` only on `.ok`).
    @Test func guardOrder() {
        let u = URL(fileURLWithPath: "/lib/B.valse"), cur = URL(fileURLWithPath: "/lib/A.valse")
        var calls: [String] = []
        func run(held: Int32?, loc: StorageLocation, readable: Bool, current: URL? = cur) -> ProjectSwitcherModel.OpenCheck {
            calls = []
            return ProjectSwitcherModel.check(u, current: current, holderPID: { _ in calls.append("lock"); return held },
                                              location: { _ in calls.append("drive"); return loc },
                                              readable: { _ in calls.append("summary"); return readable })
        }
        #expect(run(held: nil, loc: .internalDisk, readable: true, current: u) == .alreadyCurrent)
        #expect(calls.isEmpty)
        #expect(run(held: 42, loc: .unavailable(name: "SSD"), readable: false) == .heldElsewhere(pid: 42))
        #expect(calls == ["lock"])
        #expect(run(held: nil, loc: .unavailable(name: "SSD"), readable: false) == .offline(drive: "SSD"))
        #expect(calls == ["lock", "drive"])
        #expect(run(held: nil, loc: .external(name: "SSD"), readable: false) == .unreadable)
        #expect(calls == ["lock", "drive", "summary"])
        #expect(run(held: nil, loc: .internalDisk, readable: true) == .ok)
    }

    // MARK: Stale lock (holderPID)

    func package() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("valse-p1-\(UUID().uuidString)/P.valse")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @Test func aLiveNonValsePidIsAStaleLock() throws {
        let pkg = try package()
        defer { try? FileManager.default.removeItem(at: pkg.deletingLastPathComponent()) }
        // the test runner's parent (swift-test / Xcode helper): alive, but not Valse — pid reuse after a crash
        let other = getppid()
        try "\(other)".write(to: pkg.appendingPathComponent(SessionLock.fileName), atomically: true, encoding: .utf8)
        #expect(SessionLock.isAlive(other))
        #expect(!SessionLock.isValseHolder(other))
        #expect(SessionLock.holderPID(pkg) == nil)
        #expect(!SessionLock.isHeldByOtherProcess(pkg))
        #expect(SessionLock.isStale(pkg))
        #expect(CrashRecovery.hasStaleLock(pkg))
        // the same pid when it IS a running Valse (injected) holds the lock
        #expect(SessionLock.holderPID(pkg, isValse: { $0 == other }) == other)
        #expect(!SessionLock.isStale(pkg, isValse: { $0 == other }))
        // a dead pid: stale; our own pid: neither held elsewhere nor stale
        try "99999999".write(to: pkg.appendingPathComponent(SessionLock.fileName), atomically: true, encoding: .utf8)
        #expect(SessionLock.holderPID(pkg, isValse: { _ in true }) == 99999999)   // injected matcher decides
        #expect(SessionLock.holderPID(pkg) == nil)
        #expect(SessionLock.isStale(pkg))
        #expect(SessionLock.acquire(pkg) == true)   // crash recovery semantics
        #expect(SessionLock.holderPID(pkg) == nil && !SessionLock.isStale(pkg))
        SessionLock.release(pkg)
    }

    @Test func bundleIdentifierOfAnAppExecutable() {
        #expect(SessionLock.bundleIdentifier(ofExecutable: URL(fileURLWithPath: "/usr/bin/swift")) == nil)
        let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder")
        #expect(SessionLock.bundleIdentifier(ofExecutable: finder) == "com.apple.finder")
    }
}
