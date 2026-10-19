import SwiftUI
import AppKit
import MontageCore
import MontageEngine
import MontageAI

// Video AI in the editor: Split scenes (clip menu), Separate audio (clip menu), Video ▸ Basic ▸ ☐ Auto reframe.

enum VideoAIInspector {
    @MainActor static let sections: [InspectorSection] = [
        InspectorSection(id: "video.reframe", tab: "video", subTab: "basic", order: 45, titleKey: "inspector.reframe",
                         appliesTo: { $0.kind == .video }, chrome: { ctx in
            InspectorSectionChrome(isEnabled: Binding(get: { ctx.clip?.reframe != nil || ctx.clip.map { ctx.store.ai.reframeJobs[$0.id] != nil } ?? false },
                                                      set: { on in
                guard let id = ctx.clip?.id else { return }
                if on { ctx.store.autoReframe(id, options: ReframeUIState.shared.options) } else { ctx.store.removeReframe(id) }
            }))
        }) { AnyView(ReframeSection(ctx: $0)) },
    ]
}

@MainActor @Observable final class ReframeUIState {
    static let shared = ReframeUIState()
    var options = ReframeOptions()
}

/// Video ▸ Basic ▸ Auto reframe: Aspect ratio · Camera moving speed · Image stabilization (UX_AI §4.7). Changing an
/// option re-runs the analysis (cached subject path → instant re-apply).
struct ReframeSection: View {
    let ctx: InspectorContext
    var body: some View {
        let st = ReframeUIState.shared
        let current = ctx.clip?.reframe ?? st.options
        VStack(alignment: .leading, spacing: 4) {
            if let id = ctx.clip?.id, let job = ctx.store.ai.reframeJobs[id] {
                let p = ctx.store.jobProgress(job) ?? 0
                JobProgressLine(text: tr("reframe.applying", JobInfo.percent(p)), progress: p) { ctx.store.removeReframe(id) }
            }
            InlineRow(label: tr("reframe.ratio")) {
                Dropdown(items: ["9:16", "16:9", "1:1", "4:3", "3:4", "2.35:1"].map { ($0, $0) }, selection: current.ratio) { r in update { $0.ratio = r } }
            }
            InlineRow(label: tr("reframe.speed")) {
                Dropdown(items: ReframeOptions.Speed.allCases.map { ($0, tr($0.nameKey)) }, selection: current.speed) { v in update { $0.speed = v } }
            }
            InlineRow(label: tr("reframe.stability")) {
                Dropdown(items: ReframeOptions.Stability.allCases.map { ($0, tr($0.nameKey)) }, selection: current.stability) { v in update { $0.stability = v } }
            }
            HintText(text: tr("reframe.hint"))
        }
    }

    func update(_ body: (inout ReframeOptions) -> Void) {
        var o = ctx.clip?.reframe ?? ReframeUIState.shared.options
        body(&o)
        ReframeUIState.shared.options = o
        if let id = ctx.clip?.id, ctx.clip?.reframe != nil { ctx.store.autoReframe(id, options: o) }
    }
}

extension EditorStore {
    /// Split scenes: shot detection over the clip's source range, then one split per cut (one undo step).
    /// "Split scenes" (TL-034): `.scene` = fewer clips (stricter threshold, ≥ 2 s scenes), `.shot` = every shot change.
    public enum SceneSplitMode: Sendable { case scene, shot
        var options: SceneDetector.Options {
            self == .scene ? SceneDetector.Options(threshold: 0.55, minShot: 2) : SceneDetector.Options(threshold: 0.35, minShot: 0.5)
        }
    }

    public func splitScenes(_ clipID: ClipID, mode: SceneSplitMode = .shot) {
        let options = mode.options
        guard let clip = project.timeline.clip(clipID), let asset = clip.mediaID.flatMap(project.asset), asset.kind == .video else { return }
        let range = clip.sourceRange
        let box = CutsBox()
        Task {
            let id = await JobQueue.shared.enqueue(titleKey: "scenes.job", priority: 1, subject: clipID.description) { progress in
                box.cuts = try await SceneDetector.cuts(asset.url, range: range, options: options) { progress.report($0) }
            }
            guard await JobQueue.shared.wait(id) == .done else { showToast(tr("scenes.failed"), error: true); return }
            guard let c = project.timeline.clip(clipID) else { return }
            let times = SceneSplit.splitTimes(box.cuts, clip: c)
            guard !times.isEmpty else { showToast(tr("scenes.none")); return }
            if perform(Edit("cmd.splitScenes") { p in try SceneSplit.apply(times, to: clipID, in: &p.timeline) }) {
                showToast(tr("scenes.done", times.count + 1))
            }
        }
    }

