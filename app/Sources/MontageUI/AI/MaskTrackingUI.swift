import SwiftUI
import MontageCore
import MontageEngine
import MontageAI

// Video ▸ Mask / Adjust ▸ Mask ▸ Track mask (MK-003, CapCut "Track mask": forward / backward / both): Vision object
// tracking of the mask's box from the playhead, in the background (progress + cancel), then mask centre + size
// keyframes in one undo step ("Mask tracking complete").
enum MaskTrackingInspector {
    @MainActor static func applies(_ ctx: InspectorContext, _ t: MaskTarget) -> Bool {
        ctx.isMediaVideo && ctx.clip?[keyPath: t.mask] != nil
    }

    @MainActor static let sections: [InspectorSection] = [
        InspectorSection(id: "mask.track", tab: "video", subTab: "mask", order: 2, titleKey: "maskTrack.title",
                         appliesTo: { applies($0, .clip) }) { AnyView(MaskTrackingSection(ctx: $0, target: .clip, targetID: "clip")) },
        InspectorSection(id: "adjust.mask.track", tab: "adjust", subTab: "mask", order: 2, titleKey: "maskTrack.title",
                         appliesTo: { applies($0, .adjust) }) { AnyView(MaskTrackingSection(ctx: $0, target: .adjust, targetID: "adjust")) },
    ]
}

@MainActor @Observable final class MaskTrackUI {
    static let shared = MaskTrackUI()
    var direction: MaskTracking.Direction = .both
    /// Running job per clip + mask ("<clip>|clip" / "<clip>|adjust").
    var jobs: [String: JobID] = [:]
}

struct MaskTrackingSection: View {
    let ctx: InspectorContext
    let target: MaskTarget
    let targetID: String

    var body: some View {
        let ui = MaskTrackUI.shared
        let key = ctx.clip.map { "\($0.id)|\(targetID)" } ?? ""
        VStack(alignment: .leading, spacing: 6) {
            if let job = ui.jobs[key] {
                let p = ctx.store.jobs.first { $0.id == job }?.progress ?? 0
                JobProgressLine(text: tr("maskTrack.applying", Int(p * 100)), progress: p) { cancel(key) }
            }
            InlineRow(label: tr("maskTrack.direction")) {
                HStack(spacing: 8) {
                    Dropdown(items: MaskTracking.Direction.allCases.map { ($0, tr($0.nameKey)) }, selection: ui.direction) { ui.direction = $0 }
                    PillButton(title: tr("maskTrack.start"), symbol: "scope", accent: true, enabled: ui.jobs[key] == nil) { start(key) }
                        .testID("maskTrack.start.\(targetID)")
                }
            }
            HintText(text: tr("maskTrack.hint"))
        }
    }

    func cancel(_ key: String) {
        if let j = MaskTrackUI.shared.jobs[key] { MaskTrackUI.shared.jobs[key] = nil; Task { await JobQueue.shared.cancel(j) } }
    }

    func start(_ key: String) {
        guard let clip = ctx.clip else { return }
        let store = ctx.store
        let project = store.project
        let source = clip.sourceTime(at: store.transport.playhead.clamped(clip.start, clip.end - Time(ticks: 1)))
        let dir = MaskTrackUI.shared.direction
        let t = target.resolved(clip), id = clip.id
        let box = CommandBox()
        Task {
            let job = await JobQueue.shared.enqueue(titleKey: "maskTrack.job", priority: 1, subject: id.description) { progress in
                box.command = try await MaskTrackingJob.run(project: project, clipID: id, mask: t.mask, center: t.center, size: t.size,
                                                            from: source, direction: dir) { progress.report($0) }
            }
            MaskTrackUI.shared.jobs[key] = job
            let st = await JobQueue.shared.wait(job)
            if MaskTrackUI.shared.jobs[key] == job { MaskTrackUI.shared.jobs[key] = nil }
            switch st {
            case .done:
                if let cmd = box.command, store.perform(cmd) { store.showToast(tr("maskTrack.done")) }
            case .failed: store.showToast(tr("maskTrack.failed"), error: true)
            default: break
            }
        }
    }
}
