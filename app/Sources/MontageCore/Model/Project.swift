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
    /// Media bin folders (nil = none; use `folders`). Optional so older files decode.
    public var mediaFolders: [MediaFolder]?
    /// Nested timelines of compound clips (TL-021). Optional so older files decode.
    public var compounds: [CompoundClip]?
    /// Project cover (TL-045, main-track "Cover" button): nil = the first frame. Optional so older files decode.
    public var cover: ProjectCover?
    /// Player guides (PB-011), saved with the project. Optional so older files decode.
    public var guides: [ProjectGuide]?
    /// Editing inside compound clips (TL-021): the parent timelines to return to. nil = not inside a compound.
    public var compoundEdit: [CompoundEditFrame]?

    /// Multi-timeline (TL-023): every timeline in tab order; nil = one timeline. The active one is live in
    /// `timeline` / `settings` (see `TimelineSlot`). Optional so older files decode.
    public var timelines: [TimelineSlot]?
    public var activeTimelineID: TimelineSlotID?
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

    /// O(1) asset lookup for loops over every clip (perf: `asset(_:)` is a linear scan — 500 clips × 300 media on every
    /// edit tick otherwise). Build once per pass, not per clip.
    public var mediaLookup: MediaLookup { MediaLookup.cached(media) }

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
    /// Working/output colour space (SDR Rec.709 by default; HDR = Rec.2020 HLG/PQ, 10-bit export).
    public var colorSpace: ProjectColorSpace
    /// Project settings ▸ Import material: true = copy imported files into the package, false = keep them in place,
    /// nil = follow Settings ▸ Project (SE-010).
    public var copyMediaOnImport: Bool?

    public init(canvasSize: Size2 = .hd1080, frameRate: FrameRate = .fps30,
                backgroundColor: RGBA = .black, aspectPreset: String = "16:9", colorSpace: ProjectColorSpace = .sdr709) {
        self.canvasSize = canvasSize; self.frameRate = frameRate
        self.backgroundColor = backgroundColor; self.aspectPreset = aspectPreset; self.colorSpace = colorSpace
    }

    private enum CodingKeys: String, CodingKey { case canvasSize, frameRate, backgroundColor, aspectPreset, colorSpace, copyMediaOnImport }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        canvasSize = try c.decode(Size2.self, forKey: .canvasSize)
        frameRate = try c.decode(FrameRate.self, forKey: .frameRate)
        backgroundColor = try c.decode(RGBA.self, forKey: .backgroundColor)
        aspectPreset = try c.decode(String.self, forKey: .aspectPreset)
        colorSpace = try c.decodeIfPresent(ProjectColorSpace.self, forKey: .colorSpace) ?? .sdr709
        copyMediaOnImport = try c.decodeIfPresent(Bool.self, forKey: .copyMediaOnImport)
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
    /// Colour tags of the video track (AVFoundation strings, e.g. "ITU_R_2020", "ITU_R_2100_HLG"); nil = untagged.
    public var colorPrimaries: String?
    public var transferFunction: String?
    public var yCbCrMatrix: String?
    /// Bits per component of the decoded video (8, 10…), if known.
    public var bitDepth: Int?

    /// Transfer characteristic from the tags (untagged = SDR).
    public var transfer: TransferFunction {
        switch transferFunction {
        case "ITU_R_2100_HLG": return .hlg
        case "SMPTE_ST_2084_PQ": return .pq
        default: return .sdr
        }
    }
    public var isHDR: Bool { transfer != .sdr }
    public var isWideGamut: Bool { colorPrimaries == "ITU_R_2020" }
    /// Bin folder (nil = root).
    public var folderID: MediaFolderID?
    /// Set when the file needs a one-time conversion to be playable (GIF, image sequence, FFmpeg-only formats).
    public var conversion: MediaConversion?
    /// Image-sequence layout when `conversion == .imageSequence`.
    public var sequence: ImageSequenceInfo?
    /// Probed technical details (Material info, audio streams, alpha, VFR).
    public var techInfo: MediaTechInfo?
    /// Paired motion video of a Live Photo (HEIC + MOV with the same name).
    public var livePhotoVideoURL: URL?

    public init(id: MediaID = MediaID(), name: String, kind: MediaKind, url: URL, duration: Time, pixelSize: Size2,
                frameRate: FrameRate?, hasVideo: Bool, hasAudio: Bool, contentHash: String, fileSize: Int64 = 0,
                codec: String? = nil, sourceRotation: Int = 0) {
        self.id = id; self.name = name; self.kind = kind; self.url = url; self.duration = duration
        self.pixelSize = pixelSize; self.frameRate = frameRate; self.hasVideo = hasVideo; self.hasAudio = hasAudio
        self.contentHash = contentHash; self.fileSize = fileSize; self.codec = codec; self.sourceRotation = sourceRotation
    }

    /// Default timeline duration when inserted (images: Settings ▸ Edit ▸ Image duration, 5 s like CapCut).
    public var defaultClipDuration: Time { kind == .image ? EditDefaults.current.imageDuration : duration }
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

/// Id → asset index over a project's media (first match wins, like `Project.asset(_:)`).
public struct MediaLookup: Sendable {
    private let media: [MediaAsset]
    private let index: [MediaID: Int]
    public init(_ media: [MediaAsset]) {
        self.media = media
        var ix: [MediaID: Int] = [:]
        ix.reserveCapacity(media.count)
        for (i, m) in media.enumerated() where ix[m.id] == nil { ix[m.id] = i }
        index = ix
    }
    public subscript(_ id: MediaID) -> MediaAsset? { index[id].map { media[$0] } }

    /// The last lookup built, reused while the media array is the same buffer (every edit tick asks for one; the media
    /// list rarely changes). Holding the array keeps its buffer alive, so an equal address means identical contents.
    private static let cache = NSLock()
    nonisolated(unsafe) private static var last: MediaLookup?
    public static func cached(_ media: [MediaAsset]) -> MediaLookup {
        cache.lock(); defer { cache.unlock() }
        if let l = last, l.media.count == media.count,
           media.isEmpty || l.media.withUnsafeBufferPointer({ a in media.withUnsafeBufferPointer { b in a.baseAddress == b.baseAddress } }) {
            return l
        }
        let l = MediaLookup(media)
        last = l
        return l
    }
    /// Id → asset dictionary (for code that wants one).
    public var dictionary: [MediaID: MediaAsset] { index.mapValues { media[$0] } }
}

/// A player guide line (PB-011): `vertical` guides sit at `position` × canvas width, horizontal ones × height.
public struct ProjectGuide: Codable, Sendable, Equatable {
    public var vertical: Bool
    public var position: Double
    public init(vertical: Bool, position: Double) { self.vertical = vertical; self.position = position }
}
