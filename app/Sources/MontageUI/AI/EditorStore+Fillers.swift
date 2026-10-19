import SwiftUI
import Observation
import MontageCore
import MontageEngine
import MontageAI

/// How "Remove filler words" applies (C4, Settings ▸ Edit ▸ Labs, `AppSettings.fillerRemovalStyle`). The three share one
/// review surface (`TranscriptWorkspace`), shown by the Transcript panel and by Captions ▸ Filler words.
public enum FillerRemovalStyle: String, CaseIterable, Sendable {
    /// (A) cut everything found at once; the toast offers Undo.
    case instant
    /// (B) a checklist of every filler / pause, then "Remove N".
    case review
    /// (C) fillers highlighted inline in the transcript: click to keep / drop, then Apply.
    case inline

    public static var current: FillerRemovalStyle {
        FillerRemovalStyle(rawValue: AppPreferences.shared.settings.fillerRemovalStyle) ?? .review
    }
    var nameKey: String { "fillers.style.\(rawValue)" }
    var hintKey: String { "fillers.style.\(rawValue).hint" }
}

/// Where the transcript stands relative to the timeline (C4: the transcript is global, covering every main-track clip).
public enum TranscriptStatus: Equatable, Sendable {
    /// Nothing transcribed yet.
    case none
    case transcribing
    /// Every main-track media with sound has a transcript in the chosen language.
    case upToDate
    /// `missing` media were added since (or the spoken language changed: `language`).
    case stale(missing: Int, language: Bool)
    /// Nothing to transcribe (no main-track media with sound).
    case noMedia
}

/// State of the filler review (one per editor, `store.ai.fillers`).
@MainActor @Observable
public final class FillerUIState {
    /// A review is open (styles B / C).
    public var reviewing = false
    /// Candidates of the open review (timeline order).
    public var candidates: [FillerCleanup.Candidate] = []
    /// Candidate ids that will be cut (checked / struck through). New candidates start dropped.
    public var dropped: Set<String> = []
    /// Clips the review is limited to (nil = everywhere).
    public var scope: Set<ClipID>?
    /// "Remove filler words" is waiting for the transcription to finish.
    public var pendingRemove = false
    /// Style of the open review (fixed while it is open).
    public var style: FillerRemovalStyle = .review
    /// Options popover open.
    public var showOptions = false
    public init() {}
}

@MainActor
extension EditorStore {
    // MARK: Transcript freshness

    /// Main-track media with sound (what the transcript covers), in timeline order.
    func transcriptMedia() -> [MediaAsset] { mainTrackMedia() }

    public var transcriptStatus: TranscriptStatus {
        if ai.transcriptJob != nil { return .transcribing }
        let media = transcriptMedia()
        guard !media.isEmpty else { return .noMedia }
        let have = media.filter { ai.transcripts[$0.id] != nil }
        if have.isEmpty { return .none }
        let missing = media.count - have.count
        let langChanged = ai.captionLanguage.map { lang in have.contains { !(ai.transcripts[$0.id]?.language.hasPrefix(lang) ?? true) } } ?? false
        return missing == 0 && !langChanged ? .upToDate : .stale(missing: missing, language: langChanged)
    }

    /// Language the transcript was recognised in (shown next to "Auto detect").
    var transcriptLanguage: String? { ai.transcripts.values.first(where: { !$0.words.isEmpty })?.language }

    /// "Update": transcribes only what is missing (cache first), or everything again after a language change.
    public func updateTranscript() {
        if case .stale(_, true) = transcriptStatus { transcribeMainTrack(force: false, onlyMissing: false); return }
        transcribeMainTrack(force: false, onlyMissing: true)
    }

    /// Picking a spoken language: during a transcription it restarts in that language (C4 fix: the dropdown used to do
    /// nothing while transcribing).
    public func setTranscriptLanguage(_ lang: String?) {
        guard ai.captionLanguage != lang else { return }
        ai.captionLanguage = lang
        if let id = ai.transcriptJob {
            Task {
                await JobQueue.shared.cancel(id)
                _ = await JobQueue.shared.wait(id)
                self.transcribeMainTrack(force: false, onlyMissing: false)
            }
        }
    }

    // MARK: Remove filler words

    /// Main-track clips "Remove filler words" is limited to: the selected ones, else everywhere (nil).
    var fillerScope: Set<ClipID>? {
        guard let main = project.timeline.mainTrack else { return nil }
        let s = selection.intersection(main.clips.map(\.id))
        return s.isEmpty ? nil : s
    }

    var fillerOptions: FillerCleanup.Options {
        FillerCleanup.Options(kinds: ai.cleanupKinds, pauses: ai.cleanupPauses, minPause: ai.minPause)
    }

    func fillerCandidates(scope: Set<ClipID>?) -> [FillerCleanup.Candidate] {
        let tl = project.timeline
        let words = TranscriptEditing.placedWords(transcripts: ai.transcripts, timeline: tl)
        return FillerCleanup.candidates(words: words, transcripts: ai.transcripts, timeline: tl, options: fillerOptions, scope: scope)
    }

    /// The one-click "Remove filler words" (Transcript panel, Captions ▸ Filler words, timeline): transcribes what is
    /// missing first, then applies with the Labs style — at once (A), or opens the checklist (B) / inline review (C).
    public func removeFillerWords() {
        let st = transcriptStatus
        switch st {
        case .noMedia: showToast(tr("transcript.noMain"), error: true); return
        case .transcribing: ai.fillers.pendingRemove = true; return
        case .none, .stale:
            loadCachedTranscripts()
            if transcriptStatus != .upToDate {
                ai.fillers.pendingRemove = true
                if case .stale(_, true) = transcriptStatus { transcribeMainTrack(onlyMissing: false) } else { transcribeMainTrack(onlyMissing: true) }
                return
            }
        case .upToDate: break
        }
        startFillerRemoval()
    }

