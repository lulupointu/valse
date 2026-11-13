import Foundation
import ValseCore
import ValseEngine
import ValseAI

/// PERF-CAPTIONS-2 hooks of the editor: background pre-transcription (`PreTranscriber`) gets this editor's media on
/// project open and import, and pauses whenever this editor works (playback, scrubbing, export, any job, proxies).
extension EditorStore {
    /// Unit tests and UI tests never pre-transcribe in the background (a whisper process would load the machine and
    /// race the tests' own caption runs), unless `VALSE_PRETRANSCRIBE=1`.
    static var preTranscriptionAllowedInProcess: Bool {
        if ProcessInfo.processInfo.environment["VALSE_PRETRANSCRIBE"] == "1" { return true }
        return !ValseProcess.isUnitTest && !TestAnchors.isEnabled
    }

    /// Settings ▸ Performance "Transcribe speech in the background" applied to this editor (AppPreferences.apply):
    /// registers the activity check and queues the project's media, or turns the scheduler off.
    func syncPreTranscription(enabled: Bool) {
        let pt = PreTranscriber.shared
        guard enabled, persistsPreferences, Self.preTranscriptionAllowedInProcess else {
            pt.removeActivitySource(self)
            if !enabled { pt.isEnabled = false }
            return
        }
        pt.isEnabled = true
        let probe = PlayheadProbe()
        pt.setActivitySource(self) { [weak self] in self?.isBusyForBackgroundWork(probe) }
        pt.enqueue(project.media)
    }

    /// Imported media (EditorStore+Media importMedia).
    func preTranscribeImported(_ assets: [MediaAsset]) {
        guard persistsPreferences, PreTranscriber.shared.isEnabled else { return }
        PreTranscriber.shared.enqueue(assets)
    }

    /// The editor is doing something the background pass must not slow down.
    func isBusyForBackgroundWork(_ probe: PlayheadProbe) -> Bool {
        let scrubbed = probe.moved(to: transport.playhead)   // ruler / timeline scrub, seeks, frame steps
        return transport.isPlaying || engine.isPlaying || scrubbed
            || exports.queue.items.contains(where: \.isActive)
            || jobs.contains { $0.state == .running || $0.state == .queued }
            || !proxyPending.isEmpty || !convertPending.isEmpty
            || ai.captionJob != nil
    }
}

/// The playhead seen at the previous activity poll.
final class PlayheadProbe {
    private var last: Time?
    func moved(to t: Time) -> Bool {
        defer { last = t }
        return last.map { $0 != t } ?? false
    }
}
