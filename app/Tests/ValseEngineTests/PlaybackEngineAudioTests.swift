import Testing
import Foundation
import ValseCore
@testable import ValseEngine
import ValseTestSupport

/// BUG-CUT-AUDIO-HOLE phase B, acceptance through `PlaybackEngine`: AVPlayer renders the video only, `PreviewAudio`
/// the audio, both timebases on the output device clock, started together (`PlaybackEngineCheck`, the same code
/// `Valse --preview-audio-check` runs on macOS 13). Audio measured on what is enqueued (labelled chunks); A/V sync =
/// audio clock − video clock read back to back while both run (1 frame = 33 ms at 30 fps). Real time ~25 s.
@MainActor @Suite(.serialized)
struct PlaybackEngineAudioTests {
    let dir = TestMedia.directory

    /// The owner's cut: no zeroed stretch around the cut, and the preview is sample for sample the export at lag 0.
    @Test func ownersCutHasNoHoleAndMatchesTheExport() async throws {
        try await HeavyWorkGate.run {
            let r = try await PlaybackEngineCheck.ownerCut(dir: dir)
            print("PLAYBACKENGINE owner's cut: max |diff| \(r.maxDiff), lag \(r.lag), silent \(r.silent), discontinuities \(r.discontinuities), A/V spread \(r.play.avSpreadMs) ms")
            #expect(r.silent.isEmpty, "silent 5 ms windows at \(r.silent) s")
            #expect(r.lag == 0)
            #expect(r.maxDiff < 1e-3)
            #expect(r.play.avSpreadMs < 34)
        }
    }

    /// A/V within one frame after play, seek while playing, J/K/L rate changes and pause / resume (no flush at resume).
    @Test func audioAndVideoClocksStayInStep() async throws {
        try await HeavyWorkGate.run {
            let r = try await PlaybackEngineCheck.sync(dir: dir)
            for (name, ph) in r.phases {
                print("PLAYBACKENGINE sync \(name): spread \(ph.avSpreadMs) ms over \(ph.avReads) reads, start \(ph.startMs ?? -1) ms, frames \(ph.frames)")
                #expect(ph.avReads > 0, "\(name): the clocks never ran together")
                #expect(ph.avSpreadMs < 34, "\(name): audio − video clock \(ph.avSpreadMs) ms")
            }
            print("PLAYBACKENGINE sync: display-poll drift max \(r.maxPollDriftMs) ms, re-joins \(r.driftRejoins), pause discontinuities \(r.pauseDiscontinuities)")
            #expect(r.driftRejoins == 0)
            #expect(r.pauseDiscontinuities.isEmpty, "audio jumped / flushed at resume: \(r.pauseDiscontinuities)")
        }
    }

    /// 12 seeks 80 ms apart while playing: no freeze, video and audio run again in step, one reader open.
    @Test func seekStormWhilePlayingRecovers() async throws {
        try await HeavyWorkGate.run {
            let r = try await PlaybackEngineCheck.seekStorm(dir: dir)
            print("PLAYBACKENGINE storm: restarted \(r.restarted) in \(r.after.startMs ?? -1) ms, frames \(r.framesAfter), readers \(r.readersAfter), spread \(r.after.avSpreadMs) ms")
            #expect(r.restarted)
            #expect(r.framesAfter > 0, "video frozen after the storm")
            #expect(r.readersAfter <= 1)
            #expect(r.after.avSpreadMs < 34)
        }
    }

    /// Rebuilds while playing (forced, then a volume edit): the audio never stops or jumps, the video re-joins it.
    @Test func itemRebuildWhilePlayingIsGaplessForTheAudio() async throws {
        try await HeavyWorkGate.run {
            let r = try await PlaybackEngineCheck.rebuildWhilePlaying(dir: dir)
            print("PLAYBACKENGINE rebuild: playing \(r.playing), discontinuities \(r.discontinuities), re-joins \(r.rejoins), spread \(r.after.avSpreadMs) ms, edit heard after \(r.heardEditAfterMs) ms")
            #expect(r.playing)
            #expect(r.discontinuities.isEmpty, "audio jumped at \(r.discontinuities)")
            #expect(r.rejoins >= 2, "each new item re-joins the running audio")
            #expect(r.after.avSpreadMs < 34)
            #expect(r.heardEditAfterMs < 400, "the volume edit was heard \(r.heardEditAfterMs) ms after")
        }
    }

    /// Playing into the end: video and audio stop, the playhead sits at the end.
    @Test func endOfProjectStopsBoth() async throws {
        try await HeavyWorkGate.run {
            let r = try await PlaybackEngineCheck.endOfProject(dir: dir)
            print("PLAYBACKENGINE end: \(r)")
            #expect(r.stopped)
            #expect(r.audioStopped)
            #expect(r.playheadAtEnd)
            #expect(r.audioClock < r.duration + 0.15)
        }
    }
}
