import SwiftUI
import AppKit
import UniformTypeIdentifiers
@preconcurrency import Translation
import ValseCore
import ValseEngine
import ValseAI
import Perception

/// Spoken / translation languages offered in the captions UI (English name · own name, like CapCut).
enum CaptionLanguages {
    static let codes = ["fr", "en", "es", "de", "it", "pt", "nl", "ja", "zh", "ko"]
    static func title(_ code: String) -> String {
        let en = Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
        let own = Locale(identifier: code).localizedString(forLanguageCode: code) ?? code
        let ui = Locale(identifier: L10n.shared.language).localizedString(forLanguageCode: code) ?? en
        return ui.lowercased() == own.lowercased() ? ui.capitalized : "\(ui.capitalized) · \(own.capitalized)"
    }
}

/// Text ▸ Auto captions (UX_AI §1.2, [119]): Spoken language (Auto detect), Bilingual captions, track selector,
/// speech model card; footer: ☐ Delete current captions · [Generate]. Non-blocking progress.
struct AutoCaptionsPanel: View {
    let store: EditorStore

    var body: some View {
        WithPerceptionTracking {
            let ai = store.ai
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HintText(text: tr("captions.hint"))
                        label("captions.spokenLanguage")
                        Dropdown(items: [(Optional<String>.none, tr("captions.autoDetect"))] + CaptionLanguages.codes.map { (Optional($0), CaptionLanguages.title($0)) },
                                 selection: ai.captionLanguage) { ai.captionLanguage = $0 }
                        label("captions.bilingual")
                        Dropdown(items: [(Optional<String>.none, tr("captions.none"))] + CaptionLanguages.codes.map { (Optional($0), CaptionLanguages.title($0)) },
                                 selection: ai.bilingualTarget) { ai.bilingualTarget = $0 }
                        let sources = sourceItems
                        if sources.count > 2 {
                            label("captions.selectTrack")
                            Dropdown(items: sources, selection: sourceKey(ai.captionSource)) { k in ai.captionSource = source(for: k) }
                        }
                        AdvancedSpeechSection(store: store)
                        HStack {
                            Spacer()
                            Button(tr("captions.autoLyrics")) { store.generateCaptions(lyrics: true) }
                                .buttonStyle(SecondaryButtonStyle()).disabled(ai.captionJob != nil || !hasAudio).testID("captions.autoLyrics")
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                footer
            }
            .background(Theme.panel)
            .background(TranslationHost(store: store))
            .testID("captions.panel")
            // pre-flight (BUG-CAPTION-ERRORS): re-checked whenever what it depends on may have changed
            .onAppear { ai.captionsPanelVisible = true; store.refreshCaptionReadiness() }
            .onDisappear { ai.captionsPanelVisible = false }
            .onChange(of: ai.captionLanguage) { _ in store.refreshCaptionReadiness() }
            .onChange(of: ai.captionEngine) { _ in store.refreshCaptionReadiness() }
            .onChange(of: ModelManager.shared.state(ModelCatalog.whisperTurbo).isInstalled) { _ in store.refreshCaptionReadiness() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                store.refreshCaptionReadiness()
            }
        }
    }

    var hasAudio: Bool { !CaptionGenerator.sourceClips(store.project, .allTracks).isEmpty }

