import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NaturalLanguage
import MontageCore
import MontageAI
import MontageEngine
import Perception

/// Language names and properties for the caption editor (CAP-LANG-TRACKS). Names, never codes.
extension CaptionLanguages {
    /// Languages offered by "+ Add" / "Change language…" (searchable list).
    static let all: [String] = [
        "fr", "en", "es", "de", "it", "pt", "nl", "ja", "zh", "ko", "ar", "he", "ru", "uk", "pl", "cs", "sk", "ro", "hu",
        "el", "tr", "sv", "da", "no", "fi", "is", "ca", "eu", "gl", "hr", "sr", "sl", "bg", "lt", "lv", "et", "hi", "bn",
        "ur", "fa", "th", "vi", "id", "ms", "tl", "sw", "ta", "te", "mr", "pa", "gu",
    ]

    /// "Français" (in the UI language); nil / unknown → "Captions".
    static func name(_ code: String?) -> String {
        guard let code, code != "und" else { return tr("capedit.lang.unknown") }
        let ui = Locale(identifier: L10n.shared.language)
        let n = ui.localizedString(forIdentifier: code) ?? ui.localizedString(forLanguageCode: code) ?? code
        return n.prefix(1).uppercased() + n.dropFirst()
    }

    /// The name inside a sentence ("Search in French", "Rechercher en français": lower case in French).
    static func inSentence(_ code: String?) -> String {
        let n = name(code)
        return L10n.shared.language == "en" ? n : n.lowercased()
    }

    /// Search label in the + Add list: "Anglais · English".
    static func searchTitle(_ code: String) -> String { title(code) }

    static func isRightToLeft(_ code: String?) -> Bool {
        guard let code else { return false }
        return Locale.characterDirection(forLanguage: code) == .rightToLeft
    }

