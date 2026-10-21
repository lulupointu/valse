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
        if let pid = lockPID(packageURL) { crashed = pid != getpid() && !isMontageHolder(pid) }
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

    /// True if another running Montage process holds the lock (project open elsewhere).
    public static func isHeldByOtherProcess(_ packageURL: URL) -> Bool { holderPID(packageURL) != nil }

    /// PM-014: pid of the other running Montage process holding the project (to bring its window forward), else nil.
    /// Only a live process that IS Montage counts: after a crash the lock's pid can be reused by any other process
    /// (P1: `kill(pid, 0)` alone showed "already open" with no window to focus) — such a lock is stale (crash recovery).
    public static func holderPID(_ packageURL: URL, isMontage: (Int32) -> Bool = isMontageHolder) -> Int32? {
        guard let pid = lockPID(packageURL), pid != getpid(), isMontage(pid) else { return nil }
        return pid
    }

    /// True if the lock was left by a session that isn't running any more (crashed, or its pid now belongs to another app).
    public static func isStale(_ packageURL: URL, isMontage: (Int32) -> Bool = isMontageHolder) -> Bool {
        guard let pid = lockPID(packageURL) else { return false }
        return pid != getpid() && !isMontage(pid)
    }

    static func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    // MARK: Who holds a lock

    private static let holdersLock = NSLock()
    nonisolated(unsafe) private static var testHolders: Set<Int32> = []

    /// Test hook (UI fixture `home:3:heldelsewhere`, unit tests): treat a live `pid` as another Montage instance.
    public static func registerTestHolder(_ pid: Int32) { holdersLock.withLock { _ = testHolders.insert(pid) } }
    public static func unregisterTestHolder(_ pid: Int32) { holdersLock.withLock { _ = testHolders.remove(pid) } }

    /// A live process that is Montage: same bundle identifier (another copy of Montage.app), else the same executable
    /// name ("Montage", development builds run unbundled).
    public static func isMontageHolder(_ pid: Int32) -> Bool {
        guard pid > 0, isAlive(pid) else { return false }
        if holdersLock.withLock({ testHolders.contains(pid) }) { return true }
        guard let exe = executablePath(of: pid) else { return false }
        let theirs = URL(fileURLWithPath: exe).resolvingSymlinksInPath()
        if let mine = Bundle.main.bundleIdentifier, let other = bundleIdentifier(ofExecutable: theirs) { return mine == other }
        let myName = Bundle.main.executableURL?.lastPathComponent ?? ProcessInfo.processInfo.processName
        return theirs.lastPathComponent == myName
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
public enum MontagePaths {
    /// UserDefaults keys of the Settings overrides (absolute paths).
    public static let draftsOverrideKey = "MontageProjectsDirectory"
    public static let cacheOverrideKey = "MontageCacheDirectory"
    /// Only set in the volatile argument domain (UI tests / demo screenshots isolate settings and the library).
    public static let supportOverrideKey = "MontageSupportDirectory"

    static func override(_ key: String) -> URL? {
        guard let p = AppDefaults.store.string(forKey: key), !p.isEmpty else { return nil }
        return URL(fileURLWithPath: p, isDirectory: true)
    }

    /// ~/Movies/Montage — drafts folder for new projects (CapCut "Drafts"); Settings ▸ Project ▸ Save to overrides it.
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
    public static let defaultDraftsOverrideKey = "MontageDefaultProjectsDirectory"

    public static var defaultDraftsDirectory: URL {
        if let o = override(defaultDraftsOverrideKey) { return o }
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        return movies.appendingPathComponent("Montage", isDirectory: true)
    }

    /// ~/Library/Caches/Montage — proxies, thumbnails, waveforms (rebuildable, keyed by content hash).
    /// Settings ▸ Performance ▸ Cache location overrides it (engine caches pick it up at the next launch).
    public static var cacheDirectory: URL {
        if let o = override(cacheOverrideKey) { return o }
        if let t = testRunCacheDirectory { return t }
        return defaultCacheDirectory
    }

    /// Unit-test processes get a cache folder of their own (`$TMPDIR/montage-test-cache/run-<pid>`, B1): concurrent
    /// test runs (several checkouts) use the same synthetic media, so content-hash-keyed entries (mattes, stems,
    /// enhanced copies) were shared and one run deleted / rewrote what another was rendering. Compiled AI models stay
    /// shared (`models` links to the user cache: compiling them is slow). Folders of runs that ended are removed.
    static let testRunCacheDirectory: URL? = {
        guard MontageProcess.isUnitTest else { return nil }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("montage-test-cache", isDirectory: true)
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
        atexit { if let d = MontagePaths.testRunCacheDirectory { try? FileManager.default.removeItem(at: d) } }
        return dir
    }()

    public static var defaultCacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Montage", isDirectory: true)
    }

    /// ~/Library/Application Support/Montage — settings, recent projects, AI packs.
    public static var supportDirectory: URL {
        if let o = override(supportOverrideKey) { return o }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Montage", isDirectory: true)
    }

    /// A fresh, unused "Project N.montage" URL in `directory`.
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
