@preconcurrency import AVFoundation
import Testing
import Foundation
import QuartzCore
import ValseCore
@testable import ValseEngine
import ValseTestSupport

/// BUG-SPEED-AUDIO-TAIL ("speeding up a clip cuts its end audio") and BUG-CUT-AUDIO-ARTEFACT ("a split in the middle of
/// a sentence sounds weird"). Root cause of both: on a speed-scaled segment the lane tap's buffer `duration` is the
/// span × speed² (4× at 2×), so the clip gains — applied in the tap — muted the end of every sped-up clip and the frames
/// before each cut (export: up to ¾ of a 512-frame buffer; preview: the one-buffer lead added 256 ms at 2×). The step is
/// now measured from consecutive timestamps (`LaneProcessor.step`).
@MainActor @Suite(.serialized) struct SplitSpeedAudioTests {
    // MARK: lane processor (pure)

    /// A buffer of 1.0 straddling the end of a 2× clip whose tap reports `duration` = span × 4 (what AVFoundation does):
    /// the gain must stay 1 up to the clip end and fall to 0 exactly there.
    @Test(arguments: [false, true])
    func tapStepOnSpedUpSegmentFollowsTheTimestamps(leads: Bool) {
        var clip = Clip(content: .solid(.black), start: .zero, duration: Time(1.5))
        clip.speed = .constant(2)
        let p = LaneProcessor(clips: [clip], state: AudioMixState(),
                              gains: [GainRamp(start: .zero, end: Time(1.5), from: 1, to: 1)], labelsLeadOneBuffer: leads)
        p.prepare(sampleRate: 48000, channels: 2, maxFrames: 4096)
        let n = 512, span = Double(n) / 48000
        // consecutive buffers; with `leads` each is stamped one buffer early (AVPlayer)
        var t = 1.4 - (leads ? span : 0)
        var out: [Float] = []
        var times: [Double] = []
        while out.count < 48000 / 5 {
            times.append(t + (leads ? span : 0))
            out += LaneGainTests.run(p, at: t, frames: n, rate: 4)   // duration = span × speed²
            t += span
        }
        let start = times[0]
        let cut = Int(((1.5 - start) * 48000).rounded())
        #expect(out[0..<(cut - 1)].allSatisfy { $0 == 1 }, "the clip's last \(String(format: "%.1f", Double(cut - (out.firstIndex { $0 != 1 } ?? cut)) / 48))  ms were muted")
        // (± 1 frame: the stamps here are accumulated doubles)
        #expect(out[(cut + 2)...].allSatisfy { $0 == 0 })
    }

    /// A seek (stamp jump) is not a buffer span: the step falls back to the player rate on a scaled segment.
    @Test func stepIgnoresSeeksAndUsesThePlayerRate() {
        let nominal = 1.0 / 48000
        let d = CMTime(seconds: 512 * nominal * 4, preferredTimescale: 48000)
        let s0 = LaneProcessor.step(stamp: 1.0, previous: nil, lastStep: nil, frames: 512, duration: d, sampleRate: 48000,
                                    speed: { _ in 2 })
        #expect(abs(s0 - nominal) < 1e-12)
        let s1 = LaneProcessor.step(stamp: 3.0, previous: (1.0, 512), lastStep: nominal, frames: 512, duration: d,
                                    sampleRate: 48000, speed: { _ in 2 })
        #expect(abs(s1 - nominal) < 1e-12)
        let s2 = LaneProcessor.step(stamp: 1.0 + 512 * nominal * 2, previous: (1.0, 512), lastStep: nil, frames: 512,
                                    duration: d, sampleRate: 48000, playerRate: 2, speed: { _ in 2 })
        #expect(abs(s2 - 2 * nominal) < 1e-12)
    }

    // MARK: export path (AVAssetReaderAudioMixOutput + the lane taps)

    static func rms(_ x: ArraySlice<Float>) -> Double {
        var e = 0.0; for v in x { e += Double(v * v) }; return (e / Double(max(1, x.count))).squareRoot()
    }

    /// 5 ms windows of `x[range]` quieter than 30 % of the median window (start times, seconds).
    static func dropouts(_ x: [Float], in range: Range<Int>) -> [Double] {
        let w = 240
        let starts = Array(stride(from: range.lowerBound, to: range.upperBound - w + 1, by: w))
        let r = starts.map { rms(x[$0 ..< $0 + w]) }
        guard !r.isEmpty else { return [] }
        let med = r.sorted()[r.count / 2]
        return zip(starts, r).filter { $0.1 < med * 0.3 }.map { Double($0.0) / 48000 }
    }

