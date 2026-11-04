@preconcurrency import AVFoundation
import Testing
import Foundation
import QuartzCore
import ValseCore
@testable import ValseEngine
import ValseTestSupport

/// BUG-AUDIO-RESAMPLE-ALL (follow-up of BUG-SPLIT-AUDIO-FLAKE): AVFoundation's AVAssetReader outputs that resample
/// (an `AVSampleRateKey` ≠ the file's rate) zero ~15 samples at random AAC packet boundaries. Every reader now decodes
/// at the native rate and converts with `StreamResampler` (`AudioFileIO.stream` / `decode`), or reads a conformed
/// 48 kHz copy (`AudioConform`). Per path: repeated reads are identical, and the output length and timing are exact.
@Suite(.serialized) struct AudioResampleDeterminismTests {
    // MARK: fixtures

    /// `seconds` of stereo lossless WAV at `rate`: a raised-cosine pulse (peak 0.5, ± 0.68 ms) centred on `at` s.
    static func pulse(rate: Double, at: Double = 1.0, seconds: Double = 2) throws -> URL {
        let url = TestMedia.directory.appendingPathComponent("resample-pulse-\(Int(rate))-\(at)-\(seconds).wav")
        if TestMedia.isUsable(url) { return url }
        var s = [Float](repeating: 0, count: Int(rate * seconds))
        let c = Int((at * rate).rounded()), w = Int((0.00068 * rate).rounded())
        for k in -w...w { s[c + k] = Float(0.25 * (1 + cos(Double.pi * Double(k) / Double(w)))) }
        let tmp = TestMedia.directory.appendingPathComponent("resample-pulse-\(UUID().uuidString).wav")
        try AudioFileIO.write(AudioBuffer([s, s], sampleRate: rate), to: tmp, format: .wav24)
        TestMedia.publishFile(tmp, as: url)
        return url
    }

    /// 3 s of 44.1 kHz stereo AAC (noise + tone: real AAC packets, the material the reader resampling broke).
    static func aac44() throws -> URL {
        let url = TestMedia.directory.appendingPathComponent("resample-aac44-3s.m4a")
        if TestMedia.isUsable(url) { return url }
        let noise = AudioTestSignals.noise(seconds: 3, amplitude: 0.1, sampleRate: 44100, channels: 2, seed: 11)
        for c in 0..<2 { for i in 0..<noise.frames { noise[c, i] += Float(0.2 * sin(2 * Double.pi * 330 * Double(i) / 44100)) } }
        let tmp = TestMedia.directory.appendingPathComponent("resample-aac44-\(UUID().uuidString).m4a")
        let w = try AudioFileIO.Writer(url: tmp, format: .aac, sampleRate: 44100, channels: 2, bitrate: 192_000)
        try w.write(noise.block)
        w.close()
        TestMedia.publishFile(tmp, as: url)
        return url
    }

    /// Sub-sample position of the largest value (parabolic interpolation).
    static func peak(_ x: [Float]) throws -> Double {
        let i = try #require(x.indices.max { x[$0] < x[$1] })
        guard i > 0, i < x.count - 1 else { return Double(i) }
        let a = Double(x[i - 1]), b = Double(x[i]), c = Double(x[i + 1])
        let d = a - 2 * b + c
        return d == 0 ? Double(i) : Double(i) + 0.5 * (a - c) / d
    }

    // MARK: AudioFileIO.stream (the shared path: analysis, QuickCut, waveforms, AI readers)

    /// Every output rate the app reads at, from 44.1 and 48 kHz files: exact length (frames × out / in), the pulse at
    /// 1 s lands on frame `out` (± 0.1), and 8 reads of the 44.1 kHz iPhone footage are identical.
    @Test(arguments: [8000.0, 16000, 44100, 48000])
    func streamKeepsLengthTimingAndIsDeterministic(rate: Double) async throws {
        for src in [44100.0, 48000] {
            let x = try await AudioFileIO.read(try Self.pulse(rate: src), sampleRate: rate, channels: 1).channel(0)
            #expect(x.count == Int(2 * rate), "\(src) → \(rate): \(x.count) frames")
            let at = try Self.peak(x)
            #expect(abs(at - rate) < 0.1, "\(src) → \(rate): pulse at frame \(at), expected \(rate)")
        }
        let first = try await AudioFileIO.read(RealLikeMedia.iPhoneHLGPortrait, sampleRate: rate, channels: 2)
        #expect(first.channel(0).contains { abs($0) > 1e-3 })
        for k in 1..<8 {
            let again = try await AudioFileIO.read(RealLikeMedia.iPhoneHLGPortrait, sampleRate: rate, channels: 2)
            #expect(again.channel(0) == first.channel(0) && again.channel(1) == first.channel(1), "read \(k) at \(rate) differs")
        }
    }

