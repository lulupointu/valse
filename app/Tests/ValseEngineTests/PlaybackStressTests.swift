@preconcurrency import AVFoundation
import Testing
import Foundation
import QuartzCore
import ValseCore
import ValseEngine
import ValseTestSupport

/// C3-5 playback freeze: play, seek while playing (timeline clicks = exact seeks, scrubs = keyframe-tolerant bursts
/// ending with an exact seek), pause / play toggles. After every action the video output must deliver new frames
/// again (what PlayerView presents) and the player clock must advance — a frozen preview fails with the stall length.
///
/// Synthetic media always runs; real footage is opt-in:
/// `VALSE_QA_PROJECT=~/Movies/Valse/1019.valse scripts/test.sh --filter PlaybackStressTests` (the package is only
/// read; media decodes from the originals, no proxies generated).
@MainActor @Suite(.serialized) struct PlaybackStressTests {
    struct Report { var actions = 0; var maxStall = 0.0; var maxStallComposed = 0; var stalls: [String] = []; var frames = 0 }

    /// Frames the compositor may compose before the display shows a new one, at most (load-independent freeze bound:
    /// a healthy pipeline displays what it composes; measured healthy max: see the printed `max composed before a frame`).
    static let maxComposedWithoutDisplay = 30

    /// Polls the engine's video output like the display link; returns the seconds until frames advance by `need`
    /// distinct display times while the clock moves, or nil = FROZEN: no new frame while the video pipeline did no work
    /// (no composition request started, nothing composed) for `timeout` s — AVPlayer stopped asking our compositor for
    /// frames, the C3-5 freeze — or no new frame at all for `hangBound` s even though the pipeline kept working.
    /// A loaded machine only makes the pipeline slower, never idle, so the result does not depend on the load.
    /// Also FROZEN, in work units: more than `maxComposedWithoutDisplay` frames composed while the display got no new
    /// frame (the compositor runs but nothing reaches the screen — however fast or slow the machine).
    /// Returns (seconds, frames seen, most frames composed before a new frame was displayed).
    static func waitForFrames(_ engine: PlaybackEngine, need: Int = 3, timeout: Double, hangBound: Double = 30) async throws -> (Double, Int, Int)? {
        let start = CACurrentMediaTime()
        var last = CMTime.invalid, seen = 0
        var work = (CompositorStats.shared.requestsStarted, engine.state.framesComposed), lastWork = start
        var composedAtFrame = engine.state.framesComposed, maxComposed = 0
        while CACurrentMediaTime() - lastWork < timeout, CACurrentMediaTime() - start < hangBound {
            let now = (CompositorStats.shared.requestsStarted, engine.state.framesComposed)
            if now != work { work = now; lastWork = CACurrentMediaTime() }
            let composedSince = engine.state.framesComposed - composedAtFrame
            maxComposed = max(maxComposed, composedSince)
            if composedSince > Self.maxComposedWithoutDisplay { return nil }
            if let (_, t) = engine.pixelBuffer(forHostTime: CACurrentMediaTime()), t.cmTime != last {
                // consecutive frames moving forward (a stale frame of an earlier seek target resets the count)
                let forward = last.isValid && t.cmTime > last && (t.cmTime - last).seconds < 0.5
                seen = forward ? seen + 1 : 1
                last = t.cmTime
                composedAtFrame = engine.state.framesComposed
                if seen >= need { return (CACurrentMediaTime() - start, seen, maxComposed) }
            }
            try await Task.sleep(nanoseconds: 4_000_000)
        }
        return nil
    }

