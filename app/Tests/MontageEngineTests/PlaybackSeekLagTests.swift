@preconcurrency import AVFoundation
import Testing
import Foundation
import QuartzCore
import MontageCore
@testable import MontageEngine
import MontageTestSupport

/// PB-SEEK-LAG (owner): after the dropped-frames warning, clicking the timeline while playing no longer moved playback;
/// it played on from where it was until pause + play. A click must seek at once and playback continue from the target,
/// whatever the health state: stalled video pipeline (the watchdog re-priming / rebuilding the item), a starved main
/// thread, or a seek AVFoundation ends unfinished.
@MainActor @Suite(.serialized) struct PlaybackSeekLagTests {
    /// Polls like the player view until playback runs inside `target - 0.6 … target + 3` (true), or `bound` s passed.
    /// Playback that ignored the seek never gets there (every target is ≥ 5 s away from where the seek was made).
    static func reaches(_ engine: PlaybackEngine, _ target: Double, bound: Double = 20) async throws -> Bool {
        let t0 = CACurrentMediaTime()
        while CACurrentMediaTime() - t0 < bound {
            _ = engine.pixelBuffer(forHostTime: CACurrentMediaTime())
            if engine.player.rate > 0, engine.player.currentItem?.status == .readyToPlay {
                let now = engine.player.currentTime().seconds
                if now >= target - 0.6, now <= target + 3 { return true }
            }
            try await Task.sleep(nanoseconds: 4_000_000)
        }
        return false
    }

    static func play(_ engine: PlaybackEngine, seconds: Double) async throws {
        let t0 = CACurrentMediaTime()
        while CACurrentMediaTime() - t0 < seconds {
            _ = engine.pixelBuffer(forHostTime: CACurrentMediaTime())
            try await Task.sleep(nanoseconds: 4_000_000)
        }
    }

    static func project() async throws -> Project {
        var p = TestProject()
        _ = try await p.addMedia(try await TestMedia.video(.frameIndex, seconds: 30, audioHz: 440))
        return p.project
    }

    /// Lagging preview: no new frame reaches the view (the stall watchdog re-primes, then rebuilds the item) and the
    /// main thread is starved now and then. Ruler clicks (tolerant seek on mouse-down, exact on mouse-up) and plain
    /// seeks, forwards and backwards, must each move playback to the target.
    @Test func seekWhilePlayingLagging() async throws {
        let project = try await Self.project()
        try await HeavyWorkGate.run {
            let engine = PlaybackEngine(project: project)
            engine.usesProxies = false
            try await PlaybackProbe.waitReady(engine)
            engine.seek(to: .zero)
            engine.play()
            var failures: [String] = []
            for (i, target) in [20.0, 4.0, 15.0, 8.0, 24.0, 2.0].enumerated() {
                engine.withholdsFramesForTesting = i % 3 != 2
                try await Self.play(engine, seconds: 1)
                usleep(150_000)   // starved main thread right before the click
                let from = engine.currentTime.seconds
                if i % 2 == 0 {
                    engine.seek(to: Time(target), exact: false)
                    usleep(50_000)
                    engine.seek(to: Time(target), exact: true)
                } else {
                    engine.seek(to: Time(target))
                }
                if try await !Self.reaches(engine, target) {
                    failures.append("#\(i) \(String(format: "%.2f", from)) → \(target): at \(String(format: "%.2f", engine.player.currentTime().seconds)), rate \(engine.player.rate)")
                }
                #expect(engine.isPlaying)
            }
            engine.withholdsFramesForTesting = false
            engine.pause()
            #expect(failures.isEmpty, "playback ignored the seek: \(failures)")
            #expect(engine.stallRecoveries > 0, "the lag simulation exercised the stall watchdog")
        }
    }

    /// A seek AVFoundation ends unfinished is re-issued (it used to resume where the player was).
    @Test func unfinishedSeekIsReissued() async throws {
        let project = try await Self.project()
        try await HeavyWorkGate.run {
            let engine = PlaybackEngine(project: project)
            engine.usesProxies = false
            try await PlaybackProbe.waitReady(engine)
            engine.seek(to: Time(2))
            engine.play()
            try await Self.play(engine, seconds: 0.5)
            engine.seek(to: Time(20))
            engine.player.currentItem?.cancelPendingSeeks()   // completion: finished = false
            #expect(try await Self.reaches(engine, 20))
            #expect(engine.seekRetries >= 1)
            #expect(engine.isPlaying)
            engine.pause()
        }
    }
}
