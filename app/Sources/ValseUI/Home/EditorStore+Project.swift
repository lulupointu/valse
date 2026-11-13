import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import ValseCore
import ValseEngine

/// Project-level flows of the editor (W12): version history, cover thumbnails for Home, closing back to Home,
/// pack project, preference sync, auto render.
extension EditorStore {
    // MARK: Autosave side effects

    /// Called after each successful autosave (off the hot path): periodic version snapshot, Home cover, auto render.
    func didAutosave(_ snapshot: Project, to url: URL) {
        let wantsCover = coverIsStale(url)
        Task.detached(priority: .utility) {
            if ProjectVersions.autoSnapshotDue(url) { _ = try? ProjectVersions.snapshot(snapshot, in: url, kind: .auto) }
            if wantsCover { await Self.writeCover(snapshot, to: url) }
        }
        if AppPreferences.shared.settings.autoRender && persistsPreferences { autoRenderHeavyRanges() }
        kickPreTranscription()   // PERF-CAPTIONS-2: the timeline changed, Auto captions prepared again in the background
    }

    private func coverIsStale(_ url: URL) -> Bool {
        let cover = url.appendingPathComponent(ProjectPackage.coverFileName)
        guard let d = (try? FileManager.default.attributesOfItem(atPath: cover.path))?[.modificationDate] as? Date else { return true }
        return Date().timeIntervalSince(d) > 120
    }

