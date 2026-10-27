import Testing
import Foundation
import ValseCore
@testable import ValseUI

/// TL-RULER: ruler tick / label generator (integer frames, CapCut-style ladder, no "30f" labels, no overlap).
struct TimelineRulerTests {
    /// Zoom levels from the store's min (2 pt/s) to max (1200 pt/s), geometric.
    static var zooms: [Double] {
        var z: [Double] = [], p = 2.0
        while p <= 1200 { z.append(p); p *= 1.07 }
        return z + [1200]
    }

    @Test func unitsPerSecondRoundsNonIntegerRates() {
        #expect(TimelineRuler.unitsPerSecond(.fps29_97) == 30)
        #expect(TimelineRuler.unitsPerSecond(.fps23_976) == 24)
        #expect(TimelineRuler.unitsPerSecond(.fps59_94) == 60)
        #expect(TimelineRuler.unitsPerSecond(.fps25) == 25)
    }

    @Test func ladderFrameRungsDivideASecond() {
        #expect(Array(TimelineRuler.ladder(unitsPerSecond: 30).prefix(6)) == [1, 2, 5, 10, 15, 30])
        #expect(Array(TimelineRuler.ladder(unitsPerSecond: 24).prefix(5)) == [1, 2, 6, 12, 24])
        #expect(Array(TimelineRuler.ladder(unitsPerSecond: 25).prefix(3)) == [1, 5, 25])
        #expect(Array(TimelineRuler.ladder(unitsPerSecond: 60).prefix(7)) == [1, 2, 5, 10, 15, 30, 60])
        for n in [24, 25, 30, 50, 60] {
            let l = TimelineRuler.ladder(unitsPerSecond: n)
            #expect(l == l.sorted() && Set(l).count == l.count)
            for s in l { #expect(s < n ? n % s == 0 : s % n == 0, "rung \(s) at \(n) fps") }
        }
    }

    @Test func scaleAtKnownZooms() {
        // 30 fps: max zoom → 2f majors with 1f minors (CapCut [10]); 15f / 1 s majors in between; minutes zoomed out.
        var s = TimelineRuler.scale(pixelsPerSecond: 1200, rate: .fps30)
        #expect(s.major == 2 && s.minor == 1)
        s = TimelineRuler.scale(pixelsPerSecond: 200, rate: .fps30)
        #expect(s.major == 15 && s.minor == 5)   // CapCut [9]: 00:00, 15f, 00:01…
        s = TimelineRuler.scale(pixelsPerSecond: 100, rate: .fps30)
        #expect(s.major == 30 && s.minor == 5)
        s = TimelineRuler.scale(pixelsPerSecond: 20, rate: .fps30)
        #expect(s.major == 5 * 30 && s.minor == 30)   // CapCut [8]: 00:00, 00:05…
        s = TimelineRuler.scale(pixelsPerSecond: 8, rate: .fps30)
        #expect(s.major == 10 * 30)   // CapCut [7]: 00:00, 00:10…
        s = TimelineRuler.scale(pixelsPerSecond: 2, rate: .fps30)
        #expect(s.major == 60 * 30 && s.minor == 10 * 30)
        s = TimelineRuler.scale(pixelsPerSecond: 1200, rate: .fps60)
        #expect(s.major == 5 && s.minor == 1)
    }

    @Test func everyZoomAndRateGivesNonOverlappingEvenlySubdividedSteps() {
        for rate in FrameRate.common {
            let n = TimelineRuler.unitsPerSecond(rate)
            var lastMajor = Int.max
            for pps in Self.zooms {
                let s = TimelineRuler.scale(pixelsPerSecond: pps, rate: rate)
                #expect(Double(s.major) / rate.fps * pps >= TimelineRuler.minMajorSpacing, "\(rate) pps \(pps)")
                #expect(s.major % s.minor == 0)
                #expect(s.major / s.minor <= TimelineRuler.maxMinorsPerMajor)
                if s.minor < s.major { #expect(Double(s.minor) / rate.fps * pps >= TimelineRuler.minMinorSpacing) }
                // Sub-second majors divide the second (labels roll over to mm:ss); the others are whole seconds.
                #expect(s.major < n ? n % s.major == 0 : s.major % n == 0)
                #expect(s.major <= lastMajor)   // zooming in never grows the step
                lastMajor = s.major
            }
        }
    }

    @Test func labelsNeverShowFrameEqualToRateAndNeverOverlap() {
        for rate in FrameRate.common {
            let n = TimelineRuler.unitsPerSecond(rate)
            for pps in Self.zooms {
                let s = TimelineRuler.scale(pixelsPerSecond: pps, rate: rate)
                // Deep into the timeline too (float rounding there produced "30f" / uneven cadence before).
                for start in [0.0, 16.9999, 33.97, 3599.5, 7322.25] {
                    let ticks = TimelineRuler.ticks(from: Time(seconds: start), to: Time(seconds: start + 1600 / pps), scale: s)
                    #expect(!ticks.isEmpty)
                    #expect(ticks.first!.time <= Time(seconds: start))
                    var lastMajorX: Double?
                    for (a, b) in zip(ticks, ticks.dropFirst()) {
                        #expect(b.frame - a.frame == Int64(s.minor))
                        #expect(b.time > a.time)
                    }
                    for t in ticks {
                        #expect(t.time == rate.time(ofFrame: t.frame))
                        guard t.isMajor else { continue }
                        let x = t.time.seconds * pps
                        if let lx = lastMajorX { #expect(x - lx >= TimelineRuler.minMajorSpacing - 0.5) }
                        lastMajorX = x
                        let label = TimelineRuler.label(frame: t.frame, unitsPerSecond: n)
                        if label.hasSuffix("f") {
                            let f = Int(label.dropLast()) ?? -1
                            #expect(f > 0 && f < n, "\(rate) pps \(pps) label \(label)")
                        } else {
                            #expect(t.frame % Int64(n) == 0)
                        }
                    }
                }
            }
        }
    }

    @Test func bugScenarioAroundSecond16() {
        // Owner screenshot: "00:15, 00:16, 30f, 30f…". Now 15f halves roll over to the next second.
        let s = TimelineRuler.scale(pixelsPerSecond: 200, rate: .fps30)
        let ticks = TimelineRuler.ticks(from: Time(seconds: 15.9), to: Time(seconds: 18.1), scale: s)
        let labels = ticks.filter(\.isMajor).map { TimelineRuler.label(frame: $0.frame, unitsPerSecond: 30) }
        #expect(labels == ["00:16", "15f", "00:17", "15f", "00:18"])
        // 29.97: second marks are frame multiples of 30 (timecode seconds), exactly on the frame start.
        let ntsc = TimelineRuler.ticks(from: Time(seconds: 33.9), to: Time(seconds: 37.2), scale: TimelineRuler.scale(pixelsPerSecond: 100, rate: .fps29_97))
        let ntscLabels = ntsc.filter(\.isMajor).map { TimelineRuler.label(frame: $0.frame, unitsPerSecond: 30) }
        #expect(ntscLabels == ["00:34", "00:35", "00:36", "00:37"])
        #expect(ntsc.filter(\.isMajor).allSatisfy { $0.frame % 30 == 0 })
    }

    @Test func labelFormats() {
        #expect(TimelineRuler.label(frame: 0, unitsPerSecond: 30) == "00:00")
        #expect(TimelineRuler.label(frame: 34 * 30, unitsPerSecond: 30) == "00:34")
        #expect(TimelineRuler.label(frame: 34 * 30 + 15, unitsPerSecond: 30) == "15f")
        #expect(TimelineRuler.label(frame: 125 * 25, unitsPerSecond: 25) == "02:05")
        #expect(TimelineRuler.label(frame: 3600 * 24, unitsPerSecond: 24) == "01:00:00")
        #expect(TimelineRuler.label(frame: (3600 + 62) * 60, unitsPerSecond: 60) == "01:01:02")
        #expect(TimelineRuler.label(frame: 59 * 60 + 30, unitsPerSecond: 60) == "30f")
    }

    @Test func matchesTimecodeSeconds() {
        // A second mark's label is the seconds part of the app's timecode at that time (non-drop-frame).
        for rate in FrameRate.common {
            let n = Int64(TimelineRuler.unitsPerSecond(rate))
            for sec: Int64 in [1, 17, 61, 3599] {
                let tc = Timecode.string(rate.time(ofFrame: sec * n), rate: rate, style: .frames, dropFrame: false)
                #expect(tc.hasSuffix(String(format: "%02lld:%02lld:00", (sec / 60) % 60, sec % 60)), "\(rate) \(tc)")
            }
        }
    }
}
