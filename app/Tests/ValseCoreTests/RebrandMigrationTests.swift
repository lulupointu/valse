import Foundation
import Testing
@testable import ValseCore

/// Montage → Valse rename: legacy names, first-launch migration (folders, settings), legacy project packages, session
/// locks shared with a pre-rename copy.
@Suite struct LegacyNamesTests {
    @Test func contentIDsMapToValse() {
        #expect(LegacyNames.contentID("montage.effect.blur") == "valse.effect.blur")
        #expect(LegacyNames.contentID("montage.anim.text.in.typewriter") == "valse.anim.text.in.typewriter")
        #expect(LegacyNames.contentID("valse.effect.blur") == "valse.effect.blur")
        #expect(LegacyNames.contentID("user.effect.myEffect") == "user.effect.myEffect")
        // user text that merely starts with the French word stays as it is
        #expect(LegacyNames.contentID("montage. Le film") == "montage. Le film")
        #expect(LegacyNames.contentID("montage.") == "montage.")
        #expect(LegacyNames.contentID("montage") == "montage")
    }

    @Test func jsonRewriteTouchesIDsOnly() throws {
        let src = #"{"typeID":"montage.transition.dissolve","text":"Mon montage.","presets":{"montage.eq.voice":1},"n":2}"#
        let out = try JSONSerialization.jsonObject(with: LegacyNames.migrateContentIDs(inJSON: Data(src.utf8))) as! [String: Any]
        #expect(out["typeID"] as? String == "valse.transition.dissolve")
        #expect(out["text"] as? String == "Mon montage.")
        #expect((out["presets"] as? [String: Int])?["valse.eq.voice"] == 1)
        #expect(out["n"] as? Int == 2)
        let plain = Data(#"{"typeID":"valse.effect.blur"}"#.utf8)
        #expect(LegacyNames.migrateContentIDs(inJSON: plain) == plain)   // nothing to do: same bytes
    }

    @Test func settingsKeysAndValues() {
        #expect(LegacyNames.defaultsKey("MontageHomeSort") == "ValseHomeSort")
        #expect(LegacyNames.defaultsKey("MontageAutomaticUpdates") == "ValseAutomaticUpdates")
        #expect(LegacyNames.defaultsKey("montage.media.sort") == "valse.media.sort")
        #expect(LegacyNames.defaultsKey("NSWindow Frame main") == nil)
        #expect(LegacyNames.defaultsKey("SULastCheckTime") == nil)
        #expect(LegacyNames.defaultsKey("Montageur") == nil)
        #expect(LegacyNames.defaultsValue(["montage.effect.blur", "montage-lib:abc"]) as? [String] == ["valse.effect.blur", "valse-lib:abc"])
        #expect(LegacyNames.defaultsValue("/Users/x/Movies/Montage") as? String == "/Users/x/Movies/Montage")
    }
}

@Suite struct RebrandMigrationTests {
    struct Sandbox {
        let home: URL
        let domain: String
        let legacyDomain: String
        let defaults: UserDefaults
        init() {
            let id = UUID().uuidString.prefix(8)
            home = FileManager.default.temporaryDirectory.appendingPathComponent("rebrand-\(id)", isDirectory: true)
            domain = "fr.valse.rebrand-test.\(id)"
            legacyDomain = "fr.montage.rebrand-test.\(id)"
            defaults = UserDefaults(suiteName: domain)!
        }
        func url(_ p: String) -> URL { home.appendingPathComponent(p) }
        func write(_ p: String, _ s: String = "x") throws {
            let u = url(p)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(s.utf8).write(to: u)
        }
        func env(running: Bool = false) -> RebrandMigration.Environment {
            .init(home: home, defaults: defaults, domain: domain, legacyDomain: legacyDomain, legacyAppRunning: { running })
        }
        func legacySettings(_ d: [String: Any]) { UserDefaults.standard.setPersistentDomain(d, forName: legacyDomain) }
        func cleanUp() {
            try? FileManager.default.removeItem(at: home)
            UserDefaults.standard.removePersistentDomain(forName: domain)
            UserDefaults.standard.removePersistentDomain(forName: legacyDomain)
        }
        func exists(_ p: String) -> Bool { FileManager.default.fileExists(atPath: url(p).path) }
    }

