import Foundation
import ValseCore

/// Platform presets (local files only — nothing is uploaded): aspect, resolution, frame-rate cap and bit rate following
/// each platform's published upload recommendations.
public struct ExportPreset: Sendable, Identifiable, Hashable {
    public let id: String
    public let nameKey: String
    public let aspect: ExportSettings.Aspect
    public let resolution: ExportSettings.Resolution
    public let codec: ExportSettings.Codec
    /// nil = keep the project's frame rate (capped at `maxFPS`).
    public let maxFPS: Double
    /// Video Mbps at ≤ 30 fps; ×1.5 above.
    public let mbps: Double

    public func apply(to s: inout ExportSettings, projectRate: FrameRate) {
        s.aspect = aspect; s.resolution = resolution; s.codec = codec; s.container = .mp4
        s.alpha = false; s.bitDepth = .eight
        s.frameRate = projectRate.fps <= maxFPS + 0.01 ? projectRate : (ExportSettings.frameRates.last { $0.fps <= maxFPS + 0.01 } ?? .fps30)
        s.bitrateMode = .custom
        s.customBitrateMbps = s.frameRate.fps > 31 ? mbps * 1.5 : mbps
        s.includeAudio = true; s.audioBitrateKbps = 320
    }

    public static let all: [ExportPreset] = [
        ExportPreset(id: "youtube1080", nameKey: "export.preset.youtube1080", aspect: .landscape16x9, resolution: .p1080, codec: .h264, maxFPS: 60, mbps: 12),
        ExportPreset(id: "youtube4k", nameKey: "export.preset.youtube4k", aspect: .landscape16x9, resolution: .p2160, codec: .h264, maxFPS: 60, mbps: 45),
        ExportPreset(id: "youtubeShorts", nameKey: "export.preset.youtubeShorts", aspect: .portrait9x16, resolution: .p1080, codec: .h264, maxFPS: 60, mbps: 12),
        ExportPreset(id: "tiktok", nameKey: "export.preset.tiktok", aspect: .portrait9x16, resolution: .p1080, codec: .h264, maxFPS: 60, mbps: 10),
        ExportPreset(id: "instagramReels", nameKey: "export.preset.instagramReels", aspect: .portrait9x16, resolution: .p1080, codec: .h264, maxFPS: 30, mbps: 8),
        ExportPreset(id: "instagramSquare", nameKey: "export.preset.instagramSquare", aspect: .square1x1, resolution: .p1080, codec: .h264, maxFPS: 30, mbps: 8),
        ExportPreset(id: "instagramPortrait", nameKey: "export.preset.instagramPortrait", aspect: .portrait4x5, resolution: .p1080, codec: .h264, maxFPS: 30, mbps: 8),
    ]
    public static func preset(_ id: String) -> ExportPreset? { all.first { $0.id == id } }
}

/// EX-022 preflight: missing media and free disk space.
public struct ExportPreflight: Sendable, Equatable {
    public var missingMedia: [String] = []
    public var neededBytes: Int64 = 0
    public var freeBytes: Int64?
    public var hasEnoughSpace: Bool { freeBytes.map { $0 > neededBytes + 50_000_000 } ?? true }
    public var isOK: Bool { missingMedia.isEmpty && hasEnoughSpace }

    public static func check(_ p: Project, neededBytes: Int64, folder: URL) -> ExportPreflight {
        var r = ExportPreflight(neededBytes: neededBytes)
        var used = Set<MediaID>()
        for t in p.timeline.tracks { for c in t.clips { if let m = c.mediaID { used.insert(m) } } }
        for comp in p.compounds ?? [] { for t in comp.timeline.tracks { for c in t.clips { if let m = c.mediaID { used.insert(m) } } } }
        let fm = FileManager.default
        for a in p.media where used.contains(a.id) && !fm.fileExists(atPath: a.url.path) { r.missingMedia.append(a.name) }
        if let v = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage {
            r.freeBytes = v
        }
        return r
    }
}

/// One click on "Export": every checked output of the dialog (video, audio, GIF, captions) for one project snapshot.
public struct ExportJobSpec: Sendable {
    public enum OutputKind: String, Sendable { case video, audio, gif, captions, timeline }
    public struct Output: Sendable, Equatable {
        public var kind: OutputKind
        public var url: URL
    }

    public var project: Project
    public var title: String
    public var folder: URL
    /// nil = whole timeline.
    public var range: TimeRange?
    public var video: ExportSettings?
    public var audio: AudioOutputSettings?
    public var gif: GIFSettings?
    public var captions: CaptionExport.Format?
    public var timeline: TimelineInterchange.Format?
    public var coverTime: Time = .zero
    /// Cover image chosen by the user (JPEG/PNG data); nil = the frame at `coverTime`.
    public var coverImage: Data?
    public var embedCover = true

    public init(project: Project, title: String, folder: URL) {
        self.project = project; self.title = title; self.folder = folder
    }

    public var duration: Time {
        let full = TimeRange(start: .zero, duration: project.duration)
        return (range.flatMap { $0.intersection(full) } ?? full).duration
    }

