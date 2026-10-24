@preconcurrency import AVFoundation
import CoreAudio
import os
import Testing
import Foundation
import QuartzCore
import MontageCore
@testable import MontageEngine
import MontageTestSupport

/// PB-LATENCY / PB-DROP reproduction on real output devices (manual, opt-in: MONTAGE_PB_REPRO=1). Needs ffmpeg and
/// virtual output devices; nothing plays on the speakers.
/// - MONTAGE_PB_LATENCY_UID: output whose clock lead exceeds `stallSpan` (e.g. "SteamStreamingSpeakers_UID" with a
///   4096-frame IO buffer, set by the test: lead ≈ 0.36 s).
/// - MONTAGE_PB_DROP_UID: output to play the 1023-like project on; MONTAGE_PB_DROP_RATE: media sample rate (≠ device);
///   MONTAGE_PB_CAPTURE: avfoundation input name of that output's loopback (e.g. "Microsoft Teams Audio"), optional.
/// - MONTAGE_PB_OUT: directory for the report / captures.
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MONTAGE_PB_REPRO"] != nil))
struct PlaybackDeviceReproTests {
    static let env = ProcessInfo.processInfo.environment
    static let out = URL(fileURLWithPath: env["MONTAGE_PB_OUT"] ?? NSTemporaryDirectory())

    static func log(_ s: String) {
        print("PBREPRO " + s)
        let url = out.appendingPathComponent("report.txt")
        let line = Data((s + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line); try? h.close() } else { try? line.write(to: url) }
    }

