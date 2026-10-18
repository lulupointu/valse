import Foundation

/// Pure media-bin folder operations (CapCut Media panel folders). Invariants: every `parentID` / `folderID` points at
/// an existing folder, no cycles, depth ≤ `maxDepth`.
public enum BinOps {
    /// CapCut allows 10 nested levels.
    public static let maxDepth = 10

    public enum BinError: Error, Equatable, Sendable {
        case folderNotFound, tooDeep, cycle, emptyName
        public var messageKey: String {
            switch self {
            case .folderNotFound: return "error.folderNotFound"
            case .tooDeep: return "error.folderTooDeep"
            case .cycle: return "error.folderCycle"
            case .emptyName: return "error.folderName"
            }
        }
    }

    /// Depth of a folder (root children = 1).
    public static func depth(of id: MediaFolderID?, in p: Project) -> Int {
        var d = 0, cur = id
        let byID = Dictionary(uniqueKeysWithValues: p.folders.map { ($0.id, $0) })
        while let c = cur, let f = byID[c] { d += 1; cur = f.parentID; if d > 1000 { break } }
        return d
    }

    /// Height of the subtree rooted at `id` (a leaf = 1).
    static func height(of id: MediaFolderID, in p: Project) -> Int {
        1 + (p.folders.filter { $0.parentID == id }.map { height(of: $0.id, in: p) }.max() ?? 0)
    }

    public static func children(of id: MediaFolderID?, in p: Project) -> [MediaFolder] {
        p.folders.filter { $0.parentID == id }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func media(in id: MediaFolderID?, of p: Project) -> [MediaAsset] { p.media.filter { $0.folderID == id } }

    /// Root → folder chain (for breadcrumbs).
    public static func path(to id: MediaFolderID?, in p: Project) -> [MediaFolder] {
        var out: [MediaFolder] = [], cur = id
        while let c = cur, let f = p.folders.first(where: { $0.id == c }), out.count <= maxDepth { out.insert(f, at: 0); cur = f.parentID }
        return out
    }

    /// Unique name among siblings ("Folder", "Folder 2"…).
    public static func uniqueName(_ base: String, parent: MediaFolderID?, in p: Project) -> String {
        let names = Set(children(of: parent, in: p).map(\.name))
        if !names.contains(base) { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    @discardableResult
    public static func createFolder(_ name: String, parent: MediaFolderID?, in p: inout Project) throws -> MediaFolderID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BinError.emptyName }
        if let parent { guard p.folders.contains(where: { $0.id == parent }) else { throw BinError.folderNotFound } }
        guard depth(of: parent, in: p) + 1 <= maxDepth else { throw BinError.tooDeep }
        let f = MediaFolder(name: uniqueName(trimmed, parent: parent, in: p), parentID: parent)
        p.folders.append(f)
        return f.id
    }

    public static func rename(_ id: MediaFolderID, to name: String, in p: inout Project) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BinError.emptyName }
        guard let i = p.folders.firstIndex(where: { $0.id == id }) else { throw BinError.folderNotFound }
        p.folders[i].name = trimmed
    }

    public static func moveFolder(_ id: MediaFolderID, to parent: MediaFolderID?, in p: inout Project) throws {
        guard let i = p.folders.firstIndex(where: { $0.id == id }) else { throw BinError.folderNotFound }
        if let parent {
            guard p.folders.contains(where: { $0.id == parent }) else { throw BinError.folderNotFound }
            // parent must not be inside the moved subtree
            var cur: MediaFolderID? = parent
            while let c = cur { if c == id { throw BinError.cycle }; cur = p.folders.first { $0.id == c }?.parentID }
        }
        guard depth(of: parent, in: p) + height(of: id, in: p) <= maxDepth else { throw BinError.tooDeep }
        p.folders[i].parentID = parent
    }

    public static func moveMedia(_ ids: Set<MediaID>, to folder: MediaFolderID?, in p: inout Project) throws {
        if let folder { guard p.folders.contains(where: { $0.id == folder }) else { throw BinError.folderNotFound } }
        for i in p.media.indices where ids.contains(p.media[i].id) { p.media[i].folderID = folder }
    }

    /// Deletes a folder and its sub-folders. Contained media is kept and moves up to the deleted folder's parent
    /// (media may be used on the timeline; deleting media is a separate, explicit action).
    public static func deleteFolder(_ id: MediaFolderID, in p: inout Project) throws {
        guard let f = p.folders.first(where: { $0.id == id }) else { throw BinError.folderNotFound }
        var doomed: Set<MediaFolderID> = [id]
        var changed = true
        while changed {
            changed = false
            for g in p.folders where !doomed.contains(g.id) { if let par = g.parentID, doomed.contains(par) { doomed.insert(g.id); changed = true } }
        }
        for i in p.media.indices { if let fid = p.media[i].folderID, doomed.contains(fid) { p.media[i].folderID = f.parentID } }
        p.folders.removeAll { doomed.contains($0.id) }
    }

    /// Creates (or reuses) the folder chain `components` under `parent`, e.g. an imported directory's structure.
    public static func ensurePath(_ components: [String], under parent: MediaFolderID?, in p: inout Project) throws -> MediaFolderID? {
        var cur = parent
        for name in components.prefix(maxDepth - depth(of: parent, in: p)) {
            if let existing = p.folders.first(where: { $0.parentID == cur && $0.name == name }) { cur = existing.id; continue }
            let f = MediaFolder(name: name, parentID: cur)
            p.folders.append(f)
            cur = f.id
        }
        return cur
    }

    /// Invariant check (tests).
    public static func validate(_ p: Project) -> [String] {
        var issues: [String] = []
        let ids = Set(p.folders.map(\.id))
        for f in p.folders {
            if let par = f.parentID, !ids.contains(par) { issues.append("folder \(f.name): dangling parent") }
            if depth(of: f.id, in: p) > maxDepth { issues.append("folder \(f.name): too deep") }
        }
        for m in p.media { if let fid = m.folderID, !ids.contains(fid) { issues.append("media \(m.name): dangling folder") } }
        return issues
    }
}

/// Undoable bin edits.
public struct BinCommand: EditCommand {
    public let nameKey: String
    let body: @Sendable (inout Project) throws -> Void
    public static func createFolder(_ name: String, parent: MediaFolderID?) -> BinCommand {
        BinCommand(nameKey: "cmd.newFolder") { try BinOps.createFolder(name, parent: parent, in: &$0) }
    }
    public static func rename(_ id: MediaFolderID, _ name: String) -> BinCommand {
        BinCommand(nameKey: "cmd.renameFolder") { try BinOps.rename(id, to: name, in: &$0) }
    }
    public static func moveFolder(_ id: MediaFolderID, to parent: MediaFolderID?) -> BinCommand {
        BinCommand(nameKey: "cmd.moveToFolder") { try BinOps.moveFolder(id, to: parent, in: &$0) }
    }
    public static func moveMedia(_ ids: Set<MediaID>, to folder: MediaFolderID?) -> BinCommand {
        BinCommand(nameKey: "cmd.moveToFolder") { try BinOps.moveMedia(ids, to: folder, in: &$0) }
    }
    public static func deleteFolder(_ id: MediaFolderID) -> BinCommand {
        BinCommand(nameKey: "cmd.deleteFolder") { try BinOps.deleteFolder(id, in: &$0) }
    }
    public func apply(to project: inout Project) throws { try body(&project) }
}
