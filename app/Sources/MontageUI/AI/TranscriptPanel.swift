import SwiftUI
import AppKit
import MontageCore
import MontageEngine
import MontageAI

/// Transcript-based editing (UX_AI §2, AI-019/020, TL-042/035, AU-027): replaces the asset panel. Transcribe the main
/// track, click a word to seek, select words (click, ⇧-click range) and Delete → ripple cut; deleted words stay struck
/// through (Show/Hide deleted) and Restore puts the media back; pauses show as grey chips; Remove filler words deletes
/// pauses / hesitations / repetitions in one step.
struct TranscriptPanel: View {
    let store: EditorStore
    @State private var query = ""
    @State private var showDeleted = true
    @State private var showCleanup = false

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
            if ai.transcripts.isEmpty || ai.transcriptJob != nil { empty } else { editor }
        }
        .onAppear { store.loadCachedTranscripts() }
        .testID("transcript.panel")
    }

    var hasMain: Bool { !(store.project.timeline.mainTrack?.clips.isEmpty ?? true) }

    @ViewBuilder var empty: some View {
        let ai = store.ai
        VStack(spacing: 14) {
            Image(systemName: "text.word.spacing").font(.system(size: 30)).foregroundStyle(Theme.textTertiary)
            Text(loc: "transcript.emptyTitle").font(Theme.Fonts.sectionTitle).foregroundStyle(Theme.textPrimary)
            HintText(text: tr(hasMain ? "transcript.emptyHint" : "transcript.noMain")).multilineTextAlignment(.center)
            Dropdown(items: [(Optional<String>.none, tr("captions.autoDetect"))] + CaptionLanguages.codes.map { (Optional($0), CaptionLanguages.title($0)) },
                     selection: ai.captionLanguage) { ai.captionLanguage = $0 }
                .frame(width: 220)
            if ai.transcriptJob != nil {
                JobProgressLine(text: tr("transcript.progress", Int(ai.transcriptProgress * 100)), progress: ai.transcriptProgress) { store.cancelTranscript() }
                    .frame(width: 260)
            } else {
                Button(tr("transcript.transcribe")) { store.transcribeMainTrack() }.buttonStyle(AccentButtonStyle()).disabled(!hasMain)
                    .testID("transcript.transcribe")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder var editor: some View {
        let ai = store.ai
        let words = TranscriptEditing.placedWords(transcripts: ai.transcripts, timeline: store.project.timeline)
        let pauses = Dictionary(TranscriptEditing.pauses(words, minimum: ai.minPause).map { ($0.after, $0.seconds) }, uniquingKeysWith: { a, _ in a })
        let playhead = store.transport.playhead
        let current = words.lastIndex { !$0.isDeleted && $0.time <= playhead }
        let selectedDeleted = words.filter { ai.transcriptSelection.contains(Key(media: $0.media, index: $0.index)) && $0.isDeleted }
        VStack(spacing: 0) {
            // toolbar: search, show deleted, clean up
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(IStyle.caption)
                    TextField(tr("captions.find"), text: $query).textFieldStyle(.plain).font(Theme.Fonts.row)
                    if !query.isEmpty {
                        Text(verbatim: tr("captions.results", words.filter { matches($0) }.count)).font(Theme.Fonts.hint).foregroundStyle(IStyle.caption)
                    }
                }
                .padding(.horizontal, 8).frame(height: 26).background(IStyle.field, in: RoundedRectangle(cornerRadius: 4))
                SmallIconButton(symbol: showDeleted ? "eye" : "eye.slash", help: tr(showDeleted ? "transcript.hideDeleted" : "transcript.showDeleted")) { showDeleted.toggle() }
                SmallIconButton(symbol: "wand.and.stars", help: tr("transcript.removeFillers"), active: showCleanup) { showCleanup.toggle() }
                SmallIconButton(symbol: "arrow.clockwise", help: tr("transcript.retranscribe")) { store.transcribeMainTrack(force: true) }
            }
            .padding(10)
            if showCleanup { cleanup(words) }
            ScrollView {
                FlowLayout(spacing: 3, lineSpacing: 6) {
                    ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                        if showDeleted || !w.isDeleted {
                            WordChip(word: w, selected: ai.transcriptSelection.contains(Key(media: w.media, index: w.index)),
                                     current: i == current, hit: matches(w)) { shift in click(i, words, shift: shift) }
                        }
                        if let p = pauses[i] { PauseChip(seconds: p) }
                    }
                }
                .padding(12)
            }
            // action bar
            HStack(spacing: 8) {
                let n = ai.transcriptSelection.count
                if n > 0 { Text(verbatim: tr("transcript.selected", n)).font(Theme.Fonts.hint).foregroundStyle(IStyle.caption) }
                Spacer()
                if !selectedDeleted.isEmpty {
                    PillButton(title: tr("transcript.restore"), symbol: "arrow.uturn.backward") { store.restoreTranscriptWords(selectedDeleted) }
                }
                PillButton(title: tr("transcript.delete"), symbol: "delete.left", enabled: n > selectedDeleted.count) {
                    store.deleteTranscriptWords(words.filter { ai.transcriptSelection.contains(Key(media: $0.media, index: $0.index)) })
                }
                PillButton(title: tr("captions.generate"), symbol: "captions.bubble") { store.ai.captionSource = .mainTrack; store.generateCaptions() }
            }
            .padding(10)
            .background(Theme.panelHeader.opacity(0.6))
        }
        .background(KeyCatcher { store.deleteTranscriptWords(words.filter { ai.transcriptSelection.contains(Key(media: $0.media, index: $0.index)) && !$0.isDeleted }) })
    }

    func matches(_ w: TranscriptEditing.PlacedWord) -> Bool {
        !query.isEmpty && w.word.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    func click(_ i: Int, _ words: [TranscriptEditing.PlacedWord], shift: Bool) {
        let ai = store.ai
        let w = words[i]
        let key = Key(media: w.media, index: w.index)
        if shift, let anchor = ai.transcriptAnchor, let a = words.firstIndex(where: { Key(media: $0.media, index: $0.index) == anchor }) {
            ai.transcriptSelection = Set(words[min(a, i)...max(a, i)].map { Key(media: $0.media, index: $0.index) })
        } else {
            ai.transcriptSelection = [key]
            ai.transcriptAnchor = key
            if !w.isDeleted { store.seek(to: w.time) }
        }
    }

    @ViewBuilder func cleanup(_ words: [TranscriptEditing.PlacedWord]) -> some View {
        let ai = store.ai
        let kept = words.filter { !$0.isDeleted }
        let fillers = kept.filter { w in w.filler.map { ai.cleanupKinds.contains($0) } ?? false }
        let pauses = ai.cleanupPauses ? TranscriptEditing.pauses(words, minimum: ai.minPause) : []
        VStack(alignment: .leading, spacing: 8) {
            Text(loc: "transcript.removeFillers").font(Theme.Fonts.sectionTitle).foregroundStyle(Theme.textPrimary)
            HStack(spacing: 14) {
                check("transcript.kind.pause", Binding(get: { ai.cleanupPauses }, set: { ai.cleanupPauses = $0 }))
                ForEach([FillerWords.Kind.hesitation, .filler, .repetition], id: \.self) { k in
                    check("transcript.kind.\(k.rawValue)", Binding(get: { ai.cleanupKinds.contains(k) },
                                                                   set: { on in if on { ai.cleanupKinds.insert(k) } else { ai.cleanupKinds.remove(k) } }))
                }
            }
            HStack {
                Text(loc: "transcript.minPause").font(Theme.Fonts.row).foregroundStyle(IStyle.label)
                Stepper(value: Binding(get: { ai.minPause }, set: { ai.minPause = $0 }), in: 0.2...5, step: 0.1) {
                    Text(verbatim: String(format: "%.1fs", ai.minPause)).font(Theme.Fonts.numeric).foregroundStyle(Theme.textPrimary)
                }
                Spacer()
                let total = fillers.count + pauses.count
                if total == 0 { HintText(text: tr("transcript.nothingFound")) }
                PillButton(title: tr("transcript.deleteN", total), accent: true, enabled: total > 0) {
                    store.removeFillers(fillers: fillers, pauses: pauses.map { (words[$0.after], words[$0.after + 1]) })
                }
            }
        }
        .padding(10)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 10)
    }

    func check(_ key: String, _ b: Binding<Bool>) -> some View {
        HStack(spacing: 6) { CapCheckbox(isOn: b); Text(loc: key).font(Theme.Fonts.row).foregroundStyle(IStyle.label) }
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
    func loadCachedTranscripts() {
        guard ai.transcripts.isEmpty else { return }
        for a in mainTrackMedia() { if let t = TranscriptStore.shared.latest(hash: a.contentHash) { ai.transcripts[a.id] = t } }
    }

    func mainTrackMedia() -> [MediaAsset] {
        var seen = Set<MediaID>()
        return (project.timeline.mainTrack?.clips ?? []).compactMap { c in
            guard let id = c.mediaID, seen.insert(id).inserted, let a = project.asset(id), a.hasAudio else { return nil }
            return a
        }
    }

    /// Transcribes every main-track media (whole file, cached) — "Transcribe" / "Re-transcribe".
    public func transcribeMainTrack(force: Bool = false) {
        guard ai.transcriptJob == nil else { return }
        let assets = mainTrackMedia()
        guard !assets.isEmpty else { showToast(tr("transcript.noMain"), error: true); return }
        let lang = ai.captionLanguage, engine = ai.captionEngine
        let box = TranscriptBox()
        ai.transcriptProgress = 0
        Task {
            let id = await JobQueue.shared.enqueue(titleKey: "transcript.job", priority: 1) { [weak self] progress in
                for (i, a) in assets.enumerated() {
                    let key = TranscriptStore.key(hash: a.contentHash, range: nil, language: lang, engine: engine, fillers: true)
                    if !force, let t = TranscriptStore.shared.get(key) { box.add(a.id, t); continue }
                    let wav = try await AudioExtractor.wav16k(a.url, range: nil)
                    defer { try? FileManager.default.removeItem(at: wav) }
                    let t = try await Transcriber.transcribe(wav: wav, request: .init(language: lang, engine: engine, keepFillers: true)) { f in
                        let p = (Double(i) + f) / Double(assets.count)
                        progress.report(p)
                        Task { @MainActor in self?.ai.transcriptProgress = p }
                    }
                    TranscriptStore.shared.put(t, key)
                    box.add(a.id, t)
                }
            }
            ai.transcriptJob = id
            let st = await JobQueue.shared.wait(id)
            ai.transcriptJob = nil
            if st == .done {
                ai.transcripts = box.all
                if box.all.values.allSatisfy({ $0.words.isEmpty }) { showToast(tr("ai.error.noSpeech"), error: true) }
            } else if case .failed = st { showToast(tr("captions.error.failed"), error: true) }
        }
    }

    public func cancelTranscript() { if let id = ai.transcriptJob { Task { await JobQueue.shared.cancel(id) } } }

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

    /// Remove filler words: one ripple edit for the chosen fillers and the pauses (pauses keep 0.15 s on each side).
    public func removeFillers(fillers: [TranscriptEditing.PlacedWord], pauses: [(TranscriptEditing.PlacedWord, TranscriptEditing.PlacedWord)]) {
        let tl = project.timeline
        var ranges: [TimeRange] = []
        for w in fillers {
            guard let id = w.clip, let c = tl.clip(id),
                  let s = c.timelineTime(forSource: Time(w.word.start).clamped(c.sourceRange.start, c.sourceRange.end)),
                  let e = c.timelineTime(forSource: Time(w.word.end).clamped(c.sourceRange.start, c.sourceRange.end)) else { continue }
            ranges.append(TimeRange(start: min(s, e), end: max(s, e)))
        }
        for (a, b) in pauses {
            guard let id = a.clip, let c = tl.clip(id),
                  let s = c.timelineTime(forSource: Time(a.word.end + 0.15).clamped(c.sourceRange.start, c.sourceRange.end)),
                  let e = c.timelineTime(forSource: Time(b.word.start - 0.15).clamped(c.sourceRange.start, c.sourceRange.end)), e > s else { continue }
            ranges.append(TimeRange(start: s, end: e))
        }
        guard !ranges.isEmpty else { showToast(tr("transcript.nothingFound")); return }
        let cuts = ranges
        if perform(Edit("cmd.removeFillers") { p in try TranscriptEditing.rippleDelete(cuts, in: &p) }) { showToast(tr("transcript.fillersRemoved")) }
    }
}

nonisolated final class TranscriptBox: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [MediaID: Transcript] = [:]
    func add(_ id: MediaID, _ t: Transcript) { lock.withLock { map[id] = t } }
    var all: [MediaID: Transcript] { lock.withLock { map } }
}