    /// Renders the Home card thumbnail (`cover.jpg`, 320 px high) from the frame at 10 % of the project (≤ 1 s).
    nonisolated static func writeCover(_ p: Project, to package: URL) async {
        let dst = package.appendingPathComponent(ProjectPackage.coverFileName)
        guard p.duration > .zero else { try? FileManager.default.removeItem(at: dst); return }
        let c = p.settings.canvasSize
        let h = 320.0, w = (h * c.width / max(c.height, 1) / 2).rounded() * 2
        let t = min(Time(1), Time(ticks: p.duration.ticks / 10))
        guard let img = try? await OfflineRenderer.renderFrame(p, at: t, size: CGSize(width: w, height: h), sdr: true),
              let d = CGImageDestinationCreateWithURL(dst as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(d, img, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(d)
    }

    // MARK: Closing

    /// Leaves the editor (Back to home / opening another project / quit): saves if needed, takes a "close" version,
    /// refreshes the cover and releases the session lock.
    /// `coverWait`: how long to wait for the Home cover (P1: switching projects doesn't wait for it; a cover render can
    /// stall on some iPhone clips, which used to block Back to home / switching forever). The cover finishes in the
    /// background either way; the "close" version snapshot is always written before returning.
    public func closeProject(coverWait: Duration = .seconds(3)) async {
        guard let url = packageURL else { close(); return }
        let snapshot = project
        close()
        await Task.detached(priority: .userInitiated) { _ = try? ProjectVersions.snapshot(snapshot, in: url, kind: .close) }.value
        let cover = Task.detached(priority: .userInitiated) { await Self.writeCover(snapshot, to: url) }
        guard coverWait > .zero else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce()
            Task.detached { await cover.value; if once.take() { c.resume() } }
            Task.detached { try? await Task.sleep(for: coverWait); if once.take() { c.resume() } }
        }
    }

    // MARK: Versions

    public var versions: [ProjectVersions.Version] { packageURL.map(ProjectVersions.list) ?? [] }

    /// "Save version" in the version history panel.
    public func saveVersionNow() {
        if packageURL == nil { save() }
        guard let url = packageURL else { return }
        let p = project
        Task {
            let ok = await Task.detached { (try? ProjectVersions.snapshot(p, in: url, kind: .manual)) != nil }.value
            showToast(tr(ok ? "version.saved" : "version.unchanged"))
        }
    }

    /// Goes back to a version, as one undoable step (the current state is also kept as a version).
    public func restoreVersion(_ v: ProjectVersions.Version) {
        guard let url = packageURL else { return }
        let current = project
        do {
            var old = try ProjectVersions.load(v)
            old.id = current.id
            _ = try? ProjectVersions.snapshot(current, in: url, kind: .beforeRestore)
            let restored = old
            if perform(Edit("cmd.restoreVersion") { p in p = restored }) {
                selection = []
                showToast(tr("version.restored", v.date.formatted(date: .abbreviated, time: .shortened)))
            }
        } catch {
            showToast(tr("error.unreadable"), error: true)
        }
    }

    // MARK: Missing media

    public var missingMedia: [MediaAsset] { MediaRelinker.missing(in: project) }

    // MARK: Pack project

    /// "Pack project" (archive / collect media): a self-contained copy of the project with every media file inside,
    /// as a `.valse` package, or a `.zip` of it, in `directory`.
    public func packProject(to directory: URL, zip: Bool) {
        let p = project, src = packageURL
        Task {
            let outcome = await PackProgress.shared.run(name: p.name) { report in
                try ProjectPacker.pack(p, from: src, into: directory, zip: zip, progress: report)
            }
            PackProgress.present(outcome, store: self)
        }
    }

    // MARK: Preferences

    /// The player menu changed quality / proxies: remember it in Settings ▸ Performance.
    func performancePreferencesChanged() {
        guard persistsPreferences else { return }
        AppPreferences.shared.noteEditorPerformance(quality: previewQuality, usesProxies: playerUI.usesProxies)
    }

    // MARK: Auto render (Settings ▸ Performance ▸ Auto render)

    func autoRenderHeavyRanges() {
        let p = project, size = engine.renderSize
        let ranges = RenderCache.heavyRanges(p)
        guard !ranges.isEmpty else { return }
        Task { for r in ranges { _ = await RenderCache.shared.request(p, range: r, size: size) } }
    }
}

extension EditorStore {
    /// Pre-rendered preview ranges for the timeline's green bar. Hashing the project per segment is too costly per frame:
    /// cached per edit revision and refreshed at most once a second (renders finish in the background).
    func renderedPreviewRanges() -> [TimeRange] {
        let rev = session.revision, now = Date()
        if let c = RenderBarCache.shared.value, c.revision == rev, c.projectID == project.id, now.timeIntervalSince(c.date) < 1 { return c.ranges }
        let ranges = RenderCache.shared.requestedRanges(project).isEmpty ? []
            : RenderCache.shared.validSegments(project, size: engine.renderSize).map(\.range)
        RenderBarCache.shared.value = (rev, project.id, now, ranges)
        return ranges
    }
}

@MainActor final class RenderBarCache {
    static let shared = RenderBarCache()
    var value: (revision: Int, projectID: ProjectID, date: Date, ranges: [TimeRange])?
}

nonisolated final class PackBox: @unchecked Sendable { var url: URL? }

/// First caller wins (a continuation resumed by whichever of two tasks finishes first).
nonisolated final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func take() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}