    static func deviceID(_ uid: String) -> AudioObjectID {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var cf = uid as CFString
        var id = AudioObjectID(0), size = UInt32(4)
        _ = withUnsafeMutablePointer(to: &cf) { p in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<CFString>.size), p, &size, &id)
        }
        return id
    }

    static func setBuffer(_ uid: String, frames: UInt32) {
        var f = frames
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let st = AudioObjectSetPropertyData(deviceID(uid), &addr, 0, nil, 4, &f)
        log("buffer \(uid) → \(frames): status \(st)")
    }

    static func run(_ tool: String, _ args: [String], wait: Bool = true, stdout: URL? = nil) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        if let stdout { FileManager.default.createFile(atPath: stdout.path, contents: nil); p.standardOutput = try FileHandle(forWritingTo: stdout) }
        else { p.standardOutput = FileHandle.nullDevice }
        p.standardError = FileHandle.nullDevice
        try p.run()
        if wait { p.waitUntilExit() }
        return p
    }

    /// Video (or audio only) with a sine of `hz` at `rate` Hz, AAC.
    static func media(hz: Int, rate: Int, seconds: Int = 30, video: Bool) throws -> URL {
        let url = out.appendingPathComponent("m-\(hz)-\(rate)\(video ? "" : "-a").\(video ? "mov" : "m4a")")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        var a = ["-hide_banner", "-loglevel", "error", "-y"]
        if video { a += ["-f", "lavfi", "-i", "testsrc=size=320x180:rate=25:duration=\(seconds)"] }
        a += ["-f", "lavfi", "-i", "sine=frequency=\(hz):sample_rate=\(rate):duration=\(seconds),volume=0.6"]
        if video { a += ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "25"] }
        a += ["-c:a", "aac", "-ar", "\(rate)", "-ac", "2", url.path]
        _ = try run("/opt/homebrew/bin/ffmpeg", a)
        return url
    }

    /// Polls like the player view for `seconds`; returns distinct frames.
    static func drive(_ engine: PlaybackEngine, seconds: Double, sample: ((Double) -> Void)? = nil) async throws -> Int {
        let start = CACurrentMediaTime()
        var frames = 0
        var last = Time(-1)
        while CACurrentMediaTime() - start < seconds {
            if let (_, t) = engine.pixelBuffer(forHostTime: CACurrentMediaTime()), t != last { frames += 1; last = t }
            sample?(CACurrentMediaTime() - start)
            try await Task.sleep(nanoseconds: 8_000_000)
        }
        return frames
    }

    // MARK: PB-LATENCY

    @Test func latencyPlayStarts() async throws {
        guard let uid = Self.env["MONTAGE_PB_LATENCY_UID"] else { return }
        var p = TestProject(frameRate: .fps25)
        _ = try await p.addMedia(try Self.media(hz: 440, rate: 48000, seconds: 12, video: true))
        let engine = PlaybackEngine(project: p.project)
        engine.player.audioOutputDeviceUniqueID = uid
        engine.player.volume = 1   // tests export MONTAGE_MUTE_AUDIO; this output is a virtual device
        Self.setBuffer(uid, frames: 4096)
        try await PlaybackProbe.waitReady(engine)
        var failures = 0
        for (i, start) in [2.0, 5.0, -1, 8.0].enumerated() {
            if start >= 0 {
                engine.seek(to: Time(start))
                try await Task.sleep(nanoseconds: 400_000_000)
            }   // -1: resume in place after the previous pause
            let from = engine.currentTime.seconds
            let r0 = engine.stallRecoveries, b0 = engine.stallRebuilds
            var minClock = Double.infinity
            engine.play()
            let frames = try await Self.drive(engine, seconds: 2.5) { _ in
                if let tb = engine.player.currentItem?.timebase { minClock = min(minClock, CMTimebaseGetTime(tb).seconds) }
            }
            let to = engine.currentTime.seconds
            engine.pause()
            try await Task.sleep(nanoseconds: 300_000_000)
            let ok = to - from > 1.8 && engine.stallRecoveries == r0 && engine.stallRebuilds == b0
            if !ok { failures += 1 }
            Self.log(String(format: "latency case %d: from %.3f to %.3f (advanced %.2f s in 2.5 s), lead %.3f s, frames %d, recoveries +%d, rebuilds +%d %@",
                            i, from, to, to - from, from - minClock, frames, engine.stallRecoveries - r0, engine.stallRebuilds - b0, ok ? "OK" : "FAIL"))
        }
        Self.setBuffer(uid, frames: 512)
        #expect(failures == 0)
    }

    // MARK: PB-DROP

    struct Span { let track: String; let hz: Int; let start: Double; let end: Double; let volume: Double }

    /// Project 1023's layout (docs/investigations/PB-LATENCY-PB-DROP.md), one sine pitch per track.
    static func project1023(rate: Int) async throws -> (Project, [Span]) {
        var p = TestProject(canvas: Size2(180, 320), frameRate: .fps25)
        let end = 25.4
        func spans(_ starts: [Double]) -> [(Double, Double)] { starts.enumerated().map { i, s in (s, i + 1 < starts.count ? starts[i + 1] : end) } }
        let layout: [(name: String, hz: Int, video: Bool, target: InsertTarget, spans: [(Double, Double)], volumes: [Double])] = [
            ("main", 300, true, .automatic, spans([0, 5.523, 9.650, 11.520, 18.286, 20.854, 22.865]), [1.07, 1.82]),
            ("overlay1", 500, true, .newTrack, spans([5.503, 11.563, 18.286, 20.854, 22.865]), [1]),
            ("overlay2", 700, true, .newTrack, spans([11.520, 20.854, 22.865]), [2.69]),
            ("audioA", 900, false, .automatic, [(0, 5.523), (5.523, 9.650), (9.650, 18.286), (18.286, end)], [1]),
            ("audioB", 1100, false, .newTrack, [(9.650, 11.56)], [1]),
        ]
        var out: [Span] = []
        for l in layout {
            let id = try await p.addMedia(try media(hz: l.hz, rate: rate, video: l.video), target: l.target)
            let ti = try #require(p.project.timeline.tracks.firstIndex { $0.clips.contains { $0.id == id } })
            let base = p[id]
            var clips: [Clip] = []
            for (i, s) in l.spans.enumerated() {
                var c = base
                c.id = ClipID()
                c.start = Time(s.0); c.duration = Time(s.1 - s.0); c.sourceStart = Time(s.0)
                c.audio.volume = l.volumes[i % l.volumes.count]
                clips.append(c)
                out.append(Span(track: l.name, hz: l.hz, start: s.0, end: s.1, volume: c.audio.volume))
            }
            p.project.timeline.tracks[ti].clips = clips
        }
        return (p.project, out)
    }

    @Test func dropLanesAtCuts() async throws {
        guard let uid = Self.env["MONTAGE_PB_DROP_UID"] else { return }
        let rate = Int(Self.env["MONTAGE_PB_DROP_RATE"] ?? "48000")!
        let plays = Int(Self.env["MONTAGE_PB_PLAYS"] ?? "3")!
        let (project, spans) = try await Self.project1023(rate: rate)
        let engine = PlaybackEngine(project: project)
        // MONTAGE_PB_SWITCH_FROM: start on that output, play a while, then switch to `uid` (AirPods unplugged → speakers)
        let from = Self.env["MONTAGE_PB_SWITCH_FROM"]
        engine.player.audioOutputDeviceUniqueID = from ?? uid
        engine.player.volume = 1   // tests export MONTAGE_MUTE_AUDIO; this output is a virtual device
        try await PlaybackProbe.waitReady(engine)
        if from != nil {
            engine.seek(to: Time(3))
            engine.play()
            _ = try await Self.drive(engine, seconds: 4)
            engine.player.audioOutputDeviceUniqueID = uid
            _ = try await Self.drive(engine, seconds: 3)
            engine.pause()
            Self.log("switched output \(from!) → \(uid) while playing")
        }
        let built = try await CompositionBuilder.build(project: project, purpose: .preview)
        Self.log("drop: device \(uid), media \(rate) Hz, \(built.audioMix?.inputParameters.count ?? 0) audio lanes, duration \(project.duration.seconds)")
        let tapTimes = OSAllocatedUnfairLock(initialState: [Double]())
        engine.audioState.tapObserver = { e in if case .buffer(let t, _) = e { tapTimes.withLock { $0.append(t) } } }
        var totalMCM = 0
        // capture analysis is offline (the test helper may not get the loopback input): spans for the analyzer
        try spans.map { String(format: "%@ %d %.3f %.3f %.3f", $0.track, $0.hz, $0.start, $0.end, $0.volume) }.joined(separator: "\n")
            .write(to: Self.out.appendingPathComponent("spans.txt"), atomically: true, encoding: .utf8)
        // MONTAGE_PB_TAPLESS: a plain AVPlayer on the build without lane taps (the frozen-clock fallback: volumes in the mix)
        let tapless = Self.env["MONTAGE_PB_TAPLESS"] != nil
        let plain = AVPlayer()
        if tapless {
            engine.pause()
            engine.player.replaceCurrentItem(with: nil)
            let b = try await CompositionBuilder.build(project: project, purpose: .preview, audioTaps: false)
            let item = AVPlayerItem(asset: b.composition)
            item.audioMix = b.audioMix
            item.audioTimePitchAlgorithm = .spectral
            plain.automaticallyWaitsToMinimizeStalling = false
            plain.audioOutputDeviceUniqueID = uid
            plain.replaceCurrentItem(with: item)
            while item.status != .readyToPlay { try await Task.sleep(nanoseconds: 10_000_000) }
            Self.log("tapless variant: \(b.audioMix?.inputParameters.filter { $0.audioTapProcessor != nil }.count ?? 0) taps")
        }
        let switchEach = from != nil && Self.env["MONTAGE_PB_SWITCH_EACH"] != nil
        for run in 0..<plays {
            if switchEach, run > 0, let from {
                engine.player.audioOutputDeviceUniqueID = from
                engine.seek(to: Time(3))
                engine.play()
                _ = try await Self.drive(engine, seconds: 2)
                engine.player.audioOutputDeviceUniqueID = uid
                _ = try await Self.drive(engine, seconds: 2)
                engine.pause()
            }
            if tapless { await plain.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) } else { engine.seek(to: .zero) }
            try await Task.sleep(nanoseconds: 600_000_000)
            let logURL = Self.out.appendingPathComponent("mcm-\(rate)-\(run).txt")
            let logger = try Self.run("/usr/bin/log", ["stream", "--style", "compact", "--predicate", "eventMessage CONTAINS \"MCM ignoring\""],
                                      wait: false, stdout: logURL)
            try await Task.sleep(nanoseconds: 1_500_000_000)
            tapTimes.withLock { $0.removeAll() }
            Self.log(String(format: "playstart %d %.3f", run, Date().timeIntervalSince1970))
            let frames: Int
            if tapless {
                plain.play()
                try await Task.sleep(nanoseconds: UInt64((project.duration.seconds + 0.3) * 1e9))
                plain.pause()
                frames = 0
            } else {
                engine.play()
                frames = try await Self.drive(engine, seconds: project.duration.seconds + 0.3)
                engine.pause()
            }
            try await Task.sleep(nanoseconds: 500_000_000)
            logger.terminate(); logger.waitUntilExit()
            let mcm = (try? String(contentsOf: logURL, encoding: .utf8))?.split(separator: "\n").filter { $0.contains("MCM ignoring") && !$0.contains("Filtering") } ?? []
            totalMCM += mcm.count
            let taps = tapTimes.withLock { $0 }
            Self.log("run \(run): frames \(frames), recoveries \(engine.stallRecoveries), MCM lines \(mcm.count) \(mcm.first.map { String($0.suffix(60)) } ?? ""), tap buffers \(taps.count) (non-numeric \(taps.filter(\.isNaN).count) at \(taps.indices.filter { taps[$0].isNaN }.map { i in "#\(i) next \(taps[(i + 1)...].first { !$0.isNaN } ?? -1)" }))")
        }
        engine.audioState.tapObserver = nil
        Self.log("drop total: MCM lines \(totalMCM)")
        #expect(totalMCM == 0)
    }
}
