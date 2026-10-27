import SwiftUI
import Perception
import NaturalLanguage
import MontageCore
import MontageEngine
import MontageAI

/// State of the AI panels and jobs (UX_AI §0 shared job pattern). Lives in `store.ai`.
@Perceptible
public final class AIUIState {
    // Auto captions
    public var captionLanguage: String? = nil
    public var captionEngine: SpeechEngine = .automatic
    public var captionSource: CaptionOptions.Source = .allTracks
    public var replaceCaptions = true
    /// Target language for bilingual captions (nil = none).
    public var bilingualTarget: String? = nil
    public var captionJob: JobID?
    public var captionPhase: CaptionPhase?
    public var captionProgress: Double = 0
    /// Why the last caption run failed (BUG-CAPTION-ERRORS): the panel shows it as a card with its fixes.
    public var captionFailure: SpeechFailure?
    /// The same unexpected failure happened twice in a row ("Copy Details" instead of "Generate again").
    public var captionFailureRepeated = false
    /// Pre-flight result for the current language / engine (`refreshCaptionReadiness`).
    public var captionReadiness: SpeechReadiness = .ready
    /// The Auto captions panel is on screen (a failure then shows inline, not only as a toast).
    @PerceptionIgnored public var captionsPanelVisible = false
    /// Last run was Auto lyrics (fixes that regenerate redo the same kind).
    @PerceptionIgnored var lastCaptionRunLyrics = false
    /// Last fix performed (UI tests: `ui.captions.lastRemedy`; system panes / file pickers aren't opened under tests).
    public var lastSpeechRemedy = ""
    // Translation in progress (bilingual / translate)
    public var translating = false
    /// Language detected by the last auto-caption run.
    public var captionSpokenLanguage: String?
    /// Pending translation request handled by a `.translationTask` host view (needs the OS download prompt).
    public var translationRequest: TranslationRequest?
    /// CAP-LANG-TRACKS: the caption track being translated into a new language track, and whether it starts hidden.
    public var translationSource: TranslationSource?
    // Cutout: clip → running matte job
    public var cutoutJobs: [ClipID: JobID] = [:]
    public var reframeJobs: [ClipID: JobID] = [:]
    /// Customized cutout brush session (canvas tool) for a clip.
    public var brush: CutoutBrushTool?
    /// Motion tracking: box tool session and running jobs (follower clip → job).
    public var trackTool: MotionTrackBoxTool?
    public var trackingJobs: [ClipID: JobID] = [:]
    /// Colour looks being computed (clip → job), per kind.
    public var lookJobs: [String: JobID] = [:]
    /// Enhance quality / denoise / deflicker renders (clip → job + the enhancement being rendered).
    /// AI clipper dialog (nil = closed).
    var clipper: AIClipperState?
    /// Face mosaic: faces matte jobs (clip → job).
    public var faceJobs: [ClipID: JobID] = [:]
    /// Camera tracking analyses (clip → job).
    public var cameraJobs: [ClipID: JobID] = [:]
    /// AI movement analyses (clip → job).
    public var movementJobs: [ClipID: JobID] = [:]
    /// AI remove: brush session and inpainting jobs.
    public var removeTool: RemoveBrushTool?
    public var removeJobs: [ClipID: JobID] = [:]
    /// Smart media search.
    public var mediaQuery = ""
    public var mediaQueryEN: String?
    public var mediaIndexing = false
    public var mediaIndexRevision = 0
    public var enhanceJobs: [ClipID: (job: JobID, target: VideoEnhancement)] = [:]
    // Models sheet
    public var isModelSheetPresented = false
    /// OB-07 "Download required" popup + bottom-right download indicator (ModelDownloadFlow.swift).
    public let downloads = ModelDownloadFlow()
    @PerceptionIgnored var ttsRefresh: Task<Void, Never>?
    /// EditPilot chat (AI-048, EditorStore+EditPilot.swift).
    public let pilot = PilotState()
    public init() {}
}

/// Captions translation job handed to the SwiftUI translation host.
public struct TranslationRequest: Equatable, Identifiable {
    public let id = UUID()
    public let source: String
    public let target: String
    public let display: BilingualDisplay
}

