@preconcurrency import AVFoundation
import Foundation
import QuartzCore
import Testing
import ValseCore
@testable import ValseEngine
import ValseTestSupport

/// BUG-AIRPODS-SILENT part 2 (measured at the process output on the owner's AirPods, latency 0.171 s): the renderer
/// needs each sample about one output latency before the clock reaches it and drops the late ones without an error.
/// The feeder kept 0.15 s enqueued past the clock: every sample came late, the preview was silent for the whole play.
/// The enqueue horizon is now max(`ahead`, latency + `feedMargin`). The latency is injected (`latencyProvider`) so the
/// tests don't depend on this machine's output device.
@Suite(.serialized) struct PreviewAudioHorizonTests {
    let dir = TestMedia.directory

    @Test func horizonCoversTheOutputLatency() {
        #expect(PreviewAudio.feedAhead(0.15, outputLatency: 0) == 0.2)
        #expect(PreviewAudio.feedAhead(0.5, outputLatency: 0.01) == 0.5)
        let airPods = 0.171
        #expect(PreviewAudio.feedAhead(0.15, outputLatency: airPods) >= airPods + 0.2)
        let audio = PreviewAudio(audioState: AudioMixState())
        audio.latencyProvider = { _ in airPods }
        #expect(abs(audio.feedAhead - (airPods + PreviewAudio.feedMargin)) < 1e-9)
        audio.stop()
    }

    /// Largest lead (enqueued end − clock, s) seen while the clock goes from `from` to `until`.
    static func maxLead(latency: Double, from: Double, until: Double, dir: URL) async throws -> (lead: Double, horizon: Double) {
        let p = try await PreviewAudioCheck.cutProject(dir: dir)
        let state = AudioMixState(project: p)
        let built = try await PreviewAudioCheck.build(p, state: state)
        let audio = PreviewAudio(audioState: state)
        defer { audio.stop() }
        audio.latencyProvider = { _ in latency }
        audio.load(built, at: 0.3)
        audio.play()
        let started = await PreviewAudioCheck.wait(30) { audio.currentTime >= from }
        #expect(started, "the clock never reached \(from) (at \(audio.currentTime), \(audio.stats))")
        var lead = 0.0
        let t0 = CACurrentMediaTime()
        while audio.currentTime < until, CACurrentMediaTime() - t0 < 30 {
            lead = max(lead, audio.stats.enqueuedEnd - audio.currentTime)
            try await Task.sleep(nanoseconds: 3_000_000)
        }
        audio.pause()
        return (lead, audio.feedAhead)
    }

    /// While playing, the feeder keeps at least the output latency + margin enqueued past the clock (AirPods), and no
    /// more than the horizon + one chunk.
    @Test func feederStaysAheadOfTheOutputLatency() async throws {
        let latency = 0.171
        let r = try await Self.maxLead(latency: latency, from: 0.6, until: 2.0, dir: dir)
        print(String(format: "PREVIEWAUDIO horizon latency %.3f: max lead %.3f s (horizon %.3f s)", latency, r.lead, r.horizon))
        let chunk = Double(PreviewAudio.chunkFrames) / PreviewAudio.sampleRate
        #expect(r.lead >= latency + PreviewAudio.feedMargin - chunk, "max lead \(r.lead) s past the clock")
        #expect(r.lead <= r.horizon + 2 * chunk, "max lead \(r.lead) s past the clock (horizon \(r.horizon))")
    }

    /// A low-latency output keeps the short horizon (edits heard quickly): ≈ `feedMargin`, never the AirPods one.
    @Test func lowLatencyOutputKeepsAShortHorizon() async throws {
        let r = try await Self.maxLead(latency: 0.005, from: 0.6, until: 1.6, dir: dir)
        print(String(format: "PREVIEWAUDIO horizon latency 0.005: max lead %.3f s (horizon %.3f s)", r.lead, r.horizon))
        let chunk = Double(PreviewAudio.chunkFrames) / PreviewAudio.sampleRate
        #expect(r.lead >= 0.15)
        #expect(r.lead <= 0.205 + 2 * chunk, "max lead \(r.lead) s past the clock")
    }
}

