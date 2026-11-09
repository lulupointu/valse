@preconcurrency import AVFoundation
import Testing
import Foundation
import QuartzCore
import ValseCore
@testable import ValseEngine
import ValseTestSupport

/// BUG-CUT-AUDIO-HOLE (docs/investigations/BUG-METALLIC-AUDIO.md, "Part 3: root cause"): the composition time a lane
/// tap gives its buffers — what the clip gains, fades and live-effect switches use — measured against the CONTENT the
/// buffers carry (irregular 30 ms noise bursts located in the source decoded offline), preview (AVPlayer) and export.
/// ACCEPTANCE TESTS FOR THE FUTURE FIX, opt-in (`VALSE_TAP_PROBE=1`): on main (spectral lanes + one-buffer lead) they
/// pass for an unscaled 48 kHz clip at rate 1 on a 4096-frame output only; they fail, measured on Apple Silicon /
/// macOS 26, for sped-up / slowed clips (labels one buffer late: the stretcher stamps scaled segments exactly), J/K/L
/// (lead = the stretcher latency at that rate, not a buffer), 44.1 kHz media (4096 frames of 44.1 kHz) and any output
/// whose buffers are not 4096 frames (AirPods: 8208). The macOS 13 owner Mac needs no lead at all.
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["VALSE_TAP_PROBE"] != nil))
struct CutAudioTimingTests {
    typealias Captured = MetallicAudioTests.Captured

    struct Case: Sendable, CustomTestStringConvertible {
        let speed: Double, rate: Float, curve: Bool, sourceRate: Double
        init(_ speed: Double = 1, rate: Float = 1, curve: Bool = false, sourceRate: Double = 48000) {
            self.speed = speed; self.rate = rate; self.curve = curve; self.sourceRate = sourceRate
        }
        var testDescription: String { "speed \(curve ? "curve" : "\(speed)") rate \(rate) \(Int(sourceRate)) Hz" }
    }

    /// A bursts clip at 1 s (6 s of source), with the case's speed.
    static func project(_ c: Case) async throws -> (TestProject, Clip) {
        var p = TestProject(frameRate: .fps30)
        let id = try await p.addMedia(try TapProbeTests.burstFile(rate: c.sourceRate), at: Time(1.0), duration: Time(6.0))
        if c.curve {
            try TimelineOps.setSpeed(id, .curve(SpeedCurve(points: [SpeedPoint(0, 0.7), SpeedPoint(1, 1.6)])), in: &p.project.timeline)
        } else if c.speed != 1 {
            try TimelineOps.setSpeed(id, .constant(c.speed), in: &p.project.timeline)
        }
        // reference: the composition's own remap (a curve plays as frame-accurate constant-speed pieces)
        let clip = p[id]
        var remap = TapProbeTests.Remap()
        let asset = try #require(p.project.asset(clip.mediaID!))
        for s in CompositionBuilder.remapSegments(clip, asset: asset, frameRate: p.project.settings.frameRate) {
            remap.segs.append(((clip.start + s.output.start).seconds, (clip.start + s.output.end).seconds,
                               (clip.sourceStart + s.source.start).seconds, s.source.duration.seconds / s.output.duration.seconds))
        }
        TapProbeTests.remap = { remap.source(at: $0) ?? clip.sourceTime(at: Time($0)).seconds }
        return (p, clip)
    }

    /// Lead (s) = content time − label: envelope alignment, refined on the burst onsets (median).
    static func lead(_ caps: [Captured], clip: Clip, playerRate: Double) async throws -> (lead: Double, bursts: Int, corr: Double) {
        let src = try await AudioFileIO.read(try TapProbeTests.burstFile(), sampleRate: 48000, channels: 1).channel(0)
        let env = TapProbeTests.envelopeLead(caps, clip: clip, playerRate: playerRate, source: src)
        let l = TapProbeTests.leads(caps, clip: clip, playerRate: playerRate, coarse: env.lead / 1000).map(\.lead).sorted()
        return (l.isEmpty ? env.lead / 1000 : l[l.count / 2], l.count, env.corr)
    }

    nonisolated static let previewCases: [Case] = [Case(), Case(2), Case(0.5), Case(1.5), Case(curve: true), Case(rate: 2),
                                                    Case(rate: 0.5), Case(sourceRate: 44100)]

    @Test(arguments: previewCases)
    func previewLabelsFollowTheContent(_ c: Case) async throws {
        let (p, clip) = try await Self.project(c)
        let project = p.project
        let cap = MetallicAudioTests.Capture()
        try await HeavyWorkGate.run {
            let engine = PlaybackEngine(project: project)
            engine.usesProxies = false
            try await PlaybackProbe.waitReady(engine)
            MetallicAudioTests.record(engine, into: cap)
            defer { engine.audioState.tapCapture = nil }
            engine.seek(to: Time(1.3))
            if c.rate == 1 { engine.play() } else { engine.setRate(c.rate) }
            // ≥ 2 s of item time (bounded in wall time for a loaded machine)
            let t0 = CACurrentMediaTime()
            while engine.currentTime.seconds < min(3.5, clip.end.seconds - 0.3), CACurrentMediaTime() - t0 < 30 {
                _ = engine.pixelBuffer(forHostTime: CACurrentMediaTime())
                try await Task.sleep(nanoseconds: 4_000_000)
            }
            engine.pause()
        }
        let m = try await Self.lead(cap.snapshot, clip: clip, playerRate: Double(c.rate))
        print(String(format: "CUTTIMING preview %@: lead %+.2f ms (%d bursts, envelope corr %.3f)", c.testDescription, m.lead * 1000, m.bursts, m.corr))
        // (the spectral stretch smears the bursts: then the envelope alignment alone, 1 ms bins)
        try #require(m.bursts >= 3 || m.corr > 0.5, "no alignment (\(m.bursts) bursts, corr \(m.corr)): loaded machine?")
        // target: labels within a few ms of the content at rate 1, ≤ 40 ms at J/K/L
        let range = c.rate == 1 ? -0.005 ... 0.005 : -0.040 ... 0.040
        #expect(range.contains(m.lead), "preview \(c.testDescription): labels \(String(format: "%+.1f", -m.lead * 1000)) ms off the content")
    }