    /// A range read starts at the range: the pulse at 1 s of a read from 0.5 s is at 0.5 s of the output.
    @Test func rangeReadKeepsTheRangeTimeline() async throws {
        let x = try await AudioFileIO.read(try Self.pulse(rate: 44100), sampleRate: 16000, channels: 1,
                                           range: TimeRange(start: Time(0.5), duration: Time(1.5))).channel(0)
        #expect(x.count == 24000)
        let at = try Self.peak(x)
        #expect(abs(at - 8000) < 0.1, "pulse at \(at)")
    }

    // MARK: WaveformCache (timeline waveforms; also the ducking envelopes of export)

    @Test func waveformIsDeterministicWithExactLengthAndTiming() async throws {
        let w = try await WaveformCache.compute(try Self.pulse(rate: 44100))
        #expect(w.peaks.count == 200 && w.rms.count == 200)
        #expect(w.peaks.indices.max { w.peaks[$0] < w.peaks[$1] } == 100, "peak window \(String(describing: w.peaks.indices.max { w.peaks[$0] < w.peaks[$1] }))")
        #expect(w.peaks[100] > 50, "peak \(w.peaks[100])")   // (the 1.4 ms pulse is band-limited at 8 kHz: ~0.3, not 0.5)
        #expect(w.peaks.enumerated().allSatisfy { abs($0.offset - 100) <= 2 || $0.element == 0 }, "levels away from the pulse")
        let first = try await WaveformCache.compute(RealLikeMedia.iPhoneHLGPortrait)
        #expect(abs(first.peaks.count - 400) <= 1, "\(first.peaks.count) windows for 4 s")
        for k in 1..<8 {
            let again = try await WaveformCache.compute(RealLikeMedia.iPhoneHLGPortrait)
            #expect(again.peaks == first.peaks && again.rms == first.rms, "waveform read \(k) differs")
        }
    }

    // MARK: QuickCutAnalyzer (16 kHz mono)

    @Test func quickCutAnalysisIsDeterministic() async throws {
        let first = try await QuickCutAnalyzer.compute(url: RealLikeMedia.iPhoneHLGPortrait)
        for k in 1..<4 {
            let again = try await QuickCutAnalyzer.compute(url: RealLikeMedia.iPhoneHLGPortrait)
            #expect(again == first, "quick-cut analysis \(k) differs")
        }
    }

    // MARK: ScrubAudio (44.1 kHz grains)

