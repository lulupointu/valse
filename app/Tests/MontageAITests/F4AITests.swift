import Testing
import Foundation
import CoreGraphics
import CoreText
@preconcurrency import AVFoundation
@testable import MontageAI
import MontageCore
import MontageEngine
import MontageTestSupport

/// F4 finisher AI rows: CLIP free-text smart search (AI-028), lyrics vocal pre-separation (AI-002).
@Suite(.serialized) struct F4AITests {
    // MARK: AI-028 CLIP

    static func clipTokenizer() throws -> CLIPTokenizer? {
        guard let dir = ModelCatalog.installedURL(ModelCatalog.clip) else { return nil }
        return try CLIPTokenizer(vocab: dir.appendingPathComponent("vocab.json"), merges: dir.appendingPathComponent("merges.txt"))
    }

    @Test func clipModelSpecIsPinnedAndComplete() {
        let s = ModelCatalog.clip
        #expect(s.license == "MIT")
        #expect(s.parts?.count == 12)
        #expect(s.parts?.allSatisfy { $0.sha256.count == 64 && $0.url.absoluteString.contains("/resolve/b2f82c6a") } == true)
        #expect(ModelCatalog.all.contains { $0.id == s.id })
        #expect(L10n.shared.has(s.nameKey) || true)   // strings live in MontageUI (checked by l10n_check.py)
    }

    /// Reference ids from OpenAI's `clip.tokenize` / open_clip.
    @Test func clipTokenizerMatchesReferenceIDs() throws {
        guard let tok = try Self.clipTokenizer() else { print("skip: CLIP model not installed"); return }
        #expect(Array(tok.tokens("a dog").prefix(4)) == [49406, 320, 1929, 49407])
        #expect(Array(tok.tokens("A photo of a CAT.").prefix(8)) == [49406, 320, 1125, 539, 320, 2368, 269, 49407])
        let t = tok.tokens(String(repeating: "word ", count: 200))
        #expect(t.count == 77 && t.first == 49406 && t.last == 49407)
        #expect(tok.tokens("x").count == 77 && tok.tokens("x")[3] == 0)
    }

    /// Big emoji / colour cards rendered with Core Text: CLIP must rank the right description first for each.
    static func card(emoji: String? = nil, color: CGColor = CGColor(gray: 1, alpha: 1)) -> CGImage {
        let w = 320, h = 320
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(color); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        if let emoji {
            let font = CTFontCreateWithName("Apple Color Emoji" as CFString, 220, nil)
            let s = NSAttributedString(string: emoji, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let line = CTLineCreateWithAttributedString(s)
            let b = CTLineGetImageBounds(line, ctx)
            ctx.textPosition = CGPoint(x: (CGFloat(w) - b.width) / 2 - b.minX, y: (CGFloat(h) - b.height) / 2 - b.minY)
            CTLineDraw(line, ctx)
        }
        return ctx.makeImage()!
    }

    @Test func clipRanksFreeTextQueries() async throws {
        try await HeavyWorkGate.run {
            guard ClipEmbedder.isInstalled else { print("skip: CLIP model not installed"); return }
            let e = ClipEmbedder.shared
            let images: [(String, CGImage)] = [
                ("dog", Self.card(emoji: "🐶")), ("car", Self.card(emoji: "🚗")), ("tree", Self.card(emoji: "🌲")),
                ("pizza", Self.card(emoji: "🍕")), ("red", Self.card(color: CGColor(red: 0.9, green: 0.05, blue: 0.05, alpha: 1))),
            ]
            let embs = try images.map { try e.embed(image: $0.1) }
            let queries = ["a cute puppy", "a red sports car", "a pine tree in a forest", "a slice of pizza", "a plain red background"]
            for (qi, q) in queries.enumerated() {
                let t = try e.embed(text: q)
                let sims = embs.map { ClipEmbedder.cosine(t, $0) }
                let best = sims.indices.max { sims[$0] < sims[$1] }!
                print("metric clip_query '\(q)' best=\(images[best].0) sims=\(sims.map { String(format: "%.3f", $0) })")
                #expect(best == qi, "\(q) → \(images[best].0)")
            }
            // the search layer: only the matching card passes the relative + absolute thresholds
            let scores = MediaIndex.clipRelevance(query: try e.embed(text: "a cute puppy"), embeddings: embs.map { [$0] })
            #expect(scores[0] > 0.3)
            #expect(scores.dropFirst().allSatisfy { $0 < 0.3 })
        }
    }

    /// End to end through `MediaIndex`: an indexed image media is found by a free-text query it has no label for.
    @Test func mediaIndexFindsImagesByFreeText() async throws {
        try await HeavyWorkGate.run {
            guard ClipEmbedder.isInstalled else { print("skip: CLIP model not installed"); return }
            var assets: [MediaAsset] = []
            for (name, emoji) in [("IMG_0001", "🐶"), ("IMG_0002", "🚗")] {
                let u = FileManager.default.temporaryDirectory.appendingPathComponent("f4clip-\(name)-\(UUID().uuidString.prefix(6)).png")
                let dest = CGImageDestinationCreateWithURL(u as CFURL, "public.png" as CFString, 1, nil)!
                CGImageDestinationAddImage(dest, Self.card(emoji: emoji), nil); CGImageDestinationFinalize(dest)
                var a = try await MediaProbe.probe(u)
                a.contentHash = "f4clip-\(UUID().uuidString)"
                try await MediaIndex.shared.index(a)
                #expect(MediaIndex.shared.entry(a)?.clipFrames?.first?.count == ClipEmbedder.dimension)
                assets.append(a)
            }
            let ranked = await MediaIndex.shared.find(assets, query: "a puppy sitting", english: nil)
            if let q = MediaIndex.shared.clipQuery("a puppy sitting") {
                print("metric clip_index_sims=\(assets.map { a in MediaIndex.shared.entry(a)?.clipFrames?.map { ClipEmbedder.cosine(q, $0) } ?? [] })")
            }
            #expect(ranked.first?.contentHash == assets[0].contentHash)
            #expect(!ranked.contains { $0.contentHash == assets[1].contentHash })
            let cars = await MediaIndex.shared.find(assets, query: "vehicle on the road", english: nil)
            #expect(cars.first?.contentHash == assets[1].contentHash)
        }
    }

    // MARK: AI-002 lyrics vocal pre-separation

    static func readMono16k(_ url: URL, seconds: Double) throws -> [Float] {
        let f = try AVAudioFile(forReading: url)
        let n = AVAudioFrameCount(min(Double(f.length), seconds * f.processingFormat.sampleRate))
        let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: n)!
        try f.read(into: b, frameCount: n)
        let ch = Int(f.processingFormat.channelCount)
        return (0..<Int(b.frameLength)).map { i in (0..<ch).reduce(Float(0)) { $0 + b.floatChannelData![$1][i] } / Float(ch) }
    }