    /// Output files, uniqued against existing files ("Name (1).mov") and against each other.
    public func plannedOutputs(fileManager fm: FileManager = .default) -> [Output] {
        var out: [Output] = []
        var taken = Set<String>()
        func unique(_ ext: String) -> URL {
            let base = Self.sanitized(title.isEmpty ? "Valse" : title)
            var n = 0
            while true {
                let name = n == 0 ? "\(base).\(ext)" : "\(base) (\(n)).\(ext)"
                let u = folder.appendingPathComponent(name)
                if !fm.fileExists(atPath: u.path) && !taken.contains(name.lowercased()) { taken.insert(name.lowercased()); return u }
                n += 1
            }
        }
        if let v = video { out.append(Output(kind: .video, url: unique(v.fileExtension))) }
        if let a = audio { out.append(Output(kind: .audio, url: unique(a.format.fileExtension))) }
        if gif != nil { out.append(Output(kind: .gif, url: unique("gif"))) }
        if let c = captions { out.append(Output(kind: .captions, url: unique(c.fileExtension))) }
        if let t = timeline { out.append(Output(kind: .timeline, url: unique(t.fileExtension))) }
        return out
    }

    /// "Export selected clips" without the other layers: only `clip` (and the clips linked to it) stay on the timeline.
    public static func isolating(_ clip: ClipID, in p: Project) -> Project {
        var p = p
        for i in p.timeline.tracks.indices {
            p.timeline.tracks[i].clips.removeAll { $0.id != clip && $0.linkedTo != clip }
            for j in p.timeline.tracks[i].clips.indices { p.timeline.tracks[i].clips[j].transitionOut = nil }
        }
        return p
    }

    static func sanitized(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let t = s.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Valse" : String(t.prefix(200))
    }

    public var estimatedBytes: Int64 {
        let d = duration, canvas = project.settings.canvasSize
        var b: Int64 = 0
        if let v = video { b += v.estimatedBytes(duration: d, canvas: canvas) }
        if let a = audio { b += a.estimatedBytes(duration: d) }
        if let g = gif { b += g.estimatedBytes(duration: d, canvas: canvas) }
        return b
    }

    /// Relative cost of each output for one overall progress value.
    func weight(_ k: OutputKind) -> Double {
        switch k { case .video: 1; case .audio: 0.15; case .gif: 0.5; case .captions, .timeline: 0.01 }
    }
}

public enum ExportRunner {
    /// Runs every output in order. `progress` is overall 0…1. Partially written files are deleted on failure/cancel.
    public static func run(_ spec: ExportJobSpec, outputs: [ExportJobSpec.Output]? = nil,
                           progress: (@Sendable (Double) -> Void)? = nil) async throws -> [URL] {
        guard spec.project.duration > .zero else { throw ExportError.emptyProject }
        let outs = outputs ?? spec.plannedOutputs()
        try? FileManager.default.createDirectory(at: spec.folder, withIntermediateDirectories: true)
        let total = max(outs.reduce(0) { $0 + spec.weight($1.kind) }, 0.0001)
        var done = 0.0
        var written: [URL] = []
        do {
            for o in outs {
                try Task.checkCancellation()
                let w = spec.weight(o.kind), base = done
                let report: @Sendable (Double) -> Void = { p in progress?(min(1, (base + p * w) / total)) }
                switch o.kind {
                case .video:
                    guard let v = spec.video else { continue }
                    var options = ExportOptions(title: spec.title, coverTime: spec.coverTime)
                    if spec.embedCover {
                        options.artworkJPEG = try? await coverJPEG(spec)
                    }
                    try await Exporter.export(project: spec.project, settings: v, to: o.url, range: spec.range, options: options, progress: report)
                case .audio:
                    guard let a = spec.audio else { continue }
                    try await AudioOnlyExporter.export(project: spec.project, settings: a, to: o.url, range: spec.range, progress: report)
                case .gif:
                    guard let g = spec.gif else { continue }
                    try await GIFExporter.export(project: spec.project, settings: g, to: o.url, range: spec.range, progress: report)
                case .captions:
                    guard let c = spec.captions else { continue }
                    try CaptionExport.write(spec.project, format: c, range: spec.range, to: o.url)
                case .timeline:
                    guard let t = spec.timeline else { continue }
                    try TimelineInterchange.write(spec.project, format: t, name: spec.title, to: o.url)
                }
                written.append(o.url)
                done += w
                progress?(min(1, done / total))
            }
        } catch {
            for u in written { try? FileManager.default.removeItem(at: u) }
            if error is CancellationError { throw ExportError.cancelled }
            throw error
        }
        return written
    }

    /// Cover as JPEG: the user's image (re-encoded) or the frame at `coverTime`.
    public static func coverJPEG(_ spec: ExportJobSpec) async throws -> Data {
        if let d = spec.coverImage { return d }
        return try await StillFrameExporter.coverJPEG(project: spec.project, at: spec.coverTime)
    }
}
