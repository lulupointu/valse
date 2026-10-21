import Foundation

/// Installs a freshly built file / folder (compiled CoreML model, unzipped package) at a path other processes share
/// (the compiled-models cache is shared by every app and test process): the item is built elsewhere, then RENAMED into
/// place (atomic on one volume), so nobody ever sees a half-written destination, and a destination another process
/// installed first counts as success. A valid destination is never deleted; a stale one (`replace: true`) is renamed
/// aside first, so a process that already opened it keeps reading its files.
public enum AtomicInstall {
    /// Moves `built` to `dst`. Returns `dst`. `replace`: `dst` is outdated and must be swapped for `built`.
    @discardableResult
    public static func place(_ built: URL, at dst: URL, replace: Bool = false) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        // stage next to the destination (same volume), so the final step is a rename
        let staged = dst.deletingLastPathComponent().appendingPathComponent(".\(dst.lastPathComponent).\(UUID().uuidString)")
        do { try fm.moveItem(at: built, to: staged) } catch { try fm.copyItem(at: built, to: staged); try? fm.removeItem(at: built) }
        var aside: URL?
        if replace, fm.fileExists(atPath: dst.path) {
            let a = dst.deletingLastPathComponent().appendingPathComponent(".\(dst.lastPathComponent).old.\(UUID().uuidString)")
            if (try? fm.moveItem(at: dst, to: a)) != nil { aside = a }
        }
        defer { if let aside { try? fm.removeItem(at: aside) } }
        // (a file replaces an existing file atomically: readers keep the old inode)
        if rename(staged.path, dst.path) == 0 { return dst }
        // rename(2) of a directory onto an existing non-empty directory fails (ENOTEMPTY / EEXIST): someone else won
        let err = errno
        try? fm.removeItem(at: staged)
        if fm.fileExists(atPath: dst.path) { return dst }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: [NSFilePathErrorKey: dst.path])
    }
}
