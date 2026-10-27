import Foundation

/// Where a folder lives (PM-009): internal disk, an external / removable drive, a network share, or a drive that isn't
/// connected right now. Settings ▸ Project ▸ Save to warns for the last three (CapCut "external drive" warning), Home
/// shows a banner while the save folder's drive is disconnected, and new projects fall back to the default folder.
public enum StorageLocation: Equatable, Sendable {
    case internalDisk
    case external(name: String)
    case network(name: String)
    case unavailable(name: String)

    /// Volume flags read from the nearest existing ancestor (pure input of `classify`, tested without a real drive).
    public struct VolumeFlags: Equatable, Sendable {
        public var isInternal: Bool?
        public var isLocal: Bool?
        public var isRemovable: Bool?
        public var isEjectable: Bool?
        public var name: String?
        public init(isInternal: Bool? = nil, isLocal: Bool? = nil, isRemovable: Bool? = nil, isEjectable: Bool? = nil, name: String? = nil) {
            self.isInternal = isInternal; self.isLocal = isLocal; self.isRemovable = isRemovable; self.isEjectable = isEjectable; self.name = name
        }
    }

    public var needsWarning: Bool { self != .internalDisk }
    public var isUnavailable: Bool { if case .unavailable = self { return true }; return false }
    public var driveName: String? {
        switch self {
        case .internalDisk: return nil
        case .external(let n), .network(let n), .unavailable(let n): return n
        }
    }

    /// `/Volumes/<name>` for a path on a mounted (or formerly mounted) volume, nil otherwise.
    public static func volumeRoot(of url: URL) -> URL? {
        let c = url.standardizedFileURL.pathComponents   // ["/", "Volumes", "<name>", …]
        guard c.count >= 3, c[1] == "Volumes" else { return nil }
        return URL(fileURLWithPath: "/Volumes", isDirectory: true).appendingPathComponent(c[2], isDirectory: true)
    }

    /// Pure classification from the volume flags (nil flags = unknown, treated as internal).
    public static func classify(flags: VolumeFlags, fallbackName: String) -> StorageLocation {
        let name = flags.name ?? fallbackName
        if flags.isLocal == false { return .network(name: name) }
        if flags.isInternal == false || flags.isRemovable == true || flags.isEjectable == true { return .external(name: name) }
        return .internalDisk
    }

    /// Test hook: UI tests pretend a path is on an external drive (`home:…:extdrive`).
    nonisolated(unsafe) public static var testOverrides: [String: StorageLocation] = [:]

    /// Classifies `url` (it need not exist yet: the nearest existing ancestor's volume is used).
    public static func of(_ url: URL) -> StorageLocation {
        let std = url.standardizedFileURL
        for (prefix, loc) in testOverrides where std.path.hasPrefix(prefix) { return loc }
        let fm = FileManager.default
        if let root = volumeRoot(of: std), !fm.fileExists(atPath: root.path) {
            return .unavailable(name: root.lastPathComponent)
        }
        var probe = std
        while !fm.fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe.deleteLastPathComponent() }
        let keys: Set<URLResourceKey> = [.volumeIsInternalKey, .volumeIsLocalKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
                                         .volumeLocalizedNameKey, .volumeIsRootFileSystemKey]
        guard let v = try? probe.resourceValues(forKeys: keys) else { return .internalDisk }
        if v.volumeIsRootFileSystem == true { return .internalDisk }
        let flags = VolumeFlags(isInternal: v.volumeIsInternal, isLocal: v.volumeIsLocal, isRemovable: v.volumeIsRemovable,
                                isEjectable: v.volumeIsEjectable, name: v.volumeLocalizedName)
        return classify(flags: flags, fallbackName: volumeRoot(of: std)?.lastPathComponent ?? probe.lastPathComponent)
    }
}
