@preconcurrency import AVFoundation
import Testing
import Foundation
import ValseCore
@testable import ValseEngine
import ValseTestSupport

/// BUG-CUT-AUDIO-HOLE phase A: the AVPlayer-free preview audio engine (`PreviewAudio`: reader → lane processing at
/// enqueue → AVSampleBufferAudioRenderer under a synchronizer). Measured on what it ENQUEUES (labelled chunks), against
/// the source content and the export mixdown (`PreviewAudioCheck`, the same code `Valse --preview-audio-check` runs on
/// macOS 13). Every check is in media time / samples; wall-clock latencies are only emitted as metrics (and asserted in
/// perf runs). Real time: ~25 s for the suite, serialized (one renderer at a time).
@Suite(.serialized)
struct PreviewAudioTests {
    let dir = TestMedia.directory

    struct Case: Sendable, CustomTestStringConvertible {
        let rate: Double, sourceRate: Double
        var testDescription: String { "rate \(rate) src \(Int(sourceRate))" }
    }

    /// Unscaled clip: every burst onset in the enqueued stream lands on its expected frame (± 3; 44.1 kHz media is
    /// resampled by the reader), at 1× and at J/K/L rates (the renderer stretches AFTER labelling); the clock runs at the rate.
    @Test(arguments: [Case(rate: 1, sourceRate: 48000), Case(rate: 2, sourceRate: 48000), Case(rate: 0.5, sourceRate: 48000),
                      Case(rate: 1, sourceRate: 44100)])
    func labelsFollowTheContent(_ c: Case) async throws {
        let t = try await PreviewAudioCheck.timing(sourceRate: c.sourceRate, rate: c.rate, dir: dir)
        print("PREVIEWAUDIO timing \(c.testDescription): onset leads (frames) \(PreviewAudioCheck.stats(t.leads)), clock rate \(t.clockRate) \(t.debug)")
        #expect(t.leads.count >= 3, "bursts found: \(t.leads.count)")
        #expect(t.leads.allSatisfy { abs($0) <= 3 }, "onset leads \(t.leads)")
        if t.clockRate.isFinite { #expect(abs(t.clockRate / c.rate - 1) < 0.1, "clock rate \(t.clockRate)") }
    }

    /// Speed-scaled segments (the reader time-stretches, spectral): envelope alignment within 2 ms.
    @Test(arguments: [2.0, 0.5])
    func scaledSegmentsFollowTheContent(_ speed: Double) async throws {
        let t = try await PreviewAudioCheck.timing(speed: speed, dir: dir)
        print(String(format: "PREVIEWAUDIO timing speed %.1f: envelope lead %.0f ms, corr %.3f", speed, t.envelopeMs, t.corr))
        #expect(t.corr > 0.5)
        #expect(abs(t.envelopeMs) <= 2)
    }

    /// The owner's cut (A fading out | B fading in) plus a clip after a gap: sample for sample the export mixdown.
    @Test func cutWithFadesMatchesExport() async throws {
        let p = try await PreviewAudioCheck.cutProject(dir: dir)
        let (rec, audio) = try await PreviewAudioCheck.play(p, seek: 1.4, until: 3.2)
        audio.stop()
        let c = try await PreviewAudioCheck.compareToExport(rec, project: p, from: 1.45, to: 3.1)
        print("PREVIEWAUDIO cut vs export: max |diff| \(c.maxDiff), lag \(c.lag)")
        #expect(c.lag == 0)
        #expect(c.maxDiff < 1e-3)
        #expect(rec.discontinuities.isEmpty)
    }

    @Test func seekToSound() async throws {
        let s = try await PreviewAudioCheck.seekLatency(dir: dir)
        print("PREVIEWAUDIO seek→first chunk ms \(PreviewAudioCheck.stats(s.toFirstChunkMs)); seek→moving clock ms \(PreviewAudioCheck.stats(s.toClockMs))")
        #expect(s.toClockMs.count == 6)
        #expect(s.leads.count >= 6 && s.leads.allSatisfy { abs($0) <= 3 }, "leads after seeks \(s.leads)")
        let median = s.toClockMs.sorted()[s.toClockMs.count / 2]
        TimingBudget.metric("preview_audio_seek_to_clock_ms", median, "ms")
        if let limit = TimingBudget.limit(300, "preview audio seek → clock") { #expect(median < limit * 1) }
    }

    /// 12 seeks 80 ms apart while playing: no deadlock, coalesced reads, no reader left behind, engine released.
    @Test func seekStorm() async throws {
        let s = try await PreviewAudioCheck.seekStorm(dir: dir)
        print("PREVIEWAUDIO storm: \(s)")
        #expect(s.seeksPerformed >= 1 && s.seeksPerformed <= 12)
        #expect(s.readersWhilePlaying <= 1, "readers open while playing: \(s.readersWhilePlaying)")
        #expect(s.readersAfter <= 0, "readers left open after release: \(s.readersAfter)")
        #expect(s.released, "PreviewAudio not deallocated")
        #expect(s.leads.count >= 2 && s.leads.allSatisfy { abs($0) <= 3 }, "leads after the storm \(s.leads)")
        TimingBudget.metric("preview_audio_storm_settle_ms", s.settledMs, "ms")
    }

    /// A live-effect edit (EQ through AudioMixState) is heard < horizon + 100 ms after the clock at the edit (pacing:
    /// `PreviewAudio.feedAhead`, ≈ 0.2 s on a low-latency output).
    @Test func liveEditIsHeardQuickly() async throws {
        let l = try await PreviewAudioCheck.liveEdit(dir: dir)
        print("PREVIEWAUDIO live edit: \(l)")
        #expect(abs(l.ratioBefore - 1) < 0.02, "unedited level vs export \(l.ratioBefore)")
        #expect(l.ratioAfter < 0.6)
        #expect(l.heardAfterMs < l.budgetMs, "heard \(l.heardAfterMs) ms after the edit (horizon \(l.feedAheadMs) ms)")
    }

    @Test func pauseResumeIsContinuous() async throws {
        let r = try await PreviewAudioCheck.pauseResume(dir: dir)
        print("PREVIEWAUDIO pause/resume: \(r)")
        #expect(abs(r.clockDriftWhilePausedMs) < 1)
        #expect(r.seeksDuring == 0)
        #expect(r.discontinuities.isEmpty, "labels jumped at \(r.discontinuities)")
        #expect(r.leads.count >= 3 && r.leads.allSatisfy { abs($0) <= 3 })
        TimingBudget.metric("preview_audio_resume_ms", r.resumedMs, "ms")
    }

    /// `replace` while playing: no discontinuity (the new reader continues where the queue ends), labels exact, the
    /// new gains heard within 300 ms of the clock at the swap (queue ≤ `feedAhead` ≈ 0.2 s + build).
    @Test func replaceWhilePlaying() async throws {
        let r = try await PreviewAudioCheck.swapWhilePlaying(dir: dir)
        print("PREVIEWAUDIO swap: \(r)")
        #expect(r.swaps == 1)
        #expect(r.discontinuities.isEmpty)
        #expect(r.leads.count >= 3 && r.leads.allSatisfy { abs($0) <= 3 }, "leads \(r.leads)")
        // design value ≈ feedAhead + one chunk (≈ 230 ms on a low-latency output); 500 ms tolerates heavy parallel load
        #expect(r.heardAfterMs < 500, "new gain heard \(r.heardAfterMs) ms after the swap")
    }

    /// Output configuration change (device switch): flush + re-anchor at the clock, then plays on with exact labels.
    @Test func outputChangeReanchors() async throws {
        let (p, clip) = try await PreviewAudioCheck.burstProject(dir: dir)
        var at = 0.0
        let (rec, audio) = try await PreviewAudioCheck.play(p, seek: 1.3, until: 2.6) { a in
            _ = await PreviewAudioCheck.wait(10) { a.currentTime > 1.6 }
            at = a.currentTime
            a.outputConfigurationChanged()
        }
        let s = audio.stats
        audio.stop()
        #expect(s.outputChanges >= 1 && s.seeks >= 2)
        #expect(rec.discontinuities.count <= 1 + (s.outputChanges - 1))
        let leads = PreviewAudioCheck.onsetLeads(rec, clip: clip, from: at)
        #expect(leads.count >= 2 && leads.allSatisfy { abs($0) <= 3 }, "leads after the change \(leads)")
    }
}
