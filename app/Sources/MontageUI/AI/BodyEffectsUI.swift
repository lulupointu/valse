import Foundation
import MontageCore
import MontageEffects
import MontageEngine
import MontageAI

/// FX-002: body effects (outline, aura, shadow, clones, magic cutout…) on plain video or photos.
///
/// CapCut's body effects find the person by themselves. Applying one to a video / image clip that has no cutout gives
/// the clip a body-effects-only person matte (`ClipMatte.bodyOnly`, same Vision person matte as Auto cutout, cached per
/// media): the renderer applies the body effects to the cut-out person and puts them back over the whole, un-cut frame.
/// The matte is made in the background (progress on the clip); the effect shows once it is ready.
enum BodyEffects {
    nonisolated static func isBody(_ d: EffectDescriptor) -> Bool { d.groupKey == "effect.group.body" }

    /// Adds the body-effects matte to `clip` when `d` is a body effect and the clip is un-cut media.
    nonisolated static func prepare(_ clip: inout Clip, for d: EffectDescriptor, in p: Project) {
        guard isBody(d), clip.matte == nil, let id = clip.mediaID, let a = p.asset(id), a.kind == .video || a.kind == .image else { return }
        clip.matte = ClipMatte(kind: CutoutMode.person.kind, bodyOnly: true)
    }
}

extension EditorStore {
    /// Starts the person-matte job of every clip that has a body-effects matte that isn't cached yet.
    func startBodyMatteJobs(_ ids: [ClipID]) {
        for clipID in ids {
            guard let clip = project.timeline.clip(clipID), let m = clip.matte, m.isBodyOnly,
                  let asset = clip.mediaID.flatMap(project.asset), ai.cutoutJobs[clipID] == nil,
                  !MatteGenerator.isReady(asset, .person) else { continue }
            Task {
                let id = await JobQueue.shared.enqueue(titleKey: "fx.body.job", priority: 0, heavy: true, subject: clipID.description) { progress in
                    try await MatteGenerator.generate(asset, mode: .person) { progress.report($0) }
                }
                ai.cutoutJobs[clipID] = id
                let state = await JobQueue.shared.wait(id)
                if ai.cutoutJobs[clipID] == id { ai.cutoutJobs[clipID] = nil }
                switch state {
                case .done:
                    MatteStore.shared.didWriteMatte(media: asset, kind: CutoutMode.person.kind)
                    engine.forceRebuild()
                case .failed:
                    perform(UpdateClip(clipID, nameKey: "cmd.effect") { if $0.matte?.isBodyOnly == true { $0.matte = nil } })
                    showToast(tr("fx.body.failed"), error: true)
                default: break
                }
            }
        }
    }
}
