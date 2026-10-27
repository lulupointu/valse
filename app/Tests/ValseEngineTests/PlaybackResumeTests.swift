@preconcurrency import AVFoundation
import Testing
import Foundation
import QuartzCore
import ValseCore
@testable import ValseEngine
import ValseTestSupport

/// PB-RESUME: pause → play dropped the first ~150 ms of sound (AVPlayer restarted the clock at once and re-rendered
/// the audio from past the pause point); seek → play was gapless. Measured through the lane tap: the first audio the
/// resumed item renders must start at (or before) the paused time.
@MainActor @Suite(.serialized) struct PlaybackResumeTests {
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var times: [Double] = []
        func add(_ t: Double) { lock.withLock { times.append(t) } }
        var snapshot: [Double] { lock.withLock { times } }
    }

    /// Plays at least `seconds` of item time (polling like the player view), bounded in wall time.
    static func play(_ engine: PlaybackEngine, seconds: Double) async throws {
        let from = engine.requestedTime.seconds
        let t0 = CACurrentMediaTime()
        while engine.currentTime.seconds - from < seconds, CACurrentMediaTime() - t0 < 20 {
            _ = engine.pixelBuffer(forHostTime: CACurrentMediaTime())
            try await Task.sleep(nanoseconds: 4_000_000)
        }
    }

    /// Start time of the first audio buffer the tap renders after index `mark` (buffers the paused item repeats at its
    /// last queued time are not new audio).
    static func firstNewBuffer(_ times: [Double], after mark: Int) -> Double? {
        let stale = mark > 0 ? times[mark - 1] : .nan
        return times[mark...].first { $0.isFinite && $0 != stale }
    }

    /// Duration of one tap buffer during steady playback before index `mark` (median step between consecutive buffer
    /// starts), at least 10 ms.
    static func bufferDuration(_ times: [Double], before mark: Int) -> Double {
        let t = times[..<min(mark, times.count)].filter(\.isFinite)
        let steps = zip(t, t.dropFirst()).map { $1 - $0 }.filter { $0 > 0.001 && $0 < 0.1 }.sorted()
        return max(0.01, steps.isEmpty ? 0.01 : steps[steps.count / 2])
    }

    @Test func pausePlayKeepsTheAudioHead() async throws {
        var p = TestProject()
        _ = try await p.addMedia(try await TestMedia.video(.frameIndex, seconds: 8, audioHz: 440))
        let project = p.project
        try await HeavyWorkGate.run {
            let engine = PlaybackEngine(project: project)
            engine.usesProxies = false
            try await PlaybackProbe.waitReady(engine)
            let log = Log()
            engine.audioState.tapObserver = { e in if case .buffer(let t, _) = e { log.add(t) } }
            defer { engine.audioState.tapObserver = nil }
            engine.seek(to: Time(0.5))
            engine.play()
            try await Self.play(engine, seconds: 0.8)

            // pause → play in place
            engine.pause()
            let paused = engine.requestedTime.seconds
            try await Task.sleep(nanoseconds: 400_000_000)
            var mark = log.snapshot.count
            engine.play()
            try await Self.play(engine, seconds: 0.4)
            let resumed = try #require(Self.firstNewBuffer(log.snapshot, after: mark), "no audio after resume")
            // tolerance = one tap buffer: the paused time can fall inside a buffer the tap had already rendered when the
            // pause landed (a loaded machine reads `requestedTime` later), and the first NEW buffer then starts at that
            // buffer's end. The fixed 10 ms was just under one 512-frame buffer (10.67 ms at 48 kHz) and failed once by
            // 10.5 ms under load (FLAKY-SYS-UNIT); the bug this guards lost ~150 ms.
            let slack = Self.bufferDuration(log.snapshot, before: mark) + 0.001
            #expect(resumed <= paused + slack, "resume rendered audio from \(resumed) s, paused at \(paused) s: \(String(format: "%.0f", (resumed - paused) * 1000)) ms lost (one buffer = \(String(format: "%.1f", slack * 1000)) ms)")

            // control: pause, seek, play (was always gapless)
            engine.pause()
            let target = engine.requestedTime.seconds + 0.2
            engine.seek(to: Time(target))
            try await Task.sleep(nanoseconds: 300_000_000)
            mark = log.snapshot.count
            engine.play()
            try await Self.play(engine, seconds: 0.4)
            let sought = try #require(Self.firstNewBuffer(log.snapshot, after: mark), "no audio after seek")
            #expect(sought <= target + Self.bufferDuration(log.snapshot, before: mark) + 0.001, "seek → play rendered from \(sought) s, target \(target) s")
            engine.pause()
        }
    }
}
