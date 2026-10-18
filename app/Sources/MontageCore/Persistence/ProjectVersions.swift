import Foundation

/// Version history of a project (File ▸ Version history): full snapshots of project.json kept in
/// `<package>/versions/<epoch-ms>-<kind>.json`.
///
/// - The editor takes an `.auto` snapshot on autosave at most every `autoInterval` of editing, plus one when the project
///   is closed, and a `.beforeRestore` one before going back to an older version (so restoring is reversible).
/// - `prune` thins old versions: everything from the last hour, then one per hour for a day, one per day for 30 days,
///   never more than `maxCount`. Manual snapshots are kept until `maxCount` forces them out (oldest first).
public enum ProjectVersions {
    public static let directoryName = "versions"
    public static let autoInterval: TimeInterval = 5 * 60
    public static let maxCount = 50

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case auto, manual, close, beforeRestore
        public var nameKey: String { "version.kind.\(rawValue)" }
    }

    public struct Version: Sendable, Equatable, Identifiable, Hashable {
        public var url: URL
        public var date: Date
        public var kind: Kind
        public var id: String { url.lastPathComponent }
    }

    public static func directory(_ package: URL) -> URL { package.appendingPathComponent(directoryName, isDirectory: true) }

    /// Writes a snapshot (atomic). Identical consecutive content is not stored twice.
    @discardableResult
    public static func snapshot(_ project: Project, in package: URL, kind: Kind, at date: Date = Date()) throws -> Version? {
        let dir = directory(package)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try ProjectPackage.encoder().encode(project)
        if let last = list(package).first, let prev = try? Data(contentsOf: last.url), prev == data { return nil }
        var ms = Int64((date.timeIntervalSince1970 * 1000).rounded())
        var url = dir.appendingPathComponent("\(ms)-\(kind.rawValue).json")
        while FileManager.default.fileExists(atPath: url.path) { ms += 1; url = dir.appendingPathComponent("\(ms)-\(kind.rawValue).json") }
        try data.write(to: url, options: .atomic)
        prune(package, now: date)
        return Version(url: url, date: Date(timeIntervalSince1970: Double(ms) / 1000), kind: kind)
    }

    /// Versions, newest first.
    public static func list(_ package: URL) -> [Version] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory(package), includingPropertiesForKeys: nil)) ?? []
        return files.compactMap(parse).sorted { $0.date > $1.date }
    }

    static func parse(_ url: URL) -> Version? {
        guard url.pathExtension == "json" else { return nil }
        let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-", maxSplits: 1)
        guard parts.count == 2, let ms = Int64(parts[0]), let kind = Kind(rawValue: String(parts[1])) else { return nil }
        return Version(url: url, date: Date(timeIntervalSince1970: Double(ms) / 1000), kind: kind)
    }

    /// Loads a version (through the migrator, like a package).
    public static func load(_ v: Version) throws -> Project {
        let data = try Data(contentsOf: v.url)
        let migrated = try ProjectMigrator.migrate(data)
        do { return try ProjectPackage.decoder().decode(Project.self, from: migrated) } catch {
            throw PersistenceError.unreadable(String(describing: error))
        }
    }

    /// True when an automatic snapshot is due (none yet, or the newest is older than `autoInterval`).
    public static func autoSnapshotDue(_ package: URL, now: Date = Date()) -> Bool {
        guard let last = list(package).first else { return true }
        return now.timeIntervalSince(last.date) >= autoInterval
    }

    /// Thins the history (see type docs). Returns the deleted versions.
    @discardableResult
    public static func prune(_ package: URL, now: Date = Date()) -> [Version] {
        let all = list(package)
        var keep: [Version] = []
        var buckets: Set<String> = []
        for v in all {
            let age = now.timeIntervalSince(v.date)
            let bucket: String?
            if age < 3600 { bucket = nil }                                         // keep all
            else if age < 86_400 { bucket = "h\(Int(v.date.timeIntervalSince1970 / 3600))" }
            else if age < 30 * 86_400 { bucket = "d\(Int(v.date.timeIntervalSince1970 / 86_400))" }
            else { bucket = v.kind == .manual ? nil : "old" }                      // one very old auto version survives
            if v.kind == .manual || bucket == nil { keep.append(v); continue }
            if buckets.insert(bucket!).inserted { keep.append(v) }
        }
        if keep.count > maxCount { keep = Array(keep.prefix(maxCount)) }
        let keptIDs = Set(keep.map(\.id))
        let removed = all.filter { !keptIDs.contains($0.id) }
        for v in removed { try? FileManager.default.removeItem(at: v.url) }
        return removed
    }
}

/// Crash recovery (PM-004): finds projects whose `.session.lock` was left by a process that is gone, i.e. Montage quit
/// unexpectedly while they were open. Their autosave (≤ `AutosavePolicy.idleDelay` old) is what the user gets back;
/// Home asks "Montage quit unexpectedly. Recover the project?".
public enum CrashRecovery {
    public static func crashedProjects(in urls: [URL]) -> [URL] {
        urls.filter(hasStaleLock)
    }

    public static func hasStaleLock(_ package: URL) -> Bool {
        let url = package.appendingPathComponent(SessionLock.fileName)
        guard let s = try? String(contentsOf: url, encoding: .utf8),
              let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return pid != getpid() && !SessionLock.isAlive(pid)
    }

    /// "Not now": forget the crash (removes the stale lock; the autosaved project stays as it is).
    public static func dismiss(_ package: URL) {
        if hasStaleLock(package) { SessionLock.release(package) }
    }
}
