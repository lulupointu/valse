import Foundation

/// First launch after the Montage → Valse rename: moves what Montage left on disk and in its settings domain to the
/// Valse names, so an existing install keeps every setting, project, model download and cache.
///
/// Runs before anything reads a setting or a path (ValseApp/main.swift), only in a normal launch of the real app
/// (`fr.valse.Valse`; never in tests, `swift run`, screenshots or other tooling launches). Every step is idempotent and
/// safe to interrupt; a step that can't complete leaves the old data where it is, `ValsePaths` keeps using the old
/// folder then (nothing is lost, only not renamed), and the next launch tries again. Steps:
/// 1. Folders: `~/Library/Application Support/Montage` → `Valse` (settings, library index, AI models, runtimes,
///    stickers, LUTs, effects…), `~/Library/Caches/Montage` → `Valse`, and `~/Movies/Montage` → `~/Movies/Valse` when
///    it is the default project library (a custom "Save to" folder stays where it is). Same-volume renames only
///    (`rename(2)`: multi-GB model folders are never copied); skipped when the Valse folder already exists (never
///    merged), when the old one is a symbolic link, or while a pre-rename Montage still runs (its open projects live
///    there).
/// 2. Paths stored in the moved data that point into a moved folder (library index, settings.json) are rewritten.
///    Project files are not touched: media paths into a moved folder are resolved when a project opens
///    (`ProjectPackage.relink`), and `.montage` packages keep their name.
/// 3. Settings: every key of the old domain `fr.montage.Montage` is copied into Valse's (renamed keys mapped by
///    `LegacyNames.defaultsKey`, content IDs in values by `LegacyNames.defaultsValue`, paths into moved folders
///    rewritten); a key Valse already has wins. The old domain is left as it is.
/// The keychain (online-audio provider keys) is migrated by the engine (`KeychainSecretStore.migrateLegacyItems`).
public enum RebrandMigration {
    /// Set in Valse's settings once every step ran (a step that failed is retried at the next launch).
    public static let doneKey = "ValseMigratedFromMontage"

    public struct Environment {
        /// The user's home (`CFFIXED_USER_HOME` in scripts/updater_e2e.sh, the real one otherwise).
        public var home: URL
        /// Valse's settings and the name of their persistent domain (its bundle id).
        public var defaults: UserDefaults
        public var domain: String
        /// The old app's settings domain (`fr.montage.Montage`).
        public var legacyDomain: String
        /// A pre-rename Montage is running: folders wait for the next launch.
        public var legacyAppRunning: () -> Bool

        public init(home: URL, defaults: UserDefaults, domain: String, legacyDomain: String = LegacyNames.bundleID,
                    legacyAppRunning: @escaping () -> Bool) {
            self.home = home; self.defaults = defaults; self.domain = domain; self.legacyDomain = legacyDomain
            self.legacyAppRunning = legacyAppRunning
        }
    }

    public struct Report: Equatable, Sendable {
        /// Folders moved now (new paths).
        public var moved: [String] = []
        /// Old folders left in place (and why).
        public var kept: [String] = []
        public var copiedKeys = 0
        /// Every step completed (`doneKey` set), now or at an earlier launch.
        public var done = false
    }

    struct Folder { var legacy: URL; var new: URL; var isLibrary: Bool }

    static func folders(home: URL) -> [Folder] {
        let lib = home.appendingPathComponent("Library", isDirectory: true)
        let movies = home.appendingPathComponent("Movies", isDirectory: true)
        return [
            Folder(legacy: lib.appendingPathComponent("Application Support/\(LegacyNames.folderName)", isDirectory: true),
                   new: lib.appendingPathComponent("Application Support/Valse", isDirectory: true), isLibrary: false),
            Folder(legacy: lib.appendingPathComponent("Caches/\(LegacyNames.folderName)", isDirectory: true),
                   new: lib.appendingPathComponent("Caches/Valse", isDirectory: true), isLibrary: false),
            Folder(legacy: movies.appendingPathComponent(LegacyNames.folderName, isDirectory: true),
                   new: movies.appendingPathComponent("Valse", isDirectory: true), isLibrary: true),
        ]
    }