    static func stress(_ engine: PlaybackEngine, actions: Int, seed: UInt64, timeout: Double) async throws -> Report {
        var rng = SeededRNG(seed: seed)
        var r = Report()
        try await PlaybackProbe.waitReady(engine, timeout: 30)
        let d = max(1, engine.duration.seconds - timeout - 1.5)   // never reach the end while waiting
        engine.seek(to: .zero)
        engine.play()
        func check(_ what: String) async throws {
            guard engine.isPlaying else { return }
            let composed0 = engine.state.framesComposed, requests0 = CompositorStats.shared.requestsStarted
            let gpu0 = CompositorStats.shared.snapshot().frames, primes0 = engine.stallRecoveries
            if let (dt, n, c) = try await waitForFrames(engine, timeout: timeout) {
                r.maxStall = max(r.maxStall, dt); r.frames += n; r.maxStallComposed = max(r.maxStallComposed, c)
            } else {
                var probe = "no output"
                if let out = engine.videoOutput {
                    let it = out.itemTime(forHostTime: CACurrentMediaTime())
                    var shown = CMTime.invalid
                    let pb = out.copyPixelBuffer(forItemTime: it, itemTimeForDisplay: &shown)
                    probe = "itemTime \(String(format: "%.2f", it.seconds)) hasNew \(out.hasNewPixelBuffer(forItemTime: it)) forced copy \(pb != nil) shown \(String(format: "%.2f", shown.seconds))"
                    if let item = engine.player.currentItem {
                        let ranges = item.loadedTimeRanges.map { r in let r = r.timeRangeValue; return String(format: "%.1f+%.1f", r.start.seconds, r.duration.seconds) }
                        probe += " | tcs \(engine.player.timeControlStatus.rawValue) wait \(engine.player.reasonForWaitingToPlay?.rawValue ?? "-") empty \(item.isPlaybackBufferEmpty) keepUp \(item.isPlaybackLikelyToKeepUp) loaded \(ranges) outputs \(item.outputs.count)"
                    }
                }
                r.stalls.append(probe + " | ")
                r.stalls[r.stalls.count - 1] += ("\(what) → no new frame for \(timeout) s (rate \(engine.player.rate), item \(engine.player.currentItem?.status.rawValue ?? -1), t \(String(format: "%.2f", engine.player.currentTime().seconds)), composed +\(engine.state.framesComposed - composed0), requests +\(CompositorStats.shared.requestsStarted - requests0), gpu frames +\(CompositorStats.shared.snapshot().frames - gpu0), re-primes +\(engine.stallRecoveries - primes0), rebuilds \(engine.stallRebuilds))")
            }
        }
        try await check("play")
        for i in 0..<actions {
            r.actions += 1
            switch rng.next() % 6 {
            case 0, 1:   // timeline click while playing
                let t = Double(rng.next() % 10_000) / 10_000 * d
                engine.seek(to: Time(t))
                try await check("#\(i) seek \(String(format: "%.2f", t))")
            case 2:      // ruler scrub while playing: burst of tolerant seeks, exact on mouse-up
                var t = Double(rng.next() % 10_000) / 10_000 * d
                for _ in 0..<12 {
                    t = min(d, max(0, t + Double(Int(rng.next() % 200) - 100) / 100))
                    engine.seek(to: Time(t), exact: false)
                    try await Task.sleep(nanoseconds: 16_000_000)
                }
                engine.seek(to: Time(t), exact: true)
                try await check("#\(i) scrub → \(String(format: "%.2f", t))")
            case 3:      // rapid seeks (arrow keys / clicks in quick succession)
                for _ in 0..<5 { engine.seek(to: Time(Double(rng.next() % 10_000) / 10_000 * d)) }
                try await check("#\(i) seek storm")
            case 4:      // pause + play (space twice)
                engine.pause()
                try await Task.sleep(nanoseconds: UInt64(rng.next() % 150) * 1_000_000)
                engine.play()
                try await check("#\(i) pause/play")
            default:     // let it play a moment
                try await Task.sleep(nanoseconds: 300_000_000)
                try await check("#\(i) playing")
            }
            if !engine.isPlaying { engine.play(); try await check("#\(i) resume after end") }
        }
        engine.pause()
        return r
    }

