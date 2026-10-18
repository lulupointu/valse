import SwiftUI
import AppKit
import Observation
import UniformTypeIdentifiers
import MontageCore
import MontageEngine

/// Export state owned by the store: the background queue and the scope the next dialog opens with.
@Observable
public final class ExportCenter {
    public let queue = ExportQueue()
    /// Set by "Export selected clips" / "Export in/out range" before presenting the dialog.
    public var requestedScope: ExportScope?
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
        isExportSheetPresented = true
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
