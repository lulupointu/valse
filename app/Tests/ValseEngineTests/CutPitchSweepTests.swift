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
    /// is padded too, unless it directly continues the lane's previous clip: padding that edit made the stretcher
    /// restart at the split, "split 1.5x both" 11/40); the level check makes the silence a failure as well (before the fix: 60 ms silent before the cut
    /// in "1.5x | 1x", 50 ms in "2x | 1x 44.1k", deterministic). It also found the stretcher's start-up dip (30-60 % for
    /// ~20 ms) of a stretched clip after silence ("1x | 1.5x", "1x | 0.5x"): fixed with a head pre-roll.
    /// FLAKY-PB2: the level is also checked up to the PROJECT's end. The mixdown reader stopped at the end before the
    /// stretcher delivered a stretched clip's last 20-120 ms (silent: "1x | 0.5x" from 4.38 s of 4.5, "1x | 1.5x"
    /// 2.4375-2.49, "split 1.5x both" 1.98-1.99): readers now read 0.5 s past the end (`Exporter.audioReadRange`), and
    /// the lane's last clip gets a 0.25 s tail pad (0.1 s still lost ~20 ms at 0.5×), an edit of its own when the clip
    /// continues the previous one ("split 1.5x both" dipped ~20 ms before the end under load: CutPitchSweepStressTests).
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
        // ... and up to the project's end (the clip's 3 ms end ramp aside): the export reader used to stop at the end
        // before the stretcher delivered the clip's last ~0.1 s
        let end = p[right].end.seconds
        let weakEnd = Self.weakWindows(mix, amplitude: 0.5, from: end - 0.5, to: end - 0.006)
        print("PITCHSWEEP \(c.name): end at \(end) s, \(mix.count) frames; weak before the end \(weakEnd.prefix(12).map { String(format: "%.4f", $0) })")
        #expect(weakEnd.isEmpty, "\(c.name): the tone drops below 90 % of its level before the project's end at \(weakEnd.prefix(6).map { String(format: "%.4f s", $0) }) (\(weakEnd.count) windows of 2.5 ms)")
    }

    /// What it protects (FLAKY-PB2): a slowed (0.5×) clip ending the project keeps its last ~0.1 s in a video export
    /// (the export's audio reader reads past the end, `Exporter.audioReadRange`, and the file still ends at the
    /// project's end). Before: its last ~120 ms were silent in the file. The tone is checked after an AAC round trip:
    /// 80 % of its level, up to 20 ms before the end (AAC's last frame).
    @Test func slowedClipAtTheEndKeepsItsTailInAVideoExport() async throws {
        var p = TestProject(frameRate: .fps30)
        let id = try await p.addAudio(AudioTestSignals.sine(440, seconds: 6, amplitude: 0.5, sampleRate: 48000, channels: 2))
        p[id].duration = Time(2.0)
        try TimelineOps.setSpeed(id, .constant(0.5), in: &p.project.timeline)
        let end = p[id].end.seconds
        #expect(abs(p.project.duration.seconds - end) < 0.001)
        var s = ExportSettings(); s.resolution = .p480
        let url = TestMedia.directory.appendingPathComponent("pb2-tail-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try await Exporter.export(project: p.project, settings: s, to: url)
        let info = try await MediaProbe.probe(url)
        #expect(abs(info.duration.seconds - end) < 0.05, "file duration \(info.duration.seconds) s, project \(end) s")
        let audio = try await AudioFileIO.read(url).channel(0)
        let asset = AVURLAsset(url: url)
        for t in try await asset.loadTracks(withMediaType: .audio) {
            let r = try await t.load(.timeRange)
            #expect(abs(r.end.seconds - end) < 0.03, "the exported audio track ends at \(r.end.seconds) s, project \(end) s")
        }
        let w = Int(0.0025 * 48000)
        let weak = stride(from: Int((end - 0.5) * 48000), to: min(audio.count, Int((end - 0.02) * 48000)) - w, by: w).filter { s in
            audio[s ..< s + w].reduce(Float(0)) { max($0, abs($1)) } < 0.8 * 0.5
        }.map { Double($0) / 48000 }
        print("PITCHSWEEP export: \(audio.count) frames, end \(end) s, weak \(weak.prefix(12).map { String(format: "%.4f", $0) })")
        #expect(audio.count >= Int((end - 0.02) * 48000), "the exported audio stops at \(Double(audio.count) / 48000) s")
        #expect(weak.isEmpty, "the slowed clip's tail is missing from the export at \(weak.prefix(6).map { String(format: "%.4f s", $0) }) (\(weak.count) windows of 2.5 ms)")
    }
}