    @Test func movesFoldersCopiesSettingsAndRewritesPaths() throws {
        let s = Sandbox(); defer { s.cleanUp() }
        try s.write("Library/Application Support/Montage/Models/whisper/model.bin", "weights")
        try s.write("Library/Caches/Montage/thumbs/a.jpg")
        try s.write("Movies/Montage/Trip.montage/project.json", "{}")
        let oldPkg = s.url("Movies/Montage/Trip.montage").standardizedFileURL.path
        try s.write("Library/Application Support/Montage/library.json", #"{"meta":{"\#(oldPkg)":{"lastOpened":1}},"external":[]}"#)
        s.legacySettings(["MontageHomeSort": "name", "montage.assets.favoriteEffects": ["montage.effect.blur"],
                          "MontageCacheDirectory": "/Volumes/Big/cache", "SULastCheckTime": Date(timeIntervalSince1970: 5)])
        s.defaults.set("modified", forKey: "ValseHomeViewMode")

        let r = RebrandMigration.run(s.env())
        #expect(r.done && r.moved.count == 3)
        #expect(s.exists("Library/Application Support/Valse/Models/whisper/model.bin") && !s.exists("Library/Application Support/Montage"))
        #expect(s.exists("Library/Caches/Valse/thumbs/a.jpg") && s.exists("Movies/Valse/Trip.montage/project.json"))
        let index = try String(contentsOf: s.url("Library/Application Support/Valse/library.json"), encoding: .utf8)
        #expect(index.contains(s.url("Movies/Valse/Trip.montage").standardizedFileURL.path) && !index.contains("/Movies/Montage/"))
        #expect(s.defaults.string(forKey: "ValseHomeSort") == "name")
        #expect(s.defaults.stringArray(forKey: "valse.assets.favoriteEffects") == ["valse.effect.blur"])
        #expect(s.defaults.string(forKey: "ValseCacheDirectory") == "/Volumes/Big/cache")   // a custom path is kept
        #expect(s.defaults.object(forKey: "SULastCheckTime") as? Date == Date(timeIntervalSince1970: 5))
        #expect(s.defaults.string(forKey: "ValseHomeViewMode") == "modified")
        #expect(UserDefaults.standard.persistentDomain(forName: s.legacyDomain)?["MontageHomeSort"] as? String == "name")   // old kept

        // once done, never again (a Montage folder that reappears is left alone)
        try s.write("Library/Caches/Montage/new.jpg")
        #expect(RebrandMigration.run(s.env()).moved.isEmpty)
        #expect(s.exists("Library/Caches/Montage/new.jpg"))
    }

    @Test func customProjectFolderAndExistingValseFoldersStay() throws {
        let s = Sandbox(); defer { s.cleanUp() }
        try s.write("Movies/Montage/A.montage/project.json", "{}")
        try s.write("Library/Caches/Montage/x")
        try s.write("Library/Caches/Valse/y")
        s.legacySettings(["MontageProjectsDirectory": s.url("Elsewhere").path])
        let r = RebrandMigration.run(s.env())
        #expect(r.done)
        #expect(s.exists("Movies/Montage/A.montage") && !s.exists("Movies/Valse"))   // not the library: untouched
        #expect(s.exists("Library/Caches/Montage/x") && s.exists("Library/Caches/Valse/y"))   // never merged
        #expect(s.defaults.string(forKey: ValsePaths.draftsOverrideKey) == s.url("Elsewhere").path)
    }

    @Test func defaultLibrarySetExplicitlyMovesWithItsSetting() throws {
        let s = Sandbox(); defer { s.cleanUp() }
        try s.write("Movies/Montage/A.montage/project.json", "{}")
        s.legacySettings(["MontageProjectsDirectory": s.url("Movies/Montage").path])
        #expect(RebrandMigration.run(s.env()).done)
        #expect(s.exists("Movies/Valse/A.montage"))
        #expect(s.defaults.string(forKey: ValsePaths.draftsOverrideKey) == s.url("Movies/Valse").standardizedFileURL.path)
    }

    @Test func waitsWhileMontageRuns() throws {
        let s = Sandbox(); defer { s.cleanUp() }
        try s.write("Library/Application Support/Montage/settings.json", "{}")
        s.legacySettings(["MontageLanguage": "fr"])
        let r = RebrandMigration.run(s.env(running: true))
        #expect(!r.done && s.exists("Library/Application Support/Montage/settings.json"))
        #expect(s.defaults.string(forKey: "ValseLanguage") == "fr")   // settings don't wait
        #expect(RebrandMigration.run(s.env()).done)                  // next launch, Montage quit
        #expect(s.exists("Library/Application Support/Valse/settings.json"))
    }

    @Test func pathsFallBackToTheOldFolderUntilItMoves() throws {
        let s = Sandbox(); defer { s.cleanUp() }
        #expect(ValsePaths.named(in: s.home).lastPathComponent == "Valse")
        try FileManager.default.createDirectory(at: s.url("Montage"), withIntermediateDirectories: true)
        #expect(ValsePaths.named(in: s.home).lastPathComponent == "Montage")
        try FileManager.default.createDirectory(at: s.url("Valse"), withIntermediateDirectories: true)
        #expect(ValsePaths.named(in: s.home).lastPathComponent == "Valse")
        try s.write("Library/Application Support/Valse/Pasted Media/p.png")
        let old = s.url("Library/Application Support/Montage/Pasted Media/p.png")
        #expect(ValsePaths.movedFromLegacyFolder(old)?.path == s.url("Library/Application Support/Valse/Pasted Media/p.png").path)
        #expect(ValsePaths.movedFromLegacyFolder(s.url("Library/Application Support/Montage/none.png")) == nil)
    }
}

@Suite struct LegacyPackageTests {
    @Test func montagePackagesAreProjects() {
        #expect(ProjectPackage.isPackage(URL(fileURLWithPath: "/x/Old.montage")))
        #expect(ProjectPackage.isPackage(URL(fileURLWithPath: "/x/New.valse")))
        #expect(!ProjectPackage.isPackage(URL(fileURLWithPath: "/x/clip.mov")))
    }

