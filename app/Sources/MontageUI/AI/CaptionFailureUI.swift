import SwiftUI
import AppKit
import Perception
import MontageCore
import MontageEngine
import MontageAI

/// BUG-CAPTION-ERRORS: why captions couldn't be created, said in the user's terms, with the fix as a button
/// (Auto captions panel card + toast when the panel is closed). Pre-flight (`refreshCaptionReadiness`) shows a known
/// blocker before Generate.
extension EditorStore {
    /// The speech helper is in this copy of Montage (UI tests can pretend either way).
    var speechHelperPresent: Bool { SpeechTestHooks.forcedHelperPresent ?? (WhisperRuntime.cliURL != nil) }

    /// Fixes offered for `failure` on this Mac (primary first, ≤ 2).
    public func speechRemedies(for failure: SpeechFailure, repeated: Bool = false) -> [SpeechRemedy] {
        failure.remedies(helperPresent: speechHelperPresent, modelInstalled: ModelCatalog.installedWhisperModel != nil,
                         updatesAvailable: UpdateController.shared.isAvailable, repeated: repeated)
    }

    /// Shows a caption failure: inline in the panel when it is open, else a toast with the main fix.
    func presentCaptionFailure(_ failure: SpeechFailure, previous: SpeechFailure?) {
        var repeated = false
        if case .other = failure, case .other = previous { repeated = true }
        ai.captionFailureRepeated = repeated
        ai.captionFailure = failure
        guard !ai.captionsPanelVisible else { return }
        let msg = failure.message(repeated: repeated)
        if let primary = speechRemedies(for: failure, repeated: repeated).first {
            showToast(msg.toast.text(), error: true, actionTitle: primary.title.text()) { [weak self] in self?.performSpeechRemedy(primary) }
        } else {
            showToast(msg.toast.text(), error: true)
        }
    }

    /// Runs a fix. System Settings / file pickers / the pasteboard are left alone under UI tests (`lastSpeechRemedy`
    /// records the request instead).
    public func performSpeechRemedy(_ remedy: SpeechRemedy) {
        ai.lastSpeechRemedy = remedy.name
        let testing = TestAnchors.isEnabled
        switch remedy {
        case .openSettings(let pane):
            if !testing { NSWorkspace.shared.open(pane.url) }
        case .downloadSpeechModel, .useSpeechModel:
            downloadSpeechModelThenCaption(ModelCatalog.whisperTurbo)
        case .redownloadSpeechModel:
            let spec = ModelCatalog.preferredWhisperSpec
            ModelManager.shared.remove(spec)
            downloadSpeechModelThenCaption(spec)
        case .useLighterModel:
            UserDefaults.standard.set(true, forKey: ModelCatalog.preferLighterWhisperKey)
            downloadSpeechModelThenCaption(ModelCatalog.whisperSmall)
        case .detectLanguage:
            ai.captionLanguage = nil
            regenerateCaptions()
        case .useAutomatic:
            ai.captionEngine = .automatic
            regenerateCaptions()
        case .useAllTracks:
            ai.captionSource = .allTracks
            regenerateCaptions()
        case .relink(let id):
            ai.captionFailure = nil
            if !testing, let a = project.asset(id) { LinkMediaPanel.run(self, a) }
        case .checkForUpdates:
            UpdateController.shared.checkNow()
        case .retry:
            regenerateCaptions()
        case .copyDetails:
            if !testing {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(captionFailureDetails(), forType: .string)
            }
            showToast(tr("captions.failure.detailsCopied"))
        }
    }

    func regenerateCaptions() {
        ai.captionFailure = nil
        refreshCaptionReadiness()
        generateCaptions(lyrics: ai.lastCaptionRunLyrics)
    }

    /// Downloads a speech model (the bottom-right indicator shows progress), then creates the captions.
    func downloadSpeechModelThenCaption(_ spec: AIModelSpec) {
        ai.captionFailure = nil
        let mm = ModelManager.shared
        if mm.state(spec).isInstalled { regenerateCaptions(); return }
        if !mm.state(spec).isBusy { mm.download(spec) }
        mm.whenFinished(spec) { [weak self] state in
            guard let self else { return }
            self.refreshCaptionReadiness()
            if state.isInstalled { self.generateCaptions(lyrics: self.ai.lastCaptionRunLyrics) }
        }
    }

