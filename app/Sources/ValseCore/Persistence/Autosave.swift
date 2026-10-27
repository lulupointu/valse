import Foundation

/// Crash detection for an open package: `<package>/.session.lock` holds the owner pid while the project is open.
/// A lock left behind by a dead process means the previous session crashed (the autosaved state is then what the
/// user gets back, at most `AutosavePolicy.idleDelay` old).
public enum SessionLock {
    public static let fileName = ".session.lock"

    /// Takes the lock. Returns true if a stale lock from a crashed session was found.
    @discardableResult
    public static func acquire(_ packageURL: URL) -> Bool {
        let url = packageURL.appendingPathComponent(fileName)
        var crashed = false
        if let pid = lockPID(packageURL) { crashed = pid != getpid() && !isValseHolder(pid) }
        try? "\(getpid())".write(to: url, atomically: true, encoding: .utf8)
        return crashed
    }

    public static func release(_ packageURL: URL) {
        try? FileManager.default.removeItem(at: packageURL.appendingPathComponent(fileName))
    }

    /// The pid written in the lock file, if any.
    public static func lockPID(_ packageURL: URL) -> Int32? {
        guard let s = try? String(contentsOf: packageURL.appendingPathComponent(fileName), encoding: .utf8) else { return nil }
        return Int32(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// True if another running Valse process holds the lock (project open elsewhere).
    public static func isHeldByOtherProcess(_ packageURL: URL) -> Bool { holderPID(packageURL) != nil }

    /// PM-014: pid of the other running Valse process holding the project (to bring its window forward), else nil.
    /// Only a live process that IS Valse counts: after a crash the lock's pid can be reused by any other process
    /// (P1: `kill(pid, 0)` alone showed "already open" with no window to focus) — such a lock is stale (crash recovery).
    public static func holderPID(_ packageURL: URL, isValse: (Int32) -> Bool = isValseHolder) -> Int32? {
        guard let pid = lockPID(packageURL), pid != getpid(), isValse(pid) else { return nil }
        return pid
    }

    /// True if the lock was left by a session that isn't running any more (crashed, or its pid now belongs to another app).
    public static func isStale(_ packageURL: URL, isValse: (Int32) -> Bool = isValseHolder) -> Bool {
        guard let pid = lockPID(packageURL) else { return false }
        return pid != getpid() && !isValse(pid)
    }

    static func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    // MARK: Who holds a lock

    private static let holdersLock = NSLock()
    nonisolated(unsafe) private static var testHolders: Set<Int32> = []

    /// Test hook (UI fixture `home:3:heldelsewhere`, unit tests): treat a live `pid` as another Valse instance.
    public static func registerTestHolder(_ pid: Int32) { holdersLock.withLock { _ = testHolders.insert(pid) } }
    public static func unregisterTestHolder(_ pid: Int32) { holdersLock.withLock { _ = testHolders.remove(pid) } }

    /// A live process that is Valse: same bundle identifier (another copy of Valse.app), else the same executable
    /// name ("Valse", development builds run unbundled). A copy from before the rename (Montage, `fr.montage.Montage`)
    /// counts too, both ways, so mixed versions never take each other's open projects for crashed sessions.
    public static func isValseHolder(_ pid: Int32) -> Bool {
        guard pid > 0, isAlive(pid) else { return false }
        if holdersLock.withLock({ testHolders.contains(pid) }) { return true }
        guard let exe = executablePath(of: pid) else { return false }
        let theirs = URL(fileURLWithPath: exe).resolvingSymlinksInPath()
        let myName = Bundle.main.executableURL?.lastPathComponent ?? ProcessInfo.processInfo.processName
        return sameApp(myBundleID: Bundle.main.bundleIdentifier, myName: myName,
                       theirBundleID: bundleIdentifier(ofExecutable: theirs), theirName: theirs.lastPathComponent)
    }

    static let familyBundleIDs: Set<String> = ["fr.valse.Valse", LegacyNames.bundleID]
    static let familyNames: Set<String> = ["Valse", LegacyNames.appName]

    /// Same app, the pre-rename name included (pure, unit-tested).
    static func sameApp(myBundleID: String?, myName: String, theirBundleID: String?, theirName: String) -> Bool {
        if let mine = myBundleID, let other = theirBundleID {
            return mine == other || (familyBundleIDs.contains(mine) && familyBundleIDs.contains(other))
        }
        return theirName == myName || (familyNames.contains(myName) && familyNames.contains(theirName))
    }

    static func executablePath(of pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)   // PROC_PIDPATHINFO_MAXSIZE
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// `…/X.app/Contents/MacOS/X` → X.app's bundle identifier.
    static func bundleIdentifier(ofExecutable exe: URL) -> String? {
        let macOS = exe.deletingLastPathComponent(), contents = macOS.deletingLastPathComponent(), app = contents.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents", app.pathExtension == "app" else { return nil }
        return Bundle(url: app)?.bundleIdentifier
    }
}

/// Autosave timing. Every project lives in a package from creation (new projects go to the drafts folder), and the
/// editor writes it after `idleDelay` without edits, or at most every `maxInterval` while edits keep coming.
/// Saves run off the main thread on an immutable snapshot (`Project` is a value type).
public struct AutosavePolicy: Sendable {
    public var idleDelay: Duration = .seconds(2)
    public var maxInterval: Duration = .seconds(30)
    public init() {}
}

/// Default locations.
public enum ValsePaths {
    /// UserDefaults keys of the Settings overrides (absolute paths).
    public static let draftsOverrideKey = "ValseProjectsDirectory"
    public static let cacheOverrideKey = "ValseCacheDirectory"
    /// Only set in the volatile argument domain (UI tests / demo screenshots isolate settings and the library).
    public static let supportOverrideKey = "ValseSupportDirectory"

    static func override(_ key: String) -> URL? {
        guard let p = AppDefaults.store.string(forKey: key), !p.isEmpty else { return nil }
        return URL(fileURLWithPath: p, isDirectory: true)
    }

    /// ~/Movies/Valse — drafts folder for new projects (CapCut "Drafts"); Settings ▸ Project ▸ Save to overrides it.
    /// A Save-to folder on a drive that isn't connected falls back to the default folder (PM-009; Home shows a banner).
    public static var draftsDirectory: URL {
        if let o = override(draftsOverrideKey), !StorageLocation.of(o).isUnavailable { return o }
        return defaultDraftsDirectory
    }

    /// The configured Save-to folder's location when it needs a warning (external, network, disconnected), else nil.
    public static var configuredDraftsWarning: (url: URL, location: StorageLocation)? {
        guard let o = override(draftsOverrideKey) else { return nil }
        let l = StorageLocation.of(o)
        return l.needsWarning ? (o, l) : nil
    }

    /// Only set in the volatile argument domain (UI-test sandbox): the "default" folder a disconnected Save-to falls back to.
    public static let defaultDraftsOverrideKey = "ValseDefaultProjectsDirectory"

    public static var defaultDraftsDirectory: URL {
        if let o = override(defaultDraftsOverrideKey) { return o }
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        return named(in: movies)
    }

    /// `<base>/Valse`, or the pre-rename `<base>/Montage` while only that one exists (its move failed or hasn't run:
    /// `RebrandMigration`; development checkouts and tests on a machine that ran Montage). Never both: a new folder
    /// is only created where nothing older exists.
    static func named(in base: URL) -> URL {
        let fm = FileManager.default
        let new = base.appendingPathComponent("Valse", isDirectory: true)
        let legacy = base.appendingPathComponent(LegacyNames.folderName, isDirectory: true)
        return !fm.fileExists(atPath: new.path) && fm.fileExists(atPath: legacy.path) ? legacy : new
    }

    /// A file a project saved by Montage referenced inside one of Montage's folders (pasted media, generated speech,
    /// looks… in `Application Support/Montage`, a recording in `~/Movies/Montage`) that moved with its folder to the
    /// Valse one: its new URL, or nil (not such a path, or not there either).
    public static func movedFromLegacyFolder(_ url: URL) -> URL? {
        let path = url.path
        for parent in ["/Library/Application Support/", "/Library/Caches/", "/Movies/"] {
            let old = parent + LegacyNames.folderName + "/"
            guard let r = path.range(of: old) else { continue }
            let candidate = URL(fileURLWithPath: path.replacingCharacters(in: r, with: parent + "Valse/"))
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// ~/Library/Caches/Valse — proxies, thumbnails, waveforms (rebuildable, keyed by content hash).
    /// Settings ▸ Performance ▸ Cache location overrides it (engine caches pick it up at the next launch).
    public static var cacheDirectory: URL {
        if let o = override(cacheOverrideKey) { return o }
        if let t = testRunCacheDirectory { return t }
        return defaultCacheDirectory
    }

    /// Unit-test processes get a cache folder of their own (`$TMPDIR/valse-test-cache/run-<pid>`, B1): concurrent
    /// test runs (several checkouts) use the same synthetic media, so content-hash-keyed entries (mattes, stems,
    /// enhanced copies) were shared and one run deleted / rewrote what another was rendering. Compiled AI models stay
    /// shared (`models` links to the user cache: compiling them is slow). Folders of runs that ended are removed.
    /// UI-test apps (`--uitest`, AppDefaults isolated) get one too: scripts/uitest.sh `--jobs` runs several at once.
    static let testRunCacheDirectory: URL? = {
        guard ValseProcess.isUnitTest || !AppDefaults.processSuffix.isEmpty else { return nil }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("valse-test-cache", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where name.hasPrefix("run-") {
            guard let pid = Int32(name.dropFirst(4)), pid != getpid() else { continue }
            if kill(pid, 0) != 0 && errno == ESRCH { try? fm.removeItem(at: root.appendingPathComponent(name)) }
        }
        let dir = root.appendingPathComponent("run-\(getpid())", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let models = defaultCacheDirectory.appendingPathComponent("models", isDirectory: true)
        try? fm.createDirectory(at: models, withIntermediateDirectories: true)
        try? fm.createSymbolicLink(at: dir.appendingPathComponent("models"), withDestinationURL: models)
        atexit { if let d = ValsePaths.testRunCacheDirectory { try? FileManager.default.removeItem(at: d) } }
        return dir
    }()

    public static var defaultCacheDirectory: URL {
        named(in: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!)
    }

    /// ~/Library/Application Support/Valse — settings, recent projects, AI packs.
    public static var supportDirectory: URL {
        if let o = override(supportOverrideKey) { return o }
        return defaultSupportDirectory
    }

    /// The user's real Application Support/Valse, never the UI-test sandbox (AI runtimes and models aren't settings).
    public static var defaultSupportDirectory: URL {
        named(in: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!)
    }

    /// ~/Library/Caches/ValseDev (development builds' music library and test fixtures), or the pre-rename MontageDev.
    public static var developmentCacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let new = base.appendingPathComponent("ValseDev", isDirectory: true)
        let legacy = base.appendingPathComponent(LegacyNames.devCacheFolderName, isDirectory: true)
        let fm = FileManager.default
        return !fm.fileExists(atPath: new.path) && fm.fileExists(atPath: legacy.path) ? legacy : new
    }

    /// A fresh, unused "Project N.valse" URL in `directory`.
    public static func newProjectURL(in directory: URL = draftsDirectory, baseName: String) -> URL {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var n = 1
        while true {
            let name = n == 1 ? baseName : "\(baseName) \(n)"
            let url = directory.appendingPathComponent(name).appendingPathExtension(ProjectPackage.fileExtension)
            if !fm.fileExists(atPath: url.path) { return url }
            n += 1
        }
    }
}