    @Test func libraryListsAndRenamesOldPackagesWithoutChangingTheirExtension() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-lib-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = dir.appendingPathComponent("Old.montage")
        try ProjectPackage.save(Project(name: "Old"), to: old)
        try ProjectPackage.save(Project(name: "New"), to: dir.appendingPathComponent("New.valse"))
        let lib = ProjectLibrary(root: dir, indexURL: dir.appendingPathComponent(".index.json"))
        #expect(Set(lib.scan().map(\.url.lastPathComponent)) == ["Old.montage", "New.valse"])
        let renamed = try lib.rename(old, to: "Older")
        #expect(renamed.lastPathComponent == "Older.montage")
        #expect(ProjectLibrary.uniquePackageURL(for: "Fresh", in: dir).pathExtension == "valse")
    }

    @Test func sessionLocksRecogniseThePreRenameApp() {
        #expect(SessionLock.sameApp(myBundleID: "fr.valse.Valse", myName: "Valse", theirBundleID: "fr.montage.Montage", theirName: "Montage"))
        #expect(SessionLock.sameApp(myBundleID: "fr.valse.Valse", myName: "Valse", theirBundleID: "fr.valse.Valse", theirName: "Valse"))
        #expect(SessionLock.sameApp(myBundleID: nil, myName: "Valse", theirBundleID: nil, theirName: "Montage"))
        #expect(!SessionLock.sameApp(myBundleID: "fr.valse.Valse", myName: "Valse", theirBundleID: "com.apple.Safari", theirName: "Safari"))
        #expect(!SessionLock.sameApp(myBundleID: nil, myName: "Valse", theirBundleID: nil, theirName: "zsh"))
    }
}