    /// A grain of a 48 kHz file is exactly `grain` long at 44.1 kHz, the pulse 50 ms into it, the same every time.
    @Test func scrubGrainIsResampledDeterministically() async throws {
        let pulse = try Self.pulse(rate: 48000)
        let grain = try await OffPool.run { _ in
            ScrubAudio.read(ScrubAudio.Source(url: pulse, sourceTime: Time(0.95), gain: 1, stream: 0))
        }
        let g = try #require(grain)
        let want = Int(ScrubAudio.grain * ScrubAudio.sampleRate)
        #expect(g.count == want * 2)
        let left = stride(from: 0, to: g.count, by: 2).map { g[$0] }
        let at = try Self.peak(left)
        #expect(abs(at - 0.05 * 44100) < 0.1, "pulse at frame \(at) of the grain")
        let speech = RealLikeMedia.speech   // 48 kHz AAC
        let reads = try await OffPool.run { _ in
            (0..<8).map { _ in ScrubAudio.read(ScrubAudio.Source(url: speech, sourceTime: Time(0.4), gain: 1, stream: 0)) }
        }
        let a = try #require(reads[0])
        #expect(a.count == want * 2 && a.contains { abs($0) > 1e-3 })
        for (k, r) in reads.enumerated() { #expect(r == a, "grain \(k) differs") }
    }

    // MARK: ReverseManager (AudioReverser reads the 48 kHz conformed copy)

    static func reversedAudio(_ source: URL) async throws -> [Float] {
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent("rev-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: dst) }
        try await ReverseManager.generate(source: source, to: dst)
        return try await AudioFileIO.read(dst, channels: 1).channel(0)
    }

    /// 44.1 kHz source: the reversed audio is the 48 kHz copy backwards (frame for frame, 16-bit), exact length, the pulse
    /// at 1 s of a 2 s file on frame 47999 (media time s ↔ D − s), and two renders of AAC footage are identical.
    @Test func reversedAudioOf44kSourceIsExactAndDeterministic() async throws {
        let src = try Self.pulse(rate: 44100)
        let rev = try await Self.reversedAudio(src)
        #expect(rev.count == 96000)
        let at = try Self.peak(rev)
        #expect(abs(at - 47999) < 0.1, "pulse at frame \(at)")
        let fwd = try await AudioFileIO.read(src, channels: 1).channel(0)
        var maxd: Float = 0
        for i in 0..<min(rev.count, fwd.count) { maxd = max(maxd, abs(rev[i] - fwd[fwd.count - 1 - i])) }
        #expect(maxd < 1e-4, "reversed audio differs from the forward read backwards by \(maxd)")
        let aac = try Self.aac44()
        let a = try await Self.reversedAudio(aac)
        let b = try await Self.reversedAudio(aac)
        #expect(a.count == b.count && a.contains { abs($0) > 1e-3 })
        #expect(a == b, "two reversed renders of 44.1 kHz AAC differ")
    }

    // MARK: the dropout, and the preview probe

    /// Starts (s) of the reader-resampling dropout: ≥ 10 samples under 5e-4 that keep flipping sign (the converter's
    /// restart leaves ~15 near-zero samples of ±1e-4 residue: measured on the iPhone footage, see
    /// `legacyReaderDifferenceShape`) between louder audio (RMS > 2e-3 over 48 samples on both sides). A natural zero
    /// crossing is smooth (one sign change), so speech and music do not trigger it.
    static func holes(_ x: [Float], rate: Double) -> [Double] {
        var out: [Double] = []
        var i = 48
        while i < x.count - 48 {
            guard abs(x[i]) < 5e-4 else { i += 1; continue }
            var j = i, flips = 0
            while j < x.count - 48, abs(x[j]) < 5e-4 {
                if j > i, (x[j] > 0) != (x[j - 1] > 0), x[j] != 0, x[j - 1] != 0 { flips += 1 }
                j += 1
            }
            if j - i >= 10, flips >= 4 {
                func rms(_ r: Range<Int>) -> Float { var e: Float = 0; for k in r { e += x[k] * x[k] }; return (e / Float(r.count)).squareRoot() }
                if rms(max(0, i - 48) ..< i) > 2e-3, rms(j ..< min(x.count, j + 48)) > 2e-3 { out.append(Double(i) / rate) }
            }
            i = j
        }
        return out
    }

    /// The pre-fix read: an AVAssetReaderTrackOutput resampling to `rate` (left channel). Control for the probe only.
    static func legacyRead48k(_ url: URL, rate: Double = 48000) async throws -> [Float] {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        return try await OffPool.run { _ in
            let reader = try AVAssetReader(asset: asset)
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
            reader.add(out)
            guard reader.startReading() else { throw reader.error ?? NSError(domain: "test", code: 1) }
            var x: [Float] = []
            while let sb = out.copyNextSampleBuffer() {
                guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
                let n = CMBlockBufferGetDataLength(bb) / 4
                var tmp = [Float](repeating: 0, count: n)
                _ = tmp.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: n * 4, destination: $0.baseAddress!) }
                for i in stride(from: 0, to: n, by: 2) { x.append(tmp[i]) }
            }
            return x
        }
    }

    /// Investigation (opt-in, `VALSE_RESAMPLE_DIAG=1`): what a differing pre-fix 48 kHz read of the iPhone footage looks
    /// like against the most common read (4 reads at a time for load).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VALSE_RESAMPLE_DIAG"] != nil))
    func legacyReaderDifferenceShape() async throws {
        let url = RealLikeMedia.iPhoneHLGPortrait
        var all: [[Float]] = []
        for _ in 0..<40 {
            let batch = await withTaskGroup(of: [Float]?.self) { g -> [[Float]] in
                for _ in 0..<4 { g.addTask { try? await Self.legacyRead48k(url) } }
                var out: [[Float]] = []
                for await x in g { if let x { out.append(x) } }
                return out
            }
            all += batch
        }
        var counts: [[Float]: Int] = [:]
        for x in all { counts[x, default: 0] += 1 }
        let mode = counts.max { $0.value < $1.value }!.key
        print("RESAMPLE-DIAG \(all.count) reads, \(counts.count) distinct, mode ×\(counts[mode]!)")
        for (x, n) in counts where x != mode {
            guard x.count == mode.count else { print("RESAMPLE-DIAG length \(x.count) vs \(mode.count) ×\(n)"); continue }
            let idx = x.indices.filter { abs(x[$0] - mode[$0]) > 1e-4 }
            guard let a = idx.first, let b = idx.last else { continue }
            let seg = (max(0, a - 4)...min(x.count - 1, a + 24)).map { String(format: "%.4f/%.4f", x[$0], mode[$0]) }
            print("RESAMPLE-DIAG ×\(n): \(idx.count) samples differ in [\(a), \(b)] = [\(Double(a) / 48000), \(Double(b) / 48000)] s; x/mode from \(a - 4): \(seg.joined(separator: " "))")
        }
    }

