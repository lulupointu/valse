import Foundation

/// A Home-screen folder (virtual: projects stay in the library root, the index maps them to folders).
public struct ProjectFolder: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public init(id: UUID = UUID(), name: String, createdAt: Date = Date()) { self.id = id; self.name = name; self.createdAt = createdAt }
}

/// One project as the Home screen shows it.
public struct LibraryEntry: Sendable, Equatable, Identifiable, Hashable {
    public var url: URL
    public var summary: ProjectSummary
    /// Package size on disk (project, cover, versions and any copied media).
    public var sizeBytes: Int64
    public var folderID: UUID?
    public var lastOpened: Date?
    /// Set while the project is in the Trash.
    public var trashedAt: Date?
    public var coverURL: URL?

    public var id: String { url.path }
    public var name: String { summary.name.isEmpty ? url.deletingPathExtension().lastPathComponent : summary.name }
    public var modifiedAt: Date { summary.modifiedAt }
    public func hash(into h: inout Hasher) { h.combine(url) }
}

public enum LibrarySort: String, Codable, Sendable, CaseIterable {
    case modified, created, opened, name, size, duration
    public var nameKey: String { "home.sort.\(rawValue)" }
}

public enum LibraryScope: Sendable, Equatable, Hashable {
    /// Every project not in the Trash (folders included).
    case all
    /// Opened in the last 30 days, most recent first.
    case recents
    case folder(UUID)
    case trash
}

/// The local project library behind the Home screen (PM-001/005/006/007/008).
///
/// Layout: every project is a `.montage` package directly in `root` (default `~/Movies/Montage`, the drafts folder;
/// Settings ▸ Project ▸ "Save to"). Deleted projects move to `root/.Trash/` (restorable, purged after
/// `trashRetentionDays`). Folders, last-opened dates, projects opened from elsewhere ("external") and a summary cache
/// (so 100+ projects list instantly: only packages whose project.json changed are re-read) live in `indexURL`
/// (`~/Library/Application Support/Montage/library.json`).
///
/// Thread-safe; every method does file I/O, so call it off the main thread.
public final class ProjectLibrary: @unchecked Sendable {
    public static let trashRetentionDays = 30
    public static let trashDirectoryName = ".Trash"

    public let root: URL
    public let indexURL: URL
    private let lock = NSLock()
    private var index: Index

    struct Meta: Codable, Equatable {
        var folderID: UUID?
        var lastOpened: Date?
        var trashedAt: Date?
        /// Where a trashed project lived (restore target).
        var originalPath: String?
    }

    struct Cached: Codable {
        var mtime: Date
        var size: Int64
        var summary: ProjectSummary
    }

    struct Index: Codable {
        var version = 1
        var folders: [ProjectFolder] = []
        /// Keyed by standardized package path.
        var meta: [String: Meta] = [:]
        /// Packages outside `root` that were opened in Montage (shown on Home until they disappear).
        var external: [String] = []
        var cache: [String: Cached] = [:]
    }

    private static let sharedLock = NSLock()
    nonisolated(unsafe) private static var _shared: ProjectLibrary?
    /// The library at the current "Save to" folder (re-created when that setting changes).
    public static var shared: ProjectLibrary {
        sharedLock.withLock {
            let root = MontagePaths.draftsDirectory.standardizedFileURL
            if let s = _shared, s.root == root { return s }
            let s = ProjectLibrary(root: root, indexURL: MontagePaths.supportDirectory.appendingPathComponent("library.json"))
            _shared = s
            return s
        }
    }

