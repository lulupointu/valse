import Testing
import Foundation
@preconcurrency import AVFoundation
import CoreGraphics
import ImageIO
@testable import ValseAI
import ValseCore
import ValseEngine
import ValseTestSupport

/// Auto-caption timing (owner bug: captions early / late, cut at wrong places). Ground truth: bench/speech_fr_words.tsv
/// (word onsets of bench/media/speech_fr.wav from the synthesizer's own word callbacks, bench/speech_words.swift).
@Suite(.serialized) struct CaptionTimingTests {
    // MARK: Helpers

    /// Onset errors (recognised − reference, seconds) of the words matched by an LCS on normalised text.
    static func onsetErrors(_ got: [(text: String, start: Double)], _ ref: [(text: String, start: Double)]) -> [Double] {
        let a = ref.map { CaptionText.normalize($0.text) }, b = got.map { CaptionText.normalize($0.text) }
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return [] }
        var L = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                L[i][j] = a[i] == b[j] ? L[i + 1][j + 1] + 1 : max(L[i + 1][j], L[i][j + 1])
            }
        }
        var i = 0, j = 0, out: [Double] = []
        while i < n, j < m {
            if a[i] == b[j] { out.append(got[j].start - ref[i].start); i += 1; j += 1 }
            else if L[i + 1][j] >= L[i][j + 1] { i += 1 } else { j += 1 }
        }
        return out
    }

    static func mae(_ e: [Double]) -> Double { e.isEmpty ? .infinity : e.map(abs).reduce(0, +) / Double(e.count) }

    static func tmp(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("valse-ct-\(UUID().uuidString).\(ext)")
    }

    /// AAC (48 kHz stereo) in a QuickTime movie written by AVAssetWriter, which records the encoder priming
    /// (2112 samples) in an edit list — like iPhone footage.
    static func makeAACMovie(from wav: URL) async throws -> URL {
        let out = tmp("mov")
        let asset = AVURLAsset(url: wav)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let pcm: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                                  AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                                  AVLinearPCMIsNonInterleaved: false]
        let ro = AVAssetReaderTrackOutput(track: track, outputSettings: pcm)
        reader.add(ro)
        let writer = try AVAssetWriter(outputURL: out, fileType: .mov)
        var layout = AudioChannelLayout(); layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        let wi = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)])
        wi.expectsMediaDataInRealTime = false
        writer.add(wi)
        #expect(reader.startReading())
        writer.startWriting(); writer.startSession(atSourceTime: .zero)
        while let sb = await OffPool.next(ro) {   // blocking read: off the cooperative pool
            while !wi.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            wi.append(sb)
        }
        wi.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return out
    }

    static func samples(_ url: URL) throws -> [Float] {
        let f = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = try #require(AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)))
        try f.read(into: buf)
        return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
    }

    /// Lag (samples) that best aligns `b[0..<window]` with `a[offset + lag...]`.
    static func bestLag(_ a: [Float], offset: Int, _ b: [Float], window: Int, maxLag: Int) -> Int {
        var best = 0, bestV = -Float.infinity
        for lag in -maxLag...maxLag {
            var v: Float = 0
            let o = offset + lag
            guard o >= 0, o + window <= a.count, window <= b.count else { continue }
            for i in stride(from: 0, to: window, by: 1) { v += a[o + i] * b[i] }
            if v > bestV { bestV = v; best = lag }
        }
        return best
    }

    // MARK: Real footage (manual)

    /// `VALSE_CAPTION_PROJECT=/path/copy.valse`: regenerates auto captions in that (copied!) project, saves it, prints
    /// the captions and writes `<project>/captions_waveform.png` (waveform + caption spans + word onsets) to eyeball
    /// timing. Skipped otherwise.
    @Test func regenerateCaptionsOnFootage() async throws {
        guard let path = ProcessInfo.processInfo.environment["VALSE_CAPTION_PROJECT"], WhisperRuntime.isAvailable else { return }
        let url = URL(fileURLWithPath: path)
        var p = try ProjectPackage.load(from: url)
        var o = CaptionOptions(language: ProcessInfo.processInfo.environment["VALSE_CAPTION_LANG"], engine: .whisper)
        o.replaceExisting = true
        let r = try await CaptionGenerator.run(project: p, options: o)
        try r.command.apply(to: &p)
        try ProjectPackage.save(p, to: url)
        let caps = SpeechCaptions.captions(in: p.timeline)
        for c in caps {
            let t = CaptionOps.text(c)?.string.replacingOccurrences(of: "\n", with: " / ") ?? ""
            print(String(format: "caption %6.2f–%6.2f  %@", c.start.seconds, c.end.seconds, t))
        }
        // waveform of the main clip's audio (timeline time) with caption spans
        guard let main = p.timeline.mainTrack?.clips.first, let asset = main.mediaID.flatMap(p.asset) else { return }
        let wav = try await AudioExtractor.wav16k(asset.url, range: main.sourceRange)
        defer { try? FileManager.default.removeItem(at: wav) }
        let s = try Self.samples(wav)
        let W = 4000, H = 400, secs = main.duration.seconds
        let ctx = try #require(CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.08, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        func x(_ t: Double) -> CGFloat { CGFloat(t / secs) * CGFloat(W) }
        for (i, c) in caps.enumerated() {
            ctx.setFillColor(i % 2 == 0 ? CGColor(red: 0.2, green: 0.45, blue: 0.9, alpha: 0.35) : CGColor(red: 0.9, green: 0.5, blue: 0.2, alpha: 0.35))
            ctx.fill(CGRect(x: x(c.start.seconds), y: 0, width: x(c.end.seconds) - x(c.start.seconds), height: CGFloat(H)))
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 0.3, alpha: 1))
            for w in CaptionOps.words(of: c) {
                ctx.fill(CGRect(x: x((c.start - c.sourceStart + w.start).seconds), y: CGFloat(H) - 40, width: 2, height: 40))
            }
        }
        ctx.setFillColor(CGColor(gray: 0.9, alpha: 1))
        let per = max(1, s.count / W)
        for px in 0..<W {
            let a = px * per, b = min(s.count, a + per)
            guard a < b else { break }
            let peak = s[a..<b].map(abs).max() ?? 0
            let h = CGFloat(peak) * CGFloat(H) * 0.45
            ctx.fill(CGRect(x: CGFloat(px), y: CGFloat(H) / 2 - h, width: 1, height: max(1, h * 2)))
        }
        let out = url.appendingPathComponent("captions_waveform.png")
        let dest = try #require(CGImageDestinationCreateWithURL(out as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try #require(ctx.makeImage()), nil)
        CGImageDestinationFinalize(dest)
        print("waveform: \(out.path)")
    }

    // MARK: Tests

    /// The speech WAV starts exactly at the requested media time, through AAC priming / edit lists.
    @Test func speechExtractionIsSampleAccurate() async throws {
        guard let wav = AIFixtures.speechFR else { print("skip: bench/media/speech_fr.wav missing"); return }
        let mov = try await Self.makeAACMovie(from: wav)
        defer { try? FileManager.default.removeItem(at: mov) }
        let out = try await AudioExtractor.wav16k(mov, range: TimeRange(start: Time(10), end: Time(18)))
        defer { try? FileManager.default.removeItem(at: out) }
        let a = try Self.samples(wav), b = try Self.samples(out)
        let lag = Self.bestLag(a, offset: 160_000, b, window: 24_000, maxLag: 1600)
        print("metric caption_extract_lag_ms=\(Double(lag) / 16)")
        #expect(abs(lag) <= 8, "extracted audio is offset by \(Double(lag) / 16) ms")
        #expect(abs(b.count - 128_000) <= 16)
    }

    /// Word onsets vs ground truth. Before (interpolated whisper timestamps): ≈ 230 ms; after (DTW + speech-onset
    /// snapping): < 100 ms (≈ 40 ms).
    @Test func whisperWordOnsetsMatchGroundTruth() async throws {
        try await HeavyWorkGate.run {
            guard WhisperRuntime.isAvailable, let cli = WhisperRuntime.cliURL, let model = ModelCatalog.installedWhisperModel,
                  let wav = AIFixtures.speechFR, let ref = AIFixtures.speechFRWords else {
                print("skip: whisper model/runtime or bench media missing"); return
            }
            var legacyOpts = WhisperEngine.Options(language: "fr", model: model, cli: cli)
            legacyOpts.dtw = false
            let legacy = try await WhisperEngine.transcribe(wav: wav, options: legacyOpts)
            let now = try await Transcriber.transcribe(wav: wav, request: .init(language: "fr", engine: .whisper))
            let eLegacy = Self.onsetErrors(legacy.words.map { ($0.text, $0.start) }, ref)
            let eNow = Self.onsetErrors(now.words.map { ($0.text, $0.start) }, ref)
            print("metric caption_onset_mae_ms_before=\(Int(Self.mae(eLegacy) * 1000)) after=\(Int(Self.mae(eNow) * 1000)) matched=\(eNow.count)/\(ref.count)")
            #expect(eNow.count >= ref.count * 9 / 10)
            #expect(Self.mae(eNow) < 0.1)
            #expect(Self.mae(eNow) < Self.mae(eLegacy))
            #expect(eNow.filter { abs($0) > 0.25 }.count <= 3)
        }
    }

    /// End to end: AAC movie with priming, clip trimmed (in-point 5 s), sped up ×1.25 and placed at 2 s on a 9:16
    /// project. Caption words map back onto the speech, captions don't overlap, fit 2 lines, and last ≤ ~3.5 s.
    @Test func autoCaptionsFollowTrimSpeedAndPriming() async throws {
        try await HeavyWorkGate.run {
            guard WhisperRuntime.isAvailable, let wav = AIFixtures.speechFR, let ref = AIFixtures.speechFRWords else {
                print("skip: whisper model/runtime or bench media missing"); return
            }
            let mov = try await Self.makeAACMovie(from: wav)
            defer { try? FileManager.default.removeItem(at: mov) }
            var p = Project(name: "t", settings: ProjectSettings(canvasSize: Size2(1080, 1920)))
            let asset = MediaAsset(name: "speech", kind: .video, url: mov, duration: Time(45.3), pixelSize: Size2(1080, 1920),
                                   frameRate: .fps30, hasVideo: false, hasAudio: true, contentHash: "ct-\(UUID().uuidString)")
            p.media.append(asset)
            let clip = TimelineOps.makeClip(for: asset, at: .zero)
            try TimelineOps.insert(clip, into: &p, target: .automatic)
            try TimelineOps.trim(clip.id, edge: .head, to: Time(5), in: &p)
            try TimelineOps.setSpeed(clip.id, .constant(1.25), in: &p.timeline)
            let placed = try #require(p.timeline.clip(clip.id))
            #expect(abs(placed.sourceStart.seconds - 5) < 0.01)
            let r = try await CaptionGenerator.run(project: p, options: CaptionOptions(language: "fr", engine: .whisper))
            try r.command.apply(to: &p)
            let media = try #require(p.timeline.clip(clip.id))
            let caps = SpeechCaptions.captions(in: p.timeline)
            #expect(caps.count >= 10)
            var got: [(text: String, start: Double)] = []
            let maxChars = CaptionLayout.maxCharsPerLine(canvas: p.settings.canvasSize)
            for (i, c) in caps.enumerated() {
                let t = try #require(CaptionOps.text(c))
                let lines = t.string.components(separatedBy: "\n")
                #expect(lines.count <= 2, "\(t.string)")
                for l in lines { #expect(l.count <= maxChars + 6, "line too long: \(l)") }
                #expect(c.duration.seconds <= 3.2 / 1.25 + 0.6, "caption too long: \(t.string) \(c.duration.seconds)")
                if i > 0 { #expect(c.start >= caps[i - 1].end - Time(0.001)) }
                for w in CaptionOps.words(of: c) {
                    let tl = c.start - c.sourceStart + w.start
                    got.append((w.text, media.sourceTime(at: tl).seconds))
                }
            }
            let refInRange = ref.filter { $0.start >= 5.3 }
            let e = Self.onsetErrors(got, refInRange)
            print("metric caption_e2e_onset_mae_ms=\(Int(Self.mae(e) * 1000)) matched=\(e.count)/\(refInRange.count) captions=\(caps.count)")
            #expect(e.count >= refInRange.count * 8 / 10)
            #expect(Self.mae(e) < 0.1)
        }
    }
}
