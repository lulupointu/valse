import Foundation
import ValseCore
import ValseEngine
import ValseAI

/// PERF-CAPTIONS-2 hooks of the editor: background pre-transcription (`PreTranscriber`) prepares this editor's
/// "Auto captions" (the timeline's clips, the panel's current options) when the project is opened, media are imported
/// or the timeline was saved, and pauses whenever this editor works (playback, scrubbing, export, any job, proxies).
extension EditorStore {
    /// Unit tests and UI tests never pre-transcribe in the background (a whisper process would load the machine and
    /// race the tests' own caption runs), unless `VALSE_PRETRANSCRIBE=1`.
    static var preTranscriptionAllowedInProcess: Bool {
        if ProcessInfo.processInfo.environment["VALSE_PRETRANSCRIBE"] == "1" { return true }
        return !ValseProcess.isUnitTest && !TestAnchors.isEnabled
    }

    /// Settings ▸ Performance "Prepare captions in the background" applied to this editor (AppPreferences.apply).
    func syncPreTranscription(enabled: Bool) {
        let pt = PreTranscriber.shared
        guard enabled, persistsPreferences, Self.preTranscriptionAllowedInProcess else {
            pt.removeSource(self)
            if !enabled { pt.isEnabled = false }
            return
        }
        let probe = PlayheadProbe()
        pt.setSource(self, busy: { [weak self] in self?.isBusyForBackgroundWork(probe) },
                     work: { [weak self] in self.map { PreTranscriber.Work(project: $0.project, options: $0.preTranscriptionOptions) } })
        pt.isEnabled = true
        pt.kick()
    }

    /// Media imported / timeline saved: the work may have changed.
    func kickPreTranscription() {
        guard persistsPreferences, PreTranscriber.shared.isEnabled else { return }
        PreTranscriber.shared.kick()
    }

    /// What "Auto captions" would be asked with now: the panel's options (language, engine, source), never replacing
    /// anything (the replace flag does not change what is recognised).
    var preTranscriptionOptions: CaptionOptions {
        CaptionOptions(language: ai.captionLanguage, engine: ai.captionEngine, source: ai.captionSource, settings: CaptionSettings(),
                       replaceExisting: false)
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