    /// Investigation (opt-in, `VALSE_RESAMPLE_DIAG=1`): before / after per output rate the app reads at — distinct
    /// results of 80 reads (4 at a time) with the pre-fix reader resampling, and with `AudioFileIO.stream`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VALSE_RESAMPLE_DIAG"] != nil))
    func readersBeforeAndAfter() async throws {
        let cases: [(String, URL, Double)] = [
            ("iPhone 44.1k AAC", RealLikeMedia.iPhoneHLGPortrait, 8000), ("iPhone 44.1k AAC", RealLikeMedia.iPhoneHLGPortrait, 16000),
            ("iPhone 44.1k AAC", RealLikeMedia.iPhoneHLGPortrait, 48000), ("speech 48k AAC", RealLikeMedia.speech, 44100),
            ("speech 48k AAC", RealLikeMedia.speech, 16000), ("speech 48k AAC", RealLikeMedia.speech, 8000)]
        for (name, url, rate) in cases {
            for fixed in [false, true] {
                var distinct = Set<[Float]>(), reads = 0
                for _ in 0..<20 {
                    let batch = await withTaskGroup(of: [Float]?.self) { g -> [[Float]] in
                        for _ in 0..<4 {
                            g.addTask {
                                fixed ? try? await AudioFileIO.read(url, sampleRate: rate, channels: 2).channel(0)
                                      : try? await Self.legacyRead48k(url, rate: rate)
                            }
                        }
                        var out: [[Float]] = []
                        for await x in g { if let x { out.append(x) } }
                        return out
                    }
                    reads += batch.count
                    for x in batch { distinct.insert(x) }
                }
                print("RESAMPLE-DIAG \(name) → \(Int(rate)) Hz, \(fixed ? "after (AudioFileIO.stream)" : "before (reader AVSampleRateKey)"): \(distinct.count) distinct outputs in \(reads) reads")
            }
        }
    }

    /// The detector: no hole in 8 fixed reads of the footage (48 and 16 kHz) nor in its native-rate decode; the measured
    /// dropout shape planted by hand is found.
    @Test func holeDetectorFindsTheDropoutOnly() async throws {
        let url = RealLikeMedia.iPhoneHLGPortrait
        for rate in [48000.0, 16000] {
            for _ in 0..<4 {
                let x = try await AudioFileIO.read(url, sampleRate: rate, channels: 2).channel(0)
                #expect(Self.holes(x, rate: rate).isEmpty, "hole at \(Self.holes(x, rate: rate)) in a fixed read at \(rate)")
            }
        }
        var x = try await AudioFileIO.read(url, sampleRate: 44100, channels: 2).channel(0)
        #expect(Self.holes(x, rate: 44100).isEmpty)
        // the loudest 1 ms of the first second, zeroed like the measured dropout (±1e-4 residue)
        let at = try #require(stride(from: 2000, to: 44100, by: 64).max { abs(x[$0]) < abs(x[$1]) })
        for k in 0..<15 { x[at + k] = k % 2 == 0 ? 1e-4 : -1e-4 }
        let h = Self.holes(x, rate: 44100)
        #expect(h.count == 1 && abs((h.first ?? 0) - Double(at) / 44100) < 1e-3, "planted hole at \(Double(at) / 44100) s, found \(h)")
    }
}

