import Testing
import Foundation
@testable import MontageCore

/// Project store (Home screen library), version history, crash recovery, settings and cache accounting (W12).
@Suite struct ProjectLibraryTests {
    func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("montage-lib-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func library() -> (ProjectLibrary, URL) {
        let d = tempDir()
        return (ProjectLibrary(root: d.appendingPathComponent("Drafts"), indexURL: d.appendingPathComponent("library.json")), d)
    }

    func project(_ name: String, clips: Int = 2) -> Project {
        var (p, _) = Fx.project(mainClips: clips)
        p.name = name
        return p
    }

    @Test func defaultNamesFollowCapCut() {
        var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 18
        let d = Calendar(identifier: .gregorian).date(from: c)!
        #expect(ProjectLibrary.defaultName(date: d, existing: []) == "1018")
        #expect(ProjectLibrary.defaultName(date: d, existing: ["1018"]) == "1018 (1)")
        #expect(ProjectLibrary.defaultName(date: d, existing: ["1018", "1018 (1)"]) == "1018 (2)")
        #expect(ProjectLibrary.sanitized("a/b:c") == "a-b-c")
        #expect(ProjectLibrary.sanitized(".hidden") == "_hidden")
    }

    @Test func createScanAndSummaryWithoutDecodingProject() throws {
        let (lib, _) = library()
        let url = try lib.create(project("Holiday", clips: 3))
        #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent(ProjectPackage.summaryFileName).path))
        let entries = lib.scan()
        #expect(entries.count == 1)
        #expect(entries[0].name == "Holiday")
        #expect(entries[0].summary.duration == Time(12))
        #expect(entries[0].summary.clipCount == 3)
        #expect(entries[0].sizeBytes > 0)
        #expect(entries[0].lastOpened != nil)
        // Summary falls back to project.json for packages without summary.json
        try FileManager.default.removeItem(at: url.appendingPathComponent(ProjectPackage.summaryFileName))
        #expect(ProjectPackage.summary(of: url)?.name == "Holiday")
    }

    @Test func renameDuplicateTrashRestore() throws {
        let (lib, _) = library()
        let a = try lib.create(project("Alpha"))
        let renamed = try lib.rename(a, to: "Beta")
        #expect(renamed.lastPathComponent == "Beta.montage")
        #expect(try ProjectPackage.load(from: renamed).name == "Beta")
        let dup = try lib.duplicate(renamed)
        let pd = try ProjectPackage.load(from: dup)
        let pb = try ProjectPackage.load(from: renamed)
        #expect(pd.name == "Beta (1)")
        #expect(pd.id != pb.id)
        #expect(pd.timeline.allClips.count == pb.timeline.allClips.count)
        #expect(lib.scan().count == 2)

        let trashed = try lib.moveToTrash([dup])
        var all = lib.scan()
        #expect(ProjectLibrary.filter(all, scope: .all).map(\.name) == ["Beta"])
        #expect(ProjectLibrary.filter(all, scope: .trash).map(\.name) == ["Beta (1)"])
        let restored = try lib.restore(trashed[0])
        #expect(restored.deletingLastPathComponent().standardizedFileURL.path == lib.root.path)
        all = lib.scan()
        #expect(ProjectLibrary.filter(all, scope: .trash).isEmpty)
        #expect(ProjectLibrary.filter(all, scope: .all).count == 2)

        try lib.moveToTrash([restored])
        lib.emptyTrash()
        #expect(lib.scan().count == 1)
    }

    @Test func trashIsPurgedAfterRetention() throws {
        let (lib, _) = library()
        let a = try lib.create(project("Old"))
        try lib.moveToTrash([a], at: Date().addingTimeInterval(-40 * 86_400))
        #expect(lib.scan().isEmpty)  // scan purges
    }

