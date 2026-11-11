@preconcurrency import AVFoundation
import Testing
import Foundation
import QuartzCore
import ValseCore
@testable import ValseEngine
import ValseTestSupport

/// BUG-AIRPODS-SILENT: an `AVSampleBufferAudioRenderer` started with `setRate(_:time:atHostTime:)` closer than the
/// output latency stays silent for the whole playback (AirPods: ≈ 171 ms). Every scheduled start leads by at least the
/// output latency + a margin; the latency is injected so the tests don't depend on this machine's output device.
@MainActor @Suite(.serialized) struct PlaybackStartLeadTests {
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var uids: [String?] = []
        func add(_ uid: String?) { lock.withLock { uids.append(uid) } }
        var all: [String?] { lock.withLock { uids } }
    }

    @Test func leadCoversTheOutputLatency() {
        #expect(PreviewAudio.startLead(outputLatency: 0) >= PreviewAudio.minStartLead)
        #expect(PreviewAudio.startLead(outputLatency: 0.002) < 0.04)   // built-in speakers: a short lead as before
        let airPods = 0.171
        #expect(PreviewAudio.startLead(outputLatency: airPods) >= airPods + 0.02)
        #expect(PreviewAudio.startLead(outputLatency: airPods) < airPods + 0.05)
    }

    @Test func latencyIsCachedAndRefreshedOnDeviceAndConfigurationChanges() {
        let audio = PreviewAudio(audioState: AudioMixState())
        let calls = Calls()
        audio.latencyProvider = { uid in calls.add(uid); return 0.171 }
        #expect(abs(audio.outputLatency - 0.171) < 1e-9)
        #expect(audio.startLead >= 0.171 + 0.02)
        let before = calls.all.count
        _ = audio.startLead; _ = audio.startLead   // cached: no CoreAudio query per start
        #expect(calls.all.count == before)

        audio.outputConfigurationChanged()   // default output changed (AirPods connected)
        #expect(calls.all.count == before + 1)

        audio.latencyProvider = { _ in nil }   // unknown → the short default lead
        #expect(audio.outputLatency == 0)
        #expect(audio.startLead == PreviewAudio.startLead(outputLatency: 0))
        audio.stop()
    }

    /// The engine schedules the video and the audio start at least the output latency ahead (same pair for both).
    @Test func engineStartLeadsByTheOutputLatency() async throws {
        var p = TestProject()
        _ = try await p.addMedia(try await TestMedia.video(.frameIndex, seconds: 4, audioHz: 440))
        let project = p.project
        try await HeavyWorkGate.run {
            let engine = PlaybackEngine(project: project)
            engine.usesProxies = false
            engine.audio.latencyProvider = { _ in 0.171 }
            try await PlaybackProbe.waitReady(engine)
            #expect(engine.startLead.seconds >= 0.171 + 0.02)
            let launches = engine.launches
            let asked = CACurrentMediaTime()
            engine.play()
            let t0 = CACurrentMediaTime()
            while engine.launches == launches, CACurrentMediaTime() - t0 < 10 {
                try await Task.sleep(nanoseconds: 4_000_000)
            }
            #expect(engine.launches > launches, "playback never launched")
            #expect(engine.scheduledStartHost - asked >= 0.171, "start scheduled \(Int((engine.scheduledStartHost - asked) * 1000)) ms ahead")
            // the audio clock starts with the video: it reaches the scheduled host time and runs
            let t1 = CACurrentMediaTime()
            while !engine.audio.isRunning || CACurrentMediaTime() < engine.scheduledStartHost + 0.1, CACurrentMediaTime() - t1 < 5 {
                _ = engine.pixelBuffer(forHostTime: CACurrentMediaTime())
                try await Task.sleep(nanoseconds: 4_000_000)
            }
            #expect(engine.audio.isRunning)
            engine.pause()
        }
    }
}
