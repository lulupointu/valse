import SwiftUI
import AppKit
import MontageCore
import MontageEngine
import MontageAI

/// Transcript-based editing (UX_AI §2, AI-019/020, TL-042/035, AU-027): replaces the asset panel. The transcript is
/// global (every main-track clip with sound, no selection needed — C4). Click a word to seek, select words (click,
/// ⇧-click range) and Delete → ripple cut; deleted words stay struck through (Show/Hide deleted) and Restore puts the
/// media back; pauses show as grey chips. "Remove filler words" is the main action (`TranscriptWorkspace`, shared with
/// Captions ▸ Filler words).
struct TranscriptPanel: View {
    let store: EditorStore

    struct Key: Hashable { let media: MediaID; let index: Int }

    var body: some View {
        let ai = store.ai
        Panel {
            HStack {
                Text(loc: "transcript.title").font(Theme.Fonts.panelTitle).foregroundStyle(Theme.textPrimary)
                Spacer()
                SmallIconButton(symbol: "xmark", help: tr("transcript.close")) { ai.transcriptOpen = false }.testID("transcript.close")
            }
            .padding(.horizontal, 12)
        } content: {
            TranscriptWorkspace(store: store, context: .panel)
        }
        .testID("transcript.panel")
    }
}

/// THE transcript / filler-review surface (C4): status (up to date / out of date · Update), spoken language,
/// "Remove filler words" with its scope and options, then the transcript text — or, while a review is open, the
/// checklist (style B) / the transcript with fillers highlighted to keep or drop (style C). Used by the Transcript
/// panel and by Captions ▸ Filler words so both entry points behave the same.
struct TranscriptWorkspace: View {
    enum Context { case panel, captions }
    let store: EditorStore
    let context: Context
    @State private var query = ""
    @State private var showDeleted = true

    var body: some View {
        let ai = store.ai
        let f = ai.fillers
        VStack(spacing: 0) {
            TranscriptStatusBar(store: store)
            FillerBar(store: store)
            if ai.transcripts.isEmpty {
                emptyHint
            } else if f.reviewing && f.style == .review {
                FillerChecklist(store: store)
            } else {
                textToolbar
                TranscriptText(store: store, query: query, showDeleted: showDeleted)
            }
            footer
        }
        .onAppear { store.loadCachedTranscripts() }
        .onChange(of: store.session.revision) { store.refreshFillerReview() }   // undo / edits during a review
        .testID(context == .panel ? "transcript.workspace" : "captions.fillers")
    }

    var hasMain: Bool { !(store.project.timeline.mainTrack?.clips.isEmpty ?? true) }

    @ViewBuilder var emptyHint: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.word.spacing").font(.system(size: 30)).foregroundStyle(Theme.textTertiary)
            Text(loc: "transcript.emptyTitle").font(Theme.Fonts.sectionTitle).foregroundStyle(Theme.textPrimary).multilineTextAlignment(.center)
            HintText(text: tr(hasMain ? "transcript.emptyHint" : "transcript.noMain")).multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var textToolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(IStyle.caption)
                TextField(tr("captions.find"), text: $query).textFieldStyle(.plain).font(Theme.Fonts.row)
            }
            .padding(.horizontal, 8).frame(height: 26).background(IStyle.field, in: RoundedRectangle(cornerRadius: 4))
            SmallIconButton(symbol: showDeleted ? "eye" : "eye.slash", help: tr(showDeleted ? "transcript.hideDeleted" : "transcript.showDeleted")) { showDeleted.toggle() }
                .testID("transcript.showDeleted")
            SmallIconButton(symbol: "arrow.clockwise", help: tr("transcript.retranscribe")) { store.transcribeMainTrack(force: true) }
                .testID("transcript.retranscribe")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    @ViewBuilder var footer: some View {
        let ai = store.ai
        let f = ai.fillers
        if f.reviewing {
            FillerReviewFooter(store: store)
        } else if !ai.transcripts.isEmpty {
            let words = TranscriptEditing.placedWords(transcripts: ai.transcripts, timeline: store.project.timeline)
            let selected = words.filter { ai.transcriptSelection.contains(TranscriptPanel.Key(media: $0.media, index: $0.index)) }
            let selectedDeleted = selected.filter(\.isDeleted)
            HStack(spacing: 8) {
                if !selected.isEmpty { Text(verbatim: tr("transcript.selected", selected.count)).font(Theme.Fonts.hint).foregroundStyle(IStyle.caption) }
                Spacer()
                if !selectedDeleted.isEmpty {
                    PillButton(title: tr("transcript.restore"), symbol: "arrow.uturn.backward") { store.restoreTranscriptWords(selectedDeleted) }
                }
                PillButton(title: tr("transcript.delete"), symbol: "delete.left", enabled: selected.count > selectedDeleted.count) {
                    store.deleteTranscriptWords(selected)
                }
                .testID("transcript.delete")
                if context == .panel {
                    PillButton(title: tr("captions.generate"), symbol: "captions.bubble") { store.ai.captionSource = .mainTrack; store.generateCaptions() }
                }
            }
            .padding(10)
            .background(Theme.panelHeader.opacity(0.6))
            .background(KeyCatcher { store.deleteTranscriptWords(selected.filter { !$0.isDeleted }) })
        }
    }
}

