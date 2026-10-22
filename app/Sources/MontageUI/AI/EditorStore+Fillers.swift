import SwiftUI
import Perception
import MontageCore
import MontageEngine
import MontageAI

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
}
