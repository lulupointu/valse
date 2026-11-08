@preconcurrency import AVFoundation
import Testing
import Foundation
import QuartzCore
import ValseCore
@testable import ValseEngine
import ValseTestSupport

/// BUG-CUT-AUDIO-HOLE part 2 (docs/investigations/BUG-METALLIC-AUDIO.md, "Pre-effects lane taps: measurements"):
/// opt-in probes (`VALSE_TAP_PROBE=1`) of what a lane tap receives, measured on the content. Run them with the taps
/// pre-effects (`VALSE_TAP_PRE=1`, investigation switch in `AudioTap.make`) or post-effects (default). They print
/// `PROBE …` lines and assert nothing:
/// - `preview` / `export`: per buffer, raw stamp, frames, Δstamp / frames, and where the buffer's head and tail sit in
///   the source decoded offline (normalised correlation, lag in samples vs the composition's own time remap).
///   Preview runs with `VALSE_TAP_LABEL_LEAD=0` (stamps used as is).
/// - `echoDelay`: delay of the micEcho voice effect (0.16 s) in the export mix at clip speed 1 / 2 / 0.5.
/// - `previewLookAhead`: how far ahead of the playhead the tap processes (live-effect edit latency).
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["VALSE_TAP_PROBE"] != nil))
struct TapProbeTests {
    typealias Captured = MetallicAudioTests.Captured
    static var mode: String { ProcessInfo.processInfo.environment["VALSE_TAP_PRE"] != nil ? "pre" : "post" }

    /// Best lag (samples) of `x[a..<a+n]` in ref around `expected` (± range), correlation.
    static func lag(_ x: [Float], _ a: Int, _ n: Int, ref: [Float], expected: Int, range: Int) -> (Int, Double) {
        var ex = 0.0
        for i in a..<(a + n) { ex += Double(x[i]) * Double(x[i]) }
        guard ex > 1e-9 else { return (Int.min, 0) }
        var best = (0, -2.0)
        for l in -range...range {
            let s = expected + l
            guard s >= 0, s + n <= ref.count else { continue }
            var xy = 0.0, yy = 0.0
            for i in 0..<n { let y = Double(ref[s + i]); xy += Double(x[a + i]) * y; yy += y * y }
            let c = yy > 0 ? xy / (ex * yy).squareRoot() : 0
            if c > best.1 { best = (l, c) }
        }
        return best
    }

    enum Layout: String, CaseIterable { case gap, speed2, speed05, speed15, split12, rate2, rate05, k44, curve }

    /// The composition's audio remap of each clip: item-time segments → source time (what AVFoundation plays).
    struct Remap {
        var segs: [(start: Double, end: Double, src: Double, k: Double)] = []
        func source(at t: Double) -> Double? {
            guard let s = segs.first(where: { $0.start <= t + 1e-9 && t < $0.end - 1e-9 }) else { return nil }
            return s.src + (t - s.start) * s.k
        }
    }

    static func project(_ l: Layout) async throws -> (TestProject, URL, Remap) {
        var p = TestProject(frameRate: .fps30)
        var url = try MetallicAudioTests.noiseFile()
        if l == .k44 {
            url = TestMedia.directory.appendingPathComponent("probe-noise44.wav")
            if !FileManager.default.fileExists(atPath: url.path) {
                let tmp = TestMedia.directory.appendingPathComponent("probe-noise44-\(UUID().uuidString).wav")
                try AudioFileIO.write(AudioTestSignals.noise(seconds: 6, amplitude: 0.2, sampleRate: 44100, channels: 1, seed: 9), to: tmp, format: .wav24)
                TestMedia.publishFile(tmp, as: url)
            }
        }
        let id = try await p.addMedia(url, at: Time(1.0), duration: Time(3.0))
        switch l {
        case .speed2: try TimelineOps.setSpeed(id, .constant(2), in: &p.project.timeline)
        case .speed05: try TimelineOps.setSpeed(id, .constant(0.5), in: &p.project.timeline)
        case .speed15: try TimelineOps.setSpeed(id, .constant(1.5), in: &p.project.timeline)
        case .split12:
            _ = try TimelineOps.split(id, at: Time(1.5), in: &p.project.timeline)
            let second = p.project.timeline.allClips.filter { $0.mediaID != nil }.sorted { $0.start < $1.start }[1].id
            try TimelineOps.setSpeed(second, .constant(2), in: &p.project.timeline)
        case .curve:
            try TimelineOps.setSpeed(id, .curve(SpeedCurve(points: [SpeedPoint(0, 0.5), SpeedPoint(1, 2)])), in: &p.project.timeline)
        default: break
        }
        var remap = Remap()
        for c in p.project.timeline.allClips where c.mediaID != nil {
            let asset = try #require(p.project.asset(c.mediaID!))
            for s in CompositionBuilder.remapSegments(c, asset: asset, frameRate: p.project.settings.frameRate) {
                remap.segs.append(((c.start + s.output.start).seconds, (c.start + s.output.end).seconds,
                                   (c.sourceStart + s.source.start).seconds, s.source.duration.seconds / s.output.duration.seconds))
            }
        }
        remap.segs.sort { $0.start < $1.start }
        return (p, url, remap)
    }

