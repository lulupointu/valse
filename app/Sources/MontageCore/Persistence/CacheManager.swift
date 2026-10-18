import Foundation

/// Cache accounting and clean-up (PM-010, Settings ▸ Project/Performance ▸ cache sizes, "Auto delete cache N days ago",
/// render cache "Auto clear N GB", per-project cache clean-up on Home).
///
/// Every cache is rebuildable and lives in a sub-folder of `MontagePaths.cacheDirectory`, keyed by media content hash
/// (file `<hash>.<ext>`, `<hash>-<spec>.<ext>` or folder `<hash>/`). This type only does file accounting; engine
/// caches that keep an in-memory "ready" list are told to forget by MontageUI (`CacheCleaner`).
public struct CacheManager: Sendable {
    public enum Category: String, CaseIterable, Sendable, Codable {
        case proxies, thumbs, waveforms, render, converted, reversed, audio, stabilization, mattes, other
        public var nameKey: String { "cache.\(rawValue)" }
    }

    public let root: URL
    public init(root: URL = MontagePaths.cacheDirectory) { self.root = root }

    public func directory(_ c: Category) -> URL { root.appendingPathComponent(c.rawValue, isDirectory: true) }

    /// Sizes per category (bytes). `other` = everything else under the cache root (demo media, SFX…).
    public func sizes() -> [Category: Int64] {
        var out: [Category: Int64] = [:]
        let named = Set(Category.allCases.filter { $0 != .other }.map(\.rawValue))
        for c in Category.allCases where c != .other { out[c] = ProjectLibrary.directorySize(directory(c)) }
        let fm = FileManager.default
        var other: Int64 = 0
        for u in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] where !named.contains(u.lastPathComponent) {
            other += (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                ? ProjectLibrary.directorySize(u) : Int64((try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        out[.other] = other
        return out
    }

    public func totalSize() -> Int64 { sizes().values.reduce(0, +) }

    /// Deletes a category's files (the folder itself is kept).
    public func clear(_ c: Category) {
        let fm = FileManager.default
        if c == .other {
            let named = Set(Category.allCases.map(\.rawValue))
            for u in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] where !named.contains(u.lastPathComponent) {
                try? fm.removeItem(at: u)
            }
            return
        }
        for u in (try? fm.contentsOfDirectory(at: directory(c), includingPropertiesForKeys: nil)) ?? [] { try? fm.removeItem(at: u) }
    }

    /// Items (files or hash folders) of a category with their size and last-use date (access or modification).
    func items(_ c: Category) -> [(url: URL, size: Int64, used: Date)] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentAccessDateKey, .contentModificationDateKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory(c), includingPropertiesForKeys: Array(keys))) ?? []
        return urls.map { u in
            let v = try? u.resourceValues(forKeys: keys)
            let size = v?.isDirectory == true ? ProjectLibrary.directorySize(u) : Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
            let used = max(v?.contentAccessDate ?? .distantPast, v?.contentModificationDate ?? .distantPast)
            return (u, size, used)
        }
    }

    /// Deletes items not used for `days` days in the given categories. Returns the deleted item names (`<hash>…`).
    @discardableResult
    public func purge(olderThan days: Int, categories: [Category] = Category.allCases.filter { $0 != .other }, now: Date = Date()) -> [String] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        var removed: [String] = []
        for c in categories {
            for i in items(c) where i.used < cutoff {
                if (try? FileManager.default.removeItem(at: i.url)) != nil { removed.append(i.url.lastPathComponent) }
            }
        }
        return removed
    }

    /// Keeps a category under `limit` bytes by deleting least recently used items first. Returns deleted names.
    @discardableResult
    public func enforceLimit(_ limit: Int64, category: Category) -> [String] {
        var list = items(category).sorted { $0.used < $1.used }
        var total = list.reduce(0) { $0 + $1.size }
        var removed: [String] = []
        while total > limit, !list.isEmpty {
            let i = list.removeFirst()
            if (try? FileManager.default.removeItem(at: i.url)) != nil { removed.append(i.url.lastPathComponent); total -= i.size }
        }
        return removed
    }

    /// Cache items that belong to media with these content hashes.
    public func items(forHashes hashes: Set<String>) -> [(category: Category, url: URL, size: Int64)] {
        guard !hashes.isEmpty else { return [] }
        var out: [(Category, URL, Int64)] = []
        for c in Category.allCases where c != .other && c != .render {
            for i in items(c) where hashes.contains(Self.hash(of: i.url.lastPathComponent)) { out.append((c, i.url, i.size)) }
        }
        return out
    }

    /// Bytes of cache used by these media (proxies, thumbnails, waveforms, conversions, reversed/audio renders…).
    public func size(forHashes hashes: Set<String>) -> Int64 { items(forHashes: hashes).reduce(0) { $0 + $1.size } }

    /// Deletes the cache of these media. Returns the categories touched.
    @discardableResult
    public func clear(hashes: Set<String>) -> Set<Category> {
        var touched: Set<Category> = []
        for i in items(forHashes: hashes) where (try? FileManager.default.removeItem(at: i.url)) != nil { touched.insert(i.category) }
        return touched
    }

    /// Content hash a cache item name refers to: "<hash>.mp4", "<hash>-spec.caf", "<hash>" (folder).
    static func hash(of name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        if let dash = base.firstIndex(of: "-") { return String(base[..<dash]) }
        return base
    }

    /// Human-readable size ("219.65 MB"), localized decimal separator.
    public static func format(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        return f.string(fromByteCount: bytes)
    }
}
