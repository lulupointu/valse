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

    nonisolated static let cases: [Case] = [
        Case(name: "split 1x 48k", sourceRate: 48000, speedA: 1, speedB: 1),
        Case(name: "split 1x 44.1k", sourceRate: 44100, speedA: 1, speedB: 1),
        Case(name: "split 1.5x both", sourceRate: 48000, speedA: 1.5, speedB: 1.5),
        Case(name: "1x | 1.5x", sourceRate: 48000, speedA: 1, speedB: 1.5),
        Case(name: "1.5x | 1x", sourceRate: 48000, speedA: 1.5, speedB: 1),
        Case(name: "1x | 0.5x", sourceRate: 48000, speedA: 1, speedB: 0.5),
        Case(name: "2x | 1x 44.1k", sourceRate: 44100, speedA: 2, speedB: 1),
    ]

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
        print("PITCHSWEEP \(c.name): cut at \(cutOut) s; anomalies \(bad.prefix(12).map { String(format: "%.4f×%.2f", $0.t, $0.ratio) })")
        #expect(bad.isEmpty, "\(c.name): pitch leaves 440 Hz at \(bad.prefix(6).map { String(format: "%.4f s (%.2f×)", $0.t, $0.ratio) })")
    }
}
