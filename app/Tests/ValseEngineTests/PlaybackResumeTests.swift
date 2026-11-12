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

    /// Feeder seek count per enqueued chunk (written on the feeder queue).
    final class SeekLog: @unchecked Sendable {
        private let lock = NSLock()
        private var v: [Int] = []
        func append(_ n: Int) { lock.withLock { v.append(n) } }
        var values: [Int] { lock.withLock { v } }
    }

    /// What it protects (PB-RESUME): pause → play continues the audio exactly where it stopped (the clock stands at the
    /// playhead while paused, the resume plays what was queued: no re-read, no label jump), and seek → play starts the
    /// audio exactly at the target.
    ///
    /// FLAKY-PB (3/30 at load 4): (1) pause stopped the video, then the audio a moment later; preempted in between, the
    /// audio clock stood 5-7 ms past the playhead and the resume re-read it (a flush: "seeks 3 == 2", a label jump):
    /// a product race, fixed (`PreviewAudio.pause(at:)`). (2) the test took the recording's length before the seek as
    /// the seek's start, but the paused feeder can still queue a chunk from the old position before the seek runs:
    /// chunks are now tagged with the feeder's seek count.
    @Test func pausePlayKeepsTheAudioHead() async throws {
        var p = TestProject()
        _ = try await p.addMedia(try await TestMedia.video(.frameIndex, seconds: 8, audioHz: 440))
        let project = p.project
        try await HeavyWorkGate.run {
            let engine = PlaybackEngine(project: project)
            engine.usesProxies = false
            try await PlaybackProbe.waitReady(engine)
            let rec = PreviewAudioCheck.Recording()
            // each chunk with the feeder's seek count when it was enqueued: chunks the paused feeder still queued from the
            // old position before a seek ran are told apart from the seek's own (FLAKY-PB: taking the recording's
            // length before the seek counted such a chunk as "the first after the seek", 25 ms past the target)
            let audio = engine.audio, seekOf = SeekLog()
            engine.audio.capture = { t, b in rec.hook(t, b); seekOf.append(audio.stats.seeks) }
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
            let seeks2 = engine.audio.stats.seeks
            engine.seek(to: Time(target))
            try await Task.sleep(nanoseconds: 300_000_000)
            engine.play()
            try await Self.play(engine, seconds: 0.4)
            let chunks = rec.snapshot, counts = seekOf.values
            let mark2 = try #require(counts.firstIndex { $0 > seeks2 }, "no audio after seek")
            let first = chunks[mark2]
            #expect(abs(first.time - target) < 0.001, "seek → play enqueued from \(first.time) s, target \(target) s")
            #expect(Self.jumps(rec, from: mark2 + 1).isEmpty, "the audio jumped after the seek: \(Self.jumps(rec, from: mark2 + 1))")
            engine.pause()
        }
    }
}