    @Test(arguments: [Case(), Case(2), Case(0.5), Case(curve: true), Case(sourceRate: 44100)])
    func exportLabelsAreExact(_ c: Case) async throws {
        let (p, clip) = try await Self.project(c)
        let state = AudioMixState()
        let cap = MetallicAudioTests.Capture()
        state.tapCapture = { t, s, rate, step in cap.add(Captured(wall: 0, time: t, samples: Array(s), rate: rate, step: step)) }
        _ = try await AudioMixdown.render(p.project, range: TimeRange(start: .zero, duration: clip.end), audioState: state)
        let m = try await Self.lead(cap.snapshot, clip: clip, playerRate: 1)
        print(String(format: "CUTTIMING export %@: lead %+.2f ms (%d bursts, envelope corr %.3f)", c.testDescription, m.lead * 1000, m.bursts, m.corr))
        // (the spectral stretch smears the bursts on scaled segments: envelope only, 1 ms bins)
        let tol = c.speed == 1 && !c.curve ? 0.0005 : 0.0025
        #expect(abs(m.lead) <= tol, "export \(c.testDescription): labels \(String(format: "%+.2f", -m.lead * 1000)) ms off")
    }

    /// The owner's cut (BUG-CUT-AUDIO-HOLE): main track A | B with B fading in from the cut, and a 0.2 s audio clip over
    /// the cut fading out just after it. The lanes' outputs, placed at their labels (what the mixer sums, up to the
    /// common label offset), never fall silent around the cut — preview (85 ms of exact zeros there on the owner's
    /// Mac) and export. Noise sources: any silence comes from the gains.
    @Test func noHoleAtACutWithFades() async throws {
        var p = TestProject(frameRate: .fps30)
        let noise = try MetallicAudioTests.noiseFile()
        let a = try await p.addMedia(noise, at: .zero, duration: Time(2.0))
        let mainIndex = try #require(p.project.timeline.locate(a)?.track)
        let mainTrack = p.project.timeline.tracks[mainIndex].id
        let b = try await p.addMedia(noise, at: Time(2.0), target: .track(mainTrack), duration: Time(2.0))
        p[b].sourceStart = Time(2.5)
        p[b].audio.fadeIn = Time(0.3)
        let over = try await p.addMedia(noise, at: Time(1.9), target: .newTrack, duration: Time(0.2))
        p[over].sourceStart = Time(4.0)
        p[over].audio.fadeOut = Time(0.15)
        #expect(p.project.timeline.locate(over)?.track != mainIndex)
        #expect(p.project.timeline.locate(b)?.track == mainIndex)
        let project = p.project
        // preview
        let cap = MetallicAudioTests.Capture()
        try await HeavyWorkGate.run {
            let engine = PlaybackEngine(project: project)
            engine.usesProxies = false
            try await PlaybackProbe.waitReady(engine)
            MetallicAudioTests.record(engine, into: cap)
            defer { engine.audioState.tapCapture = nil }
            engine.seek(to: Time(1.2))
            engine.play()
            let t0 = CACurrentMediaTime()
            while engine.currentTime.seconds < 2.8, CACurrentMediaTime() - t0 < 30 {
                _ = engine.pixelBuffer(forHostTime: CACurrentMediaTime())
                try await Task.sleep(nanoseconds: 4_000_000)
            }
            engine.pause()
        }
        var placed = [Float](repeating: 0, count: 4 * 48000)
        var covered = [Bool](repeating: false, count: placed.count)
        for c in cap.snapshot where c.time.isFinite {
            let i0 = Int((c.time * c.rate).rounded())
            for (k, v) in c.samples.enumerated() where i0 + k >= 0 && i0 + k < placed.count { placed[i0 + k] += v * v; covered[i0 + k] = true }
        }
        let lo = Int(1.6 * 48000), hi = Int(2.4 * 48000)
        try #require(covered[lo..<hi].allSatisfy { $0 }, "the play did not cover the cut (loaded machine?)")
        #expect(Self.silentWindows(placed, lo ..< hi).isEmpty, "preview: silent 5 ms windows at \(Self.silentWindows(placed, lo ..< hi)) s")
        // export
        let mix = try await p.mixdown(seconds: 3).channel(0).map { $0 * $0 }
        #expect(Self.silentWindows(mix, lo ..< hi).isEmpty, "export: silent 5 ms windows at \(Self.silentWindows(mix, lo ..< hi)) s")
    }

    /// Start times (s) of 5 ms windows of `energy[range]` with (almost) no energy.
    static func silentWindows(_ energy: [Float], _ range: Range<Int>) -> [Double] {
        stride(from: range.lowerBound, to: range.upperBound - 240, by: 240).filter { s in
            energy[s ..< s + 240].reduce(0, +) / 240 < 1e-6
        }.map { Double($0) / 48000 }
    }
}