    /// iPhone-like clip: 10-bit HLG HEVC with B-frames (frame reordering), 28-frame GOP, 29.97 fps, AAC — encoded by
    /// ffmpeg (AVAssetWriter's synthetic HEVC has no B-frames and never froze). nil without ffmpeg.
    static func iPhoneLikeClip(_ i: Int, seconds: Int = 12) async throws -> URL? {
        guard let ff = HDRTests.ffmpegPath else { return nil }
        let url = TestMedia.directory.appendingPathComponent("iphone-like-\(i)-\(seconds)s-v1.mov")
        if TestMedia.isUsable(url) { return url }
        let tmp = TestMedia.directory.appendingPathComponent("tmp-\(UUID().uuidString).mov")
        let args = ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=30000/1001:duration=\(seconds)",
                    "-f", "lavfi", "-i", "sine=frequency=\(300 + 110 * i):duration=\(seconds)",
                    "-vf", "hue=h=\(i * 120),format=yuv420p10le", "-c:v", "libx265", "-preset", "ultrafast",
                    "-x265-params", "log-level=error:keyint=28:min-keyint=28:bframes=3:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc",
                    "-tag:v", "hvc1", "-color_primaries", "bt2020", "-color_trc", "arib-std-b67", "-colorspace", "bt2020nc",
                    "-c:a", "aac", "-shortest", tmp.path]
        // blocking process: off the cooperative pool (STATUS gotcha)
        // (a failed ffmpeg must not rename its partial output into the shared cache: shell throws on a non-zero exit)
        let ok = await withCheckedContinuation { (k: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async { k.resume(returning: (try? HDRTests.shell(ff, args)) != nil) }
        }
        guard ok else { try? FileManager.default.removeItem(at: tmp); throw NSError(domain: "PlaybackStressTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "ffmpeg failed"]) }
        guard FileManager.default.fileExists(atPath: tmp.path) else { return nil }
        TestMedia.publishFile(tmp, as: url)
        return url
    }

    @Test func playSeekScrubNeverFreezesSynthetic() async throws {
        try await HeavyWorkGate.run {
            var p = TestProject()
            var clips: [URL] = []
            for i in 0..<3 { if let u = try await Self.iPhoneLikeClip(i) { clips.append(u) } }
            if clips.count < 3 {   // no ffmpeg: AVAssetWriter HEVC (weaker repro)
                clips = []
                for i in 0..<3 { clips.append(try await TestMedia.video(i == 1 ? .movingBox(.red, .white) : .frameIndex, seconds: 12, size: CGSize(width: 1920, height: 1080), codec: .hevc, audioHz: 300 + 110 * Double(i))) }
            }
            for u in clips { try await p.addMedia(u) }
            p.project.settings.canvasSize = Size2(1920, 1080)
            p.project.settings.colorSpace = .hdrHLG
            let engine = PlaybackEngine(project: p.project)
            engine.usesProxies = false
            let r = try await Self.stress(engine, actions: 40, seed: 42, timeout: 4)   // healthy: < 0.6 s; frozen: never
            print("playback stress (synthetic): \(r.actions) actions, \(r.frames) frames, max time to frames \(String(format: "%.2f", r.maxStall)) s, max composed before a frame \(r.maxStallComposed), stalls \(r.stalls.count), pipeline re-primes \(engine.stallRecoveries), rebuilds \(engine.stallRebuilds)")
            for s in r.stalls { print("  stall: \(s)") }
            #expect(r.stalls.isEmpty, "\(r.stalls)")
            // the freeze bound in work units (load-independent): frames composed before the display got a new one
            #expect(r.maxStallComposed <= Self.maxComposedWithoutDisplay, "composed \(r.maxStallComposed) frames before one was displayed")
            // the stall watchdog re-primes only a stalled pipeline (rare), never steady playback
            #expect(engine.stallRecoveries <= 5)
            let before = engine.stallRecoveries
            engine.seek(to: Time(2))
            engine.play()
            let t0 = CACurrentMediaTime()
            while CACurrentMediaTime() - t0 < 2.5 {
                _ = engine.pixelBuffer(forHostTime: CACurrentMediaTime())
                try await Task.sleep(nanoseconds: 8_000_000)
            }
            engine.pause()
            #expect(engine.stallRecoveries - before <= 1, "re-primes during steady playback")
        }
    }

    @Test func playSeekScrubNeverFreezesRealProject() async throws {
        guard let path = ProcessInfo.processInfo.environment["VALSE_QA_PROJECT"] else { print("skip: VALSE_QA_PROJECT"); return }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let project = try ProjectPackage.load(from: url)
        try await HeavyWorkGate.run {
            let engine = PlaybackEngine(project: project)
            engine.usesProxies = false
            let n = Int(ProcessInfo.processInfo.environment["VALSE_STRESS_ACTIONS"] ?? "") ?? 80
            let r = try await Self.stress(engine, actions: n, seed: 42, timeout: 5)
            print("playback stress (\(url.lastPathComponent)): \(r.actions) actions, \(r.frames) frames, max time to frames \(String(format: "%.2f", r.maxStall)) s, stalls \(r.stalls.count), pipeline re-primes \(engine.stallRecoveries)")
            for s in r.stalls { print("  stall: \(s)") }
            #expect(r.stalls.isEmpty, "\(r.stalls)")
        }
    }
}

/// Deterministic xorshift (stress actions repeat run to run).
struct SeededRNG {
    var s: UInt64
    init(seed: UInt64) { s = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
}