    @Test func foldersSearchAndSort() throws {
        let (lib, _) = library()
        var p1 = project("Été à Paris", clips: 1); p1.modifiedAt = Date(timeIntervalSince1970: 100)
        var p2 = project("Winter", clips: 4); p2.modifiedAt = Date(timeIntervalSince1970: 300)
        var p3 = project("autumn", clips: 2); p3.modifiedAt = Date(timeIntervalSince1970: 200)
        let u1 = try lib.create(p1), u2 = try lib.create(p2), _ = try lib.create(p3)
        let f = lib.createFolder(named: "Trips")
        #expect(lib.createFolder(named: "Trips").name == "Trips (1)")
        lib.move([u1, u2], to: f.id)
        let all = lib.scan()
        #expect(ProjectLibrary.filter(all, scope: .folder(f.id)).count == 2)
        #expect(ProjectLibrary.filter(all, scope: .all, search: "ete").map(\.name) == ["Été à Paris"])
        #expect(ProjectLibrary.filter(all, scope: .all, sort: .modified).map(\.name) == ["Winter", "autumn", "Été à Paris"])
        #expect(ProjectLibrary.filter(all, scope: .all, sort: .name, ascending: true).map(\.name) == ["autumn", "Été à Paris", "Winter"])
        #expect(ProjectLibrary.filter(all, scope: .all, sort: .duration).first?.name == "Winter")
        lib.deleteFolder(f.id)
        #expect(lib.scan().allSatisfy { $0.folderID == nil })
        #expect(lib.scan().count == 3)  // deleting a folder never deletes projects
    }

    @Test func recentsAndExternalProjects() throws {
        let (lib, dir) = library()
        let ext = dir.appendingPathComponent("Elsewhere/Ext.montage")
        try ProjectPackage.save(project("Ext"), to: ext)
        lib.noteOpened(ext, at: Date())
        let entries = lib.scan()
        #expect(entries.map(\.name).contains("Ext"))
        #expect(lib.recentURLs().first?.standardizedFileURL == ext.standardizedFileURL)
        let old = Date().addingTimeInterval(-60 * 86_400)
        let u = try lib.create(project("Stale"))
        lib.noteOpened(u, at: old)
        #expect(ProjectLibrary.filter(lib.scan(), scope: .recents).map(\.name) == ["Ext"])
    }

    @Test func scanUsesCacheAndSeesChanges() throws {
        let (lib, _) = library()
        let u = try lib.create(project("Cached"))
        _ = lib.scan()
        var p = try ProjectPackage.load(from: u)
        p.name = "Changed"
        Thread.sleep(forTimeInterval: 0.01)
        try ProjectPackage.save(p, to: u)
        #expect(lib.scan().first?.name == "Changed")
        // a fresh instance reads the persisted index
        let lib2 = ProjectLibrary(root: lib.root, indexURL: lib.indexURL)
        #expect(lib2.scan().first?.name == "Changed")
    }

    @Test func packAndImportRoundTripWithMediaInside() throws {
        let (lib, dir) = library()
        // a package with media copied inside, as "Pack project" produces it
        let media = dir.appendingPathComponent("src/clip.mp4")
        try FileManager.default.createDirectory(at: media.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 1000).write(to: media)
        var p = project("Packed", clips: 1)
        let pkg = dir.appendingPathComponent("Out/Packed.montage")
        try FileManager.default.createDirectory(at: pkg.appendingPathComponent("media"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: media, to: pkg.appendingPathComponent("media/clip.mp4"))
        p.media[0].url = pkg.appendingPathComponent("media/clip.mp4")
        try ProjectPackage.save(p, to: pkg)
        let zip = dir.appendingPathComponent("Out/Packed.zip")
        try ProjectArchive.zip(pkg, to: zip)
        try FileManager.default.removeItem(at: pkg)   // the source machine is gone

        let imported = try lib.importProject(from: zip)
        let q = try ProjectPackage.load(from: imported)
        #expect(q.name == "Packed")
        #expect(q.media[0].url.standardizedFileURL.path == imported.appendingPathComponent("media/clip.mp4").standardizedFileURL.path)
        #expect(FileManager.default.fileExists(atPath: q.media[0].url.path))
        // importing the same project again gives it a new id (both stay listed)
        let again = try lib.importProject(from: zip)
        #expect(try ProjectPackage.load(from: again).id != q.id)
        #expect(lib.scan().count == 2)
    }
}

@Suite struct ProjectVersionsTests {
    func package() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("montage-ver-\(UUID().uuidString)/V.montage")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @Test func snapshotListLoadAndSkipIdentical() throws {
        let pkg = try package()
        var (p, _) = Fx.project(mainClips: 1)
        let now = Date()
        #expect(ProjectVersions.autoSnapshotDue(pkg, now: now))
        #expect(try ProjectVersions.snapshot(p, in: pkg, kind: .auto, at: now) != nil)
        #expect(try ProjectVersions.snapshot(p, in: pkg, kind: .auto, at: now.addingTimeInterval(1)) == nil)  // identical
        #expect(!ProjectVersions.autoSnapshotDue(pkg, now: now.addingTimeInterval(60)))
        #expect(ProjectVersions.autoSnapshotDue(pkg, now: now.addingTimeInterval(ProjectVersions.autoInterval + 1)))
        p.name = "Second"
        try ProjectVersions.snapshot(p, in: pkg, kind: .manual, at: now.addingTimeInterval(2))
        let list = ProjectVersions.list(pkg)
        #expect(list.count == 2)
        #expect(list[0].kind == .manual)
        #expect(try ProjectVersions.load(list[0]).name == "Second")
        #expect(try ProjectVersions.load(list[1]).name == "Test")
    }

