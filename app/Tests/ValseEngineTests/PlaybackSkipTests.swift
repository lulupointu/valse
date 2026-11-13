@preconcurrency import AVFoundation
import Testing
import Foundation
import QuartzCore
import ValseCore
@testable import ValseEngine
import ValseTestSupport

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

    /// What it protects (PB-QC quick-cut preview): playback runs over the marked slices without a single seek — the
    /// rate never drops (a seek holds it at 0), the item clock never jumps, the playhead (timeline time) is never inside
    /// a slice, no frame of a skipped range is ever shown — and the kept parts between / after the slices are shown.
    ///
    /// FLAKY-PB (history: 8 failures, load 2.7-25, in the parallel suite only; 15/15 alone at load 24-54):
    /// - "playback paused N polls": another suite's reversed render / matte / cache segment finishing rebuilt THIS
    ///   playing item (process-wide `onReady` callbacks, rebuild for any media): the gapless re-join holds the rate for
    ///   its seek. Reproduced by injecting `forceRebuild()` 0-2500 ms into a pass (14/14 failed); fixed in the product:
    ///   `PlaybackEngine` rebuilds only for its project's media (`PlaybackDerivedReadyTests`).
    /// - "kept parts not shown: frames [0.30]" (all before the BUG-CUT-AUDIO-HOLE phase B transport): a pass that ends
    ///   after a few polls. Each pass now records the item clock against the wall clock: a clock jump fails at once
    ///   with its size (a playhead teleport is a product bug, never load).
    /// FLAKY-PB2: not reproduced (≥ 60 more passes: 5 full-suite runs, 8 passes per run with `VALSE_TEST_REPEAT`, 15 with
    /// 12 busy threads `VALSE_TEST_BURNERS`). The jump check missed the poll that ENDED the pass (a jump past 4.2 s ends
    /// the loop before its body measured it): it is now measured, and every failure prints a per-poll trace (item clock,
    /// audio clock, rate, the video output's item time, device − host clock, requested time, timeControlStatus, item
    /// status) to tell an item-clock jump, a device-clock jump and an item end apart. Fixed meanwhile: a feeder tick could
    /// report the audio primed for a seek it had not performed yet (`PreviewAudioTests.seekDuringATick…`).
    /// The displayed frames are sampled by polling the view's frame source; under load AVFoundation drops late frames
    /// and a 1 s kept part can get none, without anything being wrong with the skips. Whether a pass was starved is
    /// measured in frames, not wall time: the frames the view got against the frames the item clock covered (plus a
    /// starved main actor, a watchdog re-prime / rebuild). Only a starved pass that missed a kept part is played again
    /// (at most `maxPasses`); a pass that got most of its frames and still missed a kept part fails at once. Every pass
    /// is checked strictly for what the skips must never do.
    @Test func playbackRunsOverSkippedRangesWithoutSeeking() async throws {
        let project = try await Self.project()
        for _ in 0..<TestBurners.repeats {   // (opt-in stress: VALSE_TEST_REPEAT)
        try await HeavyWorkGate.run {
            let burners = TestBurners.fromEnvironment()   // (opt-in stress)
            defer { burners?.value = true }
            let engine = PlaybackEngine(project: project)
            engine.usesProxies = false
            engine.skipRanges = Self.skips
            try await PlaybackProbe.waitReady(engine)
            try #require(await Self.until { !engine.isBuilding && !engine.itemSkip.isIdentity }, "skip build never installed")
            try await PlaybackProbe.waitReady(engine)
            var times: [Time] = []
            engine.onTimeUpdate = { times.append($0) }
            let fps = project.settings.frameRate
            let fd = fps.frameDuration
            let skips = Self.skips
            let inSlice: (Time) -> Bool = { t in skips.contains { $0.start + fd <= t && t < $0.end - fd } }
            for attempt in 1...Self.maxPasses {
                engine.seek(to: Time(0.3))
                engine.play()
                try #require(await Self.until { engine.player.rate != 0 }, "never started")   // the start seek landed
                times.removeAll()
                let start = CACurrentMediaTime()
                var frames: [Time] = [], rateDrops = 0, lastPoll = start, maxGap = 0.0, polls = 0
                var firstItem = -1.0, lastItem = 0.0, maxJump = 0.0
                let primes0 = engine.stallRecoveries, rebuilds0 = engine.stallRebuilds
                var trace: [String] = []
                let launches0 = engine.launches, sched = engine.scheduledStartHost
                while engine.currentTime < Time(4.2), CACurrentMediaTime() - start < 60 {
                    let now = CACurrentMediaTime()
                    let item = engine.player.currentTime().seconds
                    let jump = polls > 0 ? (item - lastItem) - (now - lastPoll) * Double(engine.player.rate) : 0
                    if polls < 6 || jump > 0.05 { trace.append(Self.traceLine(engine, start: start, now: now, item: item)) }
                    if polls > 0 { maxJump = max(maxJump, jump) } else { firstItem = item }
                    maxGap = max(maxGap, now - lastPoll); lastPoll = now; lastItem = item; polls += 1
                    if let (_, t) = engine.pixelBuffer(forHostTime: now), frames.last != t { frames.append(t) }
                    if engine.player.rate == 0 { rateDrops += 1 }
                    try await Task.sleep(nanoseconds: 4_000_000)
                }
                // the poll that ended the pass: a jump to past 4.2 s ends the loop before the loop body measures it
                do {
                    let now = CACurrentMediaTime(), item = engine.player.currentTime().seconds
                    if engine.player.rate != 0 { maxJump = max(maxJump, (item - lastItem) - (now - lastPoll) * Double(engine.player.rate)) }
                    trace.append("end " + Self.traceLine(engine, start: start, now: now, item: item))
                }
                engine.pause()
                let primes = engine.stallRecoveries - primes0, rebuilds = engine.stallRebuilds - rebuilds0
                // frames the item clock covered during the pass vs frames the view got
                let covered = max(1, Int(((lastItem - firstItem) / fd.seconds).rounded()))
                let diag = "pass \(attempt): frames \(frames.map { String(format: "%.2f", $0.seconds) }) (\(frames.count) of \(covered) "
                    + "covered), item clock \(String(format: "%.2f", firstItem)) → \(String(format: "%.2f", lastItem)) s, max jump "
                    + "\(String(format: "%.3f", maxJump)) s, \(polls) polls, max poll gap \(String(format: "%.2f", maxGap)) s, "
                    + "watchdog primes \(primes) rebuilds \(rebuilds), wall \(String(format: "%.2f", CACurrentMediaTime() - start)) s, "
                    + "launches \(engine.launches - launches0), scheduled start \(String(format: "%+.3f", sched - start)) s; "
                    + "trace [t item audio rate item(host) devΔ]: \(trace.joined(separator: " | "))"
                #expect(engine.currentTime >= Time(4.2) || engine.requestedTime >= Time(4.2), "playback did not get past the slices: \(diag)")
                // (a stall watchdog re-prime / rebuild under heavy load also holds the rate for its seek, and re-joins the
                // video ahead of the audio: not a slice seek)
                if primes == 0 && rebuilds == 0 {
                    #expect(rateDrops == 0, "playback paused \(rateDrops) polls (a seek at a slice): \(diag)")
                    #expect(maxJump < Self.maxClockJump, "the item clock jumped: \(diag)")
                    #expect(firstItem < 0.3 + Self.maxClockJump + (start - engine.scheduledStartHost), "the clock started past the seek target: \(diag)")
                }
                let inside = frames.filter(inSlice)
                #expect(inside.isEmpty, "frames of skipped ranges shown: \(inside.map(\.seconds)) — \(diag)")
                let skippedTimes = times.filter(inSlice)
                #expect(skippedTimes.isEmpty, "playhead inside a slice: \(skippedTimes.map(\.seconds)) — \(diag)")
                #expect(engine.driftRejoins == 0, "\(diag)")
                let keptShown = frames.contains { $0 >= Time(2) && $0 < Time(3) } && frames.contains { $0 >= Time(3.5) }
                if keptShown { break }
                let starved = frames.count * 2 < covered || maxGap >= Self.loadGap || primes > 0 || rebuilds > 0
                #expect(starved && attempt < Self.maxPasses,
                        "kept parts between / after the slices not shown\(starved ? " in \(Self.maxPasses) starved passes" : " although the view got most frames"): \(diag)")
                if !starved { break }
            }
            // back to the plain timeline: the skip map goes once the rebuild is in place
            engine.skipRanges = []
            #expect(await Self.until { !engine.isBuilding && engine.itemSkip.isIdentity })
            #expect(engine.currentTime == engine.requestedTime)
        }
        }
    }

    /// Passes played at most when a starved pass hides a kept part; poll gap (s) that counts as a starved main actor.
    static let maxPasses = 3
    static let loadGap = 0.25
    /// Item-clock advance beyond the wall clock between two polls (s) that counts as a jump (a frame is 0.033 s).
    static let maxClockJump = 0.2

    /// One poll of a pass, for the failure message: wall time since the pass started, item clock, audio clock, rate, the
    /// video output's item time for the poll's host time, and the player's source (device) clock minus the host clock.
    static func traceLine(_ engine: PlaybackEngine, start: CFTimeInterval, now: CFTimeInterval, item: Double) -> String {
        let host = CMClockGetHostTimeClock()
        let h = CMClockGetTime(host)
        let dev = engine.player.sourceClock.map { CMSyncConvertTime(h, from: host, to: $0).seconds - h.seconds } ?? .nan
        let out = engine.videoOutput?.itemTime(forHostTime: now).seconds ?? .nan
        return String(format: "%.3f %.3f %.3f %.0f %.3f %.4f req %.3f tc %d item %d", now - start, item, engine.audio.currentTime,
                      engine.player.rate, out, dev, engine.requestedTime.seconds, engine.player.timeControlStatus.rawValue,
                      engine.player.currentItem?.status.rawValue ?? -1)
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

/// FLAKY-PB: a derived render (reversed file, matte) finishing for media the project does not use must not rebuild the
/// playing item (each rebuild re-joins the video 0.25 s ahead: a hitch, and the rate drop PlaybackSkipTests saw when
/// another suite's reversed render finished); one of the project's media still rebuilds.
@MainActor struct PlaybackDerivedReadyTests {
    @Test func onlyTheProjectsMediaRebuild() async throws {
        let project = try await PlaybackSkipTests.project()
        let engine = PlaybackEngine(project: project)
        // the callbacks this engine registered (process-wide singletons: read them before any suspension point)
        let reverse = try #require(ReverseManager.shared.onReady), matte = try #require(MatteStore.shared.onMatteReady)
        engine.usesProxies = false
        try await PlaybackProbe.waitReady(engine)
        #expect(await PlaybackSkipTests.until { !engine.isBuilding })
        let hash = try #require(project.media.first?.contentHash)
        reverse("0123456789abcdef-unrelated")
        matte("0123456789abcdef-unrelated", "subject")
        #expect(!engine.isBuilding, "a render of media the project does not use rebuilt the preview")
        reverse(hash + "-matte-subject")
        #expect(engine.isBuilding, "the project's own reversed matte did not rebuild the preview")
        #expect(await PlaybackSkipTests.until { !engine.isBuilding })
        matte(hash, "subject")
        #expect(engine.isBuilding, "the project's own matte did not rebuild the preview")
    }
}
