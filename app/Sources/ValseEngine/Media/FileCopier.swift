import Foundation
import Darwin

/// Byte-level file copies with progress (BUG-PACK-PROGRESS): "Pack project" / "Copy media to project" used
/// `FileManager.copyItem`, which reports nothing until a whole file is copied (one big video = one jump of the bar).
/// A copy first tries an APFS clone (instant, same volume); otherwise it streams in chunks, reporting bytes and
/// checking cancellation between chunks. A cancelled or failed copy removes its partial destination.
public enum FileCopier {
    /// Fixed cost of one file (open / create / metadata), in "bytes" of work, so many tiny files still weigh something.
    public static let perFileCost: Int64 = 64 << 10
    static let chunkSize = 4 << 20

    /// Work units of copying `bytes` (bytes, plus the per-file overhead; a clone costs only the overhead).
    public static func cost(bytes: Int64, cloneable: Bool) -> Int64 {
        cloneable ? perFileCost : max(bytes, 0) + perFileCost
    }

    /// Size of a regular file (0 when unreadable).
    public static func size(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// True when a file at `src` can be cloned into `dir` (same volume and the volume supports clones). `dir` may not
    /// exist yet: its nearest existing ancestor is checked.
    public static func canClone(_ src: URL, into dir: URL) -> Bool {
        var d = dir.standardizedFileURL
        while !FileManager.default.fileExists(atPath: d.path), d.pathComponents.count > 1 { d = d.deletingLastPathComponent() }
        let keys: Set<URLResourceKey> = [.volumeIdentifierKey, .volumeSupportsFileCloningKey]
        guard let a = try? src.resourceValues(forKeys: keys), let b = try? d.resourceValues(forKeys: keys),
              let va = a.volumeIdentifier as? NSObject, let vb = b.volumeIdentifier as? NSObject else { return false }
        return va.isEqual(vb) && b.volumeSupportsFileCloning == true
    }

    /// Copies one regular file. `onBytes` gets the bytes of this file copied so far (ends with the file size).
    /// `clone: false` always streams (tests: byte-level progress on a same-volume copy).
    public static func copyFile(at src: URL, to dst: URL, clone: Bool = true, onBytes: (Int64) -> Void) throws {
        try Task.checkCancellation()
        let total = size(src)
        if clone, Darwin.clonefile(src.path, dst.path, 0) == 0 { onBytes(total); return }
        let fm = FileManager.default
        guard let input = FileHandle(forReadingAtPath: src.path) else { throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: src.path]) }
        defer { try? input.close() }
        guard !fm.fileExists(atPath: dst.path), fm.createFile(atPath: dst.path, contents: nil),
              let output = FileHandle(forWritingAtPath: dst.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: dst.path])
        }
        var done: Int64 = 0
        do {
            defer { try? output.close() }
            while true {
                try Task.checkCancellation()
                let chunk = try autoreleasepool { try input.read(upToCount: chunkSize) } ?? Data()
                if chunk.isEmpty { break }
                try output.write(contentsOf: chunk)
                done += Int64(chunk.count)
                onBytes(done)
            }
        } catch {
            try? fm.removeItem(at: dst)
            throw error
        }
        if let attrs = try? fm.attributesOfItem(atPath: src.path) {
            var keep: [FileAttributeKey: Any] = [:]
            if let m = attrs[.modificationDate] { keep[.modificationDate] = m }
            if let p = attrs[.posixPermissions] { keep[.posixPermissions] = p }
            try? fm.setAttributes(keep, ofItemAtPath: dst.path)
        }
        onBytes(max(done, total))
    }

    /// Files of a directory tree (relative paths, sizes), skipping the top-level names in `skip`.
    public static func treeFiles(_ root: URL, skip: Set<String> = []) -> [(path: String, size: Int64)] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: []) else { return [] }
        let base = root.standardizedFileURL.pathComponents.count
        var out: [(String, Int64)] = []
        for case let u as URL in e {
            let comps = Array(u.standardizedFileURL.pathComponents.dropFirst(base))
            guard let first = comps.first else { continue }
            if skip.contains(first) { e.skipDescendants(); continue }
            let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if v?.isRegularFile == true { out.append((comps.joined(separator: "/"), Int64(v?.fileSize ?? 0))) }
        }
        return out
    }

    /// Work units of `copyTree(root, …)` into `dir`.
    public static func treeCost(_ root: URL, into dir: URL, skip: Set<String> = [], clone: Bool = true) -> Int64 {
        let cloneable = clone && canClone(root, into: dir)
        return treeFiles(root, skip: skip).reduce(perFileCost) { $0 + cost(bytes: $1.size, cloneable: cloneable) }
    }

    /// Copies a directory tree (top-level `skip` names left out). `onCost` gets the work units done so far
    /// (same scale as `treeCost`). Symlinks and other non-regular items are copied as they are.
    public static func copyTree(at root: URL, to dst: URL, skip: Set<String> = [], clone: Bool = true,
                                onCost: (Int64) -> Void) throws {
        let fm = FileManager.default
        let cloneable = clone && canClone(root, into: dst.deletingLastPathComponent())
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey], options: []) else { return }
        let base = root.standardizedFileURL.pathComponents.count
        var doneCost = perFileCost
        onCost(doneCost)
        for case let u as URL in e {
            try Task.checkCancellation()
            let comps = Array(u.standardizedFileURL.pathComponents.dropFirst(base))
            guard let first = comps.first else { continue }
            if skip.contains(first) { e.skipDescendants(); continue }
            let target = dst.appendingPathComponent(comps.joined(separator: "/"))
            let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            if v?.isSymbolicLink == true {
                try fm.copyItem(at: u, to: target)
            } else if v?.isDirectory == true {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else if v?.isRegularFile == true {
                let sz = size(u)
                let before = doneCost
                try copyFile(at: u, to: target, clone: clone) { b in
                    onCost(before + (cloneable ? perFileCost * min(b, max(sz, 1)) / max(sz, 1) : b))
                }
                doneCost = before + cost(bytes: sz, cloneable: cloneable)
                onCost(doneCost)
            }
        }
    }
}

/// Throttles a 0…1 progress callback: forwards only increases of at least `step` or after `interval` seconds,
/// always forwards 1. Thread-safe (called from copy / zip loops off the main thread).
public final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Double = -1
    private var lastTime = Date.distantPast
    private let step: Double, interval: TimeInterval
    private let sink: @Sendable (Double) -> Void

    public init(step: Double = 0.005, interval: TimeInterval = 0.1, _ sink: @escaping @Sendable (Double) -> Void) {
        self.step = step; self.interval = interval; self.sink = sink
    }

    public func report(_ p: Double) {
        let v = min(max(p, 0), 1)
        let send: Bool = lock.withLock {
            guard v > last else { return false }
            let now = Date()
            guard v >= 1 || v - last >= step || now.timeIntervalSince(lastTime) >= interval else { return false }
            last = v; lastTime = now
            return true
        }
        if send { sink(v) }
    }
}
