import Foundation

public typealias MediaFolderID = Identifier<MediaFolder>

/// A folder of the project media bin (CapCut Media panel folders, max depth 10).
/// Folders form a tree through `parentID` (nil = bin root). Media items point at their folder with `MediaAsset.folderID`.
public struct MediaFolder: Codable, Sendable, Equatable, Identifiable {
    public var id: MediaFolderID
    public var name: String
    public var parentID: MediaFolderID?
    public init(id: MediaFolderID = MediaFolderID(), name: String, parentID: MediaFolderID? = nil) {
        self.id = id; self.name = name; self.parentID = parentID
    }
}

/// How a media file becomes playable when AVFoundation cannot read it directly. The engine converts it once in the
/// background (`PlayableMediaCache`) into a cached mezzanine keyed by `contentHash`.
public enum MediaConversion: String, Codable, Sendable {
    /// Animated GIF / APNG / animated WebP / HEICS (ImageIO frames).
    case animatedImage
    /// Numbered still images (`name0001.png` …) imported as one clip, see `MediaAsset.sequence`.
    case imageSequence
    /// Container/codec AVFoundation can't open (MKV, WebM, AVI, VP9, AV1, MPEG-2…): transcoded by the FFmpeg sidecar.
    case ffmpeg
}

/// Numbered image sequence: frames are `<prefix><index padded to digits>.<ext>` in the folder of `MediaAsset.url`.
public struct ImageSequenceInfo: Codable, Sendable, Equatable, Hashable {
    public var prefix: String
    public var digits: Int
    public var firstIndex: Int
    public var count: Int
    public var ext: String
    public init(prefix: String, digits: Int, firstIndex: Int, count: Int, ext: String) {
        self.prefix = prefix; self.digits = digits; self.firstIndex = firstIndex; self.count = count; self.ext = ext
    }
    /// File name of frame `i` (0-based).
    public func fileName(_ i: Int) -> String {
        let n = String(firstIndex + i)
        return prefix + String(repeating: "0", count: max(0, digits - n.count)) + n + "." + ext
    }
}

/// Extra technical metadata shown in "Material info" (MI-005). All optional: probed when available.
public struct MediaTechInfo: Codable, Sendable, Equatable, Hashable {
    public var bitrate: Int64?
    public var audioCodec: String?
    public var audioSampleRate: Double?
    public var audioChannels: Int?
    /// Number of audio streams (MI-014). Clips choose one with `Clip.audioStreamIndex`.
    public var audioTrackCount: Int?
    public var hasAlpha: Bool?
    /// Variable frame rate (phone footage): min/max frame duration differ.
    public var isVariableFrameRate: Bool?
    public var colorPrimaries: String?
    public var transferFunction: String?
    public var container: String?
    public init() {}
}

extension Project {
    /// Bin folders (stored optionally so older project files decode unchanged).
    public var folders: [MediaFolder] {
        get { mediaFolders ?? [] }
        set { mediaFolders = newValue.isEmpty ? nil : newValue }
    }
}
