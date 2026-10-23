@preconcurrency import AVFoundation
import Testing
import Foundation
import QuartzCore
import MontageCore
@testable import MontageEngine
import MontageTestSupport

/// PB-QC: the quick cut preview leaves the marked slices out of the preview composition (no seek at each slice).
struct SkipTimeMapTests {
    let map = SkipTimeMap([TimeRange(start: Time(4), end: Time(4.5)), TimeRange(start: Time(1), end: Time(2)),
                           TimeRange(start: Time(1.5), end: Time(2.2)), TimeRange(start: Time(9), end: Time(12))], duration: Time(10))

    @Test func normalizesRanges() {
        #expect(map.skips == [TimeRange(start: Time(1), end: Time(2.2)), TimeRange(start: Time(4), end: Time(4.5)),
                              TimeRange(start: Time(9), end: Time(10))])
        #expect(SkipTimeMap([], duration: Time(5)).isIdentity)
        #expect(SkipTimeMap([TimeRange(start: Time(6), end: Time(7))], duration: Time(5)).isIdentity)
    }

    @Test func mapsBothWays() {
        #expect(map.item(Time(0.5)) == Time(0.5))
        #expect(map.item(Time(1.5)) == Time(1))          // inside a skip: where it ends
        #expect(map.item(Time(2.2)) == Time(1))
        #expect(map.item(Time(3)) == Time(1.8))
        #expect(map.item(Time(5)) == Time(3.3))
        #expect(map.item(Time(10)) == Time(7.3))          // item duration
        #expect(map.timeline(Time(0.5)) == Time(0.5))
        #expect(map.timeline(Time(1)) == Time(2.2))       // a boundary plays the kept side
        #expect(map.timeline(Time(1.8)) == Time(3))
        #expect(map.timeline(Time(3.3)) == Time(5))
        for s in stride(from: 0.0, to: 7.3, by: 0.05) {
            let i = Time(s)
            #expect(map.item(map.timeline(i)) == i)
            #expect(map.skip(containing: map.timeline(i)) == nil)
        }
    }

    @Test func keptParts() {
        #expect(map.kept(TimeRange(start: Time(0), end: Time(5))) == [TimeRange(start: Time(0), end: Time(1)),
                TimeRange(start: Time(2.2), end: Time(4)), TimeRange(start: Time(4.5), end: Time(5))])
        #expect(map.kept(TimeRange(start: Time(1.2), end: Time(2))).isEmpty)
        #expect(map.kept(TimeRange(start: Time(5), end: Time(6))) == [TimeRange(start: Time(5), end: Time(6))])
        #expect(SkipTimeMap.identity.kept(TimeRange(start: Time(1), end: Time(2))) == [TimeRange(start: Time(1), end: Time(2))])
    }
}

@MainActor @Suite(.serialized) struct PlaybackSkipTests {
    static let skips = [TimeRange(start: Time(1), end: Time(2)), TimeRange(start: Time(3), end: Time(3.5))]

    static func project() async throws -> Project {
        var p = TestProject()
        _ = try await p.addMedia(try await TestMedia.video(.frameIndex, seconds: 6, audioHz: 440))
        return p.project
    }

    @Test func compositionLeavesSkippedRangesOut() async throws {
        let project = try await Self.project()
        let built = try await CompositionBuilder.build(project: project, purpose: .preview, skipping: Self.skips)
        #expect(abs(built.duration.seconds - (project.duration.seconds - 1.5)) < 0.01)
        #expect(abs(built.composition.duration.seconds - built.duration.seconds) < 0.05)
        for track in built.composition.tracks where track.mediaType == .audio || track.segments.count > 1 {
            // the clip's media: kept pieces back to back in item time, each from the matching source time
            let real = track.segments.filter { !$0.isEmpty }
            let target = real.map { ($0.timeMapping.target.start.seconds, $0.timeMapping.source.start.seconds) }
            #expect(target.count == 3, "\(track.mediaType.rawValue): \(target)")
            if target.count == 3 {
                #expect(abs(target[0].0) < 0.01 && abs(target[0].1) < 0.01)
                #expect(abs(target[1].0 - 1) < 0.01 && abs(target[1].1 - 2) < 0.01)
                #expect(abs(target[2].0 - 2) < 0.01 && abs(target[2].1 - 3.5) < 0.01)
            }
        }
        let plain = try await CompositionBuilder.build(project: project, purpose: .preview)
        #expect(abs(plain.duration.seconds - project.duration.seconds) < 0.01)
    }

    /// Playback runs over the slices without a single seek: the rate never drops (a seek holds it at 0), no frame of a
    /// skipped range is shown, and the playhead (timeline time) jumps over them.
    @Test func playbackRunsOverSkippedRangesWithoutSeeking() async throws {
        let project = try await Self.project()
        try await HeavyWorkGate.run {
            let engine = PlaybackEngine(project: project)
            engine.usesProxies = false
            engine.skipRanges = Self.skips
            try await PlaybackProbe.waitReady(engine)
            try #require(await Self.until { !engine.isBuilding && !engine.itemSkip.isIdentity }, "skip build never installed")
            try await PlaybackProbe.waitReady(engine)
            var times: [Time] = []
            engine.onTimeUpdate = { times.append($0) }
            engine.seek(to: Time(0.3))
            engine.play()
            try #require(await Self.until { engine.player.rate != 0 }, "never started")   // the start seek landed
            times.removeAll()
            let start = CACurrentMediaTime()
            var frames: [Time] = [], rateDrops = 0
            let primes0 = engine.stallRecoveries
            while engine.currentTime < Time(4.2), CACurrentMediaTime() - start < 30 {
                if let (_, t) = engine.pixelBuffer(forHostTime: CACurrentMediaTime()), frames.last != t { frames.append(t) }
                if engine.player.rate == 0 { rateDrops += 1 }
                try await Task.sleep(nanoseconds: 4_000_000)
            }
            engine.pause()
            #expect(engine.currentTime >= Time(4.2) || engine.requestedTime >= Time(4.2), "playback did not get past the slices")
            // (a stall watchdog re-prime under heavy load also holds the rate for its seek: not a slice seek)
            if engine.stallRecoveries == primes0 { #expect(rateDrops == 0, "playback paused \(rateDrops) polls (a seek at a slice)") }
            let fd = project.settings.frameRate.frameDuration
            let inside = frames.filter { t in Self.skips.contains { $0.start + fd <= t && t < $0.end - fd } }
            #expect(inside.isEmpty, "frames of skipped ranges shown: \(inside.map(\.seconds))")
            #expect(frames.contains { $0 >= Time(2) && $0 < Time(3) } && frames.contains { $0 >= Time(3.5) })
            let skippedTimes = times.filter { t in Self.skips.contains { $0.start + fd <= t && t < $0.end - fd } }
            #expect(skippedTimes.isEmpty, "playhead inside a slice: \(skippedTimes.map(\.seconds))")
            #expect(engine.clockRebuilds == 0)
            // back to the plain timeline: the skip map goes once the rebuild is in place
            engine.skipRanges = []
            #expect(await Self.until { !engine.isBuilding && engine.itemSkip.isIdentity })
            #expect(engine.currentTime == engine.requestedTime)
        }
    }

    /// Waits (polling the main actor) until `ok`, at most `ceiling` s.
    static func until(_ ceiling: Double = 120, _ ok: () -> Bool) async -> Bool {
        let t0 = CACurrentMediaTime()
        while !ok() {
            if CACurrentMediaTime() - t0 > ceiling { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }
}
