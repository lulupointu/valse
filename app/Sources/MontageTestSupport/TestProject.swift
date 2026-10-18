import CoreGraphics
import Foundation
import MontageCore
import MontageEngine

/// Fluent builder for engine/render tests. Small canvas by default (fast).
///
/// ```swift
/// var p = TestProject()
/// let id = try await p.addVideo(.solid(.red))
/// p[id].opacity = 0.5
/// let img = try await p.render(at: 0.5)
/// #expect(img[0.5, 0.5].isClose(to: RGBA(0.5, 0, 0)))
/// ```
public struct TestProject: Sendable {
    public var project: Project

    public init(canvas: Size2 = Size2(320, 180), frameRate: FrameRate = .fps30, background: RGBA = .black) {
        project = Project(name: "Test", settings: ProjectSettings(canvasSize: canvas, frameRate: frameRate, backgroundColor: background))
    }

    public subscript(_ id: ClipID) -> Clip {
        get { project.timeline.clip(id)! }
        set { project.timeline[clip: id] = newValue }
    }

    /// Imports a synthetic video and inserts it. Returns the clip id.
    @discardableResult
    public mutating func addVideo(_ pattern: SyntheticMedia.Pattern, seconds: Double = 2, size: CGSize = CGSize(width: 320, height: 180),
                                  audioHz: Double? = nil, at start: Time = .zero, target: InsertTarget = .automatic,
                                  duration: Time? = nil) async throws -> ClipID {
        let url = try await TestMedia.video(pattern, seconds: seconds, size: size, audioHz: audioHz)
        return try await addMedia(url, at: start, target: target, duration: duration)
    }

    @discardableResult
    public mutating func addImage(_ pattern: SyntheticMedia.Pattern, size: CGSize = CGSize(width: 320, height: 320),
                                  at start: Time = .zero, duration: Time = 2, target: InsertTarget = .automatic) async throws -> ClipID {
        try await addMedia(try TestMedia.image(pattern, size: size), at: start, target: target, duration: duration)
    }

    @discardableResult
    public mutating func addMedia(_ url: URL, at start: Time = .zero, target: InsertTarget = .automatic, duration: Time? = nil) async throws -> ClipID {
        var asset = try await MediaProbe.probe(url)
        if let existing = project.media.first(where: { $0.contentHash == asset.contentHash }) { asset = existing } else { project.media.append(asset) }
        var clip = TimelineOps.makeClip(for: asset, at: start)
        if let duration { clip.duration = duration }
        try TimelineOps.insert(clip, into: &project, target: target)
        return clip.id
    }

    @discardableResult
    public mutating func addText(_ string: String, at start: Time = .zero, duration: Time = 2,
                                 edit: (inout TextContent) -> Void = { _ in }) throws -> ClipID {
        var t = TextContent(string: string); edit(&t)
        let c = Clip(content: .text(t), start: start, duration: duration)
        try TimelineOps.insert(c, into: &project)
        return c.id
    }

    @discardableResult
    public mutating func addSolid(_ color: RGBA, at start: Time = .zero, duration: Time = 2, target: InsertTarget = .newTrack) throws -> ClipID {
        let c = Clip(content: .solid(color), start: start, duration: duration)
        try TimelineOps.insert(c, into: &project, target: target)
        return c.id
    }

    /// Adjustment clip (effect track) carrying `effects` over [start, start+duration).
    @discardableResult
    public mutating func addAdjustment(_ effects: [EffectInstance], at start: Time = .zero, duration: Time = 2) throws -> ClipID {
        var c = Clip(content: .adjustment, start: start, duration: duration)
        c.effects = effects
        try TimelineOps.insert(c, into: &project, target: .newTrack)
        return c.id
    }

    public var mainClips: [ClipID] { project.timeline.mainTrack?.clips.map(\.id) ?? [] }

    /// Renders one frame through the real compositor.
    public func render(at seconds: Double, size: CGSize? = nil) async throws -> Bitmap {
        Bitmap(try await OfflineRenderer.renderFrame(project, at: Time(seconds), size: size))
    }

    /// Exports and probes the result.
    public func export(seconds: Double? = nil, settings: ExportSettings = ExportSettings()) async throws -> ExportResult {
        try await exportProject(project, seconds: seconds, settings: settings)
    }
}

public struct ExportResult: Sendable {
    public let url: URL
    public let probe: MediaInfo
}

/// Exports `project` (optionally only the first `seconds`) to a temp file and probes it.
public func exportProject(_ project: Project, seconds: Double? = nil, settings: ExportSettings = ExportSettings()) async throws -> ExportResult {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("montage-export-\(UUID().uuidString).\(settings.codec.fileExtension)")
    let range = seconds.map { TimeRange(start: .zero, duration: Time($0)) }
    try await Exporter.export(project: project, settings: settings, to: url, range: range)
    return ExportResult(url: url, probe: try await MediaInfo.probe(url))
}

/// Renders one frame of any project.
public func renderFrame(_ project: Project, at seconds: Double, size: CGSize? = nil) async throws -> Bitmap {
    Bitmap(try await OfflineRenderer.renderFrame(project, at: Time(seconds), size: size))
}