/// Builds a self-contained project copy (W12 "Pack project"). Off-main.
/// Progress (BUG-PACK-PROGRESS) is weighted by the real work, so it moves roughly linearly in time: the package copy
/// and the media copies count their bytes (an APFS clone only a small per-file cost), the zip counts the package bytes
/// times `zipCostPerByte` (deflating runs ~50 MB/s, far slower than a disk copy), and every phase reports byte-level
/// progress (chunked copies, the growing archive). Reports are throttled (≥ 0.5 % or 0.1 s) and monotonic.
nonisolated enum ProjectPacker {
    /// Relative cost of one zipped byte vs one streamed copied byte.
    static let zipCostPerByte: Int64 = 4
    static let packageJunk: Set<String> = [".session.lock", ProjectVersions.directoryName]

    /// `clone: false` never clones files (tests: byte-level copy progress on one volume).
    static func pack(_ project: Project, from package: URL?, into directory: URL, zip: Bool, clone: Bool = true,
                     progress: (@Sendable (Double) -> Void)? = nil) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = project.name.isEmpty ? (package?.deletingPathExtension().lastPathComponent ?? "Project") : project.name
        let staging = zip ? fm.temporaryDirectory.appendingPathComponent("valse-pack-\(UUID().uuidString)") : directory
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { if zip { try? fm.removeItem(at: staging) } }
        let dest = ProjectLibrary.uniquePackageURL(for: name, in: staging)
        var zipOut: URL?
        do {
            return try build(project, from: package, dest: dest, directory: directory, zip: zip, clone: clone,
                             zipOut: &zipOut, progress: progress)
        } catch {
            // cancelled or failed: no half-written package / archive is left behind
            try? fm.removeItem(at: dest)
            if let zipOut { try? fm.removeItem(at: zipOut) }
            throw error
        }
    }

    /// Work plan of a pack, in cost units (see `FileCopier.cost`).
    struct Plan { var packageCost: Int64, saveCost: Int64, mediaCost: Int64, zipCost: Int64
        var total: Int64 { max(packageCost + saveCost + mediaCost + zipCost, 1) }
        /// Fraction at which the zip phase starts.
        var zipStart: Double { Double(packageCost + saveCost + mediaCost) / Double(total) }
    }

    static func plan(_ project: Project, from package: URL?, dest: URL, zip: Bool, clone: Bool) -> Plan {
        let source = package.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        let pkgBytes = source.map { FileCopier.treeFiles($0, skip: packageJunk).reduce(Int64(0)) { $0 + $1.size } } ?? 0
        let pkgCost = source.map { FileCopier.treeCost($0, into: dest.deletingLastPathComponent(), skip: packageJunk, clone: clone) } ?? 0
        let media = MediaConsolidator.plannedCost(project, packageURL: dest,
                                                  existingIn: source?.appendingPathComponent("media", isDirectory: true), clone: clone)
        let zipCost = zip ? (pkgBytes + media.bytes + FileCopier.perFileCost) * zipCostPerByte : 0
        return Plan(packageCost: pkgCost, saveCost: 2 * FileCopier.perFileCost, mediaCost: media.cost, zipCost: zipCost)
    }

    private static func build(_ project: Project, from package: URL?, dest: URL, directory: URL, zip: Bool, clone: Bool,
                              zipOut: inout URL?, progress: (@Sendable (Double) -> Void)?) throws -> URL {
        let fm = FileManager.default
        let work = plan(project, from: package, dest: dest, zip: zip, clone: clone)
        let total = Double(work.total)
        let throttle = ProgressThrottle { progress?($0) }
        let report: @Sendable (Int64) -> Void = { throttle.report(Double($0) / total) }
        if let package, fm.fileExists(atPath: package.path) {
            try FileCopier.copyTree(at: package, to: dest, skip: packageJunk, clone: clone) { report(min($0, work.packageCost)) }
        }
        var done = work.packageCost
        report(done)
        var p = project
        try ProjectPackage.save(p, to: dest)
        done += FileCopier.perFileCost
        report(done)
        let mediaBase = done, mediaCost = Double(work.mediaCost)
        let map = try MediaConsolidator.consolidate(p, packageURL: dest, clone: clone) { report(mediaBase + Int64($0 * mediaCost)) }
        MediaRelinker.apply(map, to: &p)
        try ProjectPackage.save(p, to: dest)
        done = mediaBase + work.mediaCost + FileCopier.perFileCost
        report(done)
        guard zip else { throttle.report(1); return dest }
        let z = directory.appendingPathComponent(dest.deletingPathExtension().lastPathComponent).appendingPathExtension("zip")
        let out = fm.fileExists(atPath: z.path)
            ? directory.appendingPathComponent("\(dest.deletingPathExtension().lastPathComponent) \(Int(Date().timeIntervalSince1970))").appendingPathExtension("zip")
            : z
        try Task.checkCancellation()
        zipOut = out
        let bytes = FileCopier.treeFiles(dest).reduce(Int64(0)) { $0 + $1.size }
        let zipBase = done, zipCost = Double(work.zipCost)
        try ProjectArchive.zip(dest, to: out, expectedBytes: bytes) { report(zipBase + Int64($0 * zipCost)) }
        try Task.checkCancellation()
        throttle.report(1)
        return out
    }
}
