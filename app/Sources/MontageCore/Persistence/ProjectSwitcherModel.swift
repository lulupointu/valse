import Foundation

/// P1 project switcher (title-bar popover, ⌘⇧O): the pure part — which projects are listed, in which order, their
/// status, keyboard selection and the checks an open must pass BEFORE the current project is closed.
/// The UI (`MontageUI/Home/ProjectSwitcher.swift`) feeds it `ProjectLibrary` entries and injected lock / drive providers.
public enum ProjectSwitcherModel {
    public enum Status: String, Sendable, Equatable {
        case normal
        /// The project shown in this window.
        case current
        /// Open in another Montage window (PM-014): a click brings that window forward.
        case otherWindow
        /// On a drive that isn't connected (PM-009).
        case offline
    }

    public struct Row: Sendable, Equatable, Identifiable {
        public var entry: LibraryEntry
        public var status: Status
        /// Shown in the meta line when several projects share the name (package name, else its folder).
        public var disambiguation: String?
        public var id: String { entry.id }
        public var isCurrent: Bool { status == .current }
        public init(entry: LibraryEntry, status: Status, disambiguation: String? = nil) {
            self.entry = entry; self.status = status; self.disambiguation = disambiguation
        }
    }

    static func same(_ a: URL, _ b: URL?) -> Bool { b.map { a.standardizedFileURL.path == $0.standardizedFileURL.path } ?? false }

    /// Every non-trashed project matching `search` (case / diacritic-insensitive): the current project first, then by
    /// last opened (most recent first), then never-opened ones by modification date.
    public static func ordered(_ entries: [LibraryEntry], current: URL?, search: String = "") -> [LibraryEntry] {
        let list = ProjectLibrary.filter(entries, scope: .all, search: search)
        return list.sorted { a, b in
            let ca = same(a.url, current), cb = same(b.url, current)
            if ca != cb { return ca }
            switch (a.lastOpened, b.lastOpened) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default:
                if a.modifiedAt != b.modifiedAt { return a.modifiedAt > b.modifiedAt }
                return a.url.path < b.url.path
            }
        }
    }

    /// Rows with their status. `heldElsewhere` / `offline` are the injected lock and drive providers.
    public static func rows(_ entries: [LibraryEntry], current: URL?, search: String = "",
                            heldElsewhere: (URL) -> Bool, offline: (URL) -> Bool) -> [Row] {
        let list = ordered(entries, current: current, search: search)
        var counts: [String: Int] = [:]
        for e in entries where e.trashedAt == nil { counts[e.name.lowercased(), default: 0] += 1 }
        return list.map { e in
            let status: Status = same(e.url, current) ? .current : offline(e.url) ? .offline : heldElsewhere(e.url) ? .otherWindow : .normal
            var dis: String?
            if counts[e.name.lowercased(), default: 0] > 1 {
                let file = e.url.deletingPathExtension().lastPathComponent
                dis = file != e.name ? file : e.url.deletingLastPathComponent().lastPathComponent
            }
            return Row(entry: e, status: status, disambiguation: dis)
        }
    }

    /// Keyboard selection when the list (re)appears: the first row after the current project.
    public static func initialSelection(_ rows: [Row]) -> Int? {
        guard !rows.isEmpty else { return nil }
        return rows.firstIndex { !$0.isCurrent } ?? 0
    }

    /// ↑ / ↓ with wrapping.
    public static func move(_ selection: Int?, by delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let s = selection else { return delta >= 0 ? 0 : count - 1 }
        return ((s + delta) % count + count) % count
    }

    // MARK: Opening

    /// Result of the checks run before anything is closed (spec order).
    public enum OpenCheck: Equatable, Sendable {
        /// The project already shown here: just close the popover.
        case alreadyCurrent
        /// Held by another running Montage window: bring it forward, keep the current project.
        case heldElsewhere(pid: Int32)
        /// On a drive that isn't connected.
        case offline(drive: String)
        /// Its summary can't be read (deleted, trashed elsewhere, corrupted).
        case unreadable
        /// Safe to close the current project and open this one.
        case ok
    }

    public static func check(_ url: URL, current: URL?, holderPID: (URL) -> Int32?, location: (URL) -> StorageLocation,
                             readable: (URL) -> Bool) -> OpenCheck {
        if same(url, current) { return .alreadyCurrent }
        if let pid = holderPID(url) { return .heldElsewhere(pid: pid) }
        if case .unavailable(let drive) = location(url) { return .offline(drive: drive) }
        if !readable(url) { return .unreadable }
        return .ok
    }

    /// Default checks against the file system.
    public static func check(_ url: URL, current: URL?) -> OpenCheck {
        check(url, current: current, holderPID: { SessionLock.holderPID($0) }, location: StorageLocation.of,
              readable: { ProjectPackage.summary(of: $0) != nil })
    }

    /// Cheap offline test for listing hundreds of rows (volume lookups only for /Volumes paths or test overrides).
    public static func isOffline(_ url: URL) -> Bool {
        guard StorageLocation.volumeRoot(of: url) != nil || !StorageLocation.testOverrides.isEmpty else { return false }
        return StorageLocation.of(url).isUnavailable
    }
}
