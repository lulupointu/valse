import Foundation
import MontageCore

/// Auto-relink at project open (MI-006): before asking the user, missing media are looked for (content fingerprint first,
/// then name + size, `MediaRelinker.search`) in the places files usually move to — the project's folder, folders the
/// user relinked from before, and the nearest existing ancestors of each missing file's old location (a renamed or
/// moved parent folder). Broad roots (/, /Users, the home folder, volumes) are never scanned.
public enum MediaAutoRelink {
    public static let rememberedKey = "montage.relinkFolders"
    public static let maxRemembered = 8

    /// Folders the user picked in "Link media" / batch relink, most recent first.
    public static var rememberedFolders: [URL] {
        (AppDefaults.store.stringArray(forKey: rememberedKey) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    public static func remember(_ folder: URL) {
        var list = AppDefaults.store.stringArray(forKey: rememberedKey) ?? []
        list.removeAll { $0 == folder.standardizedFileURL.path }
        list.insert(folder.standardizedFileURL.path, at: 0)
        AppDefaults.store.set(Array(list.prefix(maxRemembered)), forKey: rememberedKey)
    }

    /// Too broad to walk at open.
    static func isBroad(_ u: URL) -> Bool {
        let p = u.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let comps = u.standardizedFileURL.pathComponents
        return p == "/" || p == home || p == "/Users" || p == "/Volumes" || comps.count <= 2
            || (comps.count == 3 && comps[1] == "Volumes")
    }

    /// Candidate folders, nearest first, de-duplicated (a folder inside an earlier one is skipped).
    public static func candidateFolders(missing: [MediaAsset], packageURL: URL?, remembered: [URL] = rememberedFolders) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        func add(_ u: URL) {
            let s = u.standardizedFileURL
            var isDir: ObjCBool = false
            guard !isBroad(s), fm.fileExists(atPath: s.path, isDirectory: &isDir), isDir.boolValue else { return }
            if out.contains(where: { s.path == $0.path || s.path.hasPrefix($0.path + "/") }) { return }
            out.removeAll { $0.path.hasPrefix(s.path + "/") }
            out.append(s)
        }
        if let pkg = packageURL { add(pkg.deletingLastPathComponent()) }
        for a in missing {
            // nearest existing ancestor of the old location, then one level up (renamed / moved parent)
            var d = a.url.deletingLastPathComponent()
            var hops = 0
            while !fm.fileExists(atPath: d.path), d.pathComponents.count > 2, hops < 6 { d.deleteLastPathComponent(); hops += 1 }
            add(d)
            if hops == 0 { add(d.deletingLastPathComponent()) }
        }
        remembered.forEach(add)
        return out
    }

    /// Searches the candidate folders for every missing asset (blocking: call off the main thread).
    public static func search(missing: [MediaAsset], packageURL: URL?, remembered: [URL] = rememberedFolders,
                              maxFilesPerFolder: Int = 20_000) -> [MediaID: URL] {
        var left = missing
        var found: [MediaID: URL] = [:]
        for folder in candidateFolders(missing: missing, packageURL: packageURL, remembered: remembered) where !left.isEmpty {
            let hit = MediaRelinker.search(folder, for: left, maxFiles: maxFilesPerFolder, requireFingerprint: true)
            found.merge(hit) { a, _ in a }
            left.removeAll { hit[$0.id] != nil }
        }
        return found
    }
}
