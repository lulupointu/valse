import Testing
import Foundation
@testable import MontageCore

/// Finisher F3 model / logic tests.
struct F3CoreTests {
    // AU-004
    @Test func volumeNudgeStepsTenthsOfADecibel() {
        let up = VolumeNudge.nudged(0.5, by: 0.1)             // −6.02 → −5.9 dB
        #expect(abs(VolumeNudge.db(up) - -5.9) < 1e-9)
        let down = VolumeNudge.nudged(1, by: -0.1)
        #expect(abs(VolumeNudge.db(down) - -0.1) < 1e-9)
        #expect(VolumeNudge.nudged(10, by: 0.1) == 10)          // capped at +20 dB
        #expect(VolumeNudge.nudged(0, by: -0.1) == 0)           // silent stays silent
        #expect(abs(VolumeNudge.db(VolumeNudge.nudged(0, by: 0.1)) - VolumeNudge.floorDB) < 1e-9)
        #expect(VolumeNudge.nudged(VolumeNudge.gain(-60), by: -0.1) == 0)
        // 10 presses = +1 dB exactly (no drift)
        var g = 1.0
        for _ in 0..<10 { g = VolumeNudge.nudged(g, by: 0.1) }
        #expect(abs(VolumeNudge.db(g) - 1) < 1e-9)
    }
}
