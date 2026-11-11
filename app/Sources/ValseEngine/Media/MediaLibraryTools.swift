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
    /// `progress` is proportional to the bytes to copy (byte-level inside large files, BUG-PACK-PROGRESS), not to the
    /// file count. `clone: false` never clones (tests). Cancellation is checked between chunks.
    public static func consolidate(_ project: Project, packageURL: URL, clone: Bool = true,
                                   progress: (@Sendable (Double) -> Void)? = nil) throws -> [MediaID: URL] {
        let fm = FileManager.default
        let mediaDir = packageURL.appendingPathComponent("media", isDirectory: true)
        try fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        var out: [MediaID: URL] = [:]
        var taken = Set((try? fm.contentsOfDirectory(atPath: mediaDir.path)) ?? [])
        let items = plan(project, mediaDir: mediaDir, existingIn: mediaDir, clone: clone)
        let total = max(items.reduce(Int64(0)) { $0 + $1.cost }, 1)
        var done: Int64 = 0
        let throttle = progress.map { ProgressThrottle($0) }   // byte-level reports, throttled for the UI
        func report(_ c: Int64) { throttle?.report(Double(c) / Double(total)) }
        for item in items {
            try Task.checkCancellation()   // "Cancel" while packing / consolidating
            let a = item.asset
            switch item.action {
            case .sequence(let files):
                // copy the whole sequence into its own sub-folder
                let sub = mediaDir.appendingPathComponent(uniqueName(a.name, taken: &taken), isDirectory: true)
                try fm.createDirectory(at: sub, withIntermediateDirectories: true)
                let src = a.url.deletingLastPathComponent()
                for f in files {
                    let d = sub.appendingPathComponent(f.name)
                    let before = done
                    if !fm.fileExists(atPath: d.path) {
                        try FileCopier.copyFile(at: src.appendingPathComponent(f.name), to: d, clone: clone) { b in
                            report(before + (item.cloneable ? 0 : b))
                        }
                    }
                    done = before + FileCopier.cost(bytes: f.size, cloneable: item.cloneable)
                    report(done)
                }
                out[a.id] = sub.appendingPathComponent(files.first?.name ?? a.url.lastPathComponent)
            case .reuse(let existing):
                out[a.id] = existing
                done += item.cost
                report(done)
            case .copy:
                let dst = mediaDir.appendingPathComponent(uniqueName(a.url.lastPathComponent, taken: &taken))
                let before = done
                try FileCopier.copyFile(at: a.url, to: dst, clone: clone) { b in report(before + (item.cloneable ? 0 : b)) }
                out[a.id] = dst
                done = before + item.cost
                report(done)
            }
        }
        report(total)
        return out
    }

    /// Work units of `consolidate` (bytes to stream + a per-file cost; clones cost only the per-file cost) and the
    /// bytes the package grows by. `existingIn`: where already-copied files are looked up (default `<package>/media`;
    /// "Pack project" passes the source package's media folder, which is copied into the new package first).
    public static func plannedCost(_ project: Project, packageURL: URL, existingIn: URL? = nil, clone: Bool = true) -> (cost: Int64, bytes: Int64) {
        let mediaDir = packageURL.appendingPathComponent("media", isDirectory: true)
        let items = plan(project, mediaDir: mediaDir, existingIn: existingIn ?? mediaDir, clone: clone)
        return (items.reduce(0) { $0 + $1.cost }, items.reduce(0) { $0 + $1.bytes })
    }

    struct Item {
        enum Action { case sequence([(name: String, size: Int64)]), reuse(URL), copy }
        var asset: MediaAsset
        var action: Action
        var cloneable: Bool
        var cost: Int64
        var bytes: Int64
    }

    static func plan(_ project: Project, mediaDir: URL, existingIn: URL, clone: Bool) -> [Item] {
        let todo = project.media.filter { !$0.url.standardizedFileURL.path.hasPrefix(mediaDir.standardizedFileURL.path) && MediaRelinker.fileExists($0) }
        return todo.map { a in
            let cloneable = clone && FileCopier.canClone(a.url, into: mediaDir)
            if a.conversion == .imageSequence, let s = a.sequence {
                let src = a.url.deletingLastPathComponent()
                let files = (0..<s.count).map { i in (name: s.fileName(i), size: FileCopier.size(src.appendingPathComponent(s.fileName(i)))) }
                let bytes = files.reduce(Int64(0)) { $0 + $1.size }
                let cost = files.reduce(Int64(0)) { $0 + FileCopier.cost(bytes: $1.size, cloneable: cloneable) }
                return Item(asset: a, action: .sequence(files), cloneable: cloneable, cost: cost, bytes: bytes)
            }
            let existing = existingIn.appendingPathComponent(a.url.lastPathComponent)
            if a.fileSize > 0, FileCopier.size(existing) == a.fileSize, FileManager.default.fileExists(atPath: existing.path) {
                return Item(asset: a, action: .reuse(mediaDir.appendingPathComponent(a.url.lastPathComponent)),
                            cloneable: cloneable, cost: FileCopier.perFileCost, bytes: 0)
            }
            let size = FileCopier.size(a.url)
            return Item(asset: a, action: .copy, cloneable: cloneable,
                        cost: FileCopier.cost(bytes: size, cloneable: cloneable), bytes: size)
        }
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
