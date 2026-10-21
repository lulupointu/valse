import Testing
import Foundation
import QuartzCore
import Perception
import MontageCore
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
        for _ in 0..<3000 where seen.count < 2 { try await Task.sleep(for: .milliseconds(10)) }   // hang bound (load)
        #expect(seen == ["a", "b"])
        // a property the update didn't read doesn't re-run it
        m.other = 1
        try await Task.sleep(for: .milliseconds(100))
        #expect(seen == ["a", "b"])
        // a newer run supersedes the previous registration (no duplicate updates)
        t.run { seen.append("r" + m.text) }
        m.text = "c"
        for _ in 0..<3000 where seen.count < 4 { try await Task.sleep(for: .milliseconds(10)) }
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
        // ticks arrive (the main actor may be busy with parallel tests: wait for them, 30 s hang bound)
        for _ in 0..<300 where targets.count < 2 { try await Task.sleep(for: .milliseconds(100)) }
        link.invalidate()
        #expect(targets.count >= 2, "ticks: \(targets.count)")
        // target timestamps are CACurrentMediaTime-based (same clock, not mach ticks / absolute) and increasing;
        // never ahead of now by more than a frame or two, and a late callback on a loaded machine only lowers the lag
        // (another clock would be off by days or by ~1e8 s)
        #expect(zip(targets, targets.dropFirst()).allSatisfy { $0 < $1 })
        #expect(lags.allSatisfy { $0 > -30 && $0 < 0.2 }, "lags: \(Array(lags.prefix(5)))")
    }

    /// No FFmpeg sidecar (a fresh Mac, the macOS 13 VM): MP3 is unavailable. A video-only export must stay possible
    /// (it was disabled by the hidden MP3 default) and ticking Export audio falls back to AAC.
    @Test func exportWithoutMP3Encoder() throws {
        var p = Project()
        try TimelineOps.insert(Clip(content: .text(TextContent(string: "a")), start: 0, duration: Time(2)), into: &p)
        let suite = "montage.m13.test.\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        let m = ExportDialogModel(project: p, title: "t", selection: [], defaults: d)
        m.remembered.videoEnabled = true; m.remembered.audioEnabled = false
        m.remembered.audio.format = .mp3
        m.mp3Available = false
        #expect(m.canExport)
        #expect(m.remembered.audio.format == .aac)
        m.remembered.audioEnabled = true
        #expect(m.canExport)
        m.remembered.audio.format = .mp3   // e.g. remembered before the sidecar was removed
        #expect(!m.canExport)
    }

    @Test func uiTestOSConditions() {
        let major = UITestDriver.osMajor
        #expect(UITestDriver.osConditionUnmet(["minOS": major]) == nil)
        #expect(UITestDriver.osConditionUnmet(["maxOS": major]) == nil)
        #expect(UITestDriver.osConditionUnmet(["minOS": major + 1]) != nil)
        #expect(UITestDriver.osConditionUnmet(["maxOS": major - 1]) != nil)
        #expect(UITestDriver.applyModelPolicy(["requires": ["minOS": major + 1]]) != nil)
    }
}
