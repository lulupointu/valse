import Testing
@testable import MontageCore

/// Frame-accurate remap segments used by the composition (W6/W9).
@Suite struct SpeedRemapTests {
    let fd = FrameRate.fps30.frameDuration

    @Test func constantSpeedIsOneSegment() {
        let segs = Speed.constant(2).frameAccurateSegments(outputDuration: 3, frameDuration: fd, tolerance: fd * 0.25)
        #expect(segs.count == 1)
        #expect(segs[0].source.duration == Time(6))
    }

    @Test func curveSegmentsAreExactAtEveryFrame() {
        let s = Speed.curve(SpeedCurve(points: [SpeedPoint(0, 0.2), SpeedPoint(0.3, 5), SpeedPoint(0.6, 0.3), SpeedPoint(1, 3)]))
        let d: Time = 4
        let tol = fd * 0.25
        let segs = s.frameAccurateSegments(outputDuration: d, frameDuration: fd, tolerance: tol)
        #expect(segs.first?.output.start == .zero)
        #expect(segs.last?.output.end == d)
        #expect(segs.last?.source.end == s.sourceDuration(forOutput: d))
        for (a, b) in zip(segs, segs.dropFirst()) {
            #expect(a.output.end == b.output.start)
            #expect(a.source.end == b.source.start)
        }
        // every frame time maps within tolerance of the exact integral
        var t = Time.zero
        while t < d {
            let seg = segs.first { $0.output.start <= t && t < $0.output.end }!
            let lin = seg.source.start + seg.source.duration * ((t - seg.output.start) / seg.output.duration)
            let exact = s.sourceOffset(at: t, outputDuration: d)
            #expect(abs((lin - exact).ticks) <= tol.ticks + 2)
            t += fd
        }
        // far fewer edits than frames, but more than a single chord
        #expect(segs.count > 4 && segs.count < 120)
    }

    @Test func boundariesFollowTheTimelineFrameGrid() {
        // clip starting mid-frame: candidate boundaries are at the timeline frame times inside the clip
        let s = Speed.curve(SpeedCurve(points: [SpeedPoint(0, 1), SpeedPoint(1, 4)]))
        let phase = fd * 0.5
        let segs = s.frameAccurateSegments(outputDuration: 2, frameDuration: fd, firstFrame: phase, tolerance: Time(ticks: 1))
        for seg in segs.dropFirst() {
            #expect((seg.output.start - phase).ticks % fd.ticks == 0)
        }
    }
}
