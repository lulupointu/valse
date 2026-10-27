import Foundation

/// What a file-system error means for the user (BUG-ERROR-COPY): the reason an error message can name and act on
/// ("the disk is full" → Open Storage Settings) instead of a raw error domain / code. Walks `NSUnderlyingErrorKey`
/// chains (URLSession and AVFoundation wrap the POSIX error).
public enum FileErrorKind: Sendable, Equatable {
    case diskFull
    case noPermission
    case readOnlyVolume
    case notFound
    case other

    public static func classify(_ error: Error) -> FileErrorKind {
        var e: NSError? = error as NSError
        var depth = 0
        while let n = e, depth < 6 {
            if let k = kind(of: n) { return k }
            e = n.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return .other
    }

    private static func kind(of e: NSError) -> FileErrorKind? {
        switch e.domain {
        case NSCocoaErrorDomain:
            switch e.code {
            case NSFileWriteOutOfSpaceError: return .diskFull
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError: return .noPermission
            case NSFileWriteVolumeReadOnlyError: return .readOnlyVolume
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return .notFound
            default: return nil
            }
        case NSPOSIXErrorDomain:
            switch Int32(e.code) {
            case ENOSPC, EDQUOT: return .diskFull
            case EACCES, EPERM: return .noPermission
            case EROFS: return .readOnlyVolume
            case ENOENT: return .notFound
            default: return nil
            }
        default: return nil
        }
    }

    /// Name of the external drive holding `url` when that drive is not mounted any more ("/Volumes/T7/…" with no
    /// "/Volumes/T7"), else nil.
    public static func offlineVolumeName(for url: URL) -> String? {
        let parts = url.standardizedFileURL.pathComponents   // ["/", "Volumes", "T7", …]
        guard parts.count >= 3, parts[1] == "Volumes" else { return nil }
        let root = "/Volumes/" + parts[2]
        return FileManager.default.fileExists(atPath: root) ? nil : parts[2]
    }
}
