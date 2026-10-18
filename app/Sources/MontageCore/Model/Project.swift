import Foundation

/// Root document. Pure value type: copying is O(1) thanks to copy-on-write arrays, which is what makes
/// snapshot-based undo cheap (see `EditSession`). Persisted as `project.json` inside a `.montage` package.
public struct Project: Codable, Sendable, Equatable {
    /// Bump when the JSON shape changes and add a step to `ProjectMigrator`.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: ProjectID
    public var name: String
    public var settings: ProjectSettings
    /// Media bin, in import order.
    public var media: [MediaAsset]
    public var timeline: Timeline
    public var createdAt: Date
    public var modifiedAt: Date

    public init(name: String = "", settings: ProjectSettings = ProjectSettings()) {
        schemaVersion = Project.currentSchemaVersion
        id = ProjectID()
        self.name = name
        self.settings = settings
        media = []
        timeline = Timeline()
        createdAt = Date()
        modifiedAt = createdAt
    }

    public func asset(_ id: MediaID) -> MediaAsset? { media.first { $0.id == id } }

    /// Total timeline duration (end of the last clip on any track).
    public var duration: Time { timeline.duration }
}

public struct ProjectSettings: Codable, Sendable, Equatable {
    /// Canvas pixel size (export default). CapCut: "Ratio" + resolution.
    public var canvasSize: Size2
    public var frameRate: FrameRate
    public var backgroundColor: RGBA
    /// Canvas ratio preset id ("original", "16:9", "9:16", "1:1", "4:3", "3:4", "21:9", …). "original" follows the
    /// first main-track clip.
    public var aspectPreset: String

    public init(canvasSize: Size2 = .hd1080, frameRate: FrameRate = .fps30,
                backgroundColor: RGBA = .black, aspectPreset: String = "16:9") {
        self.canvasSize = canvasSize; self.frameRate = frameRate
        self.backgroundColor = backgroundColor; self.aspectPreset = aspectPreset
    }

    /// Ratio presets offered by the player "Ratio" menu: (id, width, height) at 1080p-class sizes.
    public static let aspectPresets: [(id: String, size: Size2)] = [
        ("16:9", Size2(1920, 1080)), ("4:3", Size2(1440, 1080)), ("2.35:1", Size2(2538, 1080)),
        ("2:1", Size2(2160, 1080)), ("1.85:1", Size2(1998, 1080)),
        ("9:16", Size2(1080, 1920)), ("3:4", Size2(1080, 1440)), ("5.8-inch", Size2(1080, 2338)), ("1:1", Size2(1080, 1080)),
        // not in CapCut's menu; kept so older projects still resolve their ratio
        ("21:9", Size2(2560, 1080)), ("4:5", Size2(1080, 1350)),
    ]

    /// Ratio menu rows in CapCut order (UX.md §4.1, after Original / Customized); nil = separator.
    public static let ratioMenu: [String?] = ["16:9", "4:3", "2.35:1", "2:1", "1.85:1", nil, "9:16", "3:4", "5.8-inch", "1:1"]

    public static func presetSize(_ id: String) -> Size2? { aspectPresets.first { $0.id == id }?.size }
}

public enum MediaKind: String, Codable, Sendable { case video, audio, image }

/// Imported file. Metadata is probed once at import (MontageEngine.MediaProbe) and cached here.
public struct MediaAsset: Codable, Sendable, Equatable, Identifiable {
    public var id: MediaID
    public var name: String
    public var kind: MediaKind
    /// Absolute location at last save/import.
    public var url: URL
    /// Path relative to the project package's parent directory, used to relink moved projects.
    public var relativePath: String?
    /// Security-scoped bookmark (sandboxed builds).
    public var bookmark: Data?
    /// Media duration (`.indefinite` for images).
    public var duration: Time
    /// Display pixel size (rotation already applied).
    public var pixelSize: Size2
    public var frameRate: FrameRate?
    public var hasVideo: Bool
    public var hasAudio: Bool
    /// Fast content fingerprint (size + mtime + head/tail bytes). Keys every cache (proxy/thumbs/waveform).
    public var contentHash: String
    public var fileSize: Int64
    public var codec: String?
    /// Clockwise rotation (0/90/180/270) to apply to decoded frames (from the track's preferredTransform).
    public var sourceRotation: Int

    public init(id: MediaID = MediaID(), name: String, kind: MediaKind, url: URL, duration: Time, pixelSize: Size2,
                frameRate: FrameRate?, hasVideo: Bool, hasAudio: Bool, contentHash: String, fileSize: Int64 = 0,
                codec: String? = nil, sourceRotation: Int = 0) {
        self.id = id; self.name = name; self.kind = kind; self.url = url; self.duration = duration
        self.pixelSize = pixelSize; self.frameRate = frameRate; self.hasVideo = hasVideo; self.hasAudio = hasAudio
        self.contentHash = contentHash; self.fileSize = fileSize; self.codec = codec; self.sourceRotation = sourceRotation
    }

    /// Default timeline duration when inserted (images: 5 s like CapCut).
    public var defaultClipDuration: Time { kind == .image ? Time(5) : duration }
}

public struct Marker: Codable, Sendable, Equatable, Identifiable {
    public var id: MarkerID
    public var time: Time
    public var label: String
    public var color: RGBA
    /// Free-form note ("Edit marker"). Optional for backward-compatible decoding.
    public var note: String?
    public init(time: Time, label: String = "", color: RGBA = RGBA(hex: 0x00C1CD)) {
        id = MarkerID(); self.time = time; self.label = label; self.color = color
    }
}