    static func report(_ name: String, _ caps: [Captured], ref: [Float], refRate: Double, remap: Remap) {
        print("PROBE ==== \(mode) \(name): \(caps.count) buffers, frames \(Set(caps.map(\.samples.count)).sorted()), rates \(Set(caps.map(\.rate)))")
        var prev: Captured?
        var heads: [Int] = [], tails: [Int] = []
        for (i, c) in caps.enumerated() {
            var line = String(format: "PROBE %@ %@ #%d t=%.5f n=%d", mode, name, i, c.time, c.samples.count)
            if let p = prev, p.time.isFinite, c.time.isFinite {
                line += String(format: " Δ/frames×sr=%.4f", (c.time - p.time) / Double(p.samples.count) * c.rate)
            }
            if c.time.isFinite, let src = remap.source(at: c.time) {
                let e = Int((src * refRate).rounded())
                let n = min(256, c.samples.count / 2)
                let (l0, c0) = lag(c.samples, 0, n, ref: ref, expected: e, range: 4800)
                line += " head lag=\(l0 == Int.min ? "silent" : "\(l0)") corr=\(String(format: "%.3f", c0))"
                if l0 != Int.min, c0 > 0.9 { heads.append(l0) }
                // tail, if the buffer holds contiguous source samples from its head (pre-effects hypothesis)
                let tailStart = c.samples.count - n
                let (l1, c1) = lag(c.samples, tailStart, n, ref: ref, expected: e + tailStart, range: 4800)
                line += " tail(contiguous) lag=\(l1 == Int.min ? "silent" : "\(l1)") corr=\(String(format: "%.3f", c1))"
                if l1 != Int.min, c1 > 0.9 { tails.append(l1) }
            }
            print(line)
            prev = c
        }
        print("PROBE \(mode) \(name) head lags \(Set(heads).sorted()) tail lags \(Set(tails).sorted())")
    }

    @Test(arguments: Layout.allCases)
    func preview(_ layout: Layout) async throws {
        setenv("VALSE_TAP_LABEL_LEAD", "0", 1)
        defer { unsetenv("VALSE_TAP_LABEL_LEAD") }
        let (p, url, remap) = try await Self.project(layout)
        let refRate = layout == .k44 ? 44100.0 : 48000
        let ref = try await AudioFileIO.read(url, sampleRate: refRate, channels: 1).channel(0)
        let project = p.project
        let cap = MetallicAudioTests.Capture()
        try await HeavyWorkGate.run {
            let engine = PlaybackEngine(project: project)
            engine.usesProxies = false
            try await PlaybackProbe.waitReady(engine)
            MetallicAudioTests.record(engine, into: cap)
            defer { engine.audioState.tapCapture = nil }
            engine.seek(to: Time(0.4))
            let r: Float = layout == .rate2 ? 2 : layout == .rate05 ? 0.5 : 1
            if r == 1 { engine.play() } else { engine.setRate(r) }
            let t0 = CACurrentMediaTime()
            while engine.currentTime.seconds < 2.8, CACurrentMediaTime() - t0 < 30 {
                _ = engine.pixelBuffer(forHostTime: CACurrentMediaTime())
                try await Task.sleep(nanoseconds: 4_000_000)
            }
            engine.pause()
        }
        Self.report("preview-\(layout.rawValue)", cap.snapshot, ref: ref, refRate: refRate, remap: remap)
    }

    @Test(arguments: Layout.allCases.filter { $0 != .rate2 && $0 != .rate05 })
    func export(_ layout: Layout) async throws {
        let (p, url, remap) = try await Self.project(layout)
        let ref = try await AudioFileIO.read(url, sampleRate: 48000, channels: 1).channel(0)
        let state = AudioMixState()
        let cap = MetallicAudioTests.Capture()
        state.tapCapture = { t, s, rate, step in cap.add(Captured(wall: 0, time: t, samples: Array(s), rate: rate, step: step)) }
        _ = try await AudioMixdown.render(p.project, range: TimeRange(start: .zero, duration: Time(3.0)), audioState: state)
        Self.report("export-\(layout.rawValue)", cap.snapshot, ref: ref, refRate: 48000, remap: remap)
    }