    @Test func pruneThinsOldVersions() throws {
        let pkg = try package()
        var (p, _) = Fx.project(mainClips: 1)
        let now = Date()
        // 3 versions in the last hour, 4 in the same hour yesterday-ish, 3 on the same day 10 days ago, 1 manual 60 days ago
        let ages: [TimeInterval] = [60, 600, 1800, 5 * 3600, 5 * 3600 + 60, 5 * 3600 + 120, 5 * 3600 + 180,
                                    10 * 86_400, 10 * 86_400 + 60, 10 * 86_400 + 120]
        for (i, a) in ages.enumerated() {
            p.name = "v\(i)"
            try ProjectVersions.snapshot(p, in: pkg, kind: .auto, at: now.addingTimeInterval(-a))
        }
        p.name = "manual"
        try ProjectVersions.snapshot(p, in: pkg, kind: .manual, at: now.addingTimeInterval(-60 * 86_400))
        ProjectVersions.prune(pkg, now: now)
        let kept = ProjectVersions.list(pkg)
        #expect(kept.filter { now.timeIntervalSince($0.date) < 3600 }.count == 3)
        #expect(kept.contains { $0.kind == .manual })
        // at most one per hour bucket for the day, one per day bucket beyond
        #expect(kept.count <= 3 + 2 + 2 + 1)
        #expect(kept.count >= 3 + 1 + 1 + 1)
    }

    @Test func historyIsCapped() throws {
        let pkg = try package()
        var (p, _) = Fx.project(mainClips: 1)
        let now = Date()
        for i in 0..<(ProjectVersions.maxCount + 5) {
            p.name = "v\(i)"
            try ProjectVersions.snapshot(p, in: pkg, kind: .auto, at: now.addingTimeInterval(Double(i)))
        }
        #expect(ProjectVersions.list(pkg).count == ProjectVersions.maxCount)
        #expect(try ProjectVersions.load(ProjectVersions.list(pkg)[0]).name == "v\(ProjectVersions.maxCount + 4)")
    }

    @Test func crashRecoveryFindsStaleLocks() throws {
        let a = try package(), b = try package(), c = try package()
        try "999999".write(to: a.appendingPathComponent(SessionLock.fileName), atomically: true, encoding: .utf8)  // dead pid
        SessionLock.acquire(b)                                                                                    // us: alive
        #expect(CrashRecovery.crashedProjects(in: [a, b, c]) == [a])
        CrashRecovery.dismiss(a)
        #expect(CrashRecovery.crashedProjects(in: [a, b, c]).isEmpty)
        SessionLock.release(b)
    }
}

@Suite(.serialized) struct AppSettingsTests {
    @Test func roundTripAndForwardCompatibility() throws {
        var s = AppSettings()
        s.imageDuration = 3
        s.transitionDuration = 1
        s.defaultFrameRate = .fps25
        s.previewQuality = "half"
        s.projectsDirectory = "/tmp/x"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("settings-\(UUID().uuidString).json")
        try s.save(to: url)
        #expect(AppSettings.load(from: url) == s)
        // missing keys take defaults, unknown keys are ignored, wrong types fall back per field
        let partial = #"{"imageDuration": 2.5, "futureField": 1, "stepFrames": "oops"}"#
        let d = AppSettings.decode(Data(partial.utf8))
        #expect(d.imageDuration == 2.5)
        #expect(d.stepFrames == 10)
        #expect(d.previewQuality == "auto")
        #expect(AppSettings.decode(Data("garbage".utf8)) == AppSettings())
        #expect(AppSettings.load(from: URL(fileURLWithPath: "/nonexistent/x.json")) == AppSettings())
    }

