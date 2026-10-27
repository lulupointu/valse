@preconcurrency import AVFoundation
import Testing
import Foundation
import QuartzCore
import ValseCore
@testable import ValseEngine
import ValseTestSupport

/// BUG-METALLIC-AUDIO (docs/investigations/BUG-METALLIC-AUDIO.md): voices sounded metallic during preview playback
/// until a pause → play. Measured where Valse can see the audio: each lane tap's output (`AudioMixState.tapCapture`,
/// what goes to AVPlayer's mixer) is compared, buffer by buffer, with the source decoded offline at the composition
/// time the tap reports. A copy of the voice delayed by a few ms (comb filter), a time-stretch or a wrong timestamp all
/// show up as a large residual at lag 0.
@MainActor @Suite(.serialized) struct MetallicAudioTests {
    struct Captured: Sendable { let wall: Double; let time: Double; let samples: [Float]; let rate: Double; var step: Double = 0 }

    /// Records every buffer a lane tap hands to the mixer.
    static func record(_ engine: PlaybackEngine, into cap: Capture) {
        engine.audioState.tapCapture = { t, s, rate, step in
            cap.add(Captured(wall: CACurrentMediaTime(), time: t, samples: Array(s), rate: rate, step: step))
        }
    }

    final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Captured] = []
        func add(_ c: Captured) { lock.withLock { items.append(c) } }
        var snapshot: [Captured] { lock.withLock { items } }
    }

    /// Plays at least `seconds` of item time (polling like the player view), bounded in wall time.
    static func play(_ engine: PlaybackEngine, seconds: Double) async throws {
        let t0 = CACurrentMediaTime()
        while CACurrentMediaTime() - t0 < seconds {
            _ = engine.pixelBuffer(forHostTime: CACurrentMediaTime())
            try await Task.sleep(nanoseconds: 4_000_000)
        }
    }

    /// Busy-spins every core for `seconds` (a CPU spike like the owner's: HEVC decode + proxies + crash reporter).
    static func spike(seconds: Double) {
        let end = CACurrentMediaTime() + seconds
        for _ in 0..<ProcessInfo.processInfo.activeProcessorCount {
            Thread.detachNewThread { var x = 0.0; while CACurrentMediaTime() < end { x += sin(x) } ; _ = x }
        }
    }

    /// Lag (samples, ±`range`) that best aligns buffer `c` with `ref` (normalized cross-correlation) and its correlation.
    static func align(_ c: Captured, ref: [Float], clipStart: Double, range: Int) -> (lag: Int, corr: Double) {
        let i0 = Int(((c.time - clipStart) * c.rate).rounded())
        let n = c.samples.count
        var ex = 0.0
        for v in c.samples { ex += Double(v) * Double(v) }
        var best = (lag: 0, corr: -2.0)
        for lag in -range...range {
            let s = i0 + lag
            guard s >= 0, s + n <= ref.count else { continue }
            var xy = 0.0, yy = 0.0
            for i in 0..<n { let y = Double(ref[s + i]); xy += Double(c.samples[i]) * y; yy += y * y }
            let corr = ex > 0 && yy > 0 ? xy / (ex * yy).squareRoot() : 0
            if corr > best.corr { best = (lag, corr) }
        }
        return best
    }

    struct Report {
        var buffers = 0, compared = 0, bad = 0, silent = 0
        var worst: [(time: Double, error: Double, lag: Int, wall: Double)] = []
        var overlaps: [(time: Double, overlap: Double)] = []
    }

    /// Residual of each captured buffer against `ref` (composition time `t` = ref sample `t × rate`): energy of the
    /// difference / energy of the reference. A buffer whose residual exceeds `bad` also gets its best lag (±20 ms).
    static func analyse(_ caps: [Captured], ref: [Float], clipStart: Double, bad: Double = 0.05) -> Report {
        var r = Report()
        var lastEnd: Double?
        for c in caps {
            r.buffers += 1
            guard c.time.isFinite, c.samples.count >= 64 else { lastEnd = nil; continue }
            if let e = lastEnd, c.time < e - 0.5 / c.rate, e - c.time < 0.05 { r.overlaps.append((c.time, e - c.time)) }
            lastEnd = c.time + Double(c.samples.count) / c.rate
            let i0 = Int(((c.time - clipStart) * c.rate).rounded())
            guard i0 >= 0, i0 + c.samples.count <= ref.count else { continue }
            func err(_ lag: Int) -> Double {
                var d = 0.0, e = 0.0
                for i in 0..<c.samples.count {
                    let j = i0 + i + lag
                    let rv = j >= 0 && j < ref.count ? Double(ref[j]) : 0
                    let x = Double(c.samples[i]) - rv
                    d += x * x; e += rv * rv
                }
                return e > 1e-6 ? d / e : -1
            }
            // AVPlayer hands the taps silent buffers around seeks and pauses (preroll at the target): not content
            guard c.samples.contains(where: { $0 != 0 }) else { r.silent += 1; continue }
            // ±2 samples: an item rebuilt / sought mid-play lands a sample or two off (sub-sample seek rounding)
            let e0 = (-2...2).map(err).filter { $0 >= 0 }.min() ?? -1
            guard e0 >= 0 else { continue }
            r.compared += 1
            if e0 > bad {
                r.bad += 1
                var best = (lag: 0, e: e0)
                if r.worst.count < 10 {
                    for lag in stride(from: -Int(c.rate / 50), through: Int(c.rate / 50), by: 1) where lag != 0 {
                        let e = err(lag); if e >= 0, e < best.e { best = (lag, e) }
                    }
                }
                r.worst.append((c.time, e0, best.lag, c.wall))
            }
        }
        return r
    }

    /// Position (seconds) in `ref[0 ..< window]` of the `n` samples at `k` of `x` (best normalized correlation).
    static func locate(_ x: ArraySlice<Float>, in ref: [Float], window: Int) -> (at: Double, corr: Double) {
        var best = (at: -1, corr: -2.0)
        let xs = Array(x)
        var ex = 0.0
        for v in xs { ex += Double(v) * Double(v) }
        for s in 0..<max(0, min(window, ref.count - xs.count)) {
            var xy = 0.0, yy = 0.0
            for i in 0..<xs.count { let y = Double(ref[s + i]); xy += Double(xs[i]) * y; yy += y * y }
            let c = ex > 0 && yy > 0 ? xy / (ex * yy).squareRoot() : 0
            if c > best.corr { best = (s, c) }
        }
        return (Double(best.at) / 48000, best.corr)
    }

    /// A clip after a gap, played through: the lane output (tap, after the clip gains) — what goes to the mixer —
    /// must start with the clip's FIRST source sample. Post-effects taps were labelled one tap buffer early (4096
    /// frames = 85 ms on macOS 26), so the clip gains (silence before the clip) muted the first 85 ms of every clip in
    /// preview, and fades / volume keyframes / live effects were applied 85 ms late. Measured on the audio content,
    /// not on the tap's labels.
    @Test func laneOutputStartsWithTheClipsFirstSample() async throws {
        let url = try Self.noiseFile()
        let ref = try await AudioFileIO.read(url, sampleRate: 48000, channels: 1).channel(0)
        var p = TestProject(frameRate: .fps30)
        _ = try await p.addMedia(url, at: Time(1.0), duration: Time(2.0))
        let project = p.project
        try await HeavyWorkGate.run {
            let engine = PlaybackEngine(project: project)
            engine.usesProxies = false
            try await PlaybackProbe.waitReady(engine)
            let cap = Capture()
            Self.record(engine, into: cap)
            defer { engine.audioState.tapCapture = nil }
            engine.seek(to: Time(0.4))
            engine.play()
            let t0 = CACurrentMediaTime()
            // until well past the clip start (item time, bounded in wall time for a loaded machine)
            while engine.currentTime.seconds < 1.6, CACurrentMediaTime() - t0 < 30 {
                _ = engine.pixelBuffer(forHostTime: CACurrentMediaTime())
                try await Task.sleep(nanoseconds: 4_000_000)
            }
            engine.pause()
            // the lane's output stream from the play start: the first non-silent sample is where the clip became audible
            let stream = cap.snapshot.flatMap(\.samples)
            let k = try #require(stream.firstIndex { abs($0) > 1e-5 }, "no audio reached the mixer")
            #expect(k + 1024 <= stream.count)
            let found = Self.locate(stream[k ..< min(stream.count, k + 1024)], in: ref, window: 24000)
            #expect(found.corr > 0.99, "lane output does not match the source (corr \(found.corr))")
            #expect(found.at < 0.002, "the clip became audible \(String(format: "%.1f", found.at * 1000)) ms into its source: its start was muted")
        }
    }

    /// Same layout through the export path (AVAssetReaderAudioMixOutput runs the same lane taps).
    @Test func exportStartsWithTheClipsFirstSample() async throws {
        let url = try Self.noiseFile()
        let ref = try await AudioFileIO.read(url, sampleRate: 48000, channels: 1).channel(0)
        var p = TestProject(frameRate: .fps30)
        _ = try await p.addMedia(url, at: Time(1.0), duration: Time(2.0))
        let mix = try await p.mixdown(seconds: 2.0)
        let out = mix.channel(0)
        let k = try #require(out.firstIndex { abs($0) > 1e-5 }, "silent export")
        let found = Self.locate(out[k ..< min(out.count, k + 1024)], in: ref, window: 24000)
        print(String(format: "METALLIC export onset at %.4f s, source position %.4f s, corr %.4f", Double(k) / mix.sampleRate, found.at, found.corr))
        #expect(abs(Double(k) / mix.sampleRate - 1.0) < 0.002, "export: clip audible from \(Double(k) / mix.sampleRate) s, starts at 1.0 s")
        #expect(found.at < 0.002, "export: the clip became audible \(String(format: "%.1f", found.at * 1000)) ms into its source")
    }

    static func noiseFile() throws -> URL {
        let url = TestMedia.directory.appendingPathComponent("metallic-noise-6s.wav")
        if !FileManager.default.fileExists(atPath: url.path) {
            let tmp = TestMedia.directory.appendingPathComponent("metallic-noise-6s-\(UUID().uuidString).wav")
            try AudioFileIO.write(AudioTestSignals.noise(seconds: 6, amplitude: 0.2, channels: 1, seed: 7), to: tmp, format: .wav24)
            TestMedia.publishFile(tmp, as: url)
        }
        return url
    }

    /// Investigation probe (opt-in): composition time per tap frame (Δlabel / frames × sample rate) and the onset of
    /// a clip after a gap, for a clip at speed 1.5 and at player rate 2.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VALSE_METALLIC_REPRO"] != nil), arguments: [(1.5, Float(1)), (1.0, Float(2))])
    func tapTimelineProbe(speed: Double, rate: Float) async throws {
        let url = TestMedia.directory.appendingPathComponent("metallic-sine.wav")
        if !FileManager.default.fileExists(atPath: url.path) {
            try AudioFileIO.write(AudioTestSignals.sine(440, seconds: 12, amplitude: 0.3, channels: 1), to: url, format: .wav24)
        }
        var p = TestProject(frameRate: .fps30)
        let id = try await p.addMedia(url, at: Time(1.0), duration: Time(4.0))
        p[id].speed = .constant(speed)
        let project = p.project
        try await HeavyWorkGate.run {
            let engine = PlaybackEngine(project: project)
            engine.usesProxies = false
            try await PlaybackProbe.waitReady(engine)
            let cap = Capture()
            Self.record(engine, into: cap)
            defer { engine.audioState.tapCapture = nil }
            engine.seek(to: Time(0.4))
            if rate == 1 { engine.play() } else { engine.setRate(rate) }
            try await Self.play(engine, seconds: 2.5)
            engine.pause()
            let caps = cap.snapshot.filter { $0.time.isFinite }
            var ratios: [Double] = []
            for (a, b) in zip(caps, caps.dropFirst()) where b.time > a.time {
                ratios.append((b.time - a.time) / (Double(a.samples.count) / a.rate))
            }
            ratios.sort()
            let steps = caps.map { $0.step * $0.rate }.sorted()
            print(String(format: "METALLIC probe step used by the gains × sample rate: median %.4f (min %.4f max %.4f)",
                         steps.isEmpty ? .nan : steps[steps.count / 2], steps.first ?? .nan, steps.last ?? .nan))
            let onset = caps.first { $0.samples.contains { abs($0) > 1e-4 } }.map { c in c.time + Double(c.samples.firstIndex { abs($0) > 1e-4 }!) / c.rate * (ratios.isEmpty ? 1 : ratios[ratios.count / 2]) }
            print(String(format: "METALLIC probe speed %.1f rate %.0f pre %@: frames %@ Δlabel/frame-time median %.4f, onset (label-derived) %.4f",
                         speed, rate, ProcessInfo.processInfo.environment["VALSE_TAP_PRE"] != nil ? "yes" : "no",
                         "\(Set(caps.map(\.samples.count)).sorted())", ratios.isEmpty ? .nan : ratios[ratios.count / 2], onset ?? .nan))
        }
    }

    /// Owner's session (bugreports/2026-10-24-metallic-audio): a long mono 48 kHz AAC voice clip, played from a seek,
    /// item replaced while playing (proxy ready → `forceRebuild`), seek while playing, CPU spikes, pause → play.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VALSE_METALLIC_REPRO"] != nil))
    func laneOutputMatchesSourceThroughOwnerSession() async throws {
        let owner = TestMedia.repoRoot().appendingPathComponent("bugreports/2026-10-24-metallic-audio/media/IMG_4057-audio.m4a")
        var url = FileManager.default.fileExists(atPath: owner.path) ? owner : RealLikeMedia.speech
        if ProcessInfo.processInfo.environment["VALSE_METALLIC_MEDIA"] == "wav" {
            // codec-free control: white noise in a 24-bit WAV (no AAC priming / edit list)
            url = TestMedia.directory.appendingPathComponent("metallic-noise.wav")
            try AudioFileIO.write(AudioTestSignals.noise(seconds: 30, amplitude: 0.2, channels: 1), to: url, format: .wav24)
        }
        var p = TestProject(frameRate: .fps30)
        _ = try await p.addMedia(url)
        let project = p.project
        let ref = try await AudioFileIO.read(url, sampleRate: 48000, channels: 1)
        let refSamples = ref.channel(0)
        let len = Double(ref.frames) / 48000
        try await HeavyWorkGate.run {
            let engine = PlaybackEngine(project: project)
            engine.usesProxies = false
            try await PlaybackProbe.waitReady(engine)
            let cap = Capture()
            Self.record(engine, into: cap)
            defer { engine.audioState.tapCapture = nil }
            let t0 = CACurrentMediaTime()
            var events: [String] = []
            @MainActor func mark(_ s: String) { events.append(String(format: "%7.3f %@ (item %.3f)", CACurrentMediaTime() - t0, s, engine.currentTime.seconds)) }
            engine.seek(to: Time(min(10, len / 4)))
            engine.play(); mark("play")
            try await Self.play(engine, seconds: 3)
            engine.forceRebuild(); mark("forceRebuild while playing")
            try await Self.play(engine, seconds: 3)
            engine.seek(to: Time(min(5, len / 8))); mark("seek while playing")
            try await Self.play(engine, seconds: 3)
            for _ in 0..<3 {
                Self.spike(seconds: 1.5); mark("CPU spike")
                try await Self.play(engine, seconds: 3)
            }
            engine.pause(); mark("pause")
            try await Task.sleep(nanoseconds: 300_000_000)
            engine.play(); mark("play")
            try await Self.play(engine, seconds: 3)
            engine.pause(); mark("pause")
            let caps = cap.snapshot
            let pending = engine.audioState.takeLaneJumps()
            print("METALLIC lane jumps logged \(engine.laneAudioJumps), pending \(pending.count) (largest \(pending.worst) s at \(pending.at))")
            print("METALLIC events:\n" + events.joined(separator: "\n"))
            for c in caps.filter({ $0.time.isFinite }).prefix(60).enumerated().filter({ $0.offset % 6 == 0 }).map(\.element) {
                let rms = (c.samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(c.samples.count)).squareRoot()
                let a = Self.align(c, ref: refSamples, clipStart: 0, range: 4800)
                print(String(format: "METALLIC align t=%.4f rms=%.4f lag=%d corr=%.4f", c.time, rms, a.lag, a.corr))
            }
            let r = Self.analyse(caps, ref: refSamples, clipStart: 0)
            print("METALLIC buffers \(r.buffers), compared \(r.compared), silent \(r.silent), bad \(r.bad), overlaps \(r.overlaps.count), rates \(Set(caps.map(\.rate))), frames \(Set(caps.map(\.samples.count)).sorted().prefix(8))")
            for w in r.worst.prefix(40) { print(String(format: "METALLIC bad t=%.4f err=%.3f bestLag=%d wall=%.3f", w.time, w.error, w.lag, w.wall - t0)) }
            for o in r.overlaps.prefix(20) { print(String(format: "METALLIC overlap t=%.4f by %.4f s", o.time, o.overlap)) }
            #expect(r.compared > 100)
            #expect(r.bad == 0)
        }
    }
}
