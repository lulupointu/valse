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
        if let s = try? String(contentsOf: url, encoding: .utf8), let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
            crashed = pid != getpid() && !isAlive(pid)
        }
        try? "\(getpid())".write(to: url, atomically: true, encoding: .utf8)
        return crashed
    }

    public static func release(_ packageURL: URL) {
        try? FileManager.default.removeItem(at: packageURL.appendingPathComponent(fileName))
    }

    /// True if another live process holds the lock (project open elsewhere).
    public static func isHeldByOtherProcess(_ packageURL: URL) -> Bool {
        let url = packageURL.appendingPathComponent(fileName)
        guard let s = try? String(contentsOf: url, encoding: .utf8), let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return pid != getpid() && isAlive(pid)
    }

    static func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }
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
        guard let p = UserDefaults.standard.string(forKey: key), !p.isEmpty else { return nil }
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
        return defaultCacheDirectory
    }

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
