import CoreText
import Foundation
import ValseCore

/// Missing-media detection and relinking (CapCut "Media lost" / "Link media", MI-006).
/// Matching order for each missing item: same content hash (size + head/tail bytes — survives renames and moves),
/// then same file name and size, then (when the original size is unknown) same file name.
public enum MediaRelinker {
    /// Media whose file is gone.
    public static func missing(in project: Project) -> [MediaAsset] {
        project.media.filter { !fileExists($0) }
    }

    public static func isMissing(_ a: MediaAsset) -> Bool { !fileExists(a) }

    static func fileExists(_ a: MediaAsset) -> Bool {
        if a.conversion == .imageSequence, let s = a.sequence {
            return FileManager.default.fileExists(atPath: a.url.deletingLastPathComponent().appendingPathComponent(s.fileName(0)).path)
        }
        return FileManager.default.fileExists(atPath: a.url.path)
    }

    /// Searches `folder` recursively for the given assets. Returns asset id → new URL. Never touches the project.
    /// `requireFingerprint` (auto-relink without the user, MI-006): files with a known size match on the content hash only.
    public static func search(_ folder: URL, for assets: [MediaAsset], maxFiles: Int = 50_000, requireFingerprint: Bool = false) -> [MediaID: URL] {
        guard !assets.isEmpty else { return [:] }
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        var bySize: [Int64: [URL]] = [:]
        var byName: [String: [URL]] = [:]
        let e = fm.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        var n = 0
        while let u = e?.nextObject() as? URL, n < maxFiles {
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            n += 1
            bySize[Int64(v.fileSize ?? 0), default: []].append(u)
            byName[u.lastPathComponent.lowercased(), default: []].append(u)
        }
        var out: [MediaID: URL] = [:]
        var used: Set<URL> = []
        for a in assets {
            let name = a.url.lastPathComponent.lowercased()
            // 1. content hash among same-size files
            if a.fileSize > 0, a.conversion != .imageSequence {
                for c in bySize[a.fileSize] ?? [] where !used.contains(c) {
                    if MediaProbe.contentHash(c, size: a.fileSize, mtime: nil) == a.contentHash { out[a.id] = c; used.insert(c); break }
                }
                if out[a.id] != nil || requireFingerprint { continue }
            }
            // 2. name (+ size when known)
            let named = (byName[name] ?? []).filter { !used.contains($0) }
            let sized = a.fileSize > 0 && a.conversion != .imageSequence
                ? named.filter { ((try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize).map(Int64.init) == a.fileSize } : named
            if let c = sized.first ?? (a.fileSize == 0 || a.conversion == .imageSequence ? named.first : nil) { out[a.id] = c; used.insert(c) }
        }
        return out
    }

    /// Applies new locations (pure; undoable through an `Edit`). The content hash is kept so caches stay valid.
    public static func apply(_ found: [MediaID: URL], to p: inout Project) {
        for i in p.media.indices { if let u = found[p.media[i].id] { p.media[i].url = u; p.media[i].relativePath = nil } }
    }
}

/// "Copy media to project" (MI-007): copies every external media file into `<package>/media/` and rewrites the URLs.
public enum MediaConsolidator {
    /// Copies files off the main thread; returns asset id → new URL. Existing copies with the same name+size are reused.
    public static func consolidate(_ project: Project, packageURL: URL, progress: (@Sendable (Double) -> Void)? = nil) throws -> [MediaID: URL] {
        let fm = FileManager.default
        let mediaDir = packageURL.appendingPathComponent("media", isDirectory: true)
        try fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        var out: [MediaID: URL] = [:]
        var taken = Set((try? fm.contentsOfDirectory(atPath: mediaDir.path)) ?? [])
        let todo = project.media.filter { !$0.url.standardizedFileURL.path.hasPrefix(mediaDir.standardizedFileURL.path) && MediaRelinker.fileExists($0) }
        for (k, a) in todo.enumerated() {
            if a.conversion == .imageSequence, let s = a.sequence {
                // copy the whole sequence into its own sub-folder
                let sub = mediaDir.appendingPathComponent(uniqueName(a.name, taken: &taken), isDirectory: true)
                try fm.createDirectory(at: sub, withIntermediateDirectories: true)
                let src = a.url.deletingLastPathComponent()
                for i in 0..<s.count {
                    let f = s.fileName(i)
                    let d = sub.appendingPathComponent(f)
                    if !fm.fileExists(atPath: d.path) { try fm.copyItem(at: src.appendingPathComponent(f), to: d) }
                }
                out[a.id] = sub.appendingPathComponent(s.fileName(0))
            } else {
                let existing = mediaDir.appendingPathComponent(a.url.lastPathComponent)
                let size = ((try? fm.attributesOfItem(atPath: existing.path))?[.size] as? NSNumber)?.int64Value
                if size == a.fileSize, a.fileSize > 0 {
                    out[a.id] = existing
                } else {
                    let dst = mediaDir.appendingPathComponent(uniqueName(a.url.lastPathComponent, taken: &taken))
                    try fm.copyItem(at: a.url, to: dst)
                    out[a.id] = dst
                }
            }
            progress?(Double(k + 1) / Double(max(todo.count, 1)))
        }
        return out
    }