    @ViewBuilder var footer: some View {
        let ai = store.ai
        let blocker = store.captionBlocker
        VStack(spacing: 8) {
            // why the last run failed, else what would block the next one, each with its fix
            if let f = ai.captionFailure {
                SpeechFailureCard(store: store, failure: f, repeated: ai.captionFailureRepeated, testID: "captions.failure")
            } else if let b = blocker, ai.captionJob == nil {
                SpeechFailureCard(store: store, failure: b, repeated: false, testID: "captions.readiness", hidden: [.downloadSpeechModel])
            }
            if ai.captionJob != nil {
                let waiting = ai.captionPhase == .permission
                JobProgressLine(text: waiting ? tr("captions.phase.permission")
                                    : "\(tr(ai.captionPhase?.titleKey ?? "captions.phase.transcribing")) \(Int(ai.captionProgress * 100))%",
                                progress: ai.captionProgress) { store.cancelCaptions() }
            }
            HStack {
                if store.hasAutoCaptions {
                    CapCheckbox(isOn: Binding.perceived(get: { ai.replaceCaptions }, set: { ai.replaceCaptions = $0 }))
                    Text(loc: "captions.deleteCurrent").font(Theme.Fonts.row).foregroundStyle(IStyle.label)
                }
                Spacer()
                let titleKey = store.captionGenerateTitleKey
                Button(tr(titleKey)) {
                    if titleKey == "captions.generate" { store.generateCaptions() } else { store.performSpeechRemedy(.downloadSpeechModel) }
                }
                    .buttonStyle(AccentButtonStyle())
                    .testID("captions.generate")
                    .disabled(ai.captionJob != nil || !hasAudio || blocker == .appIncomplete)
                    .help(hasAudio ? "" : tr("captions.error.noAudio"))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Theme.panelHeader.opacity(0.6))
    }

    func label(_ key: String) -> some View {
        Text(loc: key).font(Theme.Fonts.sectionTitle).foregroundStyle(Theme.textPrimary)
    }

    // track selector: All tracks / Main track / each audio track with clips
    var sourceItems: [(id: String, title: String)] {
        var out: [(String, String)] = [("all", tr("captions.track.all")), ("main", tr("captions.track.main"))]
        var n = 0
        for t in store.project.timeline.tracks where t.kind == .audio && !t.clips.isEmpty {
            n += 1
            out.append(("t:\(t.id)", t.name ?? tr("captions.track.audio", n)))
        }
        return out
    }
    func sourceKey(_ s: CaptionOptions.Source) -> String {
        switch s { case .allTracks: return "all"; case .mainTrack: return "main"; case .track(let id): return "t:\(id)"; case .clip: return "all" }
    }
    func source(for k: String) -> CaptionOptions.Source {
        if k == "main" { return .mainTrack }
        if k.hasPrefix("t:"), let id = TrackID(string: String(k.dropFirst(2))) { return .track(id) }
        return .allTracks
    }
}

/// Speech engine status: whisper model installed / downloadable (with progress + cancel), Apple speech fallback.
/// "Advanced ▸" disclosure holding the speech engine / model card (Automatic stays the default; UX_GAPS W10-2).
struct AdvancedSpeechSection: View {
    let store: EditorStore
    @State private var open = false
    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 8) {
                Button { open.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                        Text(loc: "captions.advanced").font(Theme.Fonts.row)
                    }
                    .foregroundStyle(IStyle.label).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .testID("captions.advanced")
                if open { SpeechModelCard(store: store) }
            }
        }
    }
}

struct SpeechModelCard: View {
    let store: EditorStore
    var body: some View {
        WithPerceptionTracking {
            let mm = ModelManager.shared
            let spec = ModelCatalog.whisperTurbo
            let _ = mm.states
            let state = mm.state(spec)
            let runtime = WhisperRuntime.cliURL != nil
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: state.isInstalled && runtime ? "checkmark.seal.fill" : SFSymbolCompat.compat("waveform.badge.mic"))
                        .foregroundStyle(state.isInstalled && runtime ? Theme.accent : Theme.textSecondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(loc: "captions.engine").font(Theme.Fonts.row).foregroundStyle(IStyle.label)
                        Text(verbatim: engineLine(state, runtime)).font(Theme.Fonts.hint).foregroundStyle(IStyle.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                if state.isInstalled && !runtime && UpdateController.shared.isAvailable {
                    Button(tr("captions.remedy.checkForUpdates")) { UpdateController.shared.checkNow() }
                        .buttonStyle(ValseLinkButtonStyle()).font(Theme.Fonts.hint).testID("captions.engine.checkUpdates")
                }
                ModelStateControls(spec: spec)
                if state.isInstalled && runtime {
                    InlineRow(label: tr("captions.engineChoice")) {
                        Dropdown(items: SpeechEngine.allCases.map { ($0, tr($0.nameKey)) }, selection: store.ai.captionEngine) { store.ai.captionEngine = $0 }
                    }
                }
                Button(tr("models.manage")) { store.ai.isModelSheetPresented = true }.buttonStyle(ValseLinkButtonStyle()).font(Theme.Fonts.hint)
                    .testID("models.manage")
            }
            .padding(10)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    func engineLine(_ s: AIModelState, _ runtime: Bool) -> String {
        if s.isInstalled && runtime { return tr("captions.engine.whisper") }
        if s.isInstalled && !runtime { return tr("captions.engine.noRuntime") }
        // pre-flight said Apple speech can't do it here: the model is required, not just better
        if store.captionBlocker.map({ store.speechRemedies(for: $0).first == .downloadSpeechModel }) == true { return tr("captions.engine.needsModel") }
        return tr("captions.engine.apple")
    }
}

/// Download / progress / cancel / retry / import controls of one model (shared by panels and the manager sheet).
struct ModelStateControls: View {
    let spec: AIModelSpec
    var body: some View {
        WithPerceptionTracking {
            let mm = ModelManager.shared
            switch mm.state(spec) {
            case .notInstalled:
                HStack(spacing: 8) {
                    PillButton(title: tr("models.download", ByteCountFormatter.string(fromByteCount: spec.bytes, countStyle: .file)),
                               symbol: "arrow.down.circle", accent: true) { mm.download(spec) }
                        .testID("model.download.\(spec.id)")
                    Button(tr("models.locate")) { locate() }.buttonStyle(ValseLinkButtonStyle()).font(Theme.Fonts.hint)
                }
            case .downloading(let p):
                JobProgressLine(text: tr("models.downloading", Int(p * 100)), progress: p) { mm.cancel(spec) }
            case .verifying:
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text(loc: "models.verifying").font(Theme.Fonts.hint).foregroundStyle(IStyle.caption) }
            case .installed:
                EmptyView()
            case .failed(let msg):
                VStack(alignment: .leading, spacing: 6) {
                    HintText(text: msg, color: IStyle.warning)
                    PillButton(title: tr("models.retry"), symbol: "arrow.clockwise") { mm.download(spec) }
                }
            }
        }
    }

    func locate() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = spec.parts != nil   // multi-file models (.mlmodelc folders)
        panel.canChooseFiles = spec.parts == nil
        panel.message = tr("models.locateMessage", spec.fileName)
        if panel.runModal() == .OK, let u = panel.url { ModelManager.shared.importFile(u, as: spec) }
    }
}