/// "Up to date · French" / "Out of date — timeline changed · Update" / progress, and the spoken language.
/// Its own view so transcription progress re-renders only this bar (the language menu stays usable meanwhile).
struct TranscriptStatusBar: View {
    let store: EditorStore
    var body: some View {
        let ai = store.ai
        let status = store.transcriptStatus
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                switch status {
                case .transcribing:
                    TranscriptProgress(store: store)
                case .upToDate:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent).font(.system(size: 12))
                    Text(verbatim: store.transcriptLanguage.map { tr("transcript.status.upToDateLang", CaptionLanguages.title($0)) } ?? tr("transcript.status.upToDate"))
                        .font(Theme.Fonts.hint).foregroundStyle(Theme.textSecondary).lineLimit(1)
                case .stale(_, let lang):
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(IStyle.warning).font(.system(size: 12))
                    Text(verbatim: tr(lang ? "transcript.status.staleLanguage" : "transcript.status.stale"))
                        .font(Theme.Fonts.hint).foregroundStyle(IStyle.warning).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Button(tr("transcript.update")) { store.updateTranscript() }.buttonStyle(.link).font(Theme.Fonts.hint).testID("transcript.update")
                case .none:
                    Text(loc: "transcript.status.none").font(Theme.Fonts.hint).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    Button(tr("transcript.transcribe")) { store.transcribeMainTrack() }.buttonStyle(.link).font(Theme.Fonts.hint).testID("transcript.transcribe")
                case .noMedia:
                    Text(loc: "transcript.status.noMedia").font(Theme.Fonts.hint).foregroundStyle(Theme.textSecondary).lineLimit(2)
                }
                if status != .transcribing { Spacer(minLength: 4) }
                Dropdown(items: [(Optional<String>.none, autoTitle)] + CaptionLanguages.codes.map { (Optional($0), CaptionLanguages.title($0)) },
                         selection: ai.captionLanguage) { store.setTranscriptLanguage($0) }
                    .frame(width: 150)
                    .help(tr("captions.spokenLanguage"))
                    .testID("transcript.language")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Theme.inset.opacity(0.5))
        .testID("transcript.status")
    }

    /// "Auto detect (French)" once a language was detected.
    var autoTitle: String {
        if store.ai.captionLanguage == nil, let l = store.transcriptLanguage { return tr("transcript.autoDetected", CaptionLanguages.title(l)) }
        return tr("captions.autoDetect")
    }
}

/// Transcription progress line (isolated: the only view reading `transcriptProgress`).
struct TranscriptProgress: View {
    let store: EditorStore
    var body: some View {
        let p = store.ai.transcriptProgress
        JobProgressLine(text: tr("transcript.progress", Int(p * 100)), progress: p) { store.cancelTranscript() }
            .frame(maxWidth: .infinity)
    }
}

/// The transcript as flowing words + pause chips. Filler words are tinted; while an inline review (style C) is open the
/// candidates are highlighted and a click keeps / drops them.
struct TranscriptText: View {
    let store: EditorStore
    let query: String
    let showDeleted: Bool