extension EditorStore {
    func installAIHooks() {
        MatteStore.shared.onMatteReady = { [weak self] hash, _ in
            guard let self, self.project.media.contains(where: { $0.contentHash == hash }) else { return }
            self.engine.forceRebuild()
        }
        AIModelsInstall.once()
        refreshStaleFaceMattes()
    }

    /// Face covers made before the rotation fix have a misplaced matte on rotated (iPhone portrait) footage:
    /// re-generate those mattes in the background when the project opens; the old one shows until the new one is ready.
    func refreshStaleFaceMattes() {
        var seen = Set<String>()
        for t in project.timeline.tracks {
            for c in t.clips where c.matte?.kind == CutoutMode.faces.kind {
                guard let a = c.mediaID.flatMap(project.asset), seen.insert(a.contentHash).inserted,
                      MatteGenerator.isStaleFaceMatte(a) else { continue }
                Task {
                    let id = await JobQueue.shared.enqueue(titleKey: "faceCover.job", priority: 0, heavy: true, subject: c.id.description) { progress in
                        try await MatteGenerator.generate(a, mode: .faces) { progress.report($0) }
                    }
                    if await JobQueue.shared.wait(id) == .done {
                        MatteStore.shared.didWriteMatte(media: a, kind: CutoutMode.faces.kind)
                        engine.forceRebuild()
                    }
                }
            }
        }
    }