    /// Which separated sound a "Separate audio" entry makes.
    public enum SeparatedPart: Hashable, Sendable {
        /// Speech (AUSoundIsolation ML) / everything but the speech.
        case voice, background
        /// HTDemucs music stems.
        case stem(StemSeparator.Stem)
        var storeKind: String {
            switch self { case .voice: return "voice"; case .background: return "novoice"; case .stem(let s): return s.storeKind }
        }
        var nameKey: String {
            switch self {
            case .voice: return "tlmenu.separateAudio.vocals"
            case .background: return "tlmenu.separateAudio.music"
            case .stem(let s): return s.nameKey
            }
        }
    }

    public func separateAudio(_ clipID: ClipID, keepVoice: Bool) { separateAudio(clipID, part: keepVoice ? .voice : .background) }

    /// Separate audio (AU-009/010): ML stems, added as an audio clip under the source (whose own sound is muted), like
    /// CapCut's separated stem clips. Stems are copied next to generated media so projects keep working after a cache purge.
    public func separateAudio(_ clipID: ClipID, part: SeparatedPart) {
        guard let clip = project.timeline.clip(clipID), let asset = clip.mediaID.flatMap(project.asset), asset.hasAudio else { return }
        Task {
            let id = await JobQueue.shared.enqueue(titleKey: "audio.job.separate", priority: 0, subject: clipID.description) { progress in
                if case .stem = part { try await StemSeparator.separate(asset) { progress.report($0) } }
                else { try await VoiceIsolator.separate(asset) { progress.report($0) } }
            }
            guard await JobQueue.shared.wait(id) == .done,
                  let stem = AudioStemStore.shared.readyStem(media: asset, kind: part.storeKind) else {
                showToast(tr("audio.separate.failed"), error: true); return
            }
            do {
                let dir = MontagePaths.supportDirectory.appendingPathComponent("Generated/stems", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let dst = dir.appendingPathComponent(stem.lastPathComponent)
                if !FileManager.default.fileExists(atPath: dst.path) { try FileManager.default.copyItem(at: stem, to: dst) }
                var stemAsset = try await MediaProbe.probe(dst)
                stemAsset.name = asset.name + " · " + tr(part.nameKey)
                let sa = stemAsset
                perform(Edit("cmd.separateAudio") { p in
                    guard var src = p.timeline.clip(clipID) else { throw EditError.clipNotFound }
                    if !p.media.contains(where: { $0.contentHash == sa.contentHash }) { p.media.append(sa) }
                    var c = TimelineOps.makeClip(for: sa, at: src.start)
                    c.sourceStart = src.sourceStart; c.duration = src.duration; c.speed = src.speed
                    c.audio = src.audio; c.audio.isMuted = false
                    c.extractedFrom = clipID
                    var tl = p.timeline
                    let tid = TimelineOps.addTrack(.audio, to: &tl)
                    let ti = tl.trackIndex(tid)!
                    tl.tracks[ti].clips = [c]
                    src.audio.isMuted = true
                    tl[clip: clipID] = src
                    p.timeline = tl
                })
                showToast(tr("audio.separate.done"))
            } catch { showToast(tr("audio.separate.failed"), error: true) }
        }
    }

    /// Auto reframe (AI-012): subject tracking → smoothed path → fill-scale + position keyframes; the project ratio
    /// changes to the target ratio. One undo step; the job shows on the clip.
    public func autoReframe(_ clipID: ClipID, options: ReframeOptions) {
        if let j = ai.reframeJobs[clipID] { Task { await JobQueue.shared.cancel(j) } }
        let project = self.project
        let box = CommandBox()
        Task {
            let id = await JobQueue.shared.enqueue(titleKey: "reframe.job", priority: 1, subject: clipID.description) { progress in
                box.command = try await AutoReframe.run(project: project, clipID: clipID, options: options) { progress.report($0) }
            }
            ai.reframeJobs[clipID] = id
            let st = await JobQueue.shared.wait(id)
            if ai.reframeJobs[clipID] == id { ai.reframeJobs[clipID] = nil }
            switch st {
            case .done:
                guard let cmd = box.command else { return }
                if perform(Edit("cmd.reframe") { p in try cmd.apply(to: &p); p.timeline[clip: clipID]?.reframe = options }) {
                    showToast(tr("reframe.done"))
                }
            case .failed: showToast(tr("reframe.failed"), error: true)
            case .cancelled: showToast(tr("reframe.cancelled"))
            default: break
            }
        }
    }

    public func removeReframe(_ clipID: ClipID) {
        if let j = ai.reframeJobs[clipID] { ai.reframeJobs[clipID] = nil; Task { await JobQueue.shared.cancel(j) } }
        guard project.timeline.clip(clipID)?.reframe != nil else { return }
        perform(UpdateClip(clipID, nameKey: "cmd.reframe") { c in
            c.reframe = nil
            c.keyframes[ParamKey.position.raw] = nil
            c.transform.position = .zero; c.transform.scale = .one
        })
    }
}

nonisolated final class CutsBox: @unchecked Sendable { var cuts: [Double] = [] }
nonisolated final class CommandBox: @unchecked Sendable { var command: (any EditCommand)? }
