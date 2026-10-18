import SwiftUI
import Observation
import MontageCore
import MontageEngine
import MontageAI

/// State of the AI panels and jobs (UX_AI §0 shared job pattern). Lives in `store.ai`.
@Observable
public final class AIUIState {
    // Auto captions
    public var captionLanguage: String? = nil
    public var captionEngine: SpeechEngine = .automatic
    public var captionSource: CaptionOptions.Source = .allTracks
    public var identifyFillers = false
    public var replaceCaptions = true
    /// Target language for bilingual captions (nil = none).
    public var bilingualTarget: String? = nil
    public var captionJob: JobID?
    public var captionPhase: CaptionPhase?
    public var captionProgress: Double = 0
    public var captionError: String?
    // Translation in progress (bilingual / translate)
    public var translating = false
    /// Pending translation request handled by a `.translationTask` host view (needs the OS download prompt).
    public var translationRequest: TranslationRequest?
    // Cutout: clip → running matte job
    public var cutoutJobs: [ClipID: JobID] = [:]
    /// Customized cutout brush session (canvas tool) for a clip.
    public var brush: CutoutBrushTool?
    // Models sheet
    public var isModelSheetPresented = false
    @ObservationIgnored var ttsRefresh: Task<Void, Never>?
    // Transcript-based editing
    public var transcriptOpen = false
    public var transcriptJob: JobID?
    public var transcriptProgress: Double = 0
    public var transcripts: [MediaID: Transcript] = [:]
    var transcriptSelection: Set<TranscriptPanel.Key> = []
    var transcriptAnchor: TranscriptPanel.Key?
    public var minPause: Double = 1.0
    public var cleanupPauses = true
    public var cleanupKinds: Set<FillerWords.Kind> = [.hesitation, .filler, .repetition]
    public init() {}
}

/// Captions translation job handed to the SwiftUI translation host.
public struct TranslationRequest: Equatable, Identifiable {
    public let id = UUID()
    public let source: String
    public let target: String
    public let display: CaptionDisplay
}

extension EditorStore {
    func installAIHooks() {
        MatteStore.shared.onMatteReady = { [weak self] hash, _ in
            guard let self, self.project.media.contains(where: { $0.contentHash == hash }) else { return }
            self.engine.forceRebuild()
        }
        AIModelsInstall.once()
    }