    /// Called after every project change: unticked / undone cutouts cancel their job (CapCut: ⌘Z cancels).
    func aiProjectDidChange() {
        for (clipID, job) in ai.cutoutJobs where project.timeline.clip(clipID)?.matte == nil {
            ai.cutoutJobs[clipID] = nil
            Task { await JobQueue.shared.cancel(job) }
        }
        relightProjectDidChange()
        if project.timeline.tracks.contains(where: { $0.clips.contains { $0.tts != nil } }) {   // no allClips copy per tick
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
        CaptionOptions(language: ai.captionLanguage, engine: ai.captionEngine, source: ai.captionSource, settings: CaptionSettings(),
                              replaceExisting: ai.replaceCaptions && hasAutoCaptions)
    }

    public var hasAutoCaptions: Bool {
        SpeechCaptions.captions(in: project.timeline).contains { CaptionOps.text($0)?.caption?.origin == .auto }
    }

    /// Text ▸ Auto captions ▸ Generate (or Auto lyrics). Non-blocking: the caption track (W7 model, word timings for
    /// karaoke) is inserted atomically at the end as one undo step; the panel shows the phase + % and Cancel.
    public func generateCaptions(lyrics: Bool = false) {
        guard ai.captionJob == nil else { return }
        var options = captionOptions
        options.lyrics = lyrics
        let project = self.project
        let previousFailure = ai.captionFailure
        ai.captionFailure = nil
        ai.lastCaptionRunLyrics = lyrics
        ai.captionProgress = 0
        ai.captionPhase = .extracting
        let box = CaptionBox()
        let target = ai.bilingualTarget
        Task {
            let opts = options
            let id = await JobQueue.shared.enqueue(titleKey: lyrics ? "cmd.lyrics" : "ai.captions", priority: 1, heavy: true) { [weak self] progress in
                box.result = try await CaptionGenerator.run(project: project, options: opts, progress: { p in
                    progress.report(p)
                    Task { @MainActor in self?.ai.captionProgress = p }
                }, phase: { ph in Task { @MainActor in self?.ai.captionPhase = ph } })
            }
            ai.captionJob = id
            let (state, error) = await JobQueue.shared.waitResult(id)
            ai.captionJob = nil
            ai.captionPhase = nil
            switch state {
            case .done:
                // the edit can be refused (project changed meanwhile): say so instead of failing silently
                guard let r = box.result, perform(r.command) else { showToast(tr("captions.failure.notApplied"), error: true); return }
                ai.captionFailureRepeated = false
                ai.captionSpokenLanguage = r.language
                showToast(tr("captions.addedCount", r.count))
                if let first = SpeechCaptions.captions(in: self.project.timeline).first {
                    selection = [first.id]
                    inspectorTab = "captions"
                }
                if let target, target != r.language { translateCaptions(to: target, display: .both) }
            case .failed(let msg):
                presentCaptionFailure(SpeechFailure.classify(error ?? SpeechFailure.other(detail: msg), language: opts.language),
                                      previous: previousFailure)
            case .cancelled:
                showToast(tr("captions.cancelled"))
            default: break
            }
        }
    }

    public func cancelCaptions() {
        if let id = ai.captionJob { Task { await JobQueue.shared.cancel(id) } }
    }

    /// Spoken language of the captions (last auto-caption run, else detected from the caption text).
    var captionLanguage: String {
        if let l = ai.captionSpokenLanguage { return l }
        let text = SpeechCaptions.captions(in: project.timeline).prefix(30).compactMap { CaptionOps.text($0)?.string }.joined(separator: " ")
        let r = NLLanguageRecognizer(); r.processString(text)
        return r.dominantLanguage?.rawValue ?? L10n.shared.language
    }

    /// Bilingual captions (Auto captions ▸ Bilingual): the active caption track translated on device into a second,
    /// visible language track stacked above it (CAP-LANG-TRACKS).
    public func translateCaptions(to target: String, display: BilingualDisplay) {
        guard let ti = captionEditorTrackIndex else { return }
        captionTranslate(from: project.timeline.tracks[ti].id, to: target, hidden: false)
    }

    // MARK: Cutout

    /// Ticks / unticks Auto cutout (or applies a customized selection) on a clip: sets `Clip.matte` (one undo step)
    /// and starts the matte job if the matte isn't cached yet. Progress shows on the clip in the timeline.
    /// Returns the task that runs the job and applies its result (tests await it), nil when no job was needed.
    @discardableResult
    public func setCutout(_ clipID: ClipID, mode: CutoutMode?) -> Task<Void, Never>? {
        guard let clip = project.timeline.clip(clipID) else { return nil }
        if let job = ai.cutoutJobs[clipID] { ai.cutoutJobs[clipID] = nil; Task { await JobQueue.shared.cancel(job) } }
        guard let mode else {
            perform(UpdateClip(clipID, nameKey: "cmd.cutout") { $0.matte = nil })
            return nil
        }
        let keep = clip.matte
        perform(UpdateClip(clipID, nameKey: mode.isCustom ? "cmd.cutoutCustom" : "cmd.cutout") { c in
            c.matte = ClipMatte(kind: mode.kind, feather: keep?.feather ?? 0, expand: keep?.expand ?? 0, inverted: false)
        })
        guard let asset = clip.mediaID.flatMap(project.asset), !MatteGenerator.isReady(asset, mode) else { return nil }
        let titleKey = mode.isCustom ? "cutout.job.custom" : "cutout.job.auto"
        return Task {
            let id = await JobQueue.shared.enqueue(titleKey: titleKey, priority: 0, heavy: true, subject: clipID.description) { progress in
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
            let id = await JobQueue.shared.enqueue(titleKey: "audio.job.isolate", priority: 0, heavy: true, subject: clipID.description) { progress in
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
        return jobProgress(id) ?? 0
    }
}

extension CutoutMode {
    var isCustom: Bool { if case .custom = self { return true }; return false }
}

nonisolated final class CaptionBox: @unchecked Sendable { var result: CaptionResult? }

extension EditorStore {
    /// UI tests: `ui.models.<model id, "." → "_">` = notInstalled / downloading / verifying / installed / failed, and
    /// `ui.models.progress.<id>` (0…1) while downloading — for download-flow checks.
    func modelsStateDump() -> [String: Any] {
        var d: [String: Any] = [:], progress: [String: Any] = [:]
        for spec in ModelCatalog.all {
            let k = spec.id.replacingOccurrences(of: ".", with: "_")   // path segments split on "."
            switch ModelManager.shared.state(spec) {
            case .notInstalled: d[k] = "notInstalled"
            case .downloading(let p): d[k] = "downloading"; progress[k] = p
            case .verifying: d[k] = "verifying"
            case .installed: d[k] = "installed"
            case .failed(let m): d[k] = "failed: \(m)"
            }
        }
        d["progress"] = progress
        d["flow"] = ai.downloads.dump()   // OB-07 popup / indicator
        return d
    }
}

/// One-time installs of AI engine hooks (optical-flow interpolator for smooth slow-mo).
enum AIModelsInstall {
    nonisolated(unsafe) private static var done = false
    static func once() {
        guard !done else { return }
        done = true
        AIEngineHooks.install()
        AIEngineHooks.installAudioML()
        ColorLooks.loadAll()
    }
}
