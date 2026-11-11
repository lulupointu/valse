@preconcurrency import AVFoundation
import Foundation
import QuartzCore
import ValseCore

/// End-to-end checks of preview playback through `PlaybackEngine` (BUG-CUT-AUDIO-HOLE phase B: AVPlayer renders the
/// video only, `PreviewAudio` the audio, both timebases on the output device clock). Shared by the unit tests
/// (PlaybackEngineAudioTests, which assert on the numbers) and a release app on macOS 13 (`Valse --preview-audio-check
/// <dir>`, scripts/audio_probe.sh --vm --app). What is measured:
/// - audio: the chunks `PreviewAudio` enqueues (`PreviewAudioCheck.Recording`), against the export mixdown (lag 0) and
///   for silent stretches; discontinuities (a flush / seek / restart shows as a label jump);
/// - A/V sync: the audio clock − the video clock (item seconds), read back to back while both run (`avSpread`), plus
///   the engine's own display-poll drift (`maxAVDrift`);
/// - video: frames handed to the view (polled like the player view, `pixelBuffer(forHostTime:)`).
@MainActor
public enum PlaybackEngineCheck {
    public struct Failure: Error, CustomStringConvertible { public let description: String }

    /// Engine on `project` with original media (no proxies), ready to play, recording what the audio enqueues.
    public static func engine(_ project: Project, timeout: Double = 60) async throws -> (PlaybackEngine, PreviewAudioCheck.Recording) {
        let e = PlaybackEngine(project: project)
        e.usesProxies = false
        let rec = PreviewAudioCheck.Recording()
        e.audio.capture = rec.hook
        let t0 = CACurrentMediaTime()
        while e.player.currentItem?.status != .readyToPlay || e.isBuilding {
            if let err = e.lastBuildError, !e.isBuilding { throw Failure(description: "build failed: \(err)") }
            if CACurrentMediaTime() - t0 > timeout { throw Failure(description: "player never ready") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return (e, rec)
    }

    /// What a play phase observed.
    public struct Phase: Sendable {
        /// Largest |audio clock − video clock| (ms) read back to back while both ran, and the number of reads.
        public var avSpreadMs = 0.0
        public var avReads = 0
        public var frames = 0
        /// Wall ms from the request to the video clock moving (nil: it never moved).
        public var startMs: Double?
    }

    /// Polls like the player view until `until` returns true or `timeout` wall seconds; measures the A/V spread.
    @discardableResult
    /// `since`: the video clock when the phase's request was made (default: now, at the poll's start).
    public static func poll(_ e: PlaybackEngine, timeout: Double, since: CMTime? = nil, until: () -> Bool) async -> Phase {
        var ph = Phase()
        let t0 = CACurrentMediaTime()
        let from = since ?? e.player.currentTime()
        // measure, THEN test the exit condition: when the main actor is starved (parallel suites) for longer than the
        // phase, the first poll after the start already finds `until` true; checked first, that phase got 0 reads
        // ("the clocks never ran together", FLAKY-PB) although both ran. Measured first, the poll that ends a phase
        // whose condition implies a running clock always reads it.
        while CACurrentMediaTime() - t0 < timeout {
            if e.pixelBuffer(forHostTime: CACurrentMediaTime()) != nil { ph.frames += 1 }
            // (until a scheduled start the player reports its rate while its clock still holds: not a drift)
            if e.player.rate > 0, e.audio.isRunning, CACurrentMediaTime() > e.scheduledStartHost + 0.002 {
                let v = e.player.currentTime().seconds, a = e.audio.currentTime
                if ph.startMs == nil, v > from.seconds + 0.001 { ph.startMs = (CACurrentMediaTime() - t0) * 1000 }
                if v > from.seconds + 0.02 || ph.startMs != nil {
                    ph.avSpreadMs = max(ph.avSpreadMs, abs(a - v) * 1000)
                    ph.avReads += 1
                }
            }
            if until() { break }
            try? await Task.sleep(nanoseconds: 4_000_000)
        }
        return ph
    }

    /// The owner's cut (BUG-CUT-AUDIO-HOLE): main track A [0, 2) | B [2, 4) fading in 0.3 s (B from 2.5 s of the
    /// source), and a 0.2 s clip on another track over the cut [1.9, 2.1) fading out 0.15 s (noise everywhere: any
    /// silence comes from the gains).
    public static func ownerCutProject(dir: URL) async throws -> Project {
        var p = PreviewAudioCheck.emptyProject()
        let noise = try PreviewAudioCheck.noiseFile(in: dir)
        let a = try await PreviewAudioCheck.add(noise, at: .zero, duration: Time(2.0), to: &p)
        let main = p.timeline.tracks[p.timeline.locate(a)!.track].id
        let b = try await PreviewAudioCheck.add(noise, at: Time(2.0), duration: Time(2.0), target: .track(main), to: &p)
        p.timeline[clip: b]?.sourceStart = Time(2.5)
        p.timeline[clip: b]?.audio.fadeIn = Time(0.3)
        let over = try await PreviewAudioCheck.add(noise, at: Time(1.9), duration: Time(0.2), target: .newTrack, to: &p)
        p.timeline[clip: over]?.sourceStart = Time(4.0)
        p.timeline[clip: over]?.audio.fadeOut = Time(0.15)
        return p
    }

    /// Start times (s) of 5 ms windows of `x` (frames from `start`) over [from, to) with (almost) no energy.
    public static func silentWindows(_ x: [Float], start: Int, from: Double, to: Double) -> [Double] {
        let a = PreviewAudioLanes.frame(from) - start, b = PreviewAudioLanes.frame(to) - start
        guard a >= 0, b <= x.count else { return [-1] }
        return stride(from: a, to: b - 240, by: 240).filter { s in
            x[s ..< s + 240].reduce(Float(0)) { $0 + $1 * $1 } / 240 < 1e-6
        }.map { Double(start + $0) / PreviewAudio.sampleRate }
    }

    public struct CutResult: Sendable {
        public var maxDiff: Float = .infinity, lag = 99
        public var silent: [Double] = []
        public var discontinuities: [Double] = []
        public var play = Phase()
    }

    /// Plays the owner's cut from 1.2 s through 2.8 s.
    public static func ownerCut(dir: URL) async throws -> CutResult {
        let p = try await ownerCutProject(dir: dir)
        let (e, rec) = try await engine(p)
        var r = CutResult()
        e.seek(to: Time(1.2))
        e.play()
        r.play = await poll(e, timeout: 30) { e.currentTime.seconds >= 2.8 }
        e.pause()
        guard e.currentTime.seconds >= 2.8 else { throw Failure(description: "the play did not reach 2.8 s (at \(e.currentTime.seconds))") }
        let c = try await PreviewAudioCheck.compareToExport(rec, project: p, from: 1.25, to: 2.75)
        r.maxDiff = c.maxDiff; r.lag = c.lag
        let s = rec.stream()
        r.silent = silentWindows(s.left, start: s.start, from: 1.6, to: 2.4)
        r.discontinuities = rec.discontinuities
        e.audio.stop()
        return r
    }

    public struct SyncResult: Sendable {
        /// A/V spread (ms) per phase: play, seek while playing, rate 2, rate 0.5 → 1, pause / resume.
        public var phases: [(name: String, phase: Phase)] = []
        public var maxPollDriftMs = 0.0
        public var driftRejoins = 0
        /// Audio labels that did not continue the previous chunk from the pause on (a flush / jump at resume shows here).
        public var pauseDiscontinuities: [Double] = []
        public var resumedFrom = 0.0
    }

    /// A/V sync after play, seek while playing, rate changes and pause / resume, on a bursts clip.
    public static func sync(dir: URL) async throws -> SyncResult {
        let (p, _) = try await PreviewAudioCheck.burstProject(dir: dir)
        let (e, rec) = try await engine(p)
        var r = SyncResult()
        e.seek(to: Time(1.2))
        e.play()
        r.phases.append(("play", await poll(e, timeout: 20) { e.currentTime.seconds >= 2.0 }))
        e.seek(to: Time(3.0))
        r.phases.append(("seek while playing", await poll(e, timeout: 20) { e.player.rate > 0 && e.currentTime.seconds >= 3.6 }))
        e.setRate(2)
        r.phases.append(("rate 2", await poll(e, timeout: 20) { e.currentTime.seconds >= 4.6 }))
        e.setRate(0.5)
        r.phases.append(("rate 0.5", await poll(e, timeout: 20) { e.currentTime.seconds >= 4.9 }))
        e.setRate(1)
        r.phases.append(("rate 1", await poll(e, timeout: 20) { e.currentTime.seconds >= 5.2 }))
        e.pause()
        let paused = e.audio.currentTime
        try await Task.sleep(nanoseconds: 300_000_000)
        let mark = rec.snapshot.count
        e.play()
        r.phases.append(("pause / resume", await poll(e, timeout: 20) { e.currentTime.seconds >= 5.8 }))
        e.pause()
        let after = Array(rec.snapshot.dropFirst(max(0, mark - 1)))
        r.pauseDiscontinuities = zip(after, after.dropFirst()).compactMap { a, b in
            PreviewAudioLanes.frame(b.time) == PreviewAudioLanes.frame(a.time) + a.left.count ? nil : b.time
        }
        r.resumedFrom = paused
        r.maxPollDriftMs = e.maxAVDrift * 1000
        r.driftRejoins = e.driftRejoins
        e.audio.stop()
        return r
    }

    public struct StormResult: Sendable {
        public var restarted = false
        public var after = Phase()
        public var readersAfter = 0
        public var framesAfter = 0
        /// Hot audio swaps (item rebuilds while playing) and stall-watchdog rebuilds during the storm (diagnostics).
        public var swaps = 0, rebuilds = 0
    }

    /// 12 seeks 80 ms apart while playing: video and audio both run again afterwards, in step, one reader open.
    public static func seekStorm(dir: URL) async throws -> StormResult {
        let (p, _) = try await PreviewAudioCheck.burstProject(dir: dir)
        let (e, _) = try await engine(p)
        var r = StormResult()
        e.seek(to: Time(1.0))
        e.play()
        await poll(e, timeout: 20) { e.currentTime.seconds >= 1.4 }
        var seed: UInt64 = 99
        for _ in 0..<12 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            e.seek(to: Time(1.0 + Double((seed >> 33) % 4000) / 1000))
            await poll(e, timeout: 0.08) { false }
        }
        let target = e.requestedTime.seconds
        r.after = await poll(e, timeout: 20) { e.player.rate > 0 && e.audio.isRunning && e.currentTime.seconds >= target + 0.6 }
        r.restarted = e.player.rate > 0 && e.audio.isRunning
        r.framesAfter = e.framesSinceSeek
        // this engine's (other suites run readers in parallel), between two feeder operations: read while the feeder
        // was inside a hot swap (an item rebuild while playing: stall watchdog, a cache becoming ready), the count is 2
        // for a moment by design (FLAKY-PB: the flake, `readersAfter 2`)
        r.readersAfter = await e.audio.settledOpenReaderCount()
        r.swaps = e.audio.stats.swaps
        r.rebuilds = e.stallRebuilds
        e.pause()
        e.audio.stop()
        return r
    }

    public struct RebuildResult: Sendable {
        public var discontinuities: [Double] = []
        public var rejoins = 0
        public var after = Phase()
        public var playing = false
        public var heardEditAfterMs = Double.nan
        /// The audio's enqueue horizon (ms; `PreviewAudio.feedAhead`, depends on the output latency).
        public var feedAheadMs = 150.0
        /// Budget for `heardEditAfterMs`: the horizon + the build + the next burst (bursts are ≤ 320 ms apart).
        public var heardBudgetMs: Double { feedAheadMs + 350 }
    }

    /// Item rebuilds while playing (`forceRebuild`, then a structural edit: the clip's volume halved): the audio goes
    /// on without a discontinuity, the new item's video re-joins the audio clock.
    public static func rebuildWhilePlaying(dir: URL) async throws -> RebuildResult {
        let (p, clip) = try await PreviewAudioCheck.burstProject(dir: dir)
        let (e, rec) = try await engine(p)
        var r = RebuildResult()
        r.feedAheadMs = e.audio.feedAhead * 1000
        e.seek(to: Time(1.2))
        e.play()
        await poll(e, timeout: 20) { e.currentTime.seconds >= 1.6 }
        let mark = rec.snapshot.count
        e.forceRebuild()
        await poll(e, timeout: 20) { e.currentTime.seconds >= 2.6 }
        var edited = p
        edited.timeline[clip: clip.id]?.audio.volume = 0.5
        let editClock = e.audio.currentTime
        e.update(project: edited)
        r.after = await poll(e, timeout: 20) { !e.isBuilding && e.player.rate > 0 && e.currentTime.seconds >= max(3.8, editClock + 1) }
        r.playing = e.player.rate > 0 && e.audio.isRunning
        r.rejoins = e.videoRejoins
        e.pause()
        let after = Array(rec.snapshot.dropFirst(max(0, mark - 1)))
        r.discontinuities = zip(after, after.dropFirst()).compactMap { a, b in
            PreviewAudioLanes.frame(b.time) == PreviewAudioLanes.frame(a.time) + a.left.count ? nil : b.time
        }
        // first burst onset at half level after the edit
        let st = rec.stream()
        var calm = 0
        for (i, v) in st.left.enumerated() {
            let t = Double(st.start + i) / PreviewAudio.sampleRate
            if abs(v) > 0.2 {
                if calm >= 240, t > editClock, abs(abs(v) - 0.4) < 0.05 { r.heardEditAfterMs = (t - editClock) * 1000; break }
                calm = 0
            } else if abs(v) < 0.02 { calm += 1 } else { calm = 0 }
        }
        e.audio.stop()
        return r
    }

    public struct EndResult: Sendable {
        public var stopped = false
        public var audioStopped = false
        public var playheadAtEnd = false
        public var audioClock = 0.0
        public var duration = 0.0
    }

    /// Plays into the end of the project: both stop, the playhead sits at the end, the audio clock does not run on.
    public static func endOfProject(dir: URL) async throws -> EndResult {
        let (p, _) = try await PreviewAudioCheck.burstProject(dir: dir)
        let (e, _) = try await engine(p)
        var r = EndResult()
        r.duration = e.duration.seconds
        e.seek(to: e.duration - Time(0.5))
        e.play()
        await poll(e, timeout: 20) { !e.isPlaying }
        await poll(e, timeout: 0.3) { false }
        r.stopped = !e.isPlaying
        r.audioStopped = !e.audio.isRunning
        r.audioClock = e.audio.currentTime
        r.playheadAtEnd = abs(e.currentTime.seconds - r.duration) < 0.1
        e.audio.stop()
        return r
    }

    static func ms(_ x: Double?) -> String { x.map { String(format: "%.1f", $0) } ?? "–" }

    /// Every engine scenario with the unit tests' thresholds; `log` gets one line per result.
    public static func runAll(dir: URL, log: @escaping @Sendable (String) -> Void) async -> Bool {
        var ok = true
        func check(_ name: String, _ pass: Bool, _ detail: String) {
            ok = ok && pass
            log("PLAYBACKENGINE \(pass ? "PASS" : "FAIL") \(name): \(detail)")
        }
        do {
            let c = try await ownerCut(dir: dir)
            check("owner's cut vs export", c.maxDiff < 1e-3 && c.lag == 0 && c.silent.isEmpty,
                  "max |diff| \(c.maxDiff), lag \(c.lag) frames, silent 5 ms windows \(c.silent), discontinuities \(c.discontinuities.count), A/V spread \(ms(c.play.avSpreadMs)) ms")
            let s = try await sync(dir: dir)
            let worst = s.phases.map(\.phase.avSpreadMs).max() ?? .nan
            check("A/V sync", worst < 34 && s.driftRejoins == 0 && s.pauseDiscontinuities.isEmpty,
                  s.phases.map { "\($0.name) \(ms($0.phase.avSpreadMs)) ms (start \(ms($0.phase.startMs)) ms, \($0.phase.frames) frames)" }.joined(separator: "; ")
                  + "; display-poll drift max \(ms(s.maxPollDriftMs)) ms, drift re-joins \(s.driftRejoins), pause/resume discontinuities \(s.pauseDiscontinuities.count)")
            let st = try await seekStorm(dir: dir)
            check("seek storm while playing", st.restarted && st.readersAfter <= 1 && st.framesAfter > 0 && st.after.avSpreadMs < 34,
                  "restarted \(st.restarted) in \(ms(st.after.startMs)) ms, frames after \(st.framesAfter), readers \(st.readersAfter), A/V spread \(ms(st.after.avSpreadMs)) ms")
            let rb = try await rebuildWhilePlaying(dir: dir)
            check("item rebuild / edit while playing", rb.playing && rb.discontinuities.isEmpty && rb.after.avSpreadMs < 34,
                  "playing \(rb.playing), audio discontinuities \(rb.discontinuities.count), video re-joins \(rb.rejoins), A/V spread \(ms(rb.after.avSpreadMs)) ms, edit heard after \(ms(rb.heardEditAfterMs)) ms")
            let en = try await endOfProject(dir: dir)
            check("end of project", en.stopped && en.audioStopped && en.playheadAtEnd && en.audioClock < en.duration + 0.15,
                  "stopped \(en.stopped), audio stopped \(en.audioStopped), playhead at end \(en.playheadAtEnd), audio clock \(String(format: "%.3f", en.audioClock)) / duration \(String(format: "%.3f", en.duration))")
        } catch {
            check("run", false, "\(error)")
        }
        return ok
    }
}
