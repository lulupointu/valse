@preconcurrency import AVFoundation
import Testing
import Foundation
import ValseCore
@testable import ValseEngine

/// BUG-CUT-AUDIO-HOLE: the preview tap-label lead override (`TapLabelLead`, `LaneProcessor.leadBuffers`) and the tap
/// stamp capture (`TapDiagnostics`).
@Suite struct TapLabelLeadTests {
    final class Times: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Double] = []
        func add(_ t: Double) { lock.withLock { values.append(t) } }
        var all: [Double] { lock.withLock { values } }
    }

    /// Composition time the lane gives the first frame of a buffer stamped 10 s, per lead mode.
    @Test(arguments: [0, 1, 2])
    func leadModeShiftsTheBufferTime(lead: Int) {
        let state = AudioMixState()
        let times = Times()
        state.tapCapture = { t, _, _, _ in times.add(t) }
        let p = LaneProcessor(clips: [], state: state, gains: nil, leadBuffers: lead)
        p.prepare(sampleRate: 48000, channels: 2, maxFrames: 4096)
        _ = LaneGainTests.run(p, at: 10, frames: 4096)
        let span = 4096.0 / 48000
        #expect(abs(times.all[0] - (10 + Double(lead) * span)) < 1e-9)
    }

    /// Export lanes (no lead) and the legacy flag keep their meaning.
    @Test func legacyFlagMeansOneBuffer() {
        #expect(LaneProcessor(clips: [], state: AudioMixState(), labelsLeadOneBuffer: true).leadBuffers == 1)
        let export = LaneProcessor(clips: [], state: AudioMixState())
        #expect(export.leadBuffers == 0 && !export.followsPlayerRate)
        let preview0 = LaneProcessor(clips: [], state: AudioMixState(), leadBuffers: 0)
        #expect(preview0.leadBuffers == 0 && preview0.followsPlayerRate)
    }

    @Test func overrideResolution() throws {
        let suite = "valse.tests.taplead.\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        func mode(_ env: [String: String] = [:]) -> String {
            let m = TapLabelLead.preview(defaults: d, environment: env)
            return "\(m.buffers) \(m.source)"
        }
        #expect(mode() == "1 auto")
        d.set(0, forKey: TapLabelLead.defaultsKey)
        #expect(mode() == "0 defaults")
        d.set("2", forKey: TapLabelLead.defaultsKey)
        #expect(mode() == "2 defaults")
        d.set(7, forKey: TapLabelLead.defaultsKey)   // out of range → automatic
        #expect(mode() == "1 auto")
        #expect(mode([TapLabelLead.environmentKey: "0"]) == "0 env")
    }

    /// The first buffers after a prepare / reset are recorded raw (stamp, frames, duration, rate, sound) and published
    /// once per capture; a partial capture is published at the next reset.
    @Test func capturesTheFirstBuffersAfterReset() throws {
        let state = AudioMixState()
        let p = LaneProcessor(clips: [], state: state, gains: nil, leadBuffers: 1, lane: 3)
        p.prepare(sampleRate: 48000, channels: 2, maxFrames: 4096)
        #expect(state.tapDiagnostics.take().isEmpty)
        let span = 4096.0 / 48000
        for i in 0..<9 { _ = LaneGainTests.run(p, at: 54 + Double(i) * span, frames: 4096) }
        let first = state.tapDiagnostics.take()
        #expect(first.count == 1)
        let c = try #require(first.first)
        #expect(c.lane == 3 && c.leadBuffers == 1)
        #expect(c.buffers.count == TapDiagnostics.buffersPerCapture)
        #expect(c.buffers.first?.stamp == CMTime(seconds: 54, preferredTimescale: 48000).seconds)
        #expect(c.buffers.allSatisfy { $0.frames == 4096 && $0.sampleRate == 48000 && $0.sounding })
        #expect(abs((c.buffers.first?.duration ?? 0) - span) < 1e-6)
        #expect(state.tapDiagnostics.take().isEmpty, "steady playback publishes nothing more")

        p.reset()   // seek
        _ = LaneGainTests.run(p, at: nil, frames: 512)
        _ = LaneGainTests.run(p, at: 60, frames: 512)
        p.reset()   // next seek before 6 buffers: the partial capture is published
        let partial = try #require(state.tapDiagnostics.take().first)
        #expect(partial.buffers.count == 2)
        #expect(partial.buffers.first?.stamp.isNaN == true)
        #expect(partial.buffers.last?.frames == 512)
        let line = TapDiagnostics.describe(partial)
        #expect(line.contains("lane 3") && line.contains("nostamp") && line.contains("60.0000"))
    }

    /// The lane records each captured buffer's first sounding sample and the label it used (stamp + lead).
    @Test func recordsFirstSoundAndLabel() throws {
        let state = AudioMixState()
        let p = LaneProcessor(clips: [], state: state, gains: nil, leadBuffers: 1)
        p.prepare(sampleRate: 48000, channels: 2, maxFrames: 4096)
        for i in 0..<6 { _ = LaneGainTests.run(p, at: 2 + Double(i * 4096) / 48000, frames: 4096) }
        let c = try #require(state.tapDiagnostics.take().first)
        #expect(c.buffers.allSatisfy { $0.firstSound == 0 })
        #expect(abs(c.buffers[0].label - (CMTime(seconds: 2, preferredTimescale: 48000).seconds + 4096.0 / 48000)) < 1e-9)
    }

    /// Self-check against the seek target: the macOS 26 spectral-lane shape (preroll silence stamped from
    /// target − 2 × 4096 frames, then the target's audio stamped target − 4096) reads raw onset −85.3 ms and, with the
    /// one-buffer lead, labelled onset 0; exact stamps read 0 raw.
    @Test func selfCheckAgainstTheSeekTarget() {
        let s = 4096.0 / 48000
        func rec(_ stamp: Double, _ first: Int, lead: Double = s) -> TapBufferRecord {
            TapBufferRecord(stamp: stamp, frames: 4096, duration: s, sampleRate: 48000, sounding: first >= 0, firstSound: first,
                            label: stamp + lead)
        }
        let early = TapDiagnostics.Capture(lane: 0, leadBuffers: 1,
                                           buffers: [rec(.nan, -1), rec(2 - 2 * s, -1), rec(2 - s, 0), rec(2, 0)])
        let k = TapDiagnostics.selfCheck(early, target: 2, rate: 1)
        #expect(abs((k.firstStamp ?? 0) * 1000 + 170.67) < 0.01)
        #expect(abs((k.rawOnset ?? 0) * 1000 + 85.33) < 0.01)
        #expect(abs(k.onset ?? 1) < 1e-9)
        let exact = TapDiagnostics.Capture(lane: 1, leadBuffers: 0, buffers: [rec(2 - s, -1, lead: 0), rec(2, 0, lead: 0)])
        #expect(abs(TapDiagnostics.selfCheck(exact, target: 2, rate: 1).rawOnset ?? 1) < 1e-9)
        // sound mid-buffer at 2×: offset × rate / sample rate
        let mid = TapDiagnostics.Capture(lane: 2, leadBuffers: 0, buffers: [rec(1.9, 4800, lead: 0)])
        #expect(abs((TapDiagnostics.selfCheck(mid, target: 2, rate: 2).rawOnset ?? 1) - 0.1) < 1e-9)
        let line = TapDiagnostics.describe(early, target: 2, rate: 1)
        #expect(line.contains("first stamp -170.7 ms") && line.contains("sound onset raw -85.3 ms / labelled +0.0 ms"))
    }
}