    @Test func editDefaultsDriveTheModel() throws {
        let saved = EditDefaults.current
        defer { EditDefaults.current = saved }
        var s = AppSettings()
        s.imageDuration = 2
        s.freezeDuration = 1.5
        EditDefaults.current = s.editDefaults
        var img = Fx.video("img")
        img.kind = .image
        #expect(img.defaultClipDuration == Time(2))
        #expect(TimelineOps.makeClip(for: img, at: 0).duration == Time(2))
        var (p, ids) = Fx.project(mainClips: 1)
        let f = try TimelineOps.freezeFrame(ids[0], at: Time(1), in: &p)
        #expect(p.timeline.clip(f)?.duration == Time(1.5))
    }
}

@Suite struct CacheManagerTests {
    func cache() throws -> CacheManager {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("montage-cache-\(UUID().uuidString)")
        let m = CacheManager(root: root)
        let fm = FileManager.default
        for c in [CacheManager.Category.proxies, .thumbs, .waveforms, .render] { try fm.createDirectory(at: m.directory(c), withIntermediateDirectories: true) }
        try Data(count: 10_000).write(to: m.directory(.proxies).appendingPathComponent("aaaa.mp4"))
        try Data(count: 20_000).write(to: m.directory(.proxies).appendingPathComponent("bbbb.mp4"))
        try fm.createDirectory(at: m.directory(.thumbs).appendingPathComponent("aaaa"), withIntermediateDirectories: true)
        try Data(count: 5_000).write(to: m.directory(.thumbs).appendingPathComponent("aaaa/q-96.jpg"))
        try Data(count: 1_000).write(to: m.directory(.waveforms).appendingPathComponent("aaaa.peaks"))
        try Data(count: 50_000).write(to: m.directory(.render).appendingPathComponent("r1.mov"))
        try Data(count: 50_000).write(to: m.directory(.render).appendingPathComponent("r2.mov"))
        try fm.createDirectory(at: root.appendingPathComponent("demo-media-v1"), withIntermediateDirectories: true)
        try Data(count: 3_000).write(to: root.appendingPathComponent("demo-media-v1/x.mov"))
        return m
    }

    @Test func sizesPerCategoryAndProject() throws {
        let m = try cache()
        let s = m.sizes()
        #expect(s[.proxies]! >= 30_000)
        #expect(s[.render]! >= 100_000)
        #expect(s[.other]! >= 3_000)
        #expect(m.totalSize() >= 139_000)
        let mine = m.size(forHashes: ["aaaa"])
        #expect(mine >= 16_000 && mine < 30_000)
        #expect(m.clear(hashes: ["aaaa"]) == [.proxies, .thumbs, .waveforms])
        #expect(m.size(forHashes: ["aaaa"]) == 0)
        #expect(m.size(forHashes: ["bbbb"]) >= 20_000)
        m.clear(.other)
        #expect(m.sizes()[.other] == 0)
        #expect(CacheManager.hash(of: "abcd-spec1.caf") == "abcd")
    }

    @Test func purgeAndLimit() throws {
        let m = try cache()
        let old = Date().addingTimeInterval(-40 * 86_400)
        let r1 = m.directory(.render).appendingPathComponent("r1.mov")
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: r1.path)
        try (r1 as NSURL).setResourceValue(old, forKey: .contentAccessDateKey)
        // r2 explicitly recent (a clean checkout / loaded volume can leave equal or stale timestamps)
        let r2 = m.directory(.render).appendingPathComponent("r2.mov")
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: r2.path)
        try (r2 as NSURL).setResourceValue(Date(), forKey: .contentAccessDateKey)
        let removed = m.enforceLimit(60_000, category: .render)
        #expect(removed == ["r1.mov"])  // least recently used goes first
        #expect(m.purge(olderThan: 30, categories: [.proxies]).isEmpty)
        #expect(m.purge(olderThan: 0, categories: [.proxies], now: Date().addingTimeInterval(60)).count == 2)
        m.clear(.render)
        #expect(m.sizes()[.render] == 0)
    }
}