/// Opt-in, real output (the orchestrator runs it on AirPods): plays a 440 Hz project through `PlaybackEngine` on the
/// SYSTEM DEFAULT output and measures what the process sends there (`OutputCapture`, a MUTED process tap: nothing is
/// heard). Every play must sound for ≥ 90 % of [start + 0.5 s, start + 2 s).
/// `VALSE_REAL_OUTPUT=1 scripts/test.sh --filter PreviewAudioRealOutputTests` (macOS 14.2+).
@MainActor @Suite(.serialized) struct PreviewAudioRealOutputTests {
    static let enabled = ProcessInfo.processInfo.environment["VALSE_REAL_OUTPUT"] == "1"

    static func drive(_ engine: PlaybackEngine, seconds: Double) async throws {
        let start = CACurrentMediaTime()
        while CACurrentMediaTime() - start < seconds {
            _ = engine.pixelBuffer(forHostTime: CACurrentMediaTime())
            try await Task.sleep(nanoseconds: 8_000_000)
        }
    }

    @Test func previewSoundsOnTheDefaultOutput() async throws {
        guard Self.enabled else { print("skip: VALSE_REAL_OUTPUT"); return }
        guard #available(macOS 14.2, *) else { print("skip: macOS 14.2"); return }
        let uid = try #require(AudioDevices.defaultOutputUID(), "no default output device")
        let latency = AudioDevices.outputLatency(uid: nil) ?? 0
        var p = TestProject()
        _ = try await p.addMedia(try await TestMedia.video(.frameIndex, seconds: 12, audioHz: 440))
        let project = p.project
        let engine = PlaybackEngine(project: project)
        engine.usesProxies = false
        try await PlaybackProbe.waitReady(engine, timeout: 120)
        engine.audio.renderer.volume = 1   // tests export VALSE_MUTE_AUDIO (volume 0); the capture tap is muted
        defer { engine.audio.renderer.volume = AudioOutput.volume(1) }
        let capture = try OutputCapture(clockDeviceUID: uid)
        defer { capture.stop() }
        print(String(format: "REALOUTPUT device %@, latency %.3f s, horizon %.3f s, start lead %.3f s",
                     uid, latency, engine.audio.feedAhead, engine.audio.startLead))
        var failures: [String] = []
        // first play from 0, pause + play in place, seek + play
        for (i, seekTo) in [0.0, -1, 6.0].enumerated() {
            if seekTo >= 0 {
                engine.pause()
                engine.seek(to: Time(seekTo))
                try await Self.drive(engine, seconds: 0.5)
            }
            let launches = engine.launches
            engine.play()
            let t0 = CACurrentMediaTime()
            while engine.launches == launches, CACurrentMediaTime() - t0 < 10 { try await Self.drive(engine, seconds: 0.004) }
            let start = max(engine.scheduledStartHost, t0)
            try await Self.drive(engine, seconds: start + 2.1 - CACurrentMediaTime())
            engine.pause()
            let chunks = capture.chunks(from: start + 0.5, to: start + 2.0)
            let loud = chunks.filter { $0.peak > 0.005 }.count
            let share = chunks.isEmpty ? 0 : Double(loud) / Double(chunks.count)
            let rms = chunks.isEmpty ? 0 : chunks.map { Double($0.rms) }.reduce(0, +) / Double(chunks.count)
            let line = String(format: "play %d: %d / %d IO cycles loud (%.0f %%), mean RMS %.3f", i, loud, chunks.count, share * 100, rms)
            print("REALOUTPUT " + line)
            if chunks.count < 10 || share < 0.9 { failures.append(line) }
            try await Self.drive(engine, seconds: 0.3)
        }
        #expect(failures.isEmpty, "silent output on \(uid): \(failures)")
    }
}
