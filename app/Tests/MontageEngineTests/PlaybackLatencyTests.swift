@preconcurrency import AVFoundation
import Testing
import Foundation
import QuartzCore
import MontageCore
@testable import MontageEngine
import MontageTestSupport

/// PB-LATENCY: after a seek, AVPlayer starts the item clock before the target by the output latency (0.36 s measured
/// on a 4096-frame 44.1 kHz output). The stall watchdog counted that lead as a frozen video pipeline and re-primed
/// before the target, again and again: play did nothing, the playhead crept backwards. The test polls the engine as the
/// player view does, with host times `lead` s in the past for `lead` s after each clock start: the engine sees the item
/// times before the target such an output shows it, then the real clock (frames are only kept around the real one).
@MainActor @Suite(.serialized) struct PlaybackLatencyTests {
    /// Polls like the player view for `seconds` of wall time, simulating the lead; returns the timeline time reached.
    static func drive(_ engine: PlaybackEngine, lead: Double, seconds: Double) async throws -> Double {
        let t0 = CACurrentMediaTime()
        var started = CACurrentMediaTime(), rate = engine.player.rate
        while CACurrentMediaTime() - t0 < seconds {
            let now = CACurrentMediaTime()
            if engine.player.rate != rate { rate = engine.player.rate; if rate != 0 { started = now } }   // clock (re)start
            _ = engine.pixelBuffer(forHostTime: now - started < lead ? now - lead : now)
            try await Task.sleep(nanoseconds: 8_000_000)
        }
        return engine.currentTime.seconds
    }

    @Test func clockLeadBeforeTheSeekTargetIsNotAStall() async throws {
        var p = TestProject()
        _ = try await p.addMedia(try await TestMedia.video(.frameIndex, seconds: 10, audioHz: 440))
        let project = p.project
        try await HeavyWorkGate.run {
            let engine = PlaybackEngine(project: project)
            engine.usesProxies = false
            try await PlaybackProbe.waitReady(engine)
            // seek → play, resume in place, rate change (each restarts the clock)
            engine.seek(to: Time(2))
            engine.play()
            let a = try await Self.drive(engine, lead: 0.5, seconds: 2)
            #expect(a > 3, "playback from 2 s reached \(a) s")
            engine.pause()
            let paused = engine.currentTime.seconds
            engine.play()
            let b = try await Self.drive(engine, lead: 0.5, seconds: 2)
            #expect(b > paused + 1, "resume from \(paused) s reached \(b) s")
            engine.setRate(2)
            let c = try await Self.drive(engine, lead: 0.5, seconds: 1)
            #expect(c > b + 1.2, "2× from \(b) s reached \(c) s")
            engine.pause()
            #expect(engine.stallRecoveries == 0)
            #expect(engine.stallRebuilds == 0)
        }
    }
}
