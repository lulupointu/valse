import SwiftUI
import MontageCore
import MontageEngine
import MontageAI

// Video ▸ Basic ▸ ☐ Face mosaic (AI-051): detects and follows faces in the background, then covers them with Mosaic
// or Blur (a linked copy of the clip with a faces matte one track above). One undo step; unticking removes it.
enum FaceCoverInspector {
    @MainActor static let sections: [InspectorSection] = [
        InspectorSection(id: "video.faceCover", tab: "video", subTab: "basic", order: 49, titleKey: "faceCover.title",
                         appliesTo: { ctx in (ctx.isMediaVideo || ctx.asset?.kind == .image) && ctx.clip?.matte?.kind != CutoutMode.faces.kind },
                         chrome: { ctx in
            InspectorSectionChrome(isEnabled: Binding(get: {
                guard let c = ctx.clip else { return false }
                return FaceCover.cover(of: c.id, in: ctx.store.project.timeline) != nil || ctx.store.ai.faceJobs[c.id] != nil
            }, set: { on in
                guard let id = ctx.clip?.id else { return }
                if on { ctx.store.applyFaceCover(id, style: FaceCoverUI.shared.style) } else { ctx.store.removeFaceCover(id) }
            }))
        }) { AnyView(FaceCoverSection(ctx: $0)) },
    ]
}

@MainActor @Observable final class FaceCoverUI {
    static let shared = FaceCoverUI()
    var style: FaceCover.Style = .mosaic
}

struct FaceCoverSection: View {
    let ctx: InspectorContext
    var body: some View {
        let cover = ctx.clip.flatMap { FaceCover.cover(of: $0.id, in: ctx.store.project.timeline) }
        VStack(alignment: .leading, spacing: 4) {
            if let id = ctx.clip?.id, let job = ctx.store.ai.faceJobs[id] {
                let p = ctx.store.jobs.first { $0.id == job }?.progress ?? 0
                JobProgressLine(text: tr("faceCover.applying", Int(p * 100)), progress: p) { ctx.store.removeFaceCover(id) }
            }
            InlineRow(label: tr("faceCover.style")) {
                Dropdown(items: FaceCover.Style.allCases.map { ($0, tr($0.nameKey)) }, selection: cover.map(FaceCover.style) ?? FaceCoverUI.shared.style) { s in
                    FaceCoverUI.shared.style = s
                    if let id = ctx.clip?.id, cover != nil { ctx.store.applyFaceCover(id, style: s) }
                }
            }
            HintText(text: tr("faceCover.hint"))
        }
    }
}

extension EditorStore {
    public func applyFaceCover(_ clipID: ClipID, style: FaceCover.Style) {
        guard let c = project.timeline.clip(clipID), let asset = c.mediaID.flatMap(project.asset) else { return }
        if let j = ai.faceJobs[clipID] { Task { await JobQueue.shared.cancel(j) } }
        Task {
            let id = await JobQueue.shared.enqueue(titleKey: "faceCover.job", priority: 0, subject: clipID.description) { progress in
                try await MatteGenerator.generate(asset, mode: .faces) { progress.report($0) }
            }
            ai.faceJobs[clipID] = id
            let st = await JobQueue.shared.wait(id)
            if ai.faceJobs[clipID] == id { ai.faceJobs[clipID] = nil }
            switch st {
            case .done:
                MatteStore.shared.didWriteMatte(media: asset, kind: CutoutMode.faces.kind)
                if perform(Edit("cmd.faceCover") { p in try FaceCover.apply(style, to: clipID, in: &p) }) {
                    engine.forceRebuild()
                    showToast(tr("faceCover.done"))
                }
            case .failed: showToast(tr("faceCover.failed"), error: true)
            default: break
            }
        }
    }

    public func removeFaceCover(_ clipID: ClipID) {
        if let j = ai.faceJobs[clipID] { ai.faceJobs[clipID] = nil; Task { await JobQueue.shared.cancel(j) } }
        guard FaceCover.cover(of: clipID, in: project.timeline) != nil else { return }
        perform(Edit("cmd.faceCover") { p in FaceCover.remove(from: clipID, in: &p) })
    }
}