    /// Called after every project change: unticked / undone cutouts cancel their job (CapCut: ⌘Z cancels).
    func aiProjectDidChange() {
        for (clipID, job) in ai.cutoutJobs where project.timeline.clip(clipID)?.matte == nil {
            ai.cutoutJobs[clipID] = nil
            Task { await JobQueue.shared.cancel(job) }
        }
        if project.timeline.allClips.contains(where: { $0.tts != nil }) {
            ai.ttsRefresh?.cancel()
            ai.ttsRefresh = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.2))
                guard !Task.isCancelled else { return }
                self?.refreshStaleSpeech()
            }
        }
    }

    // MARK: Auto captions

    public var captionOptions: CaptionOptions {
        var s = CaptionSettings()
        s.identifyFillers = ai.identifyFillers
        return CaptionOptions(language: ai.captionLanguage, engine: ai.captionEngine, source: ai.captionSource, settings: s,
                              replaceExisting: ai.replaceCaptions && hasAutoCaptions)
    }

    public var hasAutoCaptions: Bool { !CaptionOps.autoCaptionIDs(project.timeline).isEmpty }

    /// Text ▸ Auto captions ▸ Generate (or Auto lyrics). Non-blocking: the caption track is inserted atomically at the
    /// end as one undo step; the panel shows the phase + % and a Cancel button.
    public func generateCaptions(lyrics: Bool = false) {
        guard ai.captionJob == nil else { return }
        var options = captionOptions
        options.lyrics = lyrics
        let project = self.project
        ai.captionError = nil
        ai.captionProgress = 0
        ai.captionPhase = .extracting
        let box = CaptionBox()
        let target = ai.bilingualTarget
        Task {
            let opts = options
            let id = await JobQueue.shared.enqueue(titleKey: lyrics ? "cmd.lyrics" : "ai.captions", priority: 1) { [weak self] progress in
                box.result = try await CaptionGenerator.run(project: project, options: opts, progress: { p in
                    progress.report(p)
                    Task { @MainActor in self?.ai.captionProgress = p }
                }, phase: { ph in Task { @MainActor in self?.ai.captionPhase = ph } })
            }
            ai.captionJob = id
            let state = await JobQueue.shared.wait(id)
            ai.captionJob = nil
            ai.captionPhase = nil
            switch state {
            case .done:
                guard let r = box.result, perform(r.command) else { return }
                showToast(tr("captions.added", r.count))
                if let caps = CaptionOps.captions(in: self.project.timeline).first {
                    selection = [caps.id]
                    inspectorTab = "captions"
                }
                if let target, target != r.language { translateCaptions(to: target, display: .bilingual) }
            case .failed(let msg):
                let key = msg.contains("noSpeech") ? "ai.error.noSpeech" : (msg.contains("noInput") ? "captions.error.noAudio" : "captions.error.failed")
                ai.captionError = tr(key)
                showToast(tr(key), error: true)
            case .cancelled:
                showToast(tr("captions.cancelled"))
            default: break
            }
        }
    }

    public func cancelCaptions() {
        if let id = ai.captionJob { Task { await JobQueue.shared.cancel(id) } }
    }

    // MARK: Caption editing (caption list)

    public func setCaptionText(_ id: ClipID, _ text: String) {
        guard let c = project.timeline.clip(id), CaptionOps.mainText(c) != text else { return }
        perform(Edit("cmd.captionEdit") { p in try CaptionOps.setText(id, text, in: &p.timeline) })
    }

    public func splitCaption(_ id: ClipID, at offset: Int) {
        if !perform(Edit("cmd.captionSplit") { p in try CaptionOps.split(id, atCharacter: offset, in: &p.timeline) }) {
            showToast(tr("captions.cantSplit"), error: true)
        }
    }

    /// Merge with the previous caption (Delete at the start) or the next one (Fn-Delete at the end).
    public func mergeCaption(_ id: ClipID, withPrevious: Bool) {
        let caps = CaptionOps.captions(in: project.timeline)
        guard let i = caps.firstIndex(where: { $0.id == id }) else { return }
        let first: ClipID
        if withPrevious { guard i > 0 else { showToast(tr("captions.cantMerge"), error: true); return }; first = caps[i - 1].id }
        else { first = id }
        if !perform(Edit("cmd.captionMerge") { p in try CaptionOps.mergeWithNext(first, in: &p.timeline) }) {
            showToast(tr("captions.cantMerge"), error: true)
        } else if withPrevious { selection = [first] }
    }

    @discardableResult
    public func replaceInCaptions(_ find: String, with rep: String) -> Int {
        var n = 0
        let ok = perform(Edit("cmd.captionReplace") { p in
            let k = CaptionOps.replaceAll(find, with: rep, in: &p.timeline)
            if k == 0 { throw EditError.nothingToDo }
        })
        if ok { n = CaptionOps.search(rep, in: project.timeline).count; showToast(tr("captions.updated")) }
        return n
    }

    public func applyCaptionStyleToAll(from id: ClipID) {
        if perform(Edit("cmd.captionStyleAll") { p in try CaptionOps.applyStyleToAll(from: id, in: &p.timeline) }) {
            showToast(tr("captions.styleApplied"))
        }
    }

    public func setCaptionDisplay(_ d: CaptionDisplay) {
        perform(Edit("cmd.captionDisplay") { p in CaptionOps.setDisplay(d, in: &p.timeline) })
    }

    /// Bilingual captions: translates every caption on device (Apple Translation). Installed language pairs run
    /// directly in the background; otherwise a translation host view asks the system to download the pair first.
    public func translateCaptions(to target: String, display: CaptionDisplay) {
        let caps = CaptionOps.captions(in: project.timeline)
        guard !caps.isEmpty else { return }
        let source = caps.first?.caption?.language ?? "en"
        guard source != target else { showToast(tr("captions.sameLanguage"), error: true); return }
        ai.translating = true
        Task {
            switch await CaptionTranslator.status(from: source, to: target) {
            case .installed:
                do {
                    let map = try await CaptionTranslator.translate(caps.map { ($0.id, CaptionOps.mainText($0)) }, from: source, to: target)
                    applyTranslations(map, language: target, display: display)
                } catch {
                    ai.translationRequest = TranslationRequest(source: source, target: target, display: display)
                }
            case .needsDownload:
                ai.translationRequest = TranslationRequest(source: source, target: target, display: display)
            case .unsupported:
                ai.translating = false
                showToast(tr("captions.translateUnsupported"), error: true)
            }
        }
    }

    func applyTranslations(_ map: [ClipID: String], language: String, display: CaptionDisplay) {
        ai.translating = false
        ai.translationRequest = nil
        guard !map.isEmpty else { return }
        perform(Edit("cmd.captionTranslate") { p in CaptionOps.setTranslations(map, language: language, display: display, in: &p.timeline) })
        showToast(tr("captions.translated"))
    }

    public func clearCaptionTranslations() {
        perform(Edit("cmd.captionTranslate") { p in CaptionOps.clearTranslations(in: &p.timeline) })
    }

    // MARK: Cutout

    /// Ticks / unticks Auto cutout (or applies a customized selection) on a clip: sets `Clip.matte` (one undo step)
    /// and starts the matte job if the matte isn't cached yet. Progress shows on the clip in the timeline.
    public func setCutout(_ clipID: ClipID, mode: CutoutMode?) {
        guard let clip = project.timeline.clip(clipID) else { return }
        if let job = ai.cutoutJobs[clipID] { ai.cutoutJobs[clipID] = nil; Task { await JobQueue.shared.cancel(job) } }
        guard let mode else {
            perform(UpdateClip(clipID, nameKey: "cmd.cutout") { $0.matte = nil })
            return
        }
        let keep = clip.matte
        perform(UpdateClip(clipID, nameKey: mode.isCustom ? "cmd.cutoutCustom" : "cmd.cutout") { c in
            c.matte = ClipMatte(kind: mode.kind, feather: keep?.feather ?? 0, expand: keep?.expand ?? 0, inverted: false)
        })
        guard let asset = clip.mediaID.flatMap(project.asset), !MatteGenerator.isReady(asset, mode) else { return }
        let titleKey = mode.isCustom ? "cutout.job.custom" : "cutout.job.auto"
        Task {
            let id = await JobQueue.shared.enqueue(titleKey: titleKey, priority: 0, subject: clipID.description) { progress in
                try await MatteGenerator.generate(asset, mode: mode) { progress.report($0) }
            }
            ai.cutoutJobs[clipID] = id
            let state = await JobQueue.shared.wait(id)
            if ai.cutoutJobs[clipID] == id { ai.cutoutJobs[clipID] = nil }
            switch state {
            case .done:
                MatteStore.shared.didWriteMatte(media: asset, kind: mode.kind)
                engine.forceRebuild()
                showToast(tr(mode.isCustom ? "cutout.doneCustom" : "cutout.done"))
            case .failed:
                perform(UpdateClip(clipID, nameKey: "cmd.cutout") { if $0.matte?.kind == mode.kind { $0.matte = nil } })
                showToast(tr("cutout.failed"), error: true)
            case .cancelled:
                showToast(tr("cutout.cancelled"))
            default: break
            }
        }
    }

    // MARK: Voice stems (for the audio engine)

    /// Makes the ML `voice` / `novoice` stems of a clip's media (AudioStemStore) in the background; progress shows on the
    /// clip. The audio engine (W8) uses them for Isolate voice / Reduce noise / Enhance voice once ready.
    public func requestVoiceStems(_ clipID: ClipID) {
        guard let clip = project.timeline.clip(clipID), let asset = clip.mediaID.flatMap(project.asset), asset.hasAudio,
              !VoiceIsolator.Stem.allCases.allSatisfy({ VoiceIsolator.isReady(asset, $0) }) else { return }
        Task {
            let id = await JobQueue.shared.enqueue(titleKey: "audio.job.isolate", priority: 0, subject: clipID.description) { progress in
                try await VoiceIsolator.separate(asset) { progress.report($0) }
            }
            if await JobQueue.shared.wait(id) == .done {
                for s in VoiceIsolator.Stem.allCases { AudioStemStore.shared.didWriteStem(media: asset, kind: s.rawValue) }
                engine.forceRebuild()
            }
        }
    }

    public func cutoutProgress(_ clipID: ClipID) -> Double? {
        guard let id = ai.cutoutJobs[clipID] else { return nil }
        return jobs.first { $0.id == id }.map(\.progress) ?? 0
    }
}

extension CutoutMode {
    var isCustom: Bool { if case .custom = self { return true }; return false }
}

nonisolated final class CaptionBox: @unchecked Sendable { var result: CaptionResult? }

/// One-time installs of AI engine hooks (optical-flow interpolator for smooth slow-mo).
enum AIModelsInstall {
    nonisolated(unsafe) private static var done = false
    static func once() {
        guard !done else { return }
        done = true
        AIEngineHooks.install()
        AIEngineHooks.installAudioML()
    }
}
