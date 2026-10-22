import SwiftUI
import AppKit
import Perception
import UniformTypeIdentifiers
import AVFoundation
import MontageCore
import MontageEngine

/// Export state owned by the store: the background queue and the scope the next dialog opens with.
@Perceptible
public final class ExportCenter {
    public let queue = ExportQueue()
    /// Set by "Export selected clips" / "Export in/out range" before presenting the dialog.
    public var requestedScope: ExportScope?
    /// The open dialog's state (nil when closed) and the jobs its progress view shows.
    public var dialog: ExportDialogModel?
    public var shownJobs: [ExportJobItem] = []
    /// The finished export's preview player (ExportProgressView), loaded paused (OB-06); `ui.export.preview` in tests.
    @PerceptionIgnored public weak var previewPlayer: AVPlayer?
    public init() {}
}

extension EditorStore {
    func installExportHooks() {
        exports.queue.onFinish = { [weak self] item in
            guard let self else { return }
            switch item.state {
            case .done: self.showToast(tr("export.toast.done", item.primaryURL?.lastPathComponent ?? item.title))
            case .failed(let m): self.showToast(m, error: true)
            default: break
            }
        }
    }

    /// ⌘E / title-bar Export, optionally pre-selecting a scope (range, selected clips).
    public func openExport(scope: ExportScope? = nil) {
        guard project.duration > .zero else { showToast(tr("export.error.empty"), error: true); return }
        exports.requestedScope = scope
        exports.dialog = ExportDialogModel(project: rootProject, title: projectName, selection: selection, scope: scope)
        exports.shownJobs = []
        isExportSheetPresented = true
    }

    public func closeExportDialog() {
        isExportSheetPresented = false
        exports.requestedScope = nil
        exports.dialog = nil
        exports.shownJobs = []
    }

    /// Dialog "Export": saves the choices and queues one job per output set.
    public func confirmExport() {
        guard let m = exports.dialog, m.canExport else { return }
        m.save()
        exports.shownJobs = m.specs().map { exports.queue.enqueue($0) }
    }

    /// Timeline ▸ "Export selected clips" (EX-013): one file per selected clip.
    public func exportSelectedClips() {
        guard !selection.isEmpty else { return }
        openExport(scope: .selectedClips)
    }

    /// Timeline ▸ Range ▸ "Export in/out range" (TL-028 / EX-014).
    public func exportInOutRange() {
        guard project.timeline.inPoint != nil || project.timeline.outPoint != nil else { return }
        openExport(scope: .inOut)
    }

    /// File ▸ Export timeline (EX-020): FCPXML / EDL / OTIO next to the media, chosen with a save panel.
    public func exportTimeline(_ format: TimelineInterchange.Format) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .xml]
        panel.nameFieldStringValue = "\(projectName).\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let p = project, name = projectName
        Task {
            do {
                try await Task.detached { try TimelineInterchange.write(p, format: format, name: name, to: url) }.value
                showToast(tr("export.toast.timeline", url.lastPathComponent))
            } catch {
                showToast(tr("export.error.failed"), error: true)
            }
        }
    }

    /// Queues a job directly (tests, scripted exports).
    @discardableResult
    public func enqueueExport(_ spec: ExportJobSpec) -> ExportJobItem { exports.queue.enqueue(spec) }
}

/// `ui.export` in the UI-test state dump: dialog choices and queue jobs.
@MainActor
enum ExportStateDump {
    static func make(_ c: ExportCenter) -> [String: Any] {
        var d: [String: Any] = [:]
        if let m = c.dialog {
            let r = m.remembered
            d["dialog"] = [
                "title": m.title, "folder": m.folder.path, "scope": m.scope.rawValue, "duration": m.duration.seconds,
                "video": r.videoEnabled, "audio": r.audioEnabled, "gif": r.gifEnabled, "captions": r.captionsEnabled,
                "codec": r.video.codec.rawValue, "resolution": r.video.resolution.rawValue, "fps": r.video.frameRate.fps,
                "container": r.video.effectiveContainer.rawValue, "audioFormat": r.audio.format.rawValue,
                "gifResolution": r.gif.resolution.rawValue, "estimatedBytes": m.estimatedBytes, "canExport": m.canExport,
                "footer": m.footerText, "motionBlur": r.video.motionBlur.rawValue, "aiUltraHD": r.video.aiUltraHD, "burnCaptionsRow": m.hasBurnableCaptions, "coverReady": m.coverPreview != nil,
                "outputs": m.specs().flatMap { $0.plannedOutputs().map(\.url.lastPathComponent) },
            ] as [String: Any]
        }
        func job(_ j: ExportJobItem) -> [String: Any] {
            let state: String
            switch j.state { case .queued: state = "queued"; case .running: state = "running"; case .done: state = "done"
            case .failed: state = "failed"; case .cancelled: state = "cancelled" }
            return ["title": j.title, "state": state, "progress": j.progress, "written": j.written.map(\.path),
                    "outputs": j.outputs.map(\.url.lastPathComponent)]
        }
        d["jobs"] = c.queue.items.map(job)
        d["shown"] = c.shownJobs.map(job)
        if let p = c.previewPlayer {   // OB-06: never auto-plays
            d["preview"] = ["loaded": true, "playing": p.rate != 0 || p.timeControlStatus != .paused]
        }
        return d
    }
}
