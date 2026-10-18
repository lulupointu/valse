import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import MontageCore
import MontageEngine

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
        guard let img = try? await OfflineRenderer.renderFrame(p, at: t, size: CGSize(width: w, height: h)),
              let d = CGImageDestinationCreateWithURL(dst as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(d, img, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(d)
    }

    // MARK: Closing

    /// Leaves the editor (Back to home / opening another project / quit): saves if needed, takes a "close" version,
    /// refreshes the cover and releases the session lock.
    public func closeProject() async {
        guard let url = packageURL else { close(); return }
        let snapshot = project
        close()
        await Task.detached(priority: .userInitiated) {
            _ = try? ProjectVersions.snapshot(snapshot, in: url, kind: .close)
            await Self.writeCover(snapshot, to: url)
        }.value
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
    /// as a `.montage` package, or a `.zip` of it, in `directory`.
    public func packProject(to directory: URL, zip: Bool) {
        let p = project, src = packageURL
        Task {
            let box = PackBox()
            let id = await JobQueue.shared.enqueue(titleKey: "job.pack", priority: 1) { progress in
                box.url = try ProjectPacker.pack(p, from: src, into: directory, zip: zip) { progress.report($0) }
            }
            if await JobQueue.shared.wait(id) == .done, let u = box.url {
                showToast(tr("toast.packed", u.lastPathComponent))
                NSWorkspace.shared.activateFileViewerSelecting([u])
            } else {
                showToast(tr("toast.packFailed"), error: true)
            }
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

nonisolated final class PackBox: @unchecked Sendable { var url: URL? }

/// Builds a self-contained project copy (W12 "Pack project"). Off-main.
nonisolated enum ProjectPacker {
    static func pack(_ project: Project, from package: URL?, into directory: URL, zip: Bool,
                     progress: (@Sendable (Double) -> Void)? = nil) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = project.name.isEmpty ? (package?.deletingPathExtension().lastPathComponent ?? "Project") : project.name
        let staging = zip ? fm.temporaryDirectory.appendingPathComponent("montage-pack-\(UUID().uuidString)") : directory
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { if zip { try? fm.removeItem(at: staging) } }
        let dest = ProjectLibrary.uniquePackageURL(for: name, in: staging)
        if let package, fm.fileExists(atPath: package.path) {
            try fm.copyItem(at: package, to: dest)
            for junk in [".session.lock", ProjectVersions.directoryName] { try? fm.removeItem(at: dest.appendingPathComponent(junk)) }
        }
        var p = project
        try ProjectPackage.save(p, to: dest)
        let map = try MediaConsolidator.consolidate(p, packageURL: dest) { progress?($0 * 0.9) }
        MediaRelinker.apply(map, to: &p)
        try ProjectPackage.save(p, to: dest)
        guard zip else { progress?(1); return dest }
        let z = directory.appendingPathComponent(dest.deletingPathExtension().lastPathComponent).appendingPathExtension("zip")
        let out = fm.fileExists(atPath: z.path)
            ? directory.appendingPathComponent("\(dest.deletingPathExtension().lastPathComponent) \(Int(Date().timeIntervalSince1970))").appendingPathExtension("zip")
            : z
        try ProjectArchive.zip(dest, to: out)
        progress?(1)
        return out
    }
}
