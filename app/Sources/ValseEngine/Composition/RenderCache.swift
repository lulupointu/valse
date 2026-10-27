@preconcurrency import AVFoundation
import CryptoKit
import Foundation
import ValseCore

/// Preview render cache for heavy segments (CapCut "Render" / green bar, PB-005).
///
/// A requested timeline range is rendered in the background by the real exporter (same compositor ⇒ same pixels) to an
/// intra-frame ProRes 422 file at preview resolution: `~/Library/Caches/Valse/render/<key>.mov`. The key is a
/// SHA-256 of everything that can change those frames (project settings, every clip intersecting the range incl. its
/// placement, the media content hashes it uses, the range itself), so any edit simply makes the segment invalid —
/// no explicit invalidation. Preview builds (`CompositionBuilder`, purpose `.preview`) add each VALID ready segment as a
/// passthrough lane; `RenderState` re-validates on every project update (cheap, edits only), and the compositor serves
/// cached frames only for valid segments, otherwise it composes live. Export never uses the cache.
public final class RenderCache: @unchecked Sendable {
    public static let shared = RenderCache()

    public let directory: URL
    private let lock = NSLock()
    /// Ranges the user (or the auto policy) asked to keep rendered, per project.
    private var requested: [ProjectID: [TimeRange]] = [:]
    private var pending: [String: JobID] = [:]
    /// Main actor: a segment finished rendering (key).
    @MainActor public var onReady: ((String) -> Void)?

    init() {
        directory = ValsePaths.cacheDirectory.appendingPathComponent("render", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func url(_ key: String) -> URL { directory.appendingPathComponent("\(key).mov") }

    private struct KeyInput: Encodable {
        let settings: ProjectSettings
        let start: Time, end: Time
        let tracks: [[Clip]]
        let trackFlags: [String]
        let media: [String]
        let compounds: [CompoundClip]?
    }

    /// Content key of the frames of `range`.
    public static func key(_ project: Project, range: TimeRange, size: CGSize) -> String {
        var tracks: [[Clip]] = [], flags: [String] = [], media = Set<String>()
        for t in project.timeline.tracks where t.kind.isVisual {
            let clips = t.clips.filter { $0.range.overlaps(range) || ($0.transitionOut != nil && $0.end >= range.start) }
            guard !clips.isEmpty else { continue }
            tracks.append(clips); flags.append("\(t.kind.rawValue)-\(t.isHidden)-\(t.isMain)")
            for c in clips { if let id = c.mediaID, let a = project.asset(id) { media.insert(a.contentHash) } }
        }
        let input = KeyInput(settings: project.settings, start: range.start, end: range.end, tracks: tracks, trackFlags: flags,
                             media: media.sorted() + ["\(Int(size.width))x\(Int(size.height))"],
                             compounds: tracks.joined().contains { if case .compound = $0.content { return true }; return false } ? project.compounds : nil)
        let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys
        let data = (try? enc.encode(input)) ?? Data()
        return SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    public func requestedRanges(_ project: Project) -> [TimeRange] { lock.withLock { requested[project.id] ?? [] } }

    public func isPending(_ key: String) -> Bool { lock.withLock { pending[key] != nil } }

    /// Ready, still-valid cached segments for a preview of `size`.
    public func validSegments(_ project: Project, size: CGSize) -> [(range: TimeRange, url: URL, key: String)] {
        requestedRanges(project).compactMap { r in
            let k = Self.key(project, range: r, size: size)
            let u = url(k)
            return FileManager.default.fileExists(atPath: u.path) ? (r, u, k) : nil
        }
    }

    /// Asks for `range` (clamped to the project) to be pre-rendered at preview `size`. Idempotent; returns the job.
    @discardableResult
    public func request(_ project: Project, range: TimeRange, size: CGSize) async -> JobID? {
        guard let r = range.intersection(TimeRange(start: .zero, duration: project.duration)), r.duration > .zero else { return nil }
        lock.withLock {
            var list = requested[project.id] ?? []
            list.removeAll { $0.overlaps(r) }
            list.append(r)
            requested[project.id] = list.sorted { $0.start < $1.start }
        }
        let k = Self.key(project, range: r, size: size)
        if FileManager.default.fileExists(atPath: url(k).path) { return nil }
        if let j = lock.withLock({ pending[k] }) { return j }
        let dst = url(k)
        var settings = ExportSettings()
        settings.codec = .proRes422
        settings.includeAudio = false
        settings.frameRate = project.settings.frameRate
        let short = Int(min(size.width, size.height))
        settings.resolution = ExportSettings.Resolution.allCases.min { abs($0.rawValue - short) < abs($1.rawValue - short) } ?? .p720
        let snapshot = project, exportSettings = settings
        let id = await JobQueue.shared.enqueue(titleKey: "job.renderCache", detail: project.name, priority: -2, subject: "render-\(k)") { progress in
            let tmp = dst.deletingLastPathComponent().appendingPathComponent("tmp-\(UUID().uuidString).mov")
            try await Exporter.export(project: snapshot, settings: exportSettings, to: tmp, range: r) { progress.report($0) }
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.moveItem(at: tmp, to: dst)
        }
        lock.withLock { pending[k] = id }
        Task {
            let state = await JobQueue.shared.wait(id)
            self.lock.withLock { self.pending[k] = nil }
            if state == .done { await MainActor.run { self.onReady?(k) } }
        }
        return id
    }

    /// Forgets the requested ranges of a project (e.g. "Delete render cache").
    public func clear(_ project: Project) { lock.withLock { requested[project.id] = nil } }

    public func deleteAll() {
        lock.withLock { requested.removeAll() }
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Ranges worth pre-rendering automatically: where ≥ `minLayers` video layers (incl. aux decode lanes) overlap or a
    /// layer uses motion blur / smooth slow-mo. Merged, frame-aligned.
    public static func heavyRanges(_ project: Project, minLayers: Int = 4) -> [TimeRange] {
        let s = DecoderBudget.streams(project)
        var events: [(Time, Int)] = []
        for x in s {
            let heavy = x.lanes > 1 ? minLayers : x.lanes
            events.append((x.range.start, heavy)); events.append((x.range.end, -heavy))
        }
        events.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        var out: [TimeRange] = [], cur = 0, open: Time?
        for e in events {
            cur += e.1
            if cur >= minLayers, open == nil { open = e.0 }
            if cur < minLayers, let o = open { if e.0 > o { out.append(TimeRange(start: o, end: e.0)) }; open = nil }
        }
        return out
    }
}
