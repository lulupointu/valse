import SwiftUI
import MontageCore
import MontageEngine
import MontageAI

// Video ▸ Basic ▸ ☐ Enhance quality · ☐ Reduce image noise · ☐ Remove flickers (UX_AI §4.2–4.4, CL-017/018/019).
// Ticking (or changing a level) re-renders the processed copy from the original in the background (progress on the
// clip); the clip then plays it. Unticking the last one restores the original media.

enum EnhanceInspector {
    @MainActor static let sections: [InspectorSection] = [
        InspectorSection(id: "video.enhanceQuality", tab: "video", subTab: "basic", order: 46, titleKey: "enhance.quality",
                         appliesTo: { $0.isMediaVideo || $0.clip?.enhance != nil }, chrome: { ctx in
            chrome(ctx, get: { $0?.upscale != nil }, set: { e, on in e.upscale = on ? .hd : nil },
                   disabled: canUpscale(ctx) ? nil : tr("enhance.quality.unavailable"))
        }) { AnyView(EnhanceQualitySection(ctx: $0)) },
        InspectorSection(id: "video.denoise", tab: "video", subTab: "basic", order: 47, titleKey: "enhance.denoise",
                         appliesTo: { $0.isMediaVideo || $0.clip?.enhance != nil }, chrome: { ctx in
            chrome(ctx, get: { $0?.denoise != nil }, set: { e, on in e.denoise = on ? .normal : nil })
        }) { AnyView(EnhanceDenoiseSection(ctx: $0)) },
        InspectorSection(id: "video.deflicker", tab: "video", subTab: "basic", order: 48, titleKey: "enhance.flicker",
                         appliesTo: { $0.isMediaVideo || $0.clip?.enhance != nil }, chrome: { ctx in
            chrome(ctx, get: { $0?.deflicker != nil }, set: { e, on in e.deflicker = on ? .flashlight : nil })
        }) { AnyView(EnhanceFlickerSection(ctx: $0)) },
    ]

    @MainActor static func original(_ ctx: InspectorContext) -> MediaAsset? {
        guard let c = ctx.clip else { return nil }
        return (c.enhance?.original ?? c.mediaID).flatMap(ctx.store.project.asset)
    }

    @MainActor static func canUpscale(_ ctx: InspectorContext) -> Bool { original(ctx).map(VideoEnhancer.canUpscale) ?? false }

    @MainActor static func chrome(_ ctx: InspectorContext, get: @escaping (VideoEnhancement?) -> Bool,
                                  set: @escaping (inout VideoEnhancement, Bool) -> Void, disabled: String? = nil) -> InspectorSectionChrome {
        var c = InspectorSectionChrome(isEnabled: Binding(get: { get(ctx.store.pendingEnhancement(ctx.clip?.id) ?? ctx.clip?.enhance) }, set: { on in
            guard let id = ctx.clip?.id else { return }
            ctx.store.updateEnhancement(id) { set(&$0, on) }
        }))
        c.disabledReason = disabled
        return c
    }
}

struct EnhanceProgress: View {
    let ctx: InspectorContext
    var body: some View {
        if let id = ctx.clip?.id, let job = ctx.store.ai.enhanceJobs[id]?.job {
            let p = ctx.store.jobProgress(job) ?? 0
            JobProgressLine(text: tr("enhance.applying", JobInfo.percent(p)), progress: p) { ctx.store.cancelEnhancement(id) }
        }
    }
}

struct EnhanceQualitySection: View {
    let ctx: InspectorContext
    var body: some View {
        let e = ctx.store.pendingEnhancement(ctx.clip?.id) ?? ctx.clip?.enhance
        let target = e?.upscale ?? .hd
        VStack(alignment: .leading, spacing: 4) {
            EnhanceProgress(ctx: ctx)
            InlineRow(label: tr("enhance.quality.level")) {
                // HD = ×2, UHD = up to 4K: tiled low-latency ML super resolution (TiledScaler), faster than real time
                SegmentedTabs(UpscaleTarget.allCases.map { (id: $0.rawValue, title: tr($0.nameKey)) }, selection: Binding(get: { target.rawValue }, set: { v in
                    guard let id = ctx.clip?.id, let t = UpscaleTarget(rawValue: v), e?.upscale != nil else { return }
                    ctx.store.updateEnhancement(id) { $0.upscale = t }
                }))
                .testID("enhance.quality.target")
            }
            HintText(text: tr(target == .hd ? "enhance.quality.hint" : "enhance.quality.hintUHD"))
        }
    }
}