/// Preview (AVPlayer's real-time path) of 44.1 kHz AAC footage: does it show the reader's dropout? Every lane-tap buffer
/// (what the mixer sums) of repeated plays is searched for the dropout (`holes`). With `VALSE_PREVIEW_PLAYS=<n>`
/// (default 2) it plays `n` times while, as a control, the pre-fix 48 kHz reader runs 4 at a time in the background
/// (load on the preview; the bug must show in the control for a clean preview to mean anything).
/// Measured 2026-11-05 (40 plays, in the report of BUG-AUDIO-RESAMPLE-ALL): the tap runs at the file's rate (AVPlayer
/// decodes at 44.1 kHz; the conversion to the device rate happens after the mix, in the output's continuous real-time
/// converter, which is not fed AAC packets) and no play had a hole, while the control had them: preview keeps reading
/// the original file.
@MainActor @Suite(.serialized) struct PreviewResampleProbeTests {
    static func play(_ engine: PlaybackEngine, until end: Double) async throws -> [MetallicAudioTests.Captured] {
        let cap = MetallicAudioTests.Capture()
        MetallicAudioTests.record(engine, into: cap)
        defer { engine.audioState.tapCapture = nil }
        engine.seek(to: .zero)
        engine.play()
        let t0 = CACurrentMediaTime()
        while engine.currentTime.seconds < end, CACurrentMediaTime() - t0 < 30 {
            _ = engine.pixelBuffer(forHostTime: CACurrentMediaTime())
            try await Task.sleep(nanoseconds: 4_000_000)
        }
        engine.pause()
        return cap.snapshot.filter { $0.time.isFinite }
    }

    final class Control: @unchecked Sendable {
        private let lock = NSLock()
        private var stop = false
        private(set) var reads = 0, holed = 0
        private(set) var at = Set<Double>()
        var stopped: Bool { lock.withLock { stop } }
        func halt() { lock.withLock { stop = true } }
        func add(_ h: [Double]) {
            lock.withLock { reads += 1; if !h.isEmpty { holed += 1; for t in h { at.insert((t * 1000).rounded() / 1000) } } }
        }
    }

    @Test func previewOf44kFootageHasNoDropout() async throws {
        let plays = Int(ProcessInfo.processInfo.environment["VALSE_PREVIEW_PLAYS"] ?? "") ?? 2
        let url = RealLikeMedia.iPhoneHLGPortrait
        var p = TestProject(frameRate: .fps30)
        _ = try await p.addMedia(url)
        let project = p.project
        let control = Control()
        var load: Task<Void, Never>?
        if plays > 3 {
            load = Task.detached {
                while !control.stopped {
                    await withTaskGroup(of: [Double]?.self) { g in
                        for _ in 0..<4 {
                            g.addTask {
                                guard let x = try? await AudioResampleDeterminismTests.legacyRead48k(url) else { return nil }
                                return AudioResampleDeterminismTests.holes(x, rate: 48000)
                            }
                        }
                        for await h in g { if let h { control.add(h) } }
                    }
                }
            }
        }
        let end = 3.5
        let results: [[MetallicAudioTests.Captured]] = try await HeavyWorkGate.run {
            let engine = PlaybackEngine(project: project)
            engine.usesProxies = false
            try await PlaybackProbe.waitReady(engine)
            var out: [[MetallicAudioTests.Captured]] = []
            for _ in 0..<plays { out.append(try await Self.play(engine, until: end)) }
            return out
        }
        control.halt()
        await load?.value
        var rates = Set<Double>()
        var buffers = 0, complete = 0
        var seconds = 0.0
        var found: [String] = []
        for (k, play) in results.enumerated() {
            var span = 0.0
            for c in play where c.time >= 0 && c.time < end && c.samples.count >= 256 {
                rates.insert(c.rate)
                buffers += 1
                span += Double(c.samples.count) / c.rate
                for t in AudioResampleDeterminismTests.holes(c.samples, rate: c.rate) {
                    found.append("play \(k) at \(String(format: "%.4f", c.time + t)) s")
                }
            }
            seconds += span
            if span > end - 0.5 { complete += 1 }
        }
        let ctl = plays > 3 ? "pre-fix 48 kHz reader under the same load: \(control.holed)/\(control.reads) reads with the dropout (at \(control.at.sorted()) s)" : "control not run"
        print("PREVIEW-RESAMPLE-PROBE tap rates \(rates.sorted()); \(complete)/\(plays) complete plays, \(buffers) tap buffers (\(String(format: "%.1f", seconds)) s of audio): \(found.count) dropouts \(found.prefix(8)); \(ctl)")
        try #require(complete > 0, "no play reached \(end - 0.5) s (loaded machine?)")
        #expect(rates == [44100], "the preview tap no longer runs at the file's rate \(rates.sorted()): re-check preview for resampling dropouts")
        #expect(found.isEmpty, "preview dropouts: \(found)")
    }
}