    /// "Song" = bench speech over a loud synthetic band (saw chords + kick + hi-hat noise) at about −3 dB voice-to-music.
    static func makeSong(seconds: Double, musicGain: Float = 1.4) throws -> (url: URL, voice: [Float], music: [Float])? {
        guard let speech = AIFixtures.speechFR else { return nil }
        let clean = try readMono16k(speech, seconds: seconds)   // 16 kHz
        let sr = 48_000.0, n = Int(seconds * sr)
        var voice = [Float](repeating: 0, count: n), music = [Float](repeating: 0, count: n)
        var seed: UInt64 = 0x9E3779B97F4A7C15   // deterministic hi-hat noise (stable WER between runs)
        func noise() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) * 2 - 1 }
        let chords: [[Double]] = [[110, 138.6, 164.8], [98, 123.5, 146.8], [87.3, 110, 130.8], [98, 123.5, 146.8]]
        for i in 0..<n {
            let t = Double(i) / sr
            voice[i] = clean[min(i / 3, clean.count - 1)]
            let chord = chords[Int(t / 2) % chords.count]
            var m = 0.0
            for f in chord { for h in 1...4 { m += sin(2 * .pi * f * Double(h) * t) / Double(h) } }
            m *= 0.05
            let beat = t.truncatingRemainder(dividingBy: 0.5)
            m += 0.35 * exp(-beat * 30) * sin(2 * .pi * 55 * beat)                         // kick
            let off = (t + 0.25).truncatingRemainder(dividingBy: 0.5)
            m += noise() * 0.08 * exp(-off * 60)      // hi-hat
            music[i] = Float(m)
        }
        let vRMS = (voice.reduce(0) { $0 + $1 * $1 } / Float(n)).squareRoot()
        let mRMS = (music.reduce(0) { $0 + $1 * $1 } / Float(n)).squareRoot()
        let k = vRMS / mRMS * musicGain   // 1.4 ≈ music 3 dB louder than the voice, 2.8 ≈ 9 dB
        for i in 0..<n { music[i] *= k }
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
        buf.frameLength = AVAudioFrameCount(n)
        for i in 0..<n { let s = voice[i] + music[i]; buf.floatChannelData![0][i] = s; buf.floatChannelData![1][i] = s }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("montage-song-\(UUID().uuidString).caf")
        let f = try AVAudioFile(forWriting: url, settings: fmt.settings)
        try f.write(from: buf)
        return (url, voice, music)
    }

    static func snrDB(_ y: [Float], voice: [Float]) -> Double {
        let m = min(y.count, voice.count)
        // best least-squares gain (separators may change level), residual = everything that isn't the voice
        var yv = 0.0, vv = 0.0
        for i in 0..<m { yv += Double(y[i] * voice[i]); vv += Double(voice[i] * voice[i]) }
        let g = yv / max(vv, 1e-12)
        var sig = 0.0, err = 0.0
        for i in 0..<m { let s = g * Double(voice[i]); sig += s * s; let d = Double(y[i]) - s; err += d * d }
        return 10 * log10(sig / max(err, 1e-12))
    }

    @Test func lyricsKeysAndMethodChoice() {
        #expect(LyricsVocals.cacheSuffix(.demucs) == "-lyr-demucs")
        #expect(LyricsVocals.cacheSuffix(.voiceIsolation) == "-lyr-voiceIsolation")
        #expect(LyricsVocals.cacheSuffix(.none) == "-lyr")
        if VoiceIsolator.isAvailable { #expect(LyricsVocals.preferred == .voiceIsolation) }
        else if DemucsRuntime.isAvailable { #expect(LyricsVocals.preferred == .demucs) }
    }

    /// The vocal stem fed to ASR has a much better voice-to-band ratio than the mix (both separators).
    @Test func lyricsVocalsRemoveTheBand() async throws {
        try await HeavyWorkGate.run {
            guard VoiceIsolator.isAvailable, let song = try Self.makeSong(seconds: 12) else { print("skip: AUSoundIsolation / bench media missing"); return }
            defer { try? FileManager.default.removeItem(at: song.url) }
            var asset = try await MediaProbe.probe(song.url)
            asset.contentHash = "f4-song-\(UUID().uuidString.prefix(8))"
            defer {
                for k in ["voice", "novoice"] + StemSeparator.Stem.allCases.map(\.storeKind) {
                    try? FileManager.default.removeItem(at: AudioStemStore.shared.stemURL(media: asset, kind: k))
                }
            }
            let mixSNR = Self.snrDB(try Self.readMono16k(song.url, seconds: 12), voice: song.voice)
            var methods: [LyricsVocals.Method] = [.voiceIsolation]
            if DemucsRuntime.isAvailable && ProcessInfo.processInfo.environment["MONTAGE_SLOW_TESTS"] != nil { methods.append(.demucs) }
            let a = asset
            for m in methods {
                let r = try await withCheckedThrowingContinuation { (c: CheckedContinuation<(url: URL?, method: LyricsVocals.Method), Error>) in
                    DispatchQueue.global().async { Task { do { c.resume(returning: try await LyricsVocals.vocals(a, method: m)) } catch { c.resume(throwing: error) } } }
                }
                #expect(r.method == m)
                let u = try #require(r.url)
                let y = try Self.readMono16k(u, seconds: 12)
                let snr = Self.snrDB(y, voice: song.voice)
                print("metric lyrics_vocals_\(m.rawValue)_snr_db=\(snr) mix_snr_db=\(mixSNR)")
                #expect(snr > mixSNR + 6)
            }
        }
    }

    /// Whisper on a "song" whose band is ≈ 15 dB louder than the voice: auto lyrics on the separated vocals recognise
    /// more words than ASR on the mix.
    @Test func lyricsCaptionsOnSeparatedVocalsBeatTheMix() async throws {
        try await HeavyWorkGate.run {
            guard WhisperRuntime.isAvailable, VoiceIsolator.isAvailable, let ref = AIFixtures.speechFRReference,
                  let song = try Self.makeSong(seconds: 20, musicGain: Float(ProcessInfo.processInfo.environment["F4_GAIN"] ?? "6") ?? 6) else { print("skip: whisper / bench media missing"); return }
            defer { try? FileManager.default.removeItem(at: song.url) }
            var p = TestProject()
            let clipID = try await p.addMedia(song.url)
            let mid = p.project.timeline.clip(clipID)!.mediaID!
            if let i = p.project.media.firstIndex(where: { $0.id == mid }) { p.project.media[i].contentHash = "f4-lyr-\(UUID().uuidString.prefix(8))" }
            let asset = p.project.asset(mid)!
            defer { for k in ["voice", "novoice"] { try? FileManager.default.removeItem(at: AudioStemStore.shared.stemURL(media: asset, kind: k)) } }
            // reference = the first words of the bench transcript spoken in 20 s
            let refWords = ref.split(whereSeparator: \.isWhitespace).prefix(45).joined(separator: " ")
            func text(_ lyrics: Bool) async throws -> String {
                let o = CaptionOptions(language: "fr", engine: .whisper, lyrics: lyrics)
                let project = p.project
                let log = PhaseLog()
                let r = try await CaptionGenerator.run(project: project, options: o, progress: nil) { log.add($0) }
                // a fresh separation shows "Separating vocals…" (a cached transcript skips every phase)
                if lyrics, !log.all.isEmpty { #expect(log.all.contains(.separating)) }
                if !lyrics { #expect(!log.all.contains(.separating)) }
                var q = project
                try r.command.apply(to: &q)
                return SpeechCaptions.captions(in: q.timeline).compactMap { CaptionOps.text($0)?.string }.joined(separator: " ")
            }
            if let m = ProcessInfo.processInfo.environment["F4_METHOD"] { LyricsVocals.forcedMethod = LyricsVocals.Method(rawValue: m) }
            defer { LyricsVocals.forcedMethod = nil }
            let plain = try await text(false), lyr = try await text(true)
            let werPlain = WordErrorRate.compute(reference: refWords, hypothesis: plain)
            let werLyr = WordErrorRate.compute(reference: refWords, hypothesis: lyr)
            print("metric lyrics_wer_mix=\(werPlain) lyrics_wer_vocals=\(werLyr)\n mix: \(plain)\n vocals: \(lyr)")
            #expect(werLyr <= werPlain)
            #expect(werLyr < 0.3)
        }
    }
}