    /// Noise clip with trimmed source in and out, then a speed change: the composition audio track spans exactly the
    /// clip's timeline range and the export mix is audible up to its last 5 ms window (a title after the clip keeps the
    /// composition going, so the clip end is not the end of the asset).
    @Test(arguments: [0.5, 1.0, 1.25, 1.5, 2.0, 3.0])
    func spedUpClipKeepsItsAudioToTheEnd(speed: Double) async throws {
        var p = TestProject(frameRate: .fps30)
        let id = try await p.addMedia(try MetallicAudioTests.noiseFile())
        p[id].sourceStart = Time(1.0)        // source in
        p[id].duration = Time(3.0)           // source out at 4.0 s of a 6 s file
        try TimelineOps.setSpeed(id, .constant(speed), in: &p.project.timeline)
        let clip = p[id]
        #expect(clip.duration == Time(3.0 / speed))
        try p.addText("after", at: clip.end - Time(0.1), duration: Time(0.6))
        let built = try await CompositionBuilder.build(project: p.project, purpose: .export)
        let tracks = try await built.composition.loadTracks(withMediaType: .audio)
        #expect(tracks.count == 1)
        for t in tracks {
            // the media edits (the lane is padded with silence to the composition end)
            let media = try await t.load(.segments).filter { !$0.isEmpty }.map(\.timeMapping.target)
            let start = try #require(media.first?.start), end = try #require(media.last?.end)
            #expect(Time(cmTime: start) == clip.start)
            #expect(Time(cmTime: CMTimeSubtract(end, start)) == clip.duration,
                    "audio lasts \(CMTimeSubtract(end, start).seconds) s on the track, clip \(clip.duration.seconds) s")
        }
        let mix = try await p.mixdown().channel(0)
        let end = Int(clip.end.seconds * 48000)
        let last = mix.lastIndex { abs($0) > 1e-4 } ?? -1
        // AVFoundation's spectral time-pitch never delivers the last 1086 frames (22.6 ms) of a slowed-down track's
        // final edit (0.5×, with or without taps, even with the track padded): slow motion keeps a 2 ms tolerance plus that.
        let slack = speed < 1 ? 96 + 1086 : 96
        #expect(abs(last - end) < slack, "speed \(speed): audio ends at \(Double(last) / 48000) s, clip at \(clip.end.seconds) s")
        let gaps = Self.dropouts(mix, in: 0 ..< end - slack + 96)
        #expect(gaps.isEmpty, "speed \(speed): silent windows at \(gaps)")
    }

    /// Owner's cut (BUG-CUT-AUDIO-ARTEFACT): an off-frame-grid split of iPhone AAC footage mid-clip. At speed 1 the
    /// split export is sample-identical to the unsplit clip; at other speeds (spectral time-pitch restarts at the cut,
    /// so samples differ) nothing around the cut is muted.
    @Test(arguments: [1.0, 1.5, 2.0])
    func splitExportsLikeTheUnsplitClip(speed: Double) async throws {
        var p = TestProject(frameRate: .fps30)
        let id = try await p.addMedia(try MetallicAudioTests.noiseFile())
        p[id].sourceStart = Time(ticks: 4225601486 - 3 * Time.ticksPerSecond)   // 2.989 s: the owner's in point, shifted
        p[id].duration = Time(2.0)
        if speed != 1 { try TimelineOps.setSpeed(id, .constant(speed), in: &p.project.timeline) }
        let whole = try await p.mixdown().channel(0)
        var q = p
        let cut = Time(ticks: 143325000 * 3)   // 0.609 s: not on the 30 fps frame grid, like the owner's
        _ = try TimelineOps.split(id, at: cut, in: &q.project.timeline)
        let split = try await q.mixdown().channel(0)
        #expect(whole.count == split.count)
        let c = Int(cut.seconds * 48000)
        if speed == 1 {
            var maxd: Float = 0
            for i in 0..<min(whole.count, split.count) { maxd = max(maxd, abs(whole[i] - split[i])) }
            #expect(maxd < 1e-6, "split differs from the unsplit clip by \(maxd)")
        }
        let gaps = Self.dropouts(split, in: max(0, c - 4800) ..< min(split.count, c + 4800))
        #expect(gaps.isEmpty, "speed \(speed): silent windows around the cut at \(gaps) (cut \(cut.seconds) s)")
    }

    /// Same on real iPhone footage (HEVC + 44.1/48 kHz AAC: priming, packet boundaries): sample-identical at speed 1.
    @Test func splitOfIPhoneFootageIsSampleIdentical() async throws {
        var p = TestProject(frameRate: .fps30)
        let id = try await p.addMedia(RealLikeMedia.iPhoneHLGPortrait)
        p[id].sourceStart = Time(0.37)
        p[id].duration = Time(1.2)
        let whole = try await p.mixdown().channel(0)
        var q = p
        _ = try TimelineOps.split(id, at: Time(ticks: 143325000 * 3), in: &q.project.timeline)
        let split = try await q.mixdown().channel(0)
        #expect(whole.count == split.count)
        var maxd: Float = 0
        for i in 0..<min(whole.count, split.count) { maxd = max(maxd, abs(whole[i] - split[i])) }
        #expect(maxd < 1e-6, "split differs from the unsplit clip by \(maxd)")
        #expect(whole.contains { abs($0) > 1e-3 }, "no audio in the footage")
        // butted clips share one audio composition track (A/B audio lanes only where clips overlap)
        let built = try await CompositionBuilder.build(project: q.project, purpose: .export)
        #expect(try await built.composition.loadTracks(withMediaType: .audio).count == 1)
    }

    /// Video at the cut: the frames around an off-grid split show the same source frames as the unsplit clip.
    @Test func splitShowsTheSameFramesAtTheCut() async throws {
        var p = TestProject(frameRate: .fps30)
        let id = try await p.addVideo(.frameIndex, seconds: 3)
        p[id].sourceStart = Time(0.3)
        p[id].duration = Time(1.5)
        var q = p
        let cut = Time(ticks: 143325000 * 3)   // 0.609 s, inside frame 18
        _ = try TimelineOps.split(id, at: cut, in: &q.project.timeline)
        for f in 16...21 {
            let t = (Double(f) + 0.5) / 30
            let a = try await p.render(at: t), b = try await q.render(at: t)
            #expect(abs(a[0.5, 0.5].luma - b[0.5, 0.5].luma) < 0.01, "frame \(f): split shows another source frame")
        }
    }

    // MARK: preview (AVPlayer, lane taps labelled one buffer early)

    /// A 2× clip split in two, played from the start: the lane outputs, placed at their labelled composition times (what
    /// the mixer sums), cover the whole clip — no window muted before the cut or at the clip end.
    @Test func previewOfSpedUpSplitClipIsNotMuted() async throws {
        var p = TestProject(frameRate: .fps30)
        let id = try await p.addMedia(try MetallicAudioTests.noiseFile())
        p[id].sourceStart = Time(1.0)
        p[id].duration = Time(3.0)
        try TimelineOps.setSpeed(id, .constant(2), in: &p.project.timeline)
        _ = try TimelineOps.split(id, at: Time(0.75), in: &p.project.timeline)
        try p.addText("after", at: Time(1.4), duration: Time(0.6))
        let project = p.project
        let cap = MetallicAudioTests.Capture()
        try await HeavyWorkGate.run {
            let engine = PlaybackEngine(project: project)
            engine.usesProxies = false
            try await PlaybackProbe.waitReady(engine)
            MetallicAudioTests.record(engine, into: cap)
            defer { engine.audioState.tapCapture = nil }
            engine.seek(to: .zero)
            engine.play()
            let t0 = CACurrentMediaTime()
            while engine.currentTime.seconds < 1.7, CACurrentMediaTime() - t0 < 30 {
                _ = engine.pixelBuffer(forHostTime: CACurrentMediaTime())
                try await Task.sleep(nanoseconds: 4_000_000)
            }
            engine.pause()
        }
        var out = [Float](repeating: 0, count: 2 * 48000)
        var covered = [Bool](repeating: false, count: out.count)
        for c in cap.snapshot where c.time.isFinite {
            let i0 = Int((c.time * c.rate).rounded())
            for (k, v) in c.samples.enumerated() where i0 + k >= 0 && i0 + k < out.count { out[i0 + k] += v; covered[i0 + k] = true }
        }
        // the play start itself (first buffer of the item) is AVPlayer's preroll: judge from 0.2 s to the clip end
        let lo = Int(0.2 * 48000), hi = Int(1.5 * 48000)
        try #require(covered[lo..<hi].allSatisfy { $0 }, "the play did not reach the clip end (loaded machine?)")
        let gaps = Self.dropouts(out, in: lo ..< hi)
        #expect(gaps.isEmpty, "preview: silent windows at \(gaps) (cut 0.75 s, clip end 1.5 s)")
    }
}