    /// Text for "Copy Details": app + Mac + macOS + the raw reason.
    func captionFailureDetails() -> String {
        var detail = ai.captionFailure?.name ?? ""
        if case .other(let d) = ai.captionFailure { detail = d }
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return "Montage \(version) · \(String(cString: model)) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\nCaptions: \(detail)"
    }

    /// Pre-flight for the captions panel: on appear, language / engine change, app activation, model installed.
    public func refreshCaptionReadiness() {
        let lang = ai.captionLanguage, engine = ai.captionEngine, ui = L10n.shared.language
        Task { [weak self] in
            let r = await Transcriber.readiness(language: lang, engine: engine, uiLanguage: ui)
            guard let self, self.ai.captionLanguage == lang, self.ai.captionEngine == engine else { return }
            if self.ai.captionReadiness != r { self.ai.captionReadiness = r }
        }
    }

    /// Known blocker to show before Generate (nil = none).
    var captionBlocker: SpeechFailure? {
        if case .blocked(let f) = ai.captionReadiness { return f }
        return nil
    }

    /// UI tests: `ui.captions.{failure, readiness, remedies, title, body, lastRemedy, phase}`.
    func captionsStateDump() -> [String: Any] {
        let shown = ai.captionFailure ?? captionBlocker
        var d: [String: Any] = ["failure": ai.captionFailure?.name ?? "", "readiness": ai.captionReadiness.name,
                                "lastRemedy": ai.lastSpeechRemedy, "phase": ai.captionPhase?.rawValue ?? "",
                                "generateTitle": captionGenerateTitleKey]
        if let f = shown {
            let m = f.message(repeated: ai.captionFailure != nil && ai.captionFailureRepeated)
            d["title"] = m.title.text()
            d["body"] = m.body.text()
            d["remedies"] = speechRemedies(for: f, repeated: ai.captionFailure != nil && ai.captionFailureRepeated).map(\.name)
        } else {
            d["remedies"] = [String]()
        }
        return d
    }

    /// Footer button: "Download and create captions" when the speech model is the known fix.
    var captionGenerateTitleKey: String {
        if ai.captionFailure == nil, let b = captionBlocker, speechRemedies(for: b).first == .downloadSpeechModel {
            return SpeechRemedy.downloadSpeechModel.title.key
        }
        return "captions.generate"
    }
}

/// Title + reason + up to two fixes (Auto captions panel).
struct SpeechFailureCard: View {
    let store: EditorStore
    let failure: SpeechFailure
    let repeated: Bool
    let testID: String
    /// Remedies already offered elsewhere (the footer's "Download and create captions" in the pre-flight card).
    var hidden: Set<SpeechRemedy> = []
    var body: some View {
        WithPerceptionTracking {
            let msg = failure.message(repeated: repeated)
            let remedies = store.speechRemedies(for: failure, repeated: repeated).filter { !hidden.contains($0) }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(IStyle.warning).font(.system(size: 12))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: msg.title.text()).font(Theme.Fonts.row).fontWeight(.semibold).foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(verbatim: msg.body.text()).font(Theme.Fonts.hint).foregroundStyle(IStyle.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                if !remedies.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(Array(remedies.enumerated()), id: \.element) { i, r in
                            WithPerceptionTracking {
                                if i == 0 {
                                    Button(r.title.text()) { store.performSpeechRemedy(r) }
                                        .buttonStyle(SecondaryButtonStyle())
                                        .testID("captions.remedy.\(r.name)")
                                } else {
                                    Button(r.title.text()) { store.performSpeechRemedy(r) }
                                        .buttonStyle(.link).font(Theme.Fonts.hint)
                                        .testID("captions.remedy.\(r.name)")
                                }
                            }
                        }
                    }
                    .padding(.leading, 20)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 6))
            .testID(testID)
        }
    }
}