    static func uniqueName(_ name: String, taken: inout Set<String>) -> String {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var candidate = name, n = 2
        while taken.contains(candidate) { candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"; n += 1 }
        taken.insert(candidate)
        return candidate
    }
}

/// Live Photo pairs (MI-012): a HEIC/JPEG still and a MOV with the same base name in the same folder.
public enum LivePhoto {
    /// Splits `urls` into stills that have a paired motion file and everything else (the paired MOVs are removed).
    public static func pair(_ urls: [URL]) -> (pairs: [(still: URL, video: URL)], rest: [URL]) {
        let stills = urls.filter { ["heic", "heif", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
        var movs: [String: URL] = [:]
        for u in urls where u.pathExtension.lowercased() == "mov" { movs[key(u)] = u }
        var pairs: [(URL, URL)] = []
        var paired: Set<URL> = []
        for s in stills { if let m = movs[key(s)] { pairs.append((s, m)); paired.insert(s); paired.insert(m) } }
        return (pairs, urls.filter { !paired.contains($0) })
    }

    static func key(_ u: URL) -> String { u.deletingPathExtension().path.lowercased() }
}

/// Imported fonts (MI-021): copied to ~/Library/Application Support/Valse/Fonts and registered for this process,
/// so the text engine (Core Text) sees them like system fonts. `loadAll()` runs at startup.
public enum FontLibrary {
    public static let extensions: Set<String> = ["ttf", "otf", "ttc", "otc", "dfont"]
    public static var directory: URL { ValsePaths.supportDirectory.appendingPathComponent("Fonts", isDirectory: true) }

    /// Copies and registers fonts. Returns the PostScript names that became available. CapCut allows 9 per batch.
    @discardableResult
    public static func importFonts(_ urls: [URL], limit: Int = 9) throws -> [String] {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var names: [String] = []
        for u in urls.filter({ extensions.contains($0.pathExtension.lowercased()) }).prefix(limit) {
            let dst = directory.appendingPathComponent(u.lastPathComponent)
            if !fm.fileExists(atPath: dst.path) { try fm.copyItem(at: u, to: dst) }
            names += register(dst)
        }
        return names
    }

    /// Registers every font in the library folder (idempotent).
    @discardableResult
    public static func loadAll() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { extensions.contains($0.pathExtension.lowercased()) }.flatMap(register)
    }

    static func register(_ url: URL) -> [String] {
        var err: Unmanaged<CFError>?
        _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &err)  // "already registered" is fine
        guard let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else { return [] }
        return descs.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String }
    }
}
