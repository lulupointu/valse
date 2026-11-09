@preconcurrency import AVFoundation
import CoreAudio
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

    // MARK: Post-effects lead: root cause (owner request 2026-11-09)

    /// 3 ms noise bursts at IRREGULAR intervals (120–320 ms, fixed pseudo-random: a periodic train aliases a lead of
    /// one period), 48 kHz mono, 8 s.
    nonisolated static let burstTimes: [Double] = {
        var t = 0.05, seed: UInt64 = 12345, out: [Double] = []
        while t < 7.9 {
            out.append(t)
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            t += 0.12 + Double((seed >> 33) % 1000) / 1000 * 0.2
        }
        return out
    }()
    static func burstFile(rate: Double = 48000) throws -> URL {
        let url = TestMedia.directory.appendingPathComponent("probe-bursts3-\(Int(rate)).wav")
        if !FileManager.default.fileExists(atPath: url.path) {
            var s = [Float](repeating: 0, count: Int(8 * rate))
            var seed: UInt64 = 0x9E3779B97F4A7C15
            for b in burstTimes {
                let i0 = Int((b * rate).rounded())
                for i in i0..<(i0 + Int(0.03 * rate)) {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    s[i] = i == i0 ? 0.8 : Float(Int64(bitPattern: seed >> 11) % 1000) / 1000 * 0.5
                }
            }
            let tmp = TestMedia.directory.appendingPathComponent("probe-bursts-\(UUID().uuidString).wav")
            try AudioFileIO.write(AudioBuffer([s], sampleRate: rate), to: tmp, format: .wav24)
            TestMedia.publishFile(tmp, as: url)
        }
        return url
    }

    /// Onsets (frame index) in a buffer: |x| > 0.05 after ≥ 10 ms below 0.01 inside the buffer.
    static func onsets(_ x: [Float], quiet: Int) -> [Int] {
        var out: [Int] = []
        var calm = 0
        for (i, v) in x.enumerated() {
            if abs(v) > 0.05 { if calm >= quiet { out.append(i) }; calm = 0 } else if abs(v) < 0.01 { calm += 1 } else { calm = 0 }
        }
        return out
    }

    /// Lead of each stamped buffer, measured on the bursts: (expected composition time of the burst − stamp − frame
    /// offset × rate / sr). Post-effects output frames are in item time at the player rate.
    struct LeadSample { let stamp: Double; let frames: Int; let lead: Double }
    static func leads(_ caps: [Captured], clip: Clip, playerRate: Double, coarse: Double) -> [LeadSample] {
        var out: [LeadSample] = []
        var calm = 0
        var prevEnd = Double.nan
        let expected = burstCompositionTimes(clip)
        for c in caps where c.time.isFinite {
            let k = clip.speed.averageRate
            // quiet carried over from the previous buffer when this one continues it
            if !(abs(c.time - prevEnd) < 0.001) { calm = 0 }
            prevEnd = c.time + Double(c.samples.count) * playerRate / c.rate
            var found: [Int] = []
            for (i, v) in c.samples.enumerated() {
                if abs(v) > 0.1 { if calm >= Int(c.rate * 0.005) { found.append(i) }; calm = 0 } else if abs(v) < 0.03 { calm += 1 } else { calm = 0 }
            }
            for i in found {
                let measured = c.time + Double(i) * playerRate / c.rate
                // expected burst (composition time) nearest to measured + the coarse (envelope) lead, within 50 ms / k
                let m = measured + coarse
                guard let e = expected.min(by: { abs($0 - m) < abs($1 - m) }), abs(e - m) < 0.05 / k else { continue }
                guard e > clip.start.seconds + 0.15, e < clip.end.seconds - 0.15 else { continue }
                out.append(LeadSample(stamp: c.time, frames: c.samples.count, lead: e - measured))
            }
        }
        return out
    }

    /// Source time (s) the composition plays at composition time `t` of `clip`: `remap` when set (the composition's own
    /// piecewise remap, `CompositionBuilder.remapSegments`), else the exact `Clip.sourceTime`.
    static var remap: ((Double) -> Double)?
    static func src(_ clip: Clip, _ t: Double) -> Double { remap?(t) ?? clip.sourceTime(at: Time(t)).seconds }

    /// Composition times of the bursts inside `clip` (inverse of `Clip.sourceTime`, any speed / curve, by bisection).
    static func burstCompositionTimes(_ clip: Clip) -> [Double] {
        let s0 = src(clip, clip.start.seconds), s1 = src(clip, clip.end.seconds)
        return burstTimes.filter { $0 > s0 && $0 < s1 }.map { b in
            var lo = clip.start.seconds, hi = clip.end.seconds
            for _ in 0..<50 {
                let mid = (lo + hi) / 2
                if src(clip, mid) < b { lo = mid } else { hi = mid }
            }
            return lo
        }
    }

    /// Lead (ms) from 1 ms energy envelopes: the captured output placed at its labelled composition time vs the source
    /// placed at its composition time; the shift that best aligns them (robust to time-stretch smearing).
    static func envelopeLead(_ caps: [Captured], clip: Clip, playerRate: Double, source: [Float]) -> (lead: Double, corr: Double) {
        let t0 = clip.start.seconds, t1 = clip.end.seconds
        let bins = Int((t1 - t0) * 1000) + 1
        var got = [Double](repeating: 0, count: bins), want = [Double](repeating: 0, count: bins)
        var covered = [Bool](repeating: false, count: bins)
        for c in caps where c.time.isFinite {
            for (i, v) in c.samples.enumerated() {
                let b = Int(((c.time + Double(i) * playerRate / c.rate) - t0) * 1000)
                if b >= 0, b < bins { got[b] += Double(v * v); covered[b] = true }
            }
        }
        for b in 0..<bins {
            let s0 = Int(src(clip, t0 + Double(b) / 1000) * 48000)
            let s1 = Int(src(clip, t0 + Double(b + 1) / 1000) * 48000)
            if s0 >= 0, s1 <= source.count, s1 > s0 { for j in s0..<s1 { want[b] += Double(source[j] * source[j]) } }
        }
        // only bins the capture covers, away from the clip edges (gains)
        let valid = (0..<bins).filter { covered[$0] && $0 > 200 && $0 < bins - 200 }
        var best = (lead: 0.0, corr: -1.0)
        for lag in -300...300 {
            var xy = 0.0, xx = 0.0, yy = 0.0
            for b in valid where b + lag >= 0 && b + lag < bins { xy += got[b] * want[b + lag]; xx += got[b] * got[b]; yy += want[b + lag] * want[b + lag] }
            let c = xx > 0 && yy > 0 ? xy / (xx * yy).squareRoot() : 0
            if c > best.corr { best = (Double(lag), c) }
        }
        return best
    }

    static func summary(_ l: [LeadSample], rate: Double) -> String {
        guard !l.isEmpty else { return "no bursts found" }
        let ms = l.map { $0.lead * 1000 }.sorted()
        let frames = Set(l.map(\.frames)).sorted()
        return String(format: "lead median %.2f ms (min %.2f, max %.2f; %d bursts); buffer frames %@; lead in buffers of the median size %.3f",
                      ms[ms.count / 2], ms.first!, ms.last!, ms.count, "\(frames)",
                      ms[ms.count / 2] / 1000 / (Double(l.map(\.frames).sorted()[l.count / 2]) / 48000))
    }

    static func algorithm(_ name: String) -> AVAudioTimePitchAlgorithm {
        switch name { case "timeDomain": .timeDomain; case "varispeed": .varispeed; default: .spectral }
    }

    static func setAlgorithm(_ a: AVAudioTimePitchAlgorithm, item: AVPlayerItem) {
        item.audioTimePitchAlgorithm = a
        guard let mix = item.audioMix else { return }
        let m = AVMutableAudioMix()
        m.inputParameters = mix.inputParameters.map { p in
            let q = p.mutableCopy() as! AVMutableAudioMixInputParameters
            q.audioTimePitchAlgorithm = a
            return q
        }
        item.audioMix = m
    }

    /// Lists output devices (UID, nominal rate, IO buffer) to pick `VALSE_PROBE_DEVICE`.
    @Test func listOutputDevices() {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / 4)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
        for id in ids {
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
            var uid: Unmanaged<CFString>?
            var sz = UInt32(MemoryLayout<CFString?>.size)
            AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &uid)
            var rate = 0.0; sz = 8
            a.mSelector = kAudioDevicePropertyNominalSampleRate
            AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &rate)
            var frames = UInt32(0); sz = 4
            a.mSelector = kAudioDevicePropertyBufferFrameSize
            AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &frames)
            a.mSelector = kAudioDevicePropertyStreams; a.mScope = kAudioObjectPropertyScopeOutput
            var ss = UInt32(0)
            AudioObjectGetPropertyDataSize(id, &a, 0, nil, &ss)
            print("PROBE device \(uid?.takeUnretainedValue() as String? ?? "?") rate \(rate) buffer \(frames) outputStreams \(ss / 4)")
        }
    }

    static func setDeviceRate(_ uid: String, _ rate: Double) -> Double? {
        let id = PlaybackDeviceReproTests.deviceID(uid)
        guard id != 0 else { return nil }
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        var old = 0.0, sz = UInt32(8)
        AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &old)
        var r = rate
        let st = AudioObjectSetPropertyData(id, &a, 0, nil, 8, &r)
        print("PROBE device \(uid) rate \(old) → \(rate): status \(st)")
        return old
    }

    nonisolated static let leadCases: [(String, Float, Double)] = {
        let algos = ProcessInfo.processInfo.environment["VALSE_PROBE_ALGOS"]?.split(separator: ",").map(String.init)
            ?? ["none", "itemOnly", "remix", "spectral", "timeDomain", "varispeed"]
        let pairs: [(Float, Double)] = ProcessInfo.processInfo.environment["VALSE_PROBE_SPEEDS"] != nil
            ? [(1, 0.25), (1, 0.5), (1, 0.75), (1, 1.25), (1, 1.5), (1, 3), (2, 0.5), (0.5, 0.5)]
            : [(1, 1), (2, 1), (0.5, 1), (1, 2), (2, 2)]
        return algos.flatMap { a in pairs.map { (a, $0.0, $0.1) } }
    }()

    /// Preview lead (content-based) vs time-pitch algorithm, player rate and segment speed; plus the raw stamp structure
    /// of the first buffers after the seek (`tapDiagnostics`). `VALSE_PROBE_DEVICE` (UID) routes the player to that
    /// output, `VALSE_PROBE_DEVICE_RATE` sets its nominal rate for the test (restored after).
    @Test(arguments: leadCases)
    func previewLead(_ algo: String, _ rate: Float, _ speed: Double) async throws {
        setenv("VALSE_TAP_LABEL_LEAD", "0", 1)
        defer { unsetenv("VALSE_TAP_LABEL_LEAD") }
        let env = ProcessInfo.processInfo.environment
        var restore: (String, Double)?
        if let uid = env["VALSE_PROBE_DEVICE"], let r = env["VALSE_PROBE_DEVICE_RATE"].flatMap(Double.init), let old = Self.setDeviceRate(uid, r) {
            restore = (uid, old)
        }
        defer { if let (u, r) = restore { _ = Self.setDeviceRate(u, r) } }
        var p = TestProject(frameRate: .fps30)
        // VALSE_PROBE_SRC: "44100" (WAV at 44.1 kHz), "aac" (48 kHz AAC), "aac44100"
        let srcKind = env["VALSE_PROBE_SRC"] ?? ""
        var media = try Self.burstFile(rate: srcKind.hasSuffix("44100") ? 44100 : 48000)
        if srcKind.hasPrefix("aac") {
            let aac = TestMedia.directory.appendingPathComponent("probe-bursts3-\(srcKind).m4a")
            if !FileManager.default.fileExists(atPath: aac.path) {
                let buf = try await AudioFileIO.read(media, sampleRate: srcKind.hasSuffix("44100") ? 44100 : 48000, channels: 1)
                let tmp = TestMedia.directory.appendingPathComponent("probe-aac-\(UUID().uuidString).m4a")
                try AudioFileIO.write(buf, to: tmp, format: .aac)
                TestMedia.publishFile(tmp, as: aac)
            }
            media = aac
        }
        let id = try await p.addMedia(media, at: Time(1.0), duration: Time(6.0))
        if speed != 1 { try TimelineOps.setSpeed(id, .constant(speed), in: &p.project.timeline) }
        let clip = p[id]
        let project = p.project
        let cap = MetallicAudioTests.Capture()
        var diag: [TapDiagnostics.Capture] = []
        let seekTo = 1.3
        // "x/L" (S spectral, T timeDomain, V varispeed): preview lane algorithm set at build time (the item's own setting
        // was measured to change nothing). "none" = the shipping lanes.
        if algo.contains("/") {
            func a(_ c: Character) -> AVAudioTimePitchAlgorithm { c == "T" ? .timeDomain : c == "V" ? .varispeed : .spectral }
            CompositionBuilder.laneTimePitch = a(algo.last!)
        }
        defer { CompositionBuilder.laneTimePitch = .spectral }
        try await HeavyWorkGate.run {
            let engine = PlaybackEngine(project: project)
            engine.usesProxies = false
            if let uid = env["VALSE_PROBE_DEVICE"] { engine.player.audioOutputDeviceUniqueID = uid }
            try await PlaybackProbe.waitReady(engine)
            // "none": the shipping item untouched; "itemOnly": only the item's algorithm (spectral) re-set;
            // "remix": the same audio mix re-assigned (mutable copies, spectral); else: item + mix inputs set to `algo`
            let item = engine.player.currentItem!
            switch algo {
            case "none", _ where algo.contains("/"): break
            case "itemOnly": item.audioTimePitchAlgorithm = .spectral
            case "remix": Self.setAlgorithm(.spectral, item: item)
            case "itemTimeDomain": item.audioTimePitchAlgorithm = .timeDomain   // mix inputs stay spectral
            default: Self.setAlgorithm(Self.algorithm(algo), item: item)
            }
            _ = engine.audioState.tapDiagnostics.take()
            MetallicAudioTests.record(engine, into: cap)
            defer { engine.audioState.tapCapture = nil }
            engine.seek(to: Time(seekTo))
            if rate == 1 { engine.play() } else { engine.setRate(rate) }
            let t0 = CACurrentMediaTime()
            while CACurrentMediaTime() - t0 < 2.5 / Double(rate) + 0.5, engine.currentTime.seconds < clip.end.seconds - 0.3 {
                _ = engine.pixelBuffer(forHostTime: CACurrentMediaTime())
                diag += engine.audioState.tapDiagnostics.take()
                try await Task.sleep(nanoseconds: 4_000_000)
            }
            engine.pause()
            diag += engine.audioState.tapDiagnostics.take()
        }
        let caps = cap.snapshot
        let fmt = AudioDevices.defaultOutputFormat()
        let src = try await AudioFileIO.read(try Self.burstFile(), sampleRate: 48000, channels: 1).channel(0)
        let el = Self.envelopeLead(caps, clip: clip, playerRate: Double(rate), source: src)
        let l = Self.leads(caps, clip: clip, playerRate: Double(rate), coarse: el.lead / 1000)
        print("PROBE lead preview algo \(algo) rate \(rate) speed \(speed) device \(env["VALSE_PROBE_DEVICE"] ?? "default") (default out \(fmt.map { "\($0.sampleRate) Hz / \($0.bufferFrames) f" } ?? "?")): ENVELOPE lead \(el.lead) ms (corr \(String(format: "%.3f", el.corr))); bursts: \(Self.summary(l, rate: 48000))")
        for d in diag where d.buffers.contains(where: \.sounding) {
            let first = d.buffers.first { !$0.stamp.isNaN }
            print("PROBE lead preview algo \(algo) rate \(rate) speed \(speed) stamps: \(TapDiagnostics.describe(d))"
                  + (first.map { String(format: " | first stamp − seek target %+.2f ms", ($0.stamp - seekTo) * 1000) } ?? ""))
        }
        // stamp step vs frames: Δstamp (in item time, × sr / rate) == previous buffer's frames, or current's?
        var prevF = 0, prevT = Double.nan, matchPrev = 0, matchCur = 0, other = 0
        for c in caps where c.time.isFinite {
            if prevT.isFinite {
                let d = (c.time - prevT) * c.rate / Double(rate)
                if abs(d - Double(prevF)) < 2 { matchPrev += 1 } else if abs(d - Double(c.samples.count)) < 2 { matchCur += 1 } else { other += 1 }
            }
            prevT = c.time; prevF = c.samples.count
        }
        print("PROBE lead preview algo \(algo) rate \(rate) speed \(speed) Δstamp×sr/rate = previous frames \(matchPrev), = current frames \(matchCur) (when they differ, counted as previous), other \(other)")
    }

    @Test(arguments: [("spectral", 1.0), ("spectral", 2.0), ("timeDomain", 1.0), ("timeDomain", 2.0), ("varispeed", 1.0)])
    func exportLead(_ algo: String, _ speed: Double) async throws {
        var p = TestProject(frameRate: .fps30)
        let id = try await p.addMedia(try Self.burstFile(), at: Time(1.0), duration: Time(6.0))
        if speed != 1 { try TimelineOps.setSpeed(id, .constant(speed), in: &p.project.timeline) }
        let clip = p[id]
        let state = AudioMixState()
        let cap = MetallicAudioTests.Capture()
        state.tapCapture = { t, s, rate, step in cap.add(Captured(wall: 0, time: t, samples: Array(s), rate: rate, step: step)) }
        let built = try await CompositionBuilder.build(project: p.project, purpose: .export, audioState: state, conformsAudio: true)
        let tracks = try await built.composition.loadTracks(withMediaType: .audio)
        let a = Self.algorithm(algo)
        let mix = AVMutableAudioMix()
        mix.inputParameters = (built.audioMix?.inputParameters ?? []).map { p in
            let q = p.mutableCopy() as! AVMutableAudioMixInputParameters
            q.audioTimePitchAlgorithm = a
            return q
        }
        let job = Job(comp: built.composition, tracks: tracks, mix: mix, a: a, end: clip.end.seconds)
        try await Self.readAll(job)
        let src = try await AudioFileIO.read(try Self.burstFile(), sampleRate: 48000, channels: 1).channel(0)
        let el = Self.envelopeLead(cap.snapshot, clip: clip, playerRate: 1, source: src)
        let l = Self.leads(cap.snapshot, clip: clip, playerRate: 1, coarse: el.lead / 1000)
        print("PROBE lead export algo \(algo) speed \(speed): ENVELOPE lead \(el.lead) ms (corr \(String(format: "%.3f", el.corr))); bursts: \(Self.summary(l, rate: 48000))")
    }

    struct Job: @unchecked Sendable { let comp: AVComposition; let tracks: [AVAssetTrack]; let mix: AVAudioMix; let a: AVAudioTimePitchAlgorithm; let end: Double }
    nonisolated static func readAll(_ job: Job) async throws {
        try await OffPool.run { _ in
            let reader = try AVAssetReader(asset: job.comp)
            reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: job.end, preferredTimescale: 48000))
            let o = AVAssetReaderAudioMixOutput(audioTracks: job.tracks, audioSettings: Exporter.mixPCMSettings)
            o.audioMix = job.mix
            o.audioTimePitchAlgorithm = job.a
            reader.add(o)
            _ = reader.startReading()
            while o.copyNextSampleBuffer() != nil {}
        }
    }

    /// Latency the system time-pitch audio units report (kAudioUnitProperty_Latency) at rate 1 and 2, 48 kHz.
    @Test func timePitchUnitLatency() throws {
        for (name, sub) in [("NewTimePitch nutp", kAudioUnitSubType_NewTimePitch), ("TimePitch tmpt", kAudioUnitSubType_TimePitch),
                            ("Varispeed vari", kAudioUnitSubType_Varispeed), ("iPodTimeOther ipto", kAudioUnitSubType_AUiPodTimeOther)] {
            var desc = AudioComponentDescription(componentType: kAudioUnitType_FormatConverter, componentSubType: sub,
                                                 componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
            guard let comp = AudioComponentFindNext(nil, &desc) else { print("PROBE AU \(name): not found"); continue }
            var unit: AudioUnit?
            AudioComponentInstanceNew(comp, &unit)
            guard let u = unit else { continue }
            var fmt = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
                                                  mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsPacked,
                                                  mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
            AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, UInt32(MemoryLayout.size(ofValue: fmt)))
            AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &fmt, UInt32(MemoryLayout.size(ofValue: fmt)))
            AudioUnitInitialize(u)
            var line = "PROBE AU \(name):"
            for rate in [1.0, 2.0, 0.5] {
                AudioUnitSetParameter(u, sub == kAudioUnitSubType_Varispeed ? kVarispeedParam_PlaybackRate : kNewTimePitchParam_Rate,
                                      kAudioUnitScope_Global, 0, AudioUnitParameterValue(rate), 0)
                var lat = 0.0, sz = UInt32(8)
                let st = AudioUnitGetProperty(u, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &lat, &sz)
                var tail = 0.0; sz = 8
                AudioUnitGetProperty(u, kAudioUnitProperty_TailTime, kAudioUnitScope_Global, 0, &tail, &sz)
                line += String(format: " rate %.1f latency %.5f s (%.0f frames, status %d) tail %.4f;", rate, lat, lat * 48000, st, tail)
            }
            print(line)
            AudioUnitUninitialize(u)
            AudioComponentInstanceDispose(u)
        }
    }

    /// Position (seconds) in `ref[around ± radius]` where `x` matches best (normalised correlation).
    static func locateNear(_ x: ArraySlice<Float>, in ref: [Float], around: Int, radius: Int) -> (at: Double, corr: Double) {
        let xs = Array(x).map(Double.init)
        let ex = xs.reduce(0) { $0 + $1 * $1 }
        var best = (at: 0, corr: -2.0)
        ref.withUnsafeBufferPointer { r in
            for s in max(0, around - radius)..<min(r.count - xs.count, around + radius) {
                var xy = 0.0, yy = 0.0
                for i in 0..<xs.count { let y = Double(r[s + i]); xy += xs[i] * y; yy += y * y }
                let c = ex > 0 && yy > 0 ? xy / (ex * yy).squareRoot() : 0
                if c > best.corr { best = (s, c) }
            }
        }
        return (Double(best.at) / 48000, best.corr)
    }

    /// Structure of the first buffers after a seek (rate 1, unscaled): for each buffer, where its CONTENT starts in the
    /// source (noise, located by correlation within ±0.6 s of the target) vs its stamp and the seek target.
    /// Long play (12 s, rate 1): raw stamp and lane label vs content, every 15th buffer (drift of the stamps?).
    @Test(arguments: ["none", "x/T"])
    func longPlayDrift(_ algo: String) async throws {
        if algo.contains("/") { CompositionBuilder.laneTimePitch = .timeDomain }
        defer { CompositionBuilder.laneTimePitch = .spectral }
        let env = ProcessInfo.processInfo.environment
        let url = TestMedia.directory.appendingPathComponent("probe-noise-20s.wav")
        if !FileManager.default.fileExists(atPath: url.path) {
            let tmp = TestMedia.directory.appendingPathComponent("probe-noise-20s-\(UUID().uuidString).wav")
            try AudioFileIO.write(AudioTestSignals.noise(seconds: 20, amplitude: 0.2, channels: 1, seed: 11), to: tmp, format: .wav24)
            TestMedia.publishFile(tmp, as: url)
        }
        let ref = try await AudioFileIO.read(url, sampleRate: 48000, channels: 1).channel(0)
        var p = TestProject(frameRate: .fps30)
        _ = try await p.addMedia(url)
        let project = p.project
        let cap = MetallicAudioTests.Capture(), raw = MetallicAudioTests.Capture()
        try await HeavyWorkGate.run {
            let engine = PlaybackEngine(project: project)
            engine.usesProxies = false
            if let uid = env["VALSE_PROBE_DEVICE"] { engine.player.audioOutputDeviceUniqueID = uid }
            try await PlaybackProbe.waitReady(engine)
            engine.seek(to: Time(1.0))
            try await Task.sleep(nanoseconds: 300_000_000)
            MetallicAudioTests.record(engine, into: cap)
            engine.audioState.tapObserver = { e in if case .buffer(let t, let n) = e { raw.add(Captured(wall: 0, time: t, samples: [], rate: Double(n))) } }
            defer { engine.audioState.tapCapture = nil; engine.audioState.tapObserver = nil }
            engine.play()
            try await MetallicAudioTests.play(engine, seconds: 12)
            engine.pause()
        }
        let caps = cap.snapshot, stamps = raw.snapshot
        var line = "PROBE drift \(algo):"
        for i in stride(from: 2, to: min(caps.count, stamps.count), by: 15) {
            let c = caps[i]
            guard c.samples.count >= 1600, c.samples.contains(where: { $0 != 0 }), c.time.isFinite else { continue }
            let found = Self.locateNear(c.samples[512 ..< 1536], in: ref, around: Int(c.time * 48000), radius: 9600)
            let content = found.at - 512.0 / 48000
            line += String(format: " | #%d stamp %.4f lead %+.2f, label lead %+.2f ms (corr %.2f)", i, stamps[i].time,
                           (content - stamps[i].time) * 1000, (content - c.time) * 1000, found.corr)
        }
        print(line.replacingOccurrences(of: " | ", with: "\n  "))
    }

    @Test(arguments: ["none", "x/T"])
    func seekStructure(_ algo: String) async throws {
        if algo.contains("/") { CompositionBuilder.laneTimePitch = .timeDomain }
        defer { CompositionBuilder.laneTimePitch = .spectral }
        setenv("VALSE_TAP_LABEL_LEAD", "0", 1)
        defer { unsetenv("VALSE_TAP_LABEL_LEAD") }
        let env = ProcessInfo.processInfo.environment
        let url = try MetallicAudioTests.noiseFile()
        let ref = try await AudioFileIO.read(url, sampleRate: 48000, channels: 1).channel(0)
        var p = TestProject(frameRate: .fps30)
        _ = try await p.addMedia(url)
        let project = p.project
        for (n, target) in [2.0, 3.3337, 1.25].enumerated() {
            let cap = MetallicAudioTests.Capture()
            try await HeavyWorkGate.run {
                let engine = PlaybackEngine(project: project)
                engine.usesProxies = false
                if let uid = env["VALSE_PROBE_DEVICE"] { engine.player.audioOutputDeviceUniqueID = uid }
                try await PlaybackProbe.waitReady(engine)
                engine.seek(to: Time(target))
                try await Task.sleep(nanoseconds: 300_000_000)
                MetallicAudioTests.record(engine, into: cap)
                defer { engine.audioState.tapCapture = nil }
                engine.play()
                try await MetallicAudioTests.play(engine, seconds: 1.2)
                engine.pause()
            }
            var line = String(format: "PROBE seek %@ #%d target %.4f device %@:", algo, n, target, env["VALSE_PROBE_DEVICE"] ?? "default")
            for (i, c) in cap.snapshot.prefix(9).enumerated() {
                guard c.samples.contains(where: { $0 != 0 }) else {
                    line += String(format: " | #%d %@ %df silent", i, c.time.isFinite ? String(format: "%.4f", c.time) : "nostamp", c.samples.count); continue
                }
                // content position of the buffer's samples 512..<1536 (past a possible fade-in), then back to its start
                let k = min(512, c.samples.count / 4), n = min(1024, c.samples.count - k)
                let found = Self.locateNear(c.samples[k ..< k + n], in: ref, around: Int(target * 48000), radius: 30000)
                let start = found.at - Double(k) / 48000
                line += String(format: " | #%d %@ %df content %.4f (corr %.2f)%@", i, c.time.isFinite ? String(format: "%.4f", c.time) : "nostamp",
                                c.samples.count, start, found.corr,
                                c.time.isFinite ? String(format: " lead %+.2f ms", (start - c.time) * 1000) : "")
            }
            print(line)
        }
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
