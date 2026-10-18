import SwiftUI
import Observation
import AppKit
import MontageCore
import MontageEngine

/// What the export dialog exports (TL-028 / EX-013 / EX-014).
public enum ExportScope: String, Codable, Sendable, CaseIterable {
    case project, inOut, selectedClips
    public var nameKey: String { "export.scope.\(rawValue)" }
}

/// Export dialog state (CapCut "Export" window, UX.md §7.1). The last choices are remembered per user.
@Observable
public final class ExportDialogModel {
    /// Persisted part (UserDefaults JSON).
    public struct Remembered: Codable, Equatable {
        public var video = ExportSettings()
        public var audio = AudioOutputSettings()
        public var gif = GIFSettings()
        public var videoEnabled = true
        public var audioEnabled = false
        public var gifEnabled = false
        public var captionsEnabled = false
        public var captionFormat: CaptionExport.Format = .srt
        public var folderPath: String?
        public var presetID: String?
        public init() {}
        enum CodingKeys: String, CodingKey { case video, audio, gif, videoEnabled, audioEnabled, gifEnabled, captionsEnabled, captionFormat, folderPath, presetID }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Remembered()
            video = (try? c.decodeIfPresent(ExportSettings.self, forKey: .video)) ?? d.video
            audio = (try? c.decodeIfPresent(AudioOutputSettings.self, forKey: .audio)) ?? d.audio
            gif = (try? c.decodeIfPresent(GIFSettings.self, forKey: .gif)) ?? d.gif
            videoEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .videoEnabled)) ?? true
            audioEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .audioEnabled)) ?? false
            gifEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .gifEnabled)) ?? false
            captionsEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .captionsEnabled)) ?? false
            captionFormat = (try? c.decodeIfPresent(CaptionExport.Format.self, forKey: .captionFormat)) ?? .srt
            folderPath = try? c.decodeIfPresent(String.self, forKey: .folderPath)
            presetID = try? c.decodeIfPresent(String.self, forKey: .presetID)
        }
    }

    public static let defaultsKey = "montage.export.dialog.v1"
    /// Settings ▸ Performance "Speed up hardware encoding" (UI owned by W12). Default on.
    public static let hardwareDefaultsKey = "montage.export.hardwareEncoding"

    public var remembered: Remembered
    public var title: String
    public var folder: URL
    public var scope: ExportScope = .project
    /// "Export selected clips": include every layer during each clip (CapCut "Include all changes when exporting").
    public var includeAllLayers = true
    public var coverTime: Time = .zero
    public var coverImage: Data?
    public var coverPreview: NSImage?
    public var mp3Available = true
    /// UI: collapsed sections.
    public var expanded: Set<String> = ["video", "audio", "gif", "captions"]

    public let project: Project
    public let selectedClipIDs: [ClipID]

    public init(project: Project, title: String, selection: Set<ClipID>, scope: ExportScope? = nil,
                defaults: UserDefaults = .standard) {
        self.project = project
        self.title = title
        var r = (defaults.data(forKey: Self.defaultsKey)).flatMap { try? JSONDecoder().decode(Remembered.self, from: $0) } ?? Remembered()
        if defaults.object(forKey: Self.hardwareDefaultsKey) != nil { r.video.preferHardware = defaults.bool(forKey: Self.hardwareDefaultsKey) }
        if defaults.data(forKey: Self.defaultsKey) == nil {
            // first export: CapCut defaults, frame rate from the project, resolution ≤ canvas
            r.video.frameRate = ExportSettings.frameRates.min { abs($0.fps - project.settings.frameRate.fps) < abs($1.fps - project.settings.frameRate.fps) } ?? .fps30
            let short = min(project.settings.canvasSize.width, project.settings.canvasSize.height)
            r.video.resolution = ExportSettings.Resolution.allCases.last { Double($0.rawValue) <= short + 1 } ?? .p1080
        }
        remembered = r
        folder = r.folderPath.map { URL(fileURLWithPath: $0) }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? Self.defaultFolder
        let tl = project.timeline
        selectedClipIDs = tl.tracks.flatMap(\.clips).filter { selection.contains($0.id) }.sorted { $0.start < $1.start }.map(\.id)
        if let scope, isAvailable(scope) { self.scope = scope }
        coverTime = .zero
    }

    /// ~/Movies (CapCut: ~/Movies/CapCut).
    public static var defaultFolder: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser
    }

    public func save(defaults: UserDefaults = .standard) {
        var r = remembered
        r.folderPath = folder.path
        if let d = try? JSONEncoder().encode(r) { defaults.set(d, forKey: Self.defaultsKey) }
    }

    // MARK: Derived

    public var inOutRange: TimeRange? {
        let tl = project.timeline
        guard tl.inPoint != nil || tl.outPoint != nil else { return nil }
        let a = tl.inPoint ?? .zero, b = tl.outPoint ?? project.duration
        return b > a ? TimeRange(start: a, duration: b - a) : nil
    }

    public func isAvailable(_ s: ExportScope) -> Bool {
        switch s {
        case .project: return true
        case .inOut: return inOutRange != nil
        case .selectedClips: return !selectedClipIDs.isEmpty
        }
    }

    public var hasCaptions: Bool { CaptionExport.hasCaptions(project) }
    public var colorSpace: ProjectColorSpace { project.settings.colorSpace }

    /// Duration of the export (one clip's duration ×N for selected clips: the sum).
    public var duration: Time {
        switch scope {
        case .project: return project.duration
        case .inOut: return inOutRange?.duration ?? project.duration
        case .selectedClips:
            return selectedClipIDs.compactMap { project.timeline.clip($0)?.duration }.reduce(.zero, +)
        }
    }

    public var anyOutput: Bool {
        remembered.videoEnabled || remembered.audioEnabled || remembered.gifEnabled || (remembered.captionsEnabled && hasCaptions)
    }

    public var audioFormatUsable: Bool { remembered.audio.format != .mp3 || mp3Available }

    public var canExport: Bool { anyOutput && project.duration > .zero && audioFormatUsable && preflight.isOK }

    public var estimatedBytes: Int64 { specs().reduce(0) { $0 + $1.estimatedBytes } }

    public var preflight: ExportPreflight { ExportPreflight.check(project, neededBytes: estimatedBytes, folder: folder) }

    /// "Duration: 48s | Size: 72 MB (estimated)"
    public var footerText: String {
        tr("export.footer", Self.durationString(duration), ByteCountFormatter.string(fromByteCount: estimatedBytes, countStyle: .file))
    }

    static func durationString(_ t: Time) -> String {
        let s = Int(t.seconds.rounded())
        if s < 60 { return tr("export.duration.s", s) }
        if s < 3600 { return tr("export.duration.ms", s / 60, s % 60) }
        return tr("export.duration.hms", s / 3600, (s / 60) % 60, s % 60)
    }

    // MARK: Presets

    public func applyPreset(_ id: String?) {
        remembered.presetID = id
        guard let id, let p = ExportPreset.preset(id) else { remembered.video.aspect = .original; return }
        p.apply(to: &remembered.video, projectRate: project.settings.frameRate)
        remembered.videoEnabled = true
    }

    /// Any manual change of a preset-controlled field drops back to "Custom".
    public func editVideo(_ body: (inout ExportSettings) -> Void) {
        let before = remembered.video
        body(&remembered.video)
        if remembered.presetID != nil, remembered.video.resolution != before.resolution || remembered.video.codec != before.codec
            || remembered.video.bitrateMode != before.bitrateMode || remembered.video.customBitrateMbps != before.customBitrateMbps
            || remembered.video.frameRate != before.frameRate || remembered.video.container != before.container {
            remembered.presetID = nil
        }
        if !remembered.video.codec.supportsAlpha { remembered.video.alpha = false }
    }

    // MARK: Jobs

    /// One spec per output file set: the whole project / in-out range, or one per selected clip.
    public func specs() -> [ExportJobSpec] {
        func base(_ p: Project, title: String, range: TimeRange?) -> ExportJobSpec {
            var s = ExportJobSpec(project: p, title: title, folder: folder)
            s.range = range
            if remembered.videoEnabled { s.video = remembered.video }
            if remembered.audioEnabled { s.audio = remembered.audio }
            if remembered.gifEnabled { s.gif = remembered.gif }
            if remembered.captionsEnabled && CaptionExport.hasCaptions(p) { s.captions = remembered.captionFormat }
            s.coverImage = coverImage
            s.coverTime = coverTime
            return s
        }
        switch scope {
        case .project: return [base(project, title: title, range: nil)]
        case .inOut: return [base(project, title: title, range: inOutRange)]
        case .selectedClips:
            return selectedClipIDs.enumerated().compactMap { i, id in
                guard let c = project.timeline.clip(id) else { return nil }
                let p = includeAllLayers ? project : ExportJobSpec.isolating(id, in: project)
                var s = base(p, title: selectedClipIDs.count == 1 ? title : "\(title) \(i + 1)", range: c.range)
                s.coverTime = c.start
                return s
            }
        }
    }

    /// Cover thumbnail for the dialog (async, off-main render).
    public func refreshCover() async {
        if let d = coverImage, let img = NSImage(data: d) { coverPreview = img; return }
        let p = project, t = coverTime
        guard p.duration > .zero else { return }
        let img = try? await Task.detached { try await StillFrameExporter.image(project: p, at: t, shortSide: 360) }.value
        if let img { coverPreview = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height)) }
    }
}