/// Settings-like list of every on-device model with its state (UX: clear download / installed / error states).
struct ModelManagerSheet: View {
    let close: () -> Void
    var body: some View {
        WithPerceptionTracking {
            let mm = ModelManager.shared
            // BUG-OVERSIZED-SHEETS: an in-window modal (EditorView `.inWindowModal`) never taller than the window: title
            // pinned on top, the model list scrolls, Done pinned at the bottom.
            VStack(alignment: .leading, spacing: 0) {
                Text(loc: "models.title").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    .padding([.top, .horizontal], 20).padding(.bottom, 14)
                list(mm).padding(.horizontal, 20).scrollsWhenTight()
                HStack {
                    Spacer()
                    Button(tr("models.done"), action: close).buttonStyle(AccentButtonStyle())
                        .keyboardShortcut(.cancelAction).testID("models.done").reportsFit("modelsDone")
                }
                .padding(.top, 14).padding([.horizontal, .bottom], 20)
            }
            .fittedFrame(width: 460)
            .testID("models.sheet")
            .background(Theme.panel)
            .onAppear { mm.refresh() }
        }
    }

    private func list(_ mm: ModelManager) -> some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 14) {
                HintText(text: tr("models.privacy"))
                ForEach(ModelCatalog.all) { spec in
                    WithPerceptionTracking {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(loc: spec.nameKey).font(Theme.Fonts.sectionTitle).foregroundStyle(Theme.textPrimary)
                                Spacer()
                                Text(verbatim: ByteCountFormatter.string(fromByteCount: spec.bytes, countStyle: .file)).font(Theme.Fonts.hint).foregroundStyle(IStyle.caption)
                                if mm.state(spec).isInstalled {
                                    Label(tr("models.installed"), systemImage: "checkmark.circle.fill").font(Theme.Fonts.hint).foregroundStyle(Theme.accent)
                                    SmallIconButton(symbol: "trash", help: tr("models.remove")) { mm.remove(spec) }
                                }
                            }
                            HintText(text: tr(spec.descriptionKey) + " · " + tr("models.license", spec.license))
                            ModelStateControls(spec: spec)
                        }
                        .padding(10)
                        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                // nothing to say when the speech helper is there; otherwise say how to get it (no developer jargon)
                if WhisperRuntime.cliURL == nil {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(IStyle.warning)
                        VStack(alignment: .leading, spacing: 4) {
                            HintText(text: tr("models.runtimeMissing"))
                            if UpdateController.shared.isAvailable {
                                Button(tr("captions.remedy.checkForUpdates")) { UpdateController.shared.checkNow() }
                                    .buttonStyle(ValseLinkButtonStyle()).font(Theme.Fonts.hint).testID("models.checkUpdates")
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Hosts SwiftUI's `.translationTask` so the system can download a missing language pair (with its own consent
/// sheet), then translates every caption and applies the result as one undo step.
struct TranslationHost: View {
    let store: EditorStore
    var body: some View {
        WithPerceptionTracking {
            if #available(macOS 15.0, *), let req = store.ai.translationRequest {
                Color.clear.frame(width: 0, height: 0)
                    .translationTask(TranslationSession.Configuration(source: Locale.Language(identifier: req.source),
                                                                      target: Locale.Language(identifier: req.target))) { session in
                        let caps = store.captionTranslationItems()
                        do {
                            let map = try await CaptionTranslator.translate(caps, with: session)
                            store.applyTranslations(map, target: req.target)
                        } catch {
                            store.ai.translating = false
                            store.ai.translationRequest = nil
                            store.ai.translationSource = nil
                            store.showToast(tr("captions.translateFailed"), error: true)
                        }
                    }
            } else {
                Color.clear.frame(width: 0, height: 0)
            }
        }
    }
}