    /// Before the "Save to" folder changes: keeps the current root's projects listed (as external projects).
    public func keepProjectsListed() {
        let fm = FileManager.default
        let urls = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension == ProjectPackage.fileExtension }
        lock.withLock { for u in urls where !index.external.contains(Self.key(u)) { index.external.append(Self.key(u)) } }
        persist()
    }

    public init(root: URL, indexURL: URL) {
        self.root = root.standardizedFileURL
        self.indexURL = indexURL
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let d = try? Data(contentsOf: indexURL), let i = try? ProjectPackage.decoder().decode(Index.self, from: d) {
            index = i
        } else {
            index = Index()
        }
    }

    public var trashDirectory: URL { root.appendingPathComponent(Self.trashDirectoryName, isDirectory: true) }

    static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    private func persist() {
        let snapshot = index
        try? FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? ProjectPackage.encoder().encode(snapshot) { try? d.write(to: indexURL, options: .atomic) }
    }

    // MARK: Listing

    public var folders: [ProjectFolder] { lock.withLock { index.folders } }

    /// Scans the library (root, external projects and the Trash). Cheap when nothing changed.
    public func scan() -> [LibraryEntry] {
        let fm = FileManager.default
        func packages(in dir: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
                .filter { $0.pathExtension == ProjectPackage.fileExtension }
        }
        purgeTrash()
        let trashed = packages(in: trashDirectory)
        var urls = packages(in: root)
        let external = lock.withLock { index.external }.map { URL(fileURLWithPath: $0) }.filter { fm.fileExists(atPath: $0.path) }
        urls += external.filter { e in !urls.contains { Self.key($0) == Self.key(e) } }
        var out: [LibraryEntry] = []
        var seen: Set<String> = []
        for u in urls + trashed {
            let k = Self.key(u)
            guard !seen.contains(k), let (summary, size) = cachedSummary(u) else { continue }
            seen.insert(k)
            let meta = lock.withLock { index.meta[k] } ?? Meta()
            let cover = u.appendingPathComponent(ProjectPackage.coverFileName)
            out.append(LibraryEntry(url: u.standardizedFileURL, summary: summary, sizeBytes: size, folderID: meta.folderID,
                                    lastOpened: meta.lastOpened,
                                    trashedAt: trashed.contains(u) ? (meta.trashedAt ?? Date()) : nil,
                                    coverURL: fm.fileExists(atPath: cover.path) ? cover : nil))
        }
        lock.withLock {
            index.cache = index.cache.filter { seen.contains($0.key) }
            index.external = index.external.filter { fm.fileExists(atPath: $0) }
            let folderIDs = Set(index.folders.map(\.id))
            for (k, m) in index.meta where m.folderID != nil && !folderIDs.contains(m.folderID!) { index.meta[k]?.folderID = nil }
        }
        persist()
        return out
    }

    private func cachedSummary(_ u: URL) -> (ProjectSummary, Int64)? {
        let k = Self.key(u)
        let file = u.appendingPathComponent(ProjectPackage.projectFileName)
        guard let mtime = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date else { return nil }
        if let c = lock.withLock({ index.cache[k] }), c.mtime == mtime { return (c.summary, c.size) }
        guard let s = ProjectPackage.summary(of: u) else { return nil }
        let size = Self.directorySize(u)
        lock.withLock { index.cache[k] = Cached(mtime: mtime, size: size, summary: s) }
        return (s, size)
    }

    /// Recursive allocated size of a directory (bytes).
    public static func directorySize(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            guard let v = try? f.resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0)
        }
        return total
    }

    /// Filters, searches (name, case/diacritic-insensitive) and sorts entries. Pure.
    public static func filter(_ entries: [LibraryEntry], scope: LibraryScope, search: String = "",
                              sort: LibrarySort = .modified, ascending: Bool = false, now: Date = Date()) -> [LibraryEntry] {
        var list: [LibraryEntry]
        switch scope {
        case .all: list = entries.filter { $0.trashedAt == nil }
        case .trash: list = entries.filter { $0.trashedAt != nil }
        case .folder(let id): list = entries.filter { $0.trashedAt == nil && $0.folderID == id }
        case .recents:
            let cutoff = now.addingTimeInterval(-30 * 86_400)
            list = entries.filter { $0.trashedAt == nil && ($0.lastOpened ?? .distantPast) >= cutoff }
        }
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { list = list.filter { $0.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil } }
        let effectiveSort = scope == .recents && sort == .modified ? .opened : sort
        func less(_ a: LibraryEntry, _ b: LibraryEntry) -> Bool {
            switch effectiveSort {
            case .modified: return a.modifiedAt < b.modifiedAt
            case .created: return a.summary.createdAt < b.summary.createdAt
            case .opened: return (a.lastOpened ?? .distantPast) < (b.lastOpened ?? .distantPast)
            case .name: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .size: return a.sizeBytes < b.sizeBytes
            case .duration: return a.summary.duration < b.summary.duration
            }
        }
        list.sort { a, b in
            if less(a, b) == less(b, a) { return a.url.path < b.url.path }  // stable tie-break
            return ascending ? less(a, b) : less(b, a)
        }
        return list
    }

    // MARK: Naming

    /// CapCut default project name: today's date as `MMdd`, then "1018 (1)", "1018 (2)"…
    public static func defaultName(date: Date = Date(), existing: Set<String>) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMdd"
        return uniqueName(f.string(from: date), existing: existing)
    }

    public static func uniqueName(_ base: String, existing: Set<String>) -> String {
        if !existing.contains(base) { return base }
        var n = 1
        while existing.contains("\(base) (\(n))") { n += 1 }
        return "\(base) (\(n))"
    }

    /// File-system-safe package name.
    static func sanitized(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\\0").union(.controlCharacters)
        let s = name.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        let t = s.hasPrefix(".") ? "_" + s.dropFirst() : Substring(s)
        return t.isEmpty ? "Project" : String(t.prefix(120))
    }

    /// An unused package URL named after `name` in `directory` ("Name.montage", "Name (1).montage"…).
    public static func uniquePackageURL(for name: String, in directory: URL) -> URL {
        let fm = FileManager.default
        let base = sanitized(name)
        let taken = Set(((try? fm.contentsOfDirectory(atPath: directory.path)) ?? []).map { ($0 as NSString).deletingPathExtension })
        let n = uniqueName(base, existing: taken)
        return directory.appendingPathComponent(n).appendingPathExtension(ProjectPackage.fileExtension)
    }

    /// Names used by projects not in the Trash (for `defaultName`).
    public func existingNames() -> Set<String> {
        Set(scan().filter { $0.trashedAt == nil }.map(\.name))
    }

    // MARK: Creating & recording

    /// Creates and saves a new project package in the library root. Returns its URL.
    public func create(_ project: Project, folder: UUID? = nil) throws -> URL {
        let url = Self.uniquePackageURL(for: project.name, in: root)
        try ProjectPackage.save(project, to: url)
        lock.withLock { index.meta[Self.key(url), default: Meta()].folderID = folder; index.meta[Self.key(url)]?.lastOpened = Date() }
        persist()
        return url
    }

    /// Records that a project was opened (recents; projects outside the library root are remembered as external).
    public func noteOpened(_ url: URL, at date: Date = Date()) {
        let k = Self.key(url)
        lock.withLock {
            index.meta[k, default: Meta()].lastOpened = date
            if !k.hasPrefix(root.path + "/") && !index.external.contains(k) { index.external.append(k) }
        }
        persist()
    }

    /// Most recently opened projects (File ▸ Open Recent).
    public func recentURLs(limit: Int = 10) -> [URL] {
        let fm = FileManager.default
        let trash = trashDirectory.standardizedFileURL.path + "/"
        return lock.withLock { index.meta }
            .filter { $0.value.lastOpened != nil && !$0.key.hasPrefix(trash) && fm.fileExists(atPath: $0.key) }
            .sorted { $0.value.lastOpened! > $1.value.lastOpened! }
            .prefix(limit).map { URL(fileURLWithPath: $0.key) }
    }

    // MARK: Rename / duplicate

    /// Renames the project (its name and, when free, its package directory). Returns the new package URL.
    @discardableResult
    public func rename(_ url: URL, to newName: String) throws -> URL {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return url }
        try ensureNotOpenElsewhere(url)
        var p = try ProjectPackage.load(from: url)
        p.name = name
        try ProjectPackage.save(p, to: url)
        let dir = url.deletingLastPathComponent()
        let target = dir.appendingPathComponent(Self.sanitized(name)).appendingPathExtension(ProjectPackage.fileExtension)
        guard target.standardizedFileURL != url.standardizedFileURL else { return url }
        let dest = FileManager.default.fileExists(atPath: target.path) ? Self.uniquePackageURL(for: name, in: dir) : target
        try FileManager.default.moveItem(at: url, to: dest)
        rekey(from: url, to: dest)
        return dest
    }

    /// Duplicates a project ("<name> (1)"): a deep copy of the package (media stay referenced, copied media are copied),
    /// with a new project id and no version history or lock.
    @discardableResult
    public func duplicate(_ url: URL) throws -> URL {
        let fm = FileManager.default
        let src = try ProjectPackage.load(from: url)
        let names = existingNames()
        let base = src.name.isEmpty ? url.deletingPathExtension().lastPathComponent : src.name
        let name = Self.uniqueName(base, existing: names)
        let dest = Self.uniquePackageURL(for: name, in: url.deletingLastPathComponent())
        try fm.copyItem(at: url, to: dest)
        for junk in [SessionLock.fileName, ProjectVersions.directoryName] { try? fm.removeItem(at: dest.appendingPathComponent(junk)) }
        var p = try ProjectPackage.load(from: dest)
        p.id = ProjectID()
        p.name = name
        p.createdAt = Date()
        p.modifiedAt = p.createdAt
        try ProjectPackage.save(p, to: dest)
        let folder = lock.withLock { index.meta[Self.key(url)]?.folderID }
        lock.withLock { index.meta[Self.key(dest), default: Meta()].folderID = folder }
        persist()
        return dest
    }

    // MARK: Trash

    /// Moves projects to the library Trash (restorable for `trashRetentionDays`). Returns their new URLs.
    @discardableResult
    public func moveToTrash(_ urls: [URL], at date: Date = Date()) throws -> [URL] {
        let fm = FileManager.default
        try fm.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        var out: [URL] = []
        for u in urls {
            try ensureNotOpenElsewhere(u)
            let dest = Self.uniquePackageURL(for: u.deletingPathExtension().lastPathComponent, in: trashDirectory)
            try fm.moveItem(at: u, to: dest)
            rekey(from: u, to: dest)
            lock.withLock {
                index.meta[Self.key(dest), default: Meta()].trashedAt = date
                index.meta[Self.key(dest)]?.originalPath = Self.key(u)
                index.external.removeAll { $0 == Self.key(u) }
            }
            out.append(dest)
        }
        persist()
        return out
    }

    /// Restores a trashed project to where it was (or the library root). Returns its URL.
    @discardableResult
    public func restore(_ trashed: URL) throws -> URL {
        let fm = FileManager.default
        let meta = lock.withLock { index.meta[Self.key(trashed)] }
        var dest = meta?.originalPath.map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent(trashed.lastPathComponent)
        if !fm.fileExists(atPath: dest.deletingLastPathComponent().path) { dest = root.appendingPathComponent(trashed.lastPathComponent) }
        if fm.fileExists(atPath: dest.path) {
            dest = Self.uniquePackageURL(for: dest.deletingPathExtension().lastPathComponent, in: dest.deletingLastPathComponent())
        }
        try fm.moveItem(at: trashed, to: dest)
        rekey(from: trashed, to: dest)
        lock.withLock {
            index.meta[Self.key(dest)]?.trashedAt = nil
            index.meta[Self.key(dest)]?.originalPath = nil
            let k = Self.key(dest)
            if !k.hasPrefix(root.path + "/") && !index.external.contains(k) { index.external.append(k) }
        }
        persist()
        return dest
    }

    /// Permanently deletes a project package.
    public func deletePermanently(_ url: URL) throws {
        try ensureNotOpenElsewhere(url)
        try FileManager.default.removeItem(at: url)
        lock.withLock {
            let k = Self.key(url)
            index.meta[k] = nil; index.cache[k] = nil; index.external.removeAll { $0 == k }
        }
        persist()
    }

    public func emptyTrash() {
        let fm = FileManager.default
        for u in (try? fm.contentsOfDirectory(at: trashDirectory, includingPropertiesForKeys: nil)) ?? [] {
            try? deletePermanently(u)
        }
    }

    /// Deletes projects trashed more than `trashRetentionDays` ago.
    public func purgeTrash(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Double(Self.trashRetentionDays) * 86_400)
        let trash = trashDirectory.standardizedFileURL.path + "/"
        let old = lock.withLock { index.meta.filter { $0.key.hasPrefix(trash) && ($0.value.trashedAt ?? now) < cutoff }.map(\.key) }
        for k in old { try? deletePermanently(URL(fileURLWithPath: k)) }
    }

    // MARK: Folders

    @discardableResult
    public func createFolder(named name: String) -> ProjectFolder {
        let names = Set(folders.map(\.name))
        let f = ProjectFolder(name: Self.uniqueName(name, existing: names))
        lock.withLock { index.folders.append(f) }
        persist()
        return f
    }

    public func renameFolder(_ id: UUID, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        lock.withLock { if let i = index.folders.firstIndex(where: { $0.id == id }) { index.folders[i].name = n } }
        persist()
    }

    /// Deletes a folder; its projects go back to the top level (never deleted with the folder).
    public func deleteFolder(_ id: UUID) {
        lock.withLock {
            index.folders.removeAll { $0.id == id }
            for (k, m) in index.meta where m.folderID == id { index.meta[k]?.folderID = nil }
        }
        persist()
    }

    /// Moves projects into a folder (nil = top level).
    public func move(_ urls: [URL], to folder: UUID?) {
        lock.withLock { for u in urls { index.meta[Self.key(u), default: Meta()].folderID = folder } }
        persist()
    }

    // MARK: Import

    /// Imports a `.montage` package (or a `.zip` made by "Pack project") into the library root, as a copy.
    /// A project whose id already exists in the library gets a new id. Returns the imported package URL.
    @discardableResult
    public func importProject(from source: URL) throws -> URL {
        let fm = FileManager.default
        var pkg = source
        var temp: URL?
        if source.pathExtension.lowercased() == "zip" {
            let dir = fm.temporaryDirectory.appendingPathComponent("montage-import-\(UUID().uuidString)")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            temp = dir
            try ProjectArchive.unzip(source, into: dir)
            guard let found = ProjectArchive.findPackage(in: dir) else { throw PersistenceError.notAPackage }
            pkg = found
        }
        defer { if let temp { try? fm.removeItem(at: temp) } }
        var p = try ProjectPackage.load(from: pkg)
        let dest = Self.uniquePackageURL(for: pkg.deletingPathExtension().lastPathComponent, in: root)
        try fm.copyItem(at: pkg, to: dest)
        try? fm.removeItem(at: dest.appendingPathComponent(SessionLock.fileName))
        let ids = Set(scan().filter { Self.key($0.url) != Self.key(dest) }.map(\.summary.id))
        // media copied inside the package follow the new package location
        p = try ProjectPackage.load(from: dest)
        if ids.contains(p.id) { p.id = ProjectID() }
        try ProjectPackage.save(p, to: dest)
        noteOpened(dest)
        return dest
    }

    // MARK: Helpers

    private func rekey(from old: URL, to new: URL) {
        let a = Self.key(old), b = Self.key(new)
        lock.withLock {
            if let m = index.meta.removeValue(forKey: a) { index.meta[b] = m }
            index.cache[a] = nil
            if let i = index.external.firstIndex(of: a) { index.external[i] = b }
        }
    }

    private func ensureNotOpenElsewhere(_ url: URL) throws {
        if SessionLock.isHeldByOtherProcess(url) { throw PersistenceError.openElsewhere }
    }
}

/// Zip archives of project packages ("Pack project" output, project import). Uses the system `ditto`.
public enum ProjectArchive {
    public static func zip(_ package: URL, to zipURL: URL) throws {
        try? FileManager.default.removeItem(at: zipURL)
        try run(["-c", "-k", "--sequesterRsrc", "--keepParent", package.path, zipURL.path])
    }

    public static func unzip(_ zipURL: URL, into dir: URL) throws {
        try run(["-x", "-k", zipURL.path, dir.path])
    }

    /// First `.montage` package inside `dir` (depth ≤ 2).
    public static func findPackage(in dir: URL) -> URL? {
        let fm = FileManager.default
        let top = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        if let p = top.first(where: { $0.pathExtension == ProjectPackage.fileExtension }) { return p }
        for sub in top where (try? sub.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let inner = (try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil)) ?? []
            if let p = inner.first(where: { $0.pathExtension == ProjectPackage.fileExtension }) { return p }
        }
        return nil
    }

    static func run(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = args
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw PersistenceError.unreadable("ditto \(p.terminationStatus)") }
    }
}
