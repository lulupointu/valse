import SwiftUI
import MontageCore
import MontageEngine
import MontageAI

// Video ▸ Basic ▸ ☐ Camera tracking (UX_AI §4.8, AI-013): target Face / Body, ☐ Keep face size, canvas Fit / Blur.
// Ticking (or changing an option) runs the analysis in the background (progress on the clip); the result is the clip's
// position (+ scale) keyframes, one undo step. Excludes auto reframe.
enum CameraLockInspector {
    @MainActor static let sections: [InspectorSection] = [
        InspectorSection(id: "video.cameraLock", tab: "video", subTab: "basic", order: 44, titleKey: "cameraLock.title",
                         appliesTo: { $0.isMediaVideo }, chrome: { ctx in
            InspectorSectionChrome(isEnabled: Binding(get: {
                ctx.clip?.cameraLock != nil || ctx.clip.map { ctx.store.ai.cameraJobs[$0.id] != nil } ?? false
            }, set: { on in
                guard let id = ctx.clip?.id else { return }
                if on { ctx.store.cameraLock(id, options: CameraLockUIState.shared.options) } else { ctx.store.removeCameraLock(id) }
            }))
        }) { AnyView(CameraLockSection(ctx: $0)) },
    ]
}

@MainActor @Observable final class CameraLockUIState {
    static let shared = CameraLockUIState()
    var options = CameraLockOptions()
}

struct CameraLockSection: View {
    let ctx: InspectorContext
    var body: some View {
        let o = ctx.clip?.cameraLock ?? CameraLockUIState.shared.options
        VStack(alignment: .leading, spacing: 4) {
            if let id = ctx.clip?.id, let job = ctx.store.ai.cameraJobs[id] {
                let p = ctx.store.jobs.first { $0.id == job }?.progress ?? 0
                JobProgressLine(text: tr("cameraLock.applying", Int(p * 100)), progress: p) { ctx.store.removeCameraLock(id) }
            }
            InlineRow(label: tr("cameraLock.target")) {
                Dropdown(items: CameraLockOptions.Target.allCases.map { ($0, tr($0.nameKey)) }, selection: o.target) { v in update { $0.target = v } }
            }
            ToggleLine(label: tr(o.target == .face ? "cameraLock.keepFace" : "cameraLock.keepBody"),
                       isOn: Binding(get: { o.keepSize }, set: { v in update { $0.keepSize = v } }))
            InlineRow(label: tr("cameraLock.fill")) {
                Dropdown(items: CameraLockOptions.Fill.allCases.map { ($0, tr($0.nameKey)) }, selection: o.fill) { v in update { $0.fill = v } }
            }
            HintText(text: tr("cameraLock.hint"))
        }
    }

    func update(_ body: (inout CameraLockOptions) -> Void) {
        var o = ctx.clip?.cameraLock ?? CameraLockUIState.shared.options
        body(&o)
        CameraLockUIState.shared.options = o
        if let id = ctx.clip?.id, ctx.clip?.cameraLock != nil { ctx.store.cameraLock(id, options: o) }
    }
}

extension EditorStore {
    public func cameraLock(_ clipID: ClipID, options: CameraLockOptions) {
        if let j = ai.cameraJobs[clipID] { Task { await JobQueue.shared.cancel(j) } }
        let project = self.project
        let box = CommandBox()
        Task {
            let id = await JobQueue.shared.enqueue(titleKey: "cameraLock.job", priority: 1, subject: clipID.description) { progress in
                box.command = try await CameraLockJob.run(project: project, clipID: clipID, options: options) { progress.report($0) }
            }
            ai.cameraJobs[clipID] = id
            let st = await JobQueue.shared.wait(id)
            if ai.cameraJobs[clipID] == id { ai.cameraJobs[clipID] = nil }
            switch st {
            case .done: if let cmd = box.command, perform(cmd) { showToast(tr("cameraLock.done")) }
            case .failed: showToast(tr("cameraLock.failed"), error: true)
            case .cancelled: showToast(tr("cameraLock.cancelled"))
            default: break
            }
        }
    }

    public func removeCameraLock(_ clipID: ClipID) {
        if let j = ai.cameraJobs[clipID] { ai.cameraJobs[clipID] = nil; Task { await JobQueue.shared.cancel(j) } }
        guard project.timeline.clip(clipID)?.cameraLock != nil else { return }
        perform(UpdateClip(clipID, nameKey: "cmd.cameraLock") { CameraLock.remove(&$0) })
    }
}
