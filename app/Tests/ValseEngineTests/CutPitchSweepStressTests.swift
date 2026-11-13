@preconcurrency import AVFoundation
import Testing
import Foundation
import ValseCore
@testable import ValseEngine
import ValseTestSupport

/// A stop flag shared with busy threads.
final class StressStopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var value: Bool { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
}

/// Busy threads loading the machine from inside the test process (`count` threads; stop them with the returned flag).
/// `fromEnvironment`: `VALSE_TEST_BURNERS=<n>` (opt-in stress of playback tests; nil = none).
enum TestBurners {
    static func start(_ count: Int) -> StressStopFlag {
        let stop = StressStopFlag()
        for _ in 0..<count {
            let t = Thread { var x = 0.0; while !stop.value { for i in 0..<100_000 { x += sin(Double(i)) } }; _ = x }
            t.qualityOfService = .userInitiated
            t.start()
        }
        return stop
    }
    /// `VALSE_TEST_REPEAT=<n>`: playback tests that honour it play their scenario n times in one run (default 1).
    static var repeats: Int { max(1, Int(ProcessInfo.processInfo.environment["VALSE_TEST_REPEAT"] ?? "") ?? 1) }
    static func fromEnvironment() -> StressStopFlag? {
        Int(ProcessInfo.processInfo.environment["VALSE_TEST_BURNERS"] ?? "").map { start($0) }
    }
}

/// FLAKY-PB2 (opt-in: `VALSE_PITCH_STRESS=<mixdowns per case>`, `VALSE_PITCH_STRESS_LOAD=<busy threads>`, default 14):
/// the CutPitchSweepTests cases mixed down repeatedly while busy threads load the machine; no tone dip around the cut
/// nor before the project's end. "split 1.5x both" dipped ~20 ms before the end in 15 of 20 mixdowns under this load
/// (0 of 20 without it, which is why only the full parallel suite showed it): its last clip continues the previous
/// one and got no tail pad; fixed with a pad edit of its own (`CompositionBuilder.insert`, `tailPadOwnEdit`): 0 of 20.
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["VALSE_PITCH_STRESS"] != nil))
struct CutPitchSweepStressTests {
    @Test func toneHoldsAtTheCutAndTheEndUnderLoad() async throws {
        let env = ProcessInfo.processInfo.environment
        let n = Int(env["VALSE_PITCH_STRESS"] ?? "") ?? 20
        let burners = Int(env["VALSE_PITCH_STRESS_LOAD"] ?? "") ?? 14
        let stop = TestBurners.start(burners)
        defer { stop.value = true }
        for c in CutPitchSweepTests.cases {
            var p = TestProject(frameRate: .fps30)
            let id = try await p.addAudio(AudioTestSignals.sine(440, seconds: 6, amplitude: 0.5, sampleRate: c.sourceRate, channels: 2))
            p[id].duration = Time(3.0)
            let right = try TimelineOps.split(id, at: Time(1.5), in: &p.project.timeline)
            if c.speedA != 1 { try TimelineOps.setSpeed(id, .constant(c.speedA), in: &p.project.timeline) }
            if c.speedB != 1 { try TimelineOps.setSpeed(right, .constant(c.speedB), in: &p.project.timeline) }
            p[right].start = p[id].end
            let cut = p[right].start.seconds, end = p[right].end.seconds
            var badCut = 0, badEnd = 0, samples: [String] = []
            for _ in 0..<n {
                let mix = try await p.mixdown().channel(0)
                let wc = CutPitchSweepTests.weakWindows(mix, amplitude: 0.5, from: max(0.1, cut - 0.5), to: min(end - 0.1, cut + 0.5))
                    .filter { abs($0 - cut) > 0.006 }
                let we = CutPitchSweepTests.weakWindows(mix, amplitude: 0.5, from: end - 0.5, to: end - 0.006)
                if !wc.isEmpty { badCut += 1; samples.append("cut \(wc.prefix(3))") }
                if !we.isEmpty { badEnd += 1; samples.append("end \(we.prefix(3))") }
            }
            print("PITCHSTRESS \(c.name): cut bad \(badCut)/\(n), end bad \(badEnd)/\(n) \(samples.prefix(4))")
            #expect(badCut == 0 && badEnd == 0, "\(c.name): tone dips at the cut in \(badCut) / at the end in \(badEnd) of \(n) mixdowns: \(samples.prefix(4))")
        }
    }
}