    var body: some View {
        let ai = store.ai
        let f = ai.fillers
        let tl = store.project.timeline
        let words = TranscriptEditing.placedWords(transcripts: ai.transcripts, timeline: tl)
        let inline = f.reviewing && f.style == .inline
        let wordCands = inline ? Dictionary(f.candidates.filter { $0.kind != .pause }.map { ($0.anchor, $0) }, uniquingKeysWith: { a, _ in a }) : [:]
        let pauseList = inline ? f.candidates.filter { $0.kind == .pause }
            : FillerCleanup.pauses(words: words, transcripts: ai.transcripts, timeline: tl,
                                   options: FillerCleanup.Options(minPause: ai.minPause))
        let pausesBefore = Dictionary(grouping: pauseList, by: \.anchor)
        let playhead = store.transport.playhead
        let current = words.lastIndex { !$0.isDeleted && $0.time <= playhead }
        ScrollView {
            FlowLayout(spacing: 3, lineSpacing: 6) {
                ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                    ForEach(pausesBefore[i] ?? [], id: \.id) { p in pauseChip(p, inline: inline) }
                    if showDeleted || !w.isDeleted {
                        if let c = wordCands[i] {
                            FillerWordChip(text: w.word.text, dropped: f.dropped.contains(c.id), kind: c.kind) { store.toggleFiller(c.id) }
                                .testID("fillers.word.\(i)")
                        } else {
                            WordChip(word: w, selected: ai.transcriptSelection.contains(TranscriptPanel.Key(media: w.media, index: w.index)),
                                     current: i == current, hit: matches(w)) { shift in click(i, words, shift: shift) }
                        }
                    }
                }
                ForEach(pausesBefore[words.count] ?? [], id: \.id) { p in pauseChip(p, inline: inline) }
            }
            .padding(12)
        }
        .testID("transcript.text")
    }

    @ViewBuilder func pauseChip(_ p: FillerCleanup.Candidate, inline: Bool) -> some View {
        if inline {
            FillerPauseChip(seconds: p.seconds, dropped: store.ai.fillers.dropped.contains(p.id)) { store.toggleFiller(p.id) }
                .testID("fillers.pause.\(p.anchor)")
        } else {
            PauseChip(seconds: p.seconds).onTapGesture { store.seek(to: p.range.start) }
        }
    }

    func matches(_ w: TranscriptEditing.PlacedWord) -> Bool {
        !query.isEmpty && w.word.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    func click(_ i: Int, _ words: [TranscriptEditing.PlacedWord], shift: Bool) {
        let ai = store.ai
        let w = words[i]
        let key = TranscriptPanel.Key(media: w.media, index: w.index)
        if shift, let anchor = ai.transcriptAnchor, let a = words.firstIndex(where: { TranscriptPanel.Key(media: $0.media, index: $0.index) == anchor }) {
            ai.transcriptSelection = Set(words[min(a, i)...max(a, i)].map { TranscriptPanel.Key(media: $0.media, index: $0.index) })
        } else {
            ai.transcriptSelection = [key]
            ai.transcriptAnchor = key
            if !w.isDeleted { store.seek(to: w.time) }
        }
    }
}

struct WordChip: View {
    let word: TranscriptEditing.PlacedWord
    let selected: Bool
    let current: Bool
    let hit: Bool
    let click: (Bool) -> Void
    var body: some View {
        Text(verbatim: word.word.text)
            .font(.system(size: 13))
            .strikethrough(word.isDeleted, color: Theme.textTertiary)
            .foregroundStyle(word.isDeleted ? Theme.textTertiary : (word.filler != nil ? IStyle.warning : Theme.textPrimary))
            .padding(.horizontal, 2).padding(.vertical, 1)
            .background(selected ? Theme.accentDim : (current ? Theme.accent.opacity(0.25) : (hit ? IStyle.warning.opacity(0.25) : .clear)),
                        in: RoundedRectangle(cornerRadius: 3))
            .contentShape(Rectangle())
            .onTapGesture { click(NSEvent.modifierFlags.contains(.shift)) }
            .help(word.filler.map { tr("transcript.kind.\($0.rawValue)") } ?? "")
    }
}

struct PauseChip: View {
    let seconds: Double
    var body: some View {
        Text(verbatim: String(format: "%.2fs", seconds)).font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 5).frame(height: 16).background(Theme.buttonSecondary, in: Capsule())
    }
}

/// Wrapping layout (words flow like text).
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0, x + sz.width > w { x = 0; y += line + lineSpacing; line = 0 }
            x += sz.width + spacing; line = max(line, sz.height)
        }
        return CGSize(width: w, height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + sz.width > bounds.maxX { x = bounds.minX; y += line + lineSpacing; line = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing; line = max(line, sz.height)
        }
    }
}

/// ⌫ / ⌦ in the transcript deletes the selected words.
struct KeyCatcher: NSViewRepresentable {
    let onDelete: () -> Void
    func makeNSView(context: Context) -> NSView { let v = KeyView(); v.onDelete = onDelete; return v }
    func updateNSView(_ v: NSView, context: Context) { (v as? KeyView)?.onDelete = onDelete }
    final class KeyView: NSView {
        var onDelete: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func mouseDown(with e: NSEvent) { window?.makeFirstResponder(self); super.mouseDown(with: e) }
        override func keyDown(with e: NSEvent) {
            if e.keyCode == 51 || e.keyCode == 117 { onDelete?() } else { super.keyDown(with: e) }
        }
    }
}

