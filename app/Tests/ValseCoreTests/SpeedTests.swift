import Testing
@testable import ValseCore

@Suite struct SpeedTests {
    @Test func constantSpeedRemap() {
        let s = Speed.constant(2)
        #expect(s.sourceDuration(forOutput: 5) == Time(10))
        #expect(s.outputDuration(forSource: 10) == Time(5))
        #expect(s.sourceOffset(at: 1, outputDuration: 5) == Time(2))
    }

    @Test func curveIntegralIsExact() {
        // linear ramp 1 → 3: average 2
        let c = SpeedCurve(points: [SpeedPoint(0, 1), SpeedPoint(1, 3)])
        let s = Speed.curve(c)
        #expect(abs(s.averageRate - 2) < 1e-12)
        // ∫0^0.5 (1 + 2x) dx = 0.5 + 0.25 = 0.75
        #expect(abs(c.integral(to: 0.5) - 0.75) < 1e-12)
        let d: Time = 4
        #expect(s.sourceOffset(at: 2, outputDuration: d) == Time(3))
        #expect(s.sourceOffset(at: d, outputDuration: d) == s.sourceDuration(forOutput: d))
        #expect(s.rate(at: 2, outputDuration: d) == 2)
    }

    @Test func segmentsCoverClipMonotonically() {
        let s = Speed.curve(SpeedCurve(points: [SpeedPoint(0, 0.5), SpeedPoint(0.5, 4), SpeedPoint(1, 0.5)]))
        let d: Time = 6
        let segs = s.segments(outputDuration: d, maxSegments: 24)
        #expect(segs.first?.output.start == .zero)
        #expect(segs.last?.output.end == d)
        #expect(segs.last?.source.end == s.sourceDuration(forOutput: d))
        for i in segs.indices.dropFirst() {
            #expect(segs[i].output.start == segs[i - 1].output.end)
            #expect(segs[i].source.start == segs[i - 1].source.end)
        }
    }

    @Test func subcurvePreservesSourceExtent() {
        let curve = SpeedCurve(points: [SpeedPoint(0, 1), SpeedPoint(0.3, 5), SpeedPoint(1, 0.5)])
        let d: Time = 10
        let a = 0.4
        let left = Speed.curve(curve.subcurve(from: 0, to: a)).sourceDuration(forOutput: d * a)
        let right = Speed.curve(curve.subcurve(from: a, to: 1)).sourceDuration(forOutput: d * (1 - a))
        let whole = Speed.curve(curve).sourceDuration(forOutput: d)
        #expect(abs((left + right - whole).seconds) < 1e-6)
    }

    @Test func clipSourceTimeWithReverse() {
        var c = Clip(content: .media(MediaID()), start: 10, duration: 4, sourceStart: 1)
        c.speed = .constant(0.5)
        #expect(c.sourceTime(at: 12) == Time(2))
        c.reversed = true
        #expect(c.sourceTime(at: 10) == Time(3))
        #expect(c.sourceTime(at: 14) == Time(1))
    }
}
