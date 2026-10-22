import SwiftUI
import Perception
import MontageCore
import MontageEngine
import MontageAI

@MainActor
extension EditorStore {
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
    /// `ui.transcript` (historical name, kept for the caption scripts): captions nav, Apply to all, caption clips.
    func transcriptStateDump() -> [String: Any] {
        let caps = SpeechCaptions.captions(in: project.timeline).compactMap { c in CaptionOps.text(c).map { (c, $0) } }
        return ["captionsNav": CaptionsTabState.shared.nav,
                "applyToAllCaptions": TextUIState.shared.applyToAllCaptions,
                // caption clips (timeline order): text, start, font size (UI units ×250), colour red
                "captions": caps.map { c, t in ["text": t.string, "start": c.start.seconds, "end": c.end.seconds,
                                                "fontSize": (t.fontSize * 250).rounded(), "red": t.color.r] as [String: Any] }]
    }
}
