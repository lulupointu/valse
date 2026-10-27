import Foundation
import ValseCore
import ValseEngine

/// Preview render cache ("Render ▸ …", PB-005): pre-renders a range in the background; the preview plays the
/// rendered frames while they are still valid (any edit in the range falls back to live compositing).
extension EditorStore {
    public func renderPreview(range: TimeRange?) {
        let r = range ?? TimeRange(start: .zero, duration: project.duration)
        let p = project, size = engine.renderSize
        Task {
            if let job = await RenderCache.shared.request(p, range: r, size: size) {
                showToast(tr("toast.renderStarted"))
                if await JobQueue.shared.wait(job) == .done { showToast(tr("toast.renderDone")) }
            } else {
                showToast(tr("toast.renderDone"))
            }
        }
    }

    public func clearRenderCache() {
        RenderCache.shared.clear(project)
        engine.forceRebuild()
    }
}
