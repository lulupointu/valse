import Testing
import Foundation
import QuartzCore
import Perception
@testable import MontageUI

/// macOS 13 back-ports (Support/Compat13.swift) exercised on the host: the fallback paths are forced where possible.
@MainActor @Suite(.serialized) struct Compat13Tests {
    @Perceptible @MainActor final class Model {
        var text = "a"
        var other = 0
    }

    @Test func representableTrackingReRunsOnChange() async throws {
        let m = Model()
        let t = RepresentableTracking()
        t.forceTracking = true
        var seen: [String] = []
        t.run { seen.append(m.text) }
        #expect(seen == ["a"])
        m.text = "b"
        for _ in 0..<50 where seen.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(seen == ["a", "b"])
        // a property the update didn't read doesn't re-run it
        m.other = 1
        try await Task.sleep(for: .milliseconds(100))
        #expect(seen == ["a", "b"])
        // a newer run supersedes the previous registration (no duplicate updates)
        t.run { seen.append("r" + m.text) }
        m.text = "c"
        for _ in 0..<50 where seen.count < 4 { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(seen == ["a", "b", "rb", "rc"])
    }

    @Test func legacyDisplayLinkTicksAtVsync() async throws {
        var targets: [CFTimeInterval] = []
        var lags: [CFTimeInterval] = []
        let link = LegacyDisplayLink(screen: nil) { t in
            targets.append(t)
            lags.append(t - CACurrentMediaTime())
        }
        defer { link.invalidate() }
        try await Task.sleep(for: .milliseconds(600))
        link.invalidate()
        // ticks arrive (the main actor may be busy with parallel tests, so only a low bound: busy vsyncs are skipped)
        #expect(targets.count >= 2, "ticks: \(targets.count)")
        // target timestamps are CACurrentMediaTime-based (same clock, not mach ticks / absolute) and increasing
        #expect(zip(targets, targets.dropFirst()).allSatisfy { $0 < $1 })
        #expect(lags.allSatisfy { $0 > -1 && $0 < 0.2 }, "lags: \(Array(lags.prefix(5)))")
    }
}