    @discardableResult
    public static func run(_ env: Environment) -> Report {
        var r = Report()
        if env.defaults.bool(forKey: doneKey) { r.done = true; return r }
        let fm = FileManager.default
        let legacy = UserDefaults.standard.persistentDomain(forName: env.legacyDomain) ?? [:]
        let all = folders(home: env.home)

        // 1. Folders
        var complete = true
        let running = env.legacyAppRunning()
        for f in all where exists(f.legacy) && !exists(f.new) {
            if f.isLibrary, let custom = customLibrary(legacy: legacy, env: env),
               standardized(custom) != standardized(f.legacy.path) {
                r.kept.append("\(f.legacy.path) (not the project library: \(custom))")
                continue
            }
            if isSymlink(f.legacy) { r.kept.append("\(f.legacy.path) (symbolic link)"); continue }
            if running { complete = false; r.kept.append("\(f.legacy.path) (Montage is running)"); continue }
            try? fm.createDirectory(at: f.new.deletingLastPathComponent(), withIntermediateDirectories: true)
            if Darwin.rename(f.legacy.path, f.new.path) == 0 {
                r.moved.append(f.new.path)
            } else {
                // EXDEV (another volume), permissions…: keep using the old folder, try again next launch
                complete = false
                r.kept.append("\(f.legacy.path) (\(String(cString: strerror(errno))))")
            }
        }
        for f in all where exists(f.legacy) && exists(f.new) { r.kept.append("\(f.legacy.path) (Valse folder exists too)") }

        // 2. Paths into moved folders (also the ones moved at an interrupted earlier launch)
        let rewrites = all.filter { !exists($0.legacy) && exists($0.new) }
            .map { ($0.legacy.standardizedFileURL.path, $0.new.standardizedFileURL.path) }
        if !rewrites.isEmpty {
            let support = all[0]
            let dir = exists(support.new) ? support.new : support.legacy
            for name in ["library.json", "settings.json"] { rewritePaths(in: dir.appendingPathComponent(name), rewrites) }
        }

        // 3. Settings
        let mine = UserDefaults.standard.persistentDomain(forName: env.domain) ?? [:]
        for (k, v) in legacy {
            let key = LegacyNames.defaultsKey(k) ?? k
            guard mine[key] == nil else { continue }
            var value = LegacyNames.defaultsValue(v)
            if let s = value as? String, s.hasPrefix("/") { value = rewritePath(s, rewrites) }
            env.defaults.set(value, forKey: key)
            r.copiedKeys += 1
        }
        if complete {
            env.defaults.set(true, forKey: doneKey)
            r.done = true
        }
        return r
    }

    /// The "Save to" folder the user chose, if any (old setting, else an already migrated one).
    static func customLibrary(legacy: [String: Any], env: Environment) -> String? {
        let key = ValsePaths.draftsOverrideKey
        let old = LegacyNames.appName + key.dropFirst("Valse".count)
        let s = (legacy[old] as? String) ?? (UserDefaults.standard.persistentDomain(forName: env.domain)?[key] as? String)
        return s?.isEmpty == false ? s : nil
    }

    static func exists(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.path) || isSymlink(u) }
    static func isSymlink(_ u: URL) -> Bool {
        ((try? FileManager.default.attributesOfItem(atPath: u.path)[.type]) as? FileAttributeType) == .typeSymbolicLink
    }
    static func standardized(_ p: String) -> String { URL(fileURLWithPath: p).standardizedFileURL.path }

    static func rewritePath(_ s: String, _ rewrites: [(String, String)]) -> String {
        for (old, new) in rewrites {
            if s == old { return new }
            if s.hasPrefix(old + "/") { return new + s.dropFirst(old.count) }
        }
        return s
    }

    /// Rewrites path strings (values and dictionary keys) of a JSON file that point into a moved folder; atomic, and
    /// the file is left untouched when nothing changes.
    static func rewritePaths(in file: URL, _ rewrites: [(String, String)]) {
        guard let data = try? Data(contentsOf: file), let obj = try? JSONSerialization.jsonObject(with: data) else { return }
        var changed = false
        func walk(_ v: Any) -> Any {
            switch v {
            case let s as String:
                let n = rewritePath(s, rewrites)
                if n != s { changed = true }
                return n
            case let a as [Any]: return a.map(walk)
            case let d as [String: Any]:
                var out: [String: Any] = [:]
                for (k, x) in d {
                    let nk = rewritePath(k, rewrites)
                    if nk != k { changed = true }
                    out[nk] = walk(x)
                }
                return out
            default: return v
            }
        }
        let rewritten = walk(obj)
        guard changed, let out = try? JSONSerialization.data(withJSONObject: rewritten, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        try? out.write(to: file, options: .atomic)
    }
}