struct EnhanceDenoiseSection: View {
    let ctx: InspectorContext
    var body: some View {
        let e = ctx.store.pendingEnhancement(ctx.clip?.id) ?? ctx.clip?.enhance
        VStack(alignment: .leading, spacing: 4) {
            EnhanceProgress(ctx: ctx)
            InlineRow(label: tr("enhance.level")) {
                Dropdown(items: EnhanceLevel.allCases.map { ($0, tr($0.nameKey)) }, selection: e?.denoise ?? .normal) { l in
                    if let id = ctx.clip?.id { ctx.store.updateEnhancement(id) { $0.denoise = l } }
                }
            }
        }
    }
}

struct EnhanceFlickerSection: View {
    let ctx: InspectorContext
    var body: some View {
        let e = ctx.store.pendingEnhancement(ctx.clip?.id) ?? ctx.clip?.enhance
        VStack(alignment: .leading, spacing: 4) {
            EnhanceProgress(ctx: ctx)
            InlineRow(label: tr("enhance.flicker.mode")) {
                Dropdown(items: DeflickerMode.allCases.map { ($0, tr($0.nameKey)) }, selection: e?.deflicker ?? .flashlight) { m in
                    if let id = ctx.clip?.id { ctx.store.updateEnhancement(id) { $0.deflicker = m } }
                }
            }
            InlineRow(label: tr("enhance.level")) {
                Dropdown(items: EnhanceLevel.allCases.map { ($0, tr($0.nameKey)) }, selection: e?.deflickerLevel ?? .normal) { l in
                    if let id = ctx.clip?.id { ctx.store.updateEnhancement(id) { $0.deflickerLevel = l; if $0.deflicker == nil { $0.deflicker = .flashlight } } }
                }
            }
        }
    }
}

extension EditorStore {
    /// The enhancement being rendered for a clip (shown in the inspector until it lands).
    func pendingEnhancement(_ id: ClipID?) -> VideoEnhancement? { id.flatMap { ai.enhanceJobs[$0]?.target } }

    /// Changes a clip's enhancements and re-renders its processed media (one undo step when done).
    public func updateEnhancement(_ clipID: ClipID, _ change: (inout VideoEnhancement) -> Void) {
        guard let c = project.timeline.clip(clipID), let media = c.enhance?.original ?? c.mediaID else { return }
        var e = pendingEnhancement(clipID) ?? c.enhance ?? VideoEnhancement(original: media)
        change(&e)
        if e == c.enhance { cancelEnhancement(clipID); return }
        if e.isEmpty && c.enhance == nil { cancelEnhancement(clipID); return }
        cancelEnhancement(clipID)
        let project = self.project
        let box = CommandBox()
        let target = e
        Task {
            let id = await JobQueue.shared.enqueue(titleKey: "enhance.job", priority: 1, heavy: true, subject: clipID.description) { progress in
                box.command = try await VideoEnhanceJob.run(project: project, clipID: clipID, enhancement: target) { progress.report($0) }
            }
            ai.enhanceJobs[clipID] = (id, target)
            let st = await JobQueue.shared.wait(id)
            if ai.enhanceJobs[clipID]?.job == id { ai.enhanceJobs[clipID] = nil }
            switch st {
            case .done:
                if let cmd = box.command, perform(cmd), !target.isEmpty { showToast(tr("enhance.done")) }
            case .failed: showToast(tr("enhance.failed"), error: true)
            case .cancelled: showToast(tr("enhance.cancelled"))
            default: break
            }
        }
    }

    public func cancelEnhancement(_ clipID: ClipID) {
        if let j = ai.enhanceJobs[clipID]?.job { ai.enhanceJobs[clipID] = nil; Task { await JobQueue.shared.cancel(j) } }
    }
}
