import Foundation

public enum PersistenceError: Error, Equatable, Sendable {
    case notAPackage
    case unreadable(String)
    case newerSchema(Int)
    case migrationFailed(Int)
    /// The project is open in another Valse process.
    case openElsewhere

    public var messageKey: String {
        switch self {
        case .notAPackage: return "error.notAPackage"
        case .unreadable: return "error.unreadable"
        case .newerSchema: return "error.newerSchema"
        case .migrationFailed: return "error.migrationFailed"
        case .openElsewhere: return "error.openElsewhere"
        }
    }
}

/// `.valse` document package:
/// ```
/// MyFilm.valse/
///   project.json      versioned Codable `Project` (schemaVersion at top level)
///   media/            optional copies of media ("Copy media into project")
///   cover.jpg         optional cover thumbnail for the Home screen
///   summary.json      small `ProjectSummary` (name, duration, canvas…) so the Home screen never decodes project.json
///   versions/         version snapshots (`ProjectVersions`)
/// ```
/// Caches (proxies, thumbnails, waveforms) are NOT stored here; they live in ~/Library/Caches/Valse keyed by
/// content hash and can be rebuilt.
public enum ProjectPackage {
    public static let fileExtension = "valse"
    /// Packages saved by Montage (`.montage`) open as they are; they keep their name (never renamed for the user).
    public static let legacyFileExtensions = [LegacyNames.projectExtension]
    public static let fileExtensions = [fileExtension] + legacyFileExtensions
    /// UTIs (Info.plist): `fr.valse.project` (exported), `fr.montage.project` (imported, read).
    public static let typeIdentifier = "fr.valse.project"
    public static let legacyTypeIdentifier = LegacyNames.projectUTI

    /// A project package path (`.valse`, or a `.montage` saved before the rename).
    public static func isPackage(_ url: URL) -> Bool { fileExtensions.contains(url.pathExtension.lowercased()) }
    public static let projectFileName = "project.json"
    public static let summaryFileName = "summary.json"
    public static let coverFileName = "cover.jpg"

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .deferredToDate
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .deferredToDate
        return d
    }

    /// Atomic save: writes project.json to a temp file then swaps it in. Updates media relative paths.
    public static func save(_ project: Project, to packageURL: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: packageURL, withIntermediateDirectories: true)
        var p = project
        let base = packageURL.deletingLastPathComponent()
        for i in p.media.indices { p.media[i].relativePath = relativePath(from: base, to: p.media[i].url) }
        // multi-timeline: the active slot's copy would duplicate `timeline` (stale); store it empty
        if let i = MultiTimelineOps.activeIndex(p) { p.timelines![i].timeline = Timeline(); p.timelines![i].settings = p.settings }
        let data = try encoder().encode(p)
        try data.write(to: packageURL.appendingPathComponent(projectFileName), options: .atomic)
        try? encoder().encode(ProjectSummary(p)).write(to: packageURL.appendingPathComponent(summaryFileName), options: .atomic)
    }

    /// The package's summary (falls back to decoding project.json for packages written before summaries existed).
    public static func summary(of packageURL: URL) -> ProjectSummary? {
        if let d = try? Data(contentsOf: packageURL.appendingPathComponent(summaryFileName)),
           let s = try? decoder().decode(ProjectSummary.self, from: d) { return s }
        return (try? load(from: packageURL)).map(ProjectSummary.init)
    }

    public static func load(from packageURL: URL) throws -> Project {
        let file = packageURL.appendingPathComponent(projectFileName)
        guard FileManager.default.fileExists(atPath: file.path) else { throw PersistenceError.notAPackage }
        let data: Data
        do { data = try Data(contentsOf: file) } catch { throw PersistenceError.unreadable(error.localizedDescription) }
        let migrated = try ProjectMigrator.migrate(data)
        var p: Project
        do { p = try decoder().decode(Project.self, from: migrated) } catch { throw PersistenceError.unreadable(String(describing: error)) }
        relink(&p, packageURL: packageURL)
        return p
    }

    /// If a media file moved together with the project, find it through its relative path.
    static func relink(_ p: inout Project, packageURL: URL) {
        let fm = FileManager.default
        let base = packageURL.deletingLastPathComponent()
        for i in p.media.indices where !fm.fileExists(atPath: p.media[i].url.path) {
            if let rel = p.media[i].relativePath {
                let candidate = base.appendingPathComponent(rel).standardizedFileURL
                if fm.fileExists(atPath: candidate.path) { p.media[i].url = candidate; continue }
            }
            // media copied into the package ("Copy to project", "Pack project") whose package was renamed or moved
            let own = packageURL.appendingPathComponent("media").appendingPathComponent(p.media[i].url.lastPathComponent)
            if fm.fileExists(atPath: own.path) { p.media[i].url = own.standardizedFileURL; continue }
            // a file in one of Montage's folders (pasted media, generated speech…) that moved to the Valse one
            if let moved = ValsePaths.movedFromLegacyFolder(p.media[i].url) { p.media[i].url = moved }
        }
    }

    static func relativePath(from base: URL, to target: URL) -> String? {
        let b = base.standardizedFileURL.pathComponents, t = target.standardizedFileURL.pathComponents
        var i = 0
        while i < b.count, i < t.count, b[i] == t[i] { i += 1 }
        guard i > 1 else { return nil }  // only share "/" → keep absolute
        return (Array(repeating: "..", count: b.count - i) + t[i...]).joined(separator: "/")
    }
}

/// Schema migrations on raw JSON. Each step upgrades version n → n+1. Add a step when bumping
/// `Project.currentSchemaVersion`; never edit an existing step.
public enum ProjectMigrator {
    public typealias Step = @Sendable (inout [String: Any]) throws -> Void
    /// steps[n] migrates schemaVersion n → n+1.
    /// Example when v2 ships: `[1: { obj in obj["newField"] = 0 }]`.
    public static let steps: [Int: Step] = [:]

    public static func migrate(_ data: Data) throws -> Data {
        // projects saved before the Montage → Valse rename name built-in content "montage.…" (any schema version)
        let data = LegacyNames.migrateContentIDs(inJSON: data)
        guard var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PersistenceError.unreadable("root is not an object")
        }
        var v = obj["schemaVersion"] as? Int ?? 0
        if v > Project.currentSchemaVersion { throw PersistenceError.newerSchema(v) }
        if v == Project.currentSchemaVersion { return data }
        while v < Project.currentSchemaVersion {
            guard let step = steps[v] else { throw PersistenceError.migrationFailed(v) }
            try step(&obj)
            v += 1
            obj["schemaVersion"] = v
        }
        return try JSONSerialization.data(withJSONObject: obj)
    }
}

/// What the Home screen needs to show a project card without decoding the whole project (`summary.json`).
public struct ProjectSummary: Codable, Sendable, Equatable {
    public var id: ProjectID
    public var name: String
    public var duration: Time
    public var canvasSize: Size2
    public var frameRate: FrameRate
    public var mediaCount: Int
    public var clipCount: Int
    public var createdAt: Date
    public var modifiedAt: Date

    public init(_ p: Project) {
        id = p.id; name = p.name; duration = p.duration; canvasSize = p.settings.canvasSize; frameRate = p.settings.frameRate
        mediaCount = p.media.count; clipCount = p.timeline.allClips.count; createdAt = p.createdAt; modifiedAt = p.modifiedAt
    }
}