    func startFillerRemoval() {
        ai.fillers.pendingRemove = false
        let scope = fillerScope
        let found = fillerCandidates(scope: scope)
        guard !found.isEmpty else { showToast(tr("transcript.nothingFound")); return }
        let style = FillerRemovalStyle.current
        if style == .instant {
            applyFillerCuts(found)
            return
        }
        let f = ai.fillers
        f.style = style
        f.scope = scope
        f.candidates = found
        f.dropped = Set(found.map(\.id))
        f.reviewing = true
    }

    /// Options changed during a review: recompute, keep the user's keep / drop choices, new ones start dropped.
    func refreshFillerReview() {
        let f = ai.fillers
        guard f.reviewing else { return }
        let old = Set(f.candidates.map(\.id))
        let found = fillerCandidates(scope: f.scope)
        f.candidates = found
        f.dropped = Set(found.map(\.id).filter { f.dropped.contains($0) || !old.contains($0) })
    }

    public func toggleFiller(_ id: String) {
        let f = ai.fillers
        if f.dropped.contains(id) { f.dropped.remove(id) } else { f.dropped.insert(id) }
    }

    /// Apply / Remove N: cuts the dropped candidates (recomputed on the current timeline).
    public func applyFillerReview() {
        let f = ai.fillers
        let ids = f.dropped
        let cuts = fillerCandidates(scope: f.scope).filter { ids.contains($0.id) }
        f.reviewing = false
        f.candidates = []
        guard !cuts.isEmpty else { return }
        applyFillerCuts(cuts)
    }

    public func cancelFillerReview() {
        ai.fillers.reviewing = false
        ai.fillers.candidates = []
        ai.fillers.pendingRemove = false
    }

    /// One ripple edit + a toast with the count, the time saved and Undo.
    func applyFillerCuts(_ cuts: [FillerCleanup.Candidate]) {
        let saved = FillerCleanup.totalDuration(cuts).seconds
        if perform(Edit("cmd.removeFillers") { p in try FillerCleanup.apply(cuts, in: &p) }) {
            ai.transcriptSelection = []
            showToast(tr("fillers.removed", cuts.count, Fmt.num(saved, 1)), actionTitle: tr("fillers.undo")) { [weak self] in
                guard let self, self.session.undoNameKey == "cmd.removeFillers" else { return }
                self.undo()
            }
        }
    }

    // MARK: Caption style sync ("Apply to all main captions")

    /// The caption whose style edits are replayed on its track (the single selected caption; used by the UI).
    var captionStyleSource: ClipID? {
        guard let c = singleSelectedClip, CaptionOps.isCaption(c) else { return nil }
        return c.id
    }

    func installCaptionStyleSync() {
        let me = UncheckedSendable(WeakStore(self))
        setSessionPostProcess { before, after in
            MainActor.assumeIsolated {
                // never read `s.project` here: the session is being mutated (exclusive access) — only the selection
                // C2 multi-select: several selected captions are edited together; the first (timeline order) is the source
                guard TextUIState.shared.applyToAllCaptions, let s = me.value.store, !s.selection.isEmpty else { return }
                let caps = s.selection.compactMap { id in before.timeline.clip(id).flatMap { CaptionOps.isCaption($0) ? $0 : nil } }
                guard caps.count == s.selection.count, let first = caps.min(by: { $0.start < $1.start }) else { return }
                CaptionStyleSync.propagate(from: first.id, coEdited: s.selection, before: before, after: &after)
            }
        }
    }
}

final class WeakStore {
    weak var store: EditorStore?
    init(_ s: EditorStore) { store = s }
}

// MARK: - UI test state (C4)

extension EditorStore {
    func transcriptStateDump() -> [String: Any] {
        let status: String
        switch transcriptStatus {
        case .none: status = "none"
        case .transcribing: status = "transcribing"
        case .upToDate: status = "upToDate"
        case .stale(_, let lang): status = lang ? "staleLanguage" : "stale"
        case .noMedia: status = "noMedia"
        }
        let words = TranscriptEditing.placedWords(transcripts: ai.transcripts, timeline: project.timeline)
        let caps = SpeechCaptions.captions(in: project.timeline).compactMap { c in CaptionOps.text(c).map { (c, $0) } }
        return ["open": ai.transcriptOpen, "status": status, "words": words.filter { !$0.isDeleted }.map(\.word.text),
                "language": ai.captionLanguage ?? "auto", "captionsNav": CaptionsTabState.shared.nav,
                "applyToAllCaptions": TextUIState.shared.applyToAllCaptions,
                // caption clips (timeline order): text, start, font size (UI units ×250), colour red
                "captions": caps.map { c, t in ["text": t.string, "start": c.start.seconds, "end": c.end.seconds,
                                                "fontSize": (t.fontSize * 250).rounded(), "red": t.color.r] as [String: Any] }]
    }

    func fillersStateDump() -> [String: Any] {
        let f = ai.fillers
        return ["reviewing": f.reviewing, "style": FillerRemovalStyle.current.rawValue, "reviewStyle": f.style.rawValue,
                "count": f.candidates.count, "dropped": f.candidates.filter { f.dropped.contains($0.id) }.count,
                "pending": f.pendingRemove, "scope": f.scope?.count ?? 0,
                "candidates": f.candidates.map { ["kind": $0.kind.rawValue, "edge": $0.edge?.rawValue ?? "", "text": $0.text,
                                                   "start": $0.range.start.seconds, "end": $0.range.end.seconds] as [String: Any] }]
    }
}