extension EditorStore {
    /// Fills in cached transcripts of main-track media that have none yet (instant, no job).
    func loadCachedTranscripts() {
        for a in mainTrackMedia() where ai.transcripts[a.id] == nil {
            if let t = TranscriptStore.shared.latest(hash: a.contentHash) { ai.transcripts[a.id] = t }
        }
    }

    func mainTrackMedia() -> [MediaAsset] {
        var seen = Set<MediaID>()
        return (project.timeline.mainTrack?.clips ?? []).compactMap { c in
            guard let id = c.mediaID, seen.insert(id).inserted, let a = project.asset(id), a.hasAudio else { return nil }
            return a
        }
    }

    /// Transcribes main-track media (whole files, cached) — "Transcribe", "Update" (`onlyMissing`: incremental, only the
    /// media without a transcript) and "Re-transcribe" (`force`). Results are merged into `ai.transcripts`; a pending
    /// "Remove filler words" continues when it finishes.
    public func transcribeMainTrack(force: Bool = false, onlyMissing: Bool = false) {
        guard ai.transcriptJob == nil else { return }
        let all = mainTrackMedia()
        let assets = onlyMissing ? all.filter { ai.transcripts[$0.id] == nil } : all
        guard !assets.isEmpty else {
            if all.isEmpty { showToast(tr("transcript.noMain"), error: true) }
            if ai.fillers.pendingRemove { startFillerRemoval() }
            return
        }
        let lang = ai.captionLanguage, engine = ai.captionEngine
        let box = TranscriptBox()
        ai.transcriptProgress = 0
        let gate = ProgressGate()
        Task {
            let id = await JobQueue.shared.enqueue(titleKey: "transcript.job", priority: 1) { [weak self] progress in
                for (i, a) in assets.enumerated() {
                    try Task.checkCancellation()
                    let key = TranscriptStore.key(hash: a.contentHash, range: nil, language: lang, engine: engine, fillers: true)
                    if !force, let t = TranscriptStore.shared.get(key) { box.add(a.id, t); continue }
                    let wav = try await AudioExtractor.wav16k(a.url, range: nil)
                    defer { try? FileManager.default.removeItem(at: wav) }
                    let t = try await Transcriber.transcribe(wav: wav, request: .init(language: lang, engine: engine, keepFillers: true)) { f in
                        let p = (Double(i) + f) / Double(assets.count)
                        progress.report(p)
                        // ≤ 1 UI update per percent (a flood of re-renders kept menus from opening — C4)
                        if gate.pass(p) { Task { @MainActor in self?.ai.transcriptProgress = p } }
                    }
                    TranscriptStore.shared.put(t, key)
                    box.add(a.id, t)
                }
            }
            ai.transcriptJob = id
            let st = await JobQueue.shared.wait(id)
            ai.transcriptJob = nil
            if st == .done {
                for (k, v) in box.all { ai.transcripts[k] = v }
                if ai.transcripts.values.allSatisfy({ $0.words.isEmpty }) { showToast(tr("ai.error.noSpeech"), error: true); ai.fillers.pendingRemove = false }
                else if ai.fillers.pendingRemove { startFillerRemoval() }
            } else {
                ai.fillers.pendingRemove = false
                if case .failed = st { showToast(tr("captions.error.failed"), error: true) }
            }
        }
    }

    public func cancelTranscript() {
        ai.fillers.pendingRemove = false
        if let id = ai.transcriptJob { Task { await JobQueue.shared.cancel(id) } }
    }

    public func deleteTranscriptWords(_ words: [TranscriptEditing.PlacedWord]) {
        let live = words.filter { !$0.isDeleted }
        guard !live.isEmpty else { return }
        if perform(Edit("cmd.transcriptDelete") { p in try TranscriptEditing.deleteWords(live, in: &p) }) {
            ai.transcriptSelection = []
        }
    }

    public func restoreTranscriptWords(_ words: [TranscriptEditing.PlacedWord]) {
        if perform(Edit("cmd.transcriptRestore") { p in try TranscriptEditing.restore(words, in: &p) }) { ai.transcriptSelection = [] }
    }
}

nonisolated final class TranscriptBox: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [MediaID: Transcript] = [:]
    func add(_ id: MediaID, _ t: Transcript) { lock.withLock { map[id] = t } }
    var all: [MediaID: Transcript] { lock.withLock { map } }
}

/// Lets a progress value through when it moved by ≥ 1 % (thread-safe).
nonisolated final class ProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1.0
    func pass(_ p: Double) -> Bool { lock.withLock { if p - last >= 0.01 || p >= 1 { last = p; return true }; return false } }
}
