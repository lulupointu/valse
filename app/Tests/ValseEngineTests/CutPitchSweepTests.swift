@preconcurrency import AVFoundation
import Testing
import Foundation
import ValseCore
@testable import ValseEngine
import ValseTestSupport

/// Owner report "laser saber": at a cut between clips the audio sweeps in pitch. A pure tone through a cut must stay a
/// pure tone: every half period of the output stays within a few percent of the source's, any sweep (resampler or
/// time-stretch ramp, filter restart) shows as a run of stretched / squeezed half periods.
@MainActor @Suite(.serialized)
struct CutPitchSweepTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String, sourceRate: Double, speedA: Double, speedB: Double
        var testDescription: String { name }
    }

    /// Half periods (seconds) of the zero crossings of `x`, with the time of each (linear interpolation).
    static func halfPeriods(_ x: [Float], rate: Double = 48000) -> [(t: Double, half: Double)] {
        var out: [(Double, Double)] = []
        var last: Double?
        for i in 1..<x.count where (x[i - 1] < 0) != (x[i] < 0) && x[i - 1] != x[i] {
            let frac = Double(x[i - 1]) / Double(x[i - 1] - x[i])
            let t = (Double(i - 1) + frac) / rate
            if let l = last { out.append((t, t - l)) }
            last = t
        }
        return out
    }

    /// Times where the half period leaves ±`tol` of `nominal` (after amplitude is established: skip `skip` seconds).
    static func anomalies(_ x: [Float], hz: Double, tol: Double, from: Double, to: Double) -> [(t: Double, ratio: Double)] {
        let nominal = 0.5 / hz
        return halfPeriods(x).filter { $0.t >= from && $0.t <= to && abs($0.half / nominal - 1) > tol }.map { ($0.t, $0.half / nominal) }
    }

    /// Start times of 2.5 ms windows (> one half period of 440 Hz: each holds a peak) whose peak is under 90 % of
    /// `amplitude`, over [from, to).
    static func weakWindows(_ x: [Float], amplitude: Float, from: Double, to: Double, rate: Double = 48000) -> [Double] {
        let w = Int(0.0025 * rate)
        return stride(from: Int(from * rate), to: min(x.count, Int(to * rate)) - w, by: w).filter { s in
            x[s ..< s + w].reduce(Float(0)) { max($0, abs($1)) } < 0.9 * amplitude
        }.map { Double($0) / rate }
    }

    nonisolated static let cases: [Case] = [
        Case(name: "split 1x 48k", sourceRate: 48000, speedA: 1, speedB: 1),
        Case(name: "split 1x 44.1k", sourceRate: 44100, speedA: 1, speedB: 1),
        Case(name: "split 1.5x both", sourceRate: 48000, speedA: 1.5, speedB: 1.5),
        Case(name: "1x | 1.5x", sourceRate: 48000, speedA: 1, speedB: 1.5),
        Case(name: "1.5x | 1x", sourceRate: 48000, speedA: 1.5, speedB: 1),
        Case(name: "1x | 0.5x", sourceRate: 48000, speedA: 1, speedB: 0.5),
        Case(name: "2x | 1x 44.1k", sourceRate: 44100, speedA: 2, speedB: 1),
    ]

    /// What it protects: across a cut between clips (same or different speeds, 48 / 44.1 kHz), a pure tone stays a pure
    /// tone at its level — no pitch sweep (half periods), no drop-out or fade (2.5 ms window peaks), ±6 ms around the
    /// cut left to the 3 ms anti-click ramps.
    ///
    /// FLAKY-PB ("1.5x | 1x": anomalies at 0.9916 / 0.9921 s, 2/20 runs alone, same values every time): the lane's last
    /// stretched clip never got its tail pad, and the stretcher either dropped the clip's last ~60 ms — silence, which
    /// the zero-crossing check cannot see, so that run passed — or delivered them fading out (the "anomalies"). Which of
    /// the two varied per mixdown in one process (probe: 2/40). Fixed in `CompositionBuilder.packAudio` (the last clip
    /// is padded too); the level check makes the silence a failure as well (before the fix: 60 ms silent before the cut
    /// in "1.5x | 1x", 50 ms in "2x | 1x 44.1k", deterministic). It also found the stretcher's start-up dip (30-60 % for
    /// ~20 ms) of a stretched clip after silence ("1x | 1.5x", "1x | 0.5x"): fixed with a head pre-roll.
    /// Not checked here: a slowed clip at the PROJECT's end can still lose its last ~0.1 s (the export reader stops at
    /// the end before the stretcher delivers it; reported separately).
    @Test(arguments: cases)
    func tonePitchStaysConstantAcrossACut(_ c: Case) async throws {
        var p = TestProject(frameRate: .fps30)
        let id = try await p.addAudio(AudioTestSignals.sine(440, seconds: 6, amplitude: 0.5, sampleRate: c.sourceRate, channels: 2))
        p[id].duration = Time(3.0)
        let cut = Time(1.5)
        let right = try TimelineOps.split(id, at: cut, in: &p.project.timeline)
        if c.speedA != 1 { try TimelineOps.setSpeed(id, .constant(c.speedA), in: &p.project.timeline) }
        if c.speedB != 1 { try TimelineOps.setSpeed(right, .constant(c.speedB), in: &p.project.timeline) }
        p[right].start = p[id].end   // butted, whatever the speeds
        let cutOut = p[right].start.seconds
        let mix = try await p.mixdown().channel(0)
        // (the 2 ms edge ramp of the clip starting at the cut is not a sweep: skip the first 3 ms after it)
        let bad = Self.anomalies(mix, hz: 440, tol: 0.08, from: 0.1, to: p[right].end.seconds - 0.1)
            .filter { abs($0.t - cutOut) > 0.003 }
        // the level too: zero crossings only see where there IS signal, a dropped or fading stretch shows no anomaly
        // (around the cut, the subject here: the project's end has a defect of its own, see the doc comment)
        let weak = Self.weakWindows(mix, amplitude: 0.5, from: max(0.1, cutOut - 0.5), to: min(p[right].end.seconds - 0.1, cutOut + 0.5))
            .filter { abs($0 - cutOut) > 0.006 }
        let w = Int(0.0025 * 48000), c0 = Int((cutOut - 0.02) * 48000)
        let peaks = (0..<16).map { k in mix[(c0 + k * w) ..< (c0 + (k + 1) * w)].reduce(Float(0)) { max($0, abs($1)) } }
        print("PITCHSWEEP \(c.name): cut at \(cutOut) s; anomalies \(bad.prefix(12).map { String(format: "%.4f×%.2f", $0.t, $0.ratio) }); weak \(weak.prefix(12).map { String(format: "%.4f", $0) }); peaks from cut − 20 ms \(peaks.map { String(format: "%.2f", $0) })")
        #expect(bad.isEmpty, "\(c.name): pitch leaves 440 Hz at \(bad.prefix(6).map { String(format: "%.4f s (%.2f×)", $0.t, $0.ratio) })")
        #expect(weak.isEmpty, "\(c.name): the tone drops below 90 % of its level at \(weak.prefix(6).map { String(format: "%.4f s", $0) }) (\(weak.count) windows of 2.5 ms)")
    }
}