    /// micEcho (high-pass + 0.16 s echo) on a 10 ms burst at 0.5 s of the source, clip speed `speed` (negative = no
    /// effect, `bed`: a quiet noise bed under the burst): the echo delay in the export mix, and the raw tap stamps.
    @Test(arguments: [(1.0, false), (2.0, false), (0.5, false), (-1.0, false), (1.0, true)])
    func echoDelay(_ arg: Double, _ bed: Bool) async throws {
        let speed = abs(arg)
        var g = SystemRandomNumberGenerator()
        var s = (0..<(48000 * 3)).map { _ in bed ? Float.random(in: -0.003...0.003, using: &g) : 0 }
        for i in 24000..<24480 { s[i] = Float.random(in: -0.5...0.5, using: &g) }
        var p = TestProject(frameRate: .fps30)
        let id = try await p.addAudio(AudioBuffer([s], sampleRate: 48000))
        if arg > 0 { p[id].audio.voice = VoiceEffects.descriptor("valse.voice.micEcho")!.makeEffect() }
        if speed != 1 { try TimelineOps.setSpeed(id, .constant(speed), in: &p.project.timeline) }
        let state = AudioMixState()
        let raw = MetallicAudioTests.Capture()
        state.tapObserver = { e in if case .buffer(let t, let n) = e { raw.add(Captured(wall: 0, time: t, samples: [Float](repeating: 0, count: n), rate: 0)) } }
        let out = try await AudioMixdown.render(p.project, audioState: state).channel(0)
        let tag = "\(Self.mode) speed \(speed) effect \(arg > 0) bed \(bed)"
        print("PROBE echo \(tag): raw stamps/frames \(raw.snapshot.prefix(6).map { String(format: "%.4f/%d", $0.time, $0.samples.count) }); "
              + "mix nonzero \(out.filter { $0 != 0 }.count) of \(out.count) frames (clip \(p[id].start.seconds)–\(p[id].end.seconds) s)")
        let w = 96   // 2 ms RMS envelope
        let env = stride(from: 0, to: out.count - w, by: w).map { a in (out[a..<(a + w)].reduce(0.0) { $0 + Double($1 * $1) } / Double(w)).squareRoot() }
        guard let i0 = env.indices.max(by: { env[$0] < env[$1] }), env[i0] > 0, i0 + 15 < env.count else {
            print("PROBE echo \(tag): silent mix"); return
        }
        let i1 = ((i0 + 15)..<min(env.count, i0 + 250)).max { env[$0] < env[$1] }!
        print(String(format: "PROBE echo %@: burst at %.3f s, echo at %.3f s → delay %.1f ms (echo/burst %.2f)",
                     tag, Double(i0 * w) / 48000, Double(i1 * w) / 48000, Double((i1 - i0) * w) / 48, env[i1] / env[i0]))
    }

    /// How far ahead of the playhead the lane tap processes in preview (= latency of a live-effect edit).
    @Test func previewLookAhead() async throws {
        let (p, _, _) = try await Self.project(.gap)
        let project = p.project
        let cap = MetallicAudioTests.Capture()
        var marks: [(wall: Double, item: Double)] = []
        try await HeavyWorkGate.run {
            let engine = PlaybackEngine(project: project)
            engine.usesProxies = false
            try await PlaybackProbe.waitReady(engine)
            MetallicAudioTests.record(engine, into: cap)
            defer { engine.audioState.tapCapture = nil }
            engine.seek(to: Time(0.4))
            engine.play()
            let t0 = CACurrentMediaTime()
            while engine.currentTime.seconds < 3.5, CACurrentMediaTime() - t0 < 30 {
                _ = engine.pixelBuffer(forHostTime: CACurrentMediaTime())
                if engine.player.rate != 0 { marks.append((CACurrentMediaTime(), engine.player.currentTime().seconds)) }
                try await Task.sleep(nanoseconds: 4_000_000)
            }
            engine.pause()
        }
        var ahead: [Double] = []
        for c in cap.snapshot where c.time.isFinite {
            guard let m = marks.min(by: { abs($0.wall - c.wall) < abs($1.wall - c.wall) }), abs(m.wall - c.wall) < 0.05 else { continue }
            ahead.append((c.time - m.item - (c.wall - m.wall)) * 1000)
        }
        ahead.sort()
        print(String(format: "PROBE lookahead %@: tap processes a buffer %.0f ms (median; max %.0f) before the playhead reaches its stamp, %d buffers, frames %@",
                     Self.mode, ahead.isEmpty ? .nan : ahead[ahead.count / 2], ahead.last ?? .nan, ahead.count,
                     "\(Set(cap.snapshot.map(\.samples.count)).sorted())"))
    }
}
