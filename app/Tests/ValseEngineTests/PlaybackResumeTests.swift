@preconcurrency import AVFoundation
import Testing
import Foundation
import QuartzCore
import ValseCore
@testable import ValseEngine
import ValseTestSupport

/// PB-RESUME: pause → play dropped the first ~150 ms of sound (AVPlayer restarted the clock at once and re-rendered
/// the audio from past the pause point); seek → play was gapless. Since BUG-CUT-AUDIO-HOLE phase B the audio is
/// `PreviewAudio`: pause keeps what is enqueued past the pause point and resume restarts the clock from the paused time,
/// so the audio enqueued after the resume must continue the stream with no jump, and the clock must resume where it stood.
@MainActor @Suite(.serialized) struct PlaybackResumeTests {
    /// Plays at least `seconds` of item time (polling like the player view), bounded in wall time.
    static func play(_ engine: PlaybackEngine, seconds: Double) async throws {
        let from = engine.requestedTime.seconds
        let t0 = CACurrentMediaTime()
        while engine.currentTime.seconds - from < seconds, CACurrentMediaTime() - t0 < 20 {
            _ = engine.pixelBuffer(forHostTime: CACurrentMediaTime())
            try await Task.sleep(nanoseconds: 4_000_000)
        }
    }

    /// Labels (s) of chunks from index `mark` on that do not continue the previous chunk.
    static func jumps(_ rec: PreviewAudioCheck.Recording, from mark: Int) -> [Double] {
        let c = Array(rec.snapshot.dropFirst(max(0, mark - 1)))
        return zip(c, c.dropFirst()).compactMap { a, b in
            PreviewAudioLanes.frame(b.time) == PreviewAudioLanes.frame(a.time) + a.left.count ? nil : b.time
        }
    }

    @Test func pausePlayKeepsTheAudioHead() async throws {
        var p = TestProject()
        _ = try await p.addMedia(try await TestMedia.video(.frameIndex, seconds: 8, audioHz: 440))
        let project = p.project
        try await HeavyWorkGate.run {
            let engine = PlaybackEngine(project: project)
            engine.usesProxies = false
            try await PlaybackProbe.waitReady(engine)
            let rec = PreviewAudioCheck.Recording()
            engine.audio.capture = rec.hook
            defer { engine.audio.capture = nil }
            engine.seek(to: Time(0.5))
            engine.play()
            try await Self.play(engine, seconds: 0.8)

            // pause → play in place
            engine.pause()
            let paused = engine.audio.currentTime
            #expect(abs(paused - engine.requestedTime.seconds) < 0.005, "audio clock \(paused) s, playhead \(engine.requestedTime.seconds) s")
            try await Task.sleep(nanoseconds: 400_000_000)
            #expect(abs(engine.audio.currentTime - paused) < 0.001, "the audio clock moved while paused")
            let mark = rec.snapshot.count
            let seeks = engine.audio.stats.seeks
            engine.play()
            try await Self.play(engine, seconds: 0.4)
            #expect(engine.audio.stats.seeks == seeks, "resume re-read the audio (flush) instead of playing what was queued")
            #expect(Self.jumps(rec, from: mark).isEmpty, "the audio jumped at resume: \(Self.jumps(rec, from: mark))")

            // control: pause, seek, play: the new audio starts at the target
            engine.pause()
            let target = engine.requestedTime.seconds + 0.2
            let mark2 = rec.snapshot.count
            engine.seek(to: Time(target))
            try await Task.sleep(nanoseconds: 300_000_000)
            engine.play()
            try await Self.play(engine, seconds: 0.4)
            let first = try #require(rec.snapshot.dropFirst(mark2).first, "no audio after seek")
            #expect(abs(first.time - target) < 0.001, "seek → play enqueued from \(first.time) s, target \(target) s")
            #expect(Self.jumps(rec, from: mark2 + 1).isEmpty, "the audio jumped after the seek: \(Self.jumps(rec, from: mark2 + 1))")
            engine.pause()
        }
    }
}
