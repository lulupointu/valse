import Testing
@testable import ValseCore

@Suite struct TimeTests {
    @Test func flicksAreExactForCommonRates() {
        for r in FrameRate.common {
            let f = r.frameDuration
            #expect(r.time(ofFrame: Int64(r.fps.rounded()) * 10).ticks == f.ticks * Int64(r.fps.rounded()) * 10)
            #expect(r.frame(containing: r.time(ofFrame: 1234)) == 1234)
        }
        #expect(Time(ticks: Time.ticksPerSecond).seconds == 1)
        #expect(Time.ticksPerSecond % 48000 == 0 && Time.ticksPerSecond % 44100 == 0)
    }

    @Test func arithmeticAndLiterals() {
        let a: Time = 2, b: Time = 0.5
        #expect((a + b).seconds == 2.5)
        #expect((a - b).seconds == 1.5)
        #expect((a * 1.5).seconds == 3)
        #expect(a / b == 4)
        #expect(Time(1.0 / 3.0) * 3.0 == Time(1))
    }

    @Test func frameSnapAndTimecode() {
        let r = FrameRate.fps30
        #expect(r.snap(Time(1.01)) == Time(1))
        #expect(r.frame(containing: Time(-0.01)) == -1)
        #expect(Timecode.string(Time(65.5), rate: r) == "00:01:05:15")
        #expect(Timecode.string(Time(3600), rate: r, showFrames: false) == "01:00:00")
    }

    @Test func ranges() {
        let r = TimeRange(start: 1, duration: 2)
        #expect(r.contains(1) && !r.contains(3))
        #expect(r.intersection(TimeRange(start: 2, duration: 5)) == TimeRange(start: 2, end: 3))
        #expect(!r.overlaps(TimeRange(start: 3, duration: 1)))
    }
}