    /// A language whose captions are all empty (added "Empty, same timing" and not typed yet).
    static func isEmptyLanguage(_ t: Track) -> Bool {
        !t.clips.isEmpty && t.clips.allSatisfy { (CaptionOps.text($0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Dominant language of a text (NLLanguageRecognizer), nil when unsure.
    nonisolated static func detect(_ text: String) -> String? {
        guard text.count >= 3 else { return nil }
        let r = NLLanguageRecognizer()
        r.processString(text)
        return r.dominantLanguage?.rawValue
    }
}

/// How "+ Add" fills the new language.
enum CaptionAddMode: String, CaseIterable { case translate, empty, generate, importFile }

// MARK: - + Add language

struct CaptionAddLanguageButton: View {
    let store: EditorStore
    let track: Track

    var body: some View {
        WithPerceptionTracking {
            let ed = store.captionEditor
            Button { ed.showAddLanguage.toggle() } label: {
                HStack(spacing: 3) {
                    Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                    Text(loc: "capedit.lang.add").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 10).frame(height: 24)
                .overlay(Capsule().stroke(Theme.separator, lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(tr("capedit.lang.addTitle"))
            .testID("captions.lang.add")
        }
    }
}

struct CaptionAddLanguageCard: View {
    let store: EditorStore
    let sourceTrack: Track
    @State private var query = ""
    @State private var code: String?
    @State private var mode: CaptionAddMode = .translate

    var body: some View {
        WithPerceptionTracking {
            let source = CaptionLanguages.inSentence(sourceTrack.captionLanguage)
            let used = Set(CaptionOps.captionTracks(store.project.timeline).compactMap { store.project.timeline.tracks[$0].captionLanguage })
            let q = query.lowercased()
            let codes = CaptionLanguages.all.filter { !used.contains($0) && (q.isEmpty || CaptionLanguages.searchTitle($0).lowercased().contains(q)) }
            VStack(alignment: .leading, spacing: 10) {
                Text(loc: "capedit.lang.addTitle").font(Theme.Fonts.sectionTitle).foregroundStyle(Theme.textPrimary)
                TextField(tr("capedit.lang.search"), text: $query).textFieldStyle(.plain).font(.system(size: 12))
                    .padding(.horizontal, 8).frame(height: 26).background(IStyle.field, in: RoundedRectangle(cornerRadius: 4))
                    .testID("captions.lang.search")
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(codes, id: \.self) { c in
                            WithPerceptionTracking {
                                Button { code = c } label: {
                                    Text(verbatim: CaptionLanguages.searchTitle(c)).font(Theme.Fonts.row)
                                        .foregroundStyle(code == c ? Theme.onAccent : Theme.textPrimary)
                                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).frame(height: 24)
                                        .background(code == c ? Theme.accent : .clear, in: RoundedRectangle(cornerRadius: 4))
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .testID("captions.lang.option.\(c)")
                            }
                        }
                    }
                }
                .frame(height: 160)
                VStack(alignment: .leading, spacing: 4) {
                    modeRow(.translate, tr("capedit.lang.translateFrom", source))
                    modeRow(.empty, tr("capedit.lang.emptySameTiming", source))
                    modeRow(.generate, tr("capedit.lang.generate"))
                    modeRow(.importFile, tr("capedit.lang.import"))
                }
                HStack {
                    Spacer()
                    PillButton(title: tr("capedit.cancel")) { store.captionEditor.showAddLanguage = false }
                    PillButton(title: tr("capedit.lang.addAction"), accent: true, enabled: code != nil) {
                        guard let code else { return }
                        store.captionEditor.showAddLanguage = false
                        store.captionAddLanguage(code, mode: mode, from: sourceTrack.id)
                    }
                    .testID("captions.lang.confirm")
                }
            }
            .padding(12)
            .background(Theme.Valse.raised, in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 12).padding(.bottom, 8)
            .testID("captions.lang.card")
        }
    }

    func modeRow(_ m: CaptionAddMode, _ title: String) -> some View {
        Button { mode = m } label: {
            HStack(spacing: 8) {
                ZStack {
                    Circle().stroke(mode == m ? Theme.accent : IStyle.iconDim, lineWidth: 1.5).frame(width: 13, height: 13)
                    if mode == m { Circle().fill(Theme.accent).frame(width: 7, height: 7) }
                }
                Text(verbatim: title).font(Theme.Fonts.row).foregroundStyle(Theme.textPrimary)
                Spacer()
            }
            .frame(height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .testID("captions.lang.mode.\(m.rawValue)")
    }
}

// MARK: - Store: language tracks

extension EditorStore {
    func captionSelectLanguage(_ id: TrackID) {
        endCaptionTyping()
        captionEditor.activeTrackID = id
        captionEditor.confirmDeleteAll = false
        if let s = selection.first, selection.count == 1, project.timeline.locate(s).map({ project.timeline.tracks[$0.track].id }) != id {
            captionEditor.selectingFromEditor = true
            selection = []
            captionEditor.selectingFromEditor = false
        }
    }

    /// Shown in video = the track's visibility (several languages may show at once).
    func captionSetShown(_ id: TrackID, _ shown: Bool) {
        perform(Edit("cmd.captionShown") { p in
            guard let i = p.timeline.trackIndex(id) else { throw EditError.clipNotFound }
            p.timeline.tracks[i].isHidden = !shown
        })
    }

    func captionSetLanguage(_ id: TrackID, _ code: String) {
        perform(Edit("cmd.captionLanguage") { p in
            guard let i = p.timeline.trackIndex(id) else { throw EditError.clipNotFound }
            p.timeline.tracks[i].captionLanguage = CaptionLanguageTracks.normalized(code)
        })
    }

    /// 🗑 Delete all [language] captions (after the inline confirmation): one undo step + toast with Undo.
    func captionDeleteLanguage(_ id: TrackID) {
        endCaptionTyping()
        let tl = project.timeline
        guard let i = tl.trackIndex(id) else { return }
        let name = CaptionLanguages.inSentence(tl.tracks[i].captionLanguage), n = tl.tracks[i].clips.count
        guard perform(Edit("cmd.captionDeleteAll") { p in try CaptionOps.deleteAll(trackID: id, in: &p) }) else { return }
        if captionEditor.activeTrackID == id { captionEditor.activeTrackID = nil }
        selection = []
        showToast(tr("capedit.deleteAll.done", n, name), actionTitle: tr("capedit.undo")) { [weak self] in self?.undo() }
    }

    /// + Add ▸ a new language tab (active at once). Translated / empty languages start hidden in the video (toast with
    /// "Show").
    func captionAddLanguage(_ code: String, mode: CaptionAddMode, from source: TrackID) {
        endCaptionTyping()
        switch mode {
        case .empty:
            captionCreateLanguageTrack(code, from: source, texts: [:], hidden: true)
        case .translate:
            captionTranslate(from: source, to: code, hidden: true)
        case .generate:
            openAutoCaptions(language: code)
        case .importFile:
            chooseCaptionFileToImport(language: code)
        }
    }

    @discardableResult
    func captionCreateLanguageTrack(_ code: String, from source: TrackID, texts: [ClipID: String], hidden: Bool) -> TrackID? {
        let box = UncheckedSendableBox<TrackID?>(nil)
        let ok = perform(Edit("cmd.captionAddLanguage") { p in
            box.value = try CaptionLanguageTracks.addLanguage(from: source, language: code, texts: texts, hidden: hidden, stacked: true, in: &p)
        })
        guard ok, let id = box.value else { return nil }
        captionEditor.activeTrackID = id
        selection = []
        let name = CaptionLanguages.inSentence(code)
        if hidden {
            showToast(tr("capedit.lang.addedHidden", name), actionTitle: tr("capedit.lang.show")) { [weak self] in self?.captionSetShown(id, true) }
        } else {
            showToast(tr("capedit.lang.added", name))
        }
        return id
    }

    /// Translates the source track's captions on device into a new language track (Apple Translation; a missing pair
    /// goes through the system download prompt, `TranslationHost`).
    func captionTranslate(from source: TrackID, to target: String, hidden: Bool) {
        guard let si = project.timeline.trackIndex(source) else { return }
        let track = project.timeline.tracks[si]
        let from = track.captionLanguage ?? captionLanguage
        guard CaptionLanguageTracks.normalized(from) != CaptionLanguageTracks.normalized(target) else {
            showToast(tr("captions.sameLanguage"), error: true); return
        }
        let items = track.clips.map { ($0.id, CaptionOps.text($0)?.string ?? "") }
        ai.translating = true
        ai.translationSource = TranslationSource(trackID: source, hidden: hidden)
        Task {
            switch await CaptionTranslator.status(from: from, to: target) {
            case .installed:
                do {
                    let map = try await CaptionTranslator.translate(items, from: from, to: target)
                    applyTranslations(map, target: target)
                } catch {
                    ai.translationRequest = TranslationRequest(source: from, target: target, display: .both)
                }
            case .needsDownload:
                ai.translationRequest = TranslationRequest(source: from, target: target, display: .both)
            case .unsupported:
                ai.translating = false
                ai.translationSource = nil
                showToast(tr("captions.translateUnsupported"), error: true)
            }
        }
    }

    /// Captions the pending translation translates (`TranslationHost`).
    func captionTranslationItems() -> [(ClipID, String)] {
        guard let s = ai.translationSource, let i = project.timeline.trackIndex(s.trackID) else { return [] }
        return project.timeline.tracks[i].clips.map { ($0.id, CaptionOps.text($0)?.string ?? "") }
    }

    /// A translation finished: the new language track (same timing).
    func applyTranslations(_ map: [ClipID: String], target: String) {
        ai.translating = false
        ai.translationRequest = nil
        let src = ai.translationSource
        ai.translationSource = nil
        guard !map.isEmpty, let src else { return }
        captionCreateLanguageTrack(target, from: src.trackID, texts: map, hidden: src.hidden)
    }

    /// Generate from speech: the Captions asset tab ▸ Auto captions with the language preselected.
    func openAutoCaptions(language: String?) {
        if let language { ai.captionLanguage = CaptionLanguageTracks.normalized(language).map { String($0.prefix(2)) } }
        CaptionsTabState.shared.nav = "auto"
        activeAssetTab = "captions"
    }

    /// Type a script: Captions ▸ Local captions (Enter scripts).
    func openScriptCaptions() {
        CaptionsTabState.shared.nav = "local"
        activeAssetTab = "captions"
    }

    // MARK: Export

    /// Export ▾ ▸ format: the active language, file `<project>.<lang>.<ext>`.
    func captionExport(format: CaptionFormat) {
        CaptionExportPrefs.lastFormat = format
        let lang = captionEditorTrackIndex.flatMap { project.timeline.tracks[$0].captionLanguage }
        let p = NSSavePanel()
        p.allowedContentTypes = UTType(filenameExtension: format.fileExtension).map { [$0] } ?? []
        p.nameFieldStringValue = [projectName, lang, format.fileExtension].compactMap { $0 }.joined(separator: ".")
        p.begin { [weak self] r in
            guard r == .OK, let url = p.url else { return }
            Task { @MainActor in self?.exportCaptions(format: format, to: url) }
        }
    }

    /// Export ▾ ▸ All languages…: a folder, one file per language in the last used format.
    func captionExportAllLanguages() {
        let format = CaptionExportPrefs.lastFormat
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.prompt = tr("capedit.export")
        p.begin { [weak self] r in
            guard r == .OK, let dir = p.url else { return }
            Task { @MainActor in self?.exportAllCaptionLanguages(format: format, to: dir) }
        }
    }

    /// Writes one file per caption track into `dir`. Returns the written URLs (tests).
    @discardableResult
    func exportAllCaptionLanguages(format: CaptionFormat, to dir: URL) -> [URL] {
        let tl = project.timeline
        var out: [URL] = []
        for (n, ti) in CaptionOps.captionTracks(tl).enumerated() {
            let t = tl.tracks[ti]
            let segs = CaptionOps.segments(of: t)
            guard !segs.isEmpty else { continue }
            let lang = t.captionLanguage ?? "\(n + 1)"
            let url = dir.appendingPathComponent("\(projectName).\(lang).\(format.fileExtension)")
            let text = CaptionFiles.serialize(segs, format: format, style: t.clips.first.flatMap(CaptionOps.text), canvas: project.settings.canvasSize)
            if (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil { out.append(url) }
        }
        showToast(out.isEmpty ? tr("captions.export.failed") : tr("captions.export.done"), error: out.isEmpty)
        return out
    }

    // MARK: Opening a project

    /// CAP-LANG-TRACKS: languages detected, bilingual sub-lines moved to their own tracks (no undo step: it is how the
    /// project opens).
    static func captionLanguagesMigrated(_ p: Project) -> Project {
        var q = p
        CaptionLanguageTracks.migrate(&q, detect: CaptionLanguages.detect)
        return q
    }
}

/// Which track a pending translation reads and whether its result starts hidden.
public struct TranslationSource: Equatable, Sendable {
    let trackID: TrackID
    let hidden: Bool
}
