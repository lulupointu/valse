import SwiftUI
import MontageCore
import MontageEngine
import MontageAI

// Video ▸ Basic ▸ ☐ AI movement (UX_AI §4.9, AI-025): presets Dynamic / Soft / Shake / Zoom, Strength, ☐ Sync to beats
// (only when the project has beat markers under the clip). Ticking runs the subject analysis in the background
// (progress on the clip; stills are instant) and writes position / scale (/ rotation) keyframes as one undo step.
// Changing an option re-applies from the cached analysis. Excludes auto reframe and camera tracking.
enum AIMovementInspector {
    @MainActor static let sections: [InspectorSection] = [
        InspectorSection(id: "video.aiMovement", tab: "video", subTab: "basic", order: 46, titleKey: "aiMovement.title",
                         appliesTo: { $0.isMediaVideo || $0.asset?.kind == .image }, chrome: { ctx in
            InspectorSectionChrome(isEnabled: Binding(get: {
                ctx.clip?.aiMovement != nil || ctx.clip.map { ctx.store.ai.movementJobs[$0.id] != nil } ?? false
            }, set: { on in
                guard let id = ctx.clip?.id else { return }
                if on { ctx.store.applyAIMovement(id, options: AIMovementUIState.shared.options) } else { ctx.store.removeAIMovement(id) }
            }))
        }) { AnyView(AIMovementSection(ctx: $0)) },
    ]
}

@MainActor @Observable final class AIMovementUIState {
    static let shared = AIMovementUIState()
    var options = AIMovementOptions()
    /// Strength while the slider is dragged (applied on release).
    var draftStrength: Double?
}

struct AIMovementSection: View {
    let ctx: InspectorContext
    var body: some View {
        let st = AIMovementUIState.shared
        let o = ctx.clip?.aiMovement ?? st.options
        let strength = st.draftStrength ?? o.strength
        let hasBeats = ctx.clip.map { !AIMovement.beats(for: $0, in: ctx.store.project.timeline).isEmpty } ?? false
        VStack(alignment: .leading, spacing: 6) {
            if let id = ctx.clip?.id, let job = ctx.store.ai.movementJobs[id] {
                let p = ctx.store.jobProgress(job) ?? 0
                JobProgressLine(text: tr("aiMovement.applying", JobInfo.percent(p)), progress: p) { ctx.store.removeAIMovement(id) }
                    .testID("aiMovement.progress")
            }
            HStack(spacing: 6) {
                ForEach(AIMovementOptions.Preset.allCases, id: \.self) { preset in
                    let on = o.preset == preset
                    Button { update { $0.preset = preset } } label: {
                        VStack(spacing: 4) {
                            Image(systemName: preset.symbol).font(.system(size: 15))
                            Text(loc: preset.nameKey).font(Theme.Fonts.hint).lineLimit(1)
                        }
                        .foregroundStyle(on ? Theme.accent : Theme.textPrimary)
                        .frame(maxWidth: .infinity).frame(height: 54)
                        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(on ? Theme.accent : Color.clear, lineWidth: 1.5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .testID("aiMovement.preset.\(preset.rawValue)")
                }
            }
            SliderRowView(label: tr("aiMovement.strength"), unit: strength, originUnit: 0, gradient: nil, ticks: [],
                          display: Fmt.int(strength * 100), enabled: true, labelAccessory: nil, parse: NumberParse.number,
                          onBegin: { st.draftStrength = strength }, onChange: { st.draftStrength = $0 },
                          onEnd: { let v = st.draftStrength ?? strength; st.draftStrength = nil; update { $0.strength = v } },
                          commit: { v in update { $0.strength = min(max(v / 100, 0), 1) } },
                          step: { d in update { $0.strength = min(max($0.strength + Double(d) * 0.01, 0), 1) } }, triplet: nil)
                .testID("aiMovement.strength")
            if hasBeats {
                ToggleLine(label: tr("aiMovement.beats"), isOn: Binding(get: { o.syncToBeats }, set: { v in update { $0.syncToBeats = v } }))
                    .testID("aiMovement.beats")
            }
            HintText(text: tr("aiMovement.hint"))
        }
    }

    func update(_ body: (inout AIMovementOptions) -> Void) {
        var o = ctx.clip?.aiMovement ?? AIMovementUIState.shared.options
        body(&o)
        AIMovementUIState.shared.options = o
        if let id = ctx.clip?.id, ctx.clip?.aiMovement != nil { ctx.store.applyAIMovement(id, options: o) }
    }
}

extension EditorStore {
    /// AI movement (AI-025): subject analysis (cached) → keyframed camera move, one undo step; progress on the clip.
    public func applyAIMovement(_ clipID: ClipID, options: AIMovementOptions) {
        if let j = ai.movementJobs[clipID] { Task { await JobQueue.shared.cancel(j) } }
        let project = self.project
        let box = CommandBox()
        let wasOn = project.timeline.clip(clipID)?.aiMovement != nil
        Task {
            let id = await JobQueue.shared.enqueue(titleKey: "aiMovement.job", priority: 1, subject: clipID.description) { progress in
                box.command = try await AIMovementJob.run(project: project, clipID: clipID, options: options) { progress.report($0) }
            }
            ai.movementJobs[clipID] = id
            let st = await JobQueue.shared.wait(id)
            if ai.movementJobs[clipID] == id { ai.movementJobs[clipID] = nil }
            switch st {
            case .done: if let cmd = box.command, perform(cmd), !wasOn { showToast(tr("aiMovement.done")) }
            case .failed: showToast(tr("aiMovement.failed"), error: true)
            case .cancelled: showToast(tr("aiMovement.cancelled"))
            default: break
            }
        }
    }

    public func removeAIMovement(_ clipID: ClipID) {
        if let j = ai.movementJobs[clipID] { ai.movementJobs[clipID] = nil; Task { await JobQueue.shared.cancel(j) } }
        guard project.timeline.clip(clipID)?.aiMovement != nil else { return }
        perform(UpdateClip(clipID, nameKey: "cmd.aiMovement") { AIMovement.remove(&$0) })
    }
}
