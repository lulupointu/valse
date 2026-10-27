@preconcurrency import AVFoundation
import Testing
import Foundation
import ValseCore
@testable import ValseEngine
import ValseTestSupport

/// TL-048 Quick cut detector (port of the bench's S5 hybrid) and per-media analysis / cache.
@Suite struct QuickCutAnalyzerTests {
    static let sr = 16000

    struct RNG {
        var s: UInt64
        mutating func next() -> UInt64 {
            s &+= 0x9E3779B97F4A7C15; var z = s
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func uni() -> Float { Float(next() >> 40) / Float(1 << 24) }
        mutating func gauss() -> Float { let u = max(uni(), 1e-7), v = uni(); return sqrtf(-2 * logf(u)) * cosf(2 * .pi * v) }
    }

    /// Speech-like voiced signal: harmonics of a gliding f0 (≈ 120 Hz), syllable envelope at ≈ 4.5 Hz.
    static func voiced(_ seconds: Double, amp: Float, f0: Float = 120, rng: inout RNG) -> [Float] {
        let n = Int(seconds * Double(sr))
        var out = [Float](repeating: 0, count: n)
        var phase: Float = 0
        for i in 0..<n {
            let t = Float(i) / Float(sr)
            let f = f0 * (1 + 0.12 * sinf(2 * .pi * 1.3 * t))
            phase += 2 * .pi * f / Float(sr)
            if phase > 2 * .pi * 1000 { phase -= 2 * .pi * 1000 }
            var v: Float = 0
            for h in 1...12 { v += sinf(Float(h) * phase) / Float(h) }
            let env = 0.35 + 0.65 * abs(sinf(.pi * t / 0.22))
            out[i] = amp * env * v * 0.5 + amp * 0.02 * rng.gauss()
        }
        return out
    }

    static func noise(_ seconds: Double, rms: Float, rng: inout RNG) -> [Float] {
        (0..<Int(seconds * Double(sr))).map { _ in rms * rng.gauss() }
    }

    /// Band-passed noise burst (≈ a breath), Hann envelope.
    static func breath(_ seconds: Double, rms: Float, rng: inout RNG) -> [Float] {
        let n = Int(seconds * Double(sr))
        var b = (0..<n).map { _ in rng.gauss() }
        var hp = Biquad2.highPass(500, sampleRate: Double(sr)), lp = Biquad2.lowPass(2500, sampleRate: Double(sr))
        b.withUnsafeMutableBufferPointer { p in hp.run(p.baseAddress!, p.baseAddress!, n); lp.run(p.baseAddress!, p.baseAddress!, n) }
        let r = sqrtf(b.reduce(0) { $0 + $1 * $1 } / Float(n))
        return (0..<n).map { k in b[k] / r * rms * (0.5 - 0.5 * cosf(2 * .pi * Float(k) / Float(n))) }
    }

    /// Noise through `sections` (biquads), scaled to `rms`, Hann envelope when `hann`.
    static func filteredNoise(_ seconds: Double, rms: Float, _ sections: [Biquad2], hann: Bool, rng: inout RNG) -> [Float] {
        let n = Int(seconds * Double(sr))
        var b = (0..<n).map { _ in rng.gauss() }
        for var s in sections { b.withUnsafeMutableBufferPointer { p in s.run(p.baseAddress!, p.baseAddress!, n) } }
        let r = sqrtf(b.reduce(0) { $0 + $1 * $1 } / Float(n))
        return (0..<n).map { k in b[k] / r * rms * (hann ? 0.5 - 0.5 * cosf(2 * .pi * Float(k) / Float(n)) : 1) }
    }

    /// An /s/: noise above 4 kHz.
    static func sibilant(_ seconds: Double, rms: Float, rng: inout RNG) -> [Float] {
        let d = Double(sr)
        return filteredNoise(seconds, rms: rms, [.highPass(4000, sampleRate: d), .highPass(4000, sampleRate: d)], hann: false, rng: &rng)
    }

    /// An exhale after a phrase as measured on the owner's iPhone rushes: broadband hiss (1 … 6 kHz, as much energy
    /// above 4 kHz as below), Hann envelope.
    static func exhale(_ seconds: Double, rms: Float, rng: inout RNG) -> [Float] {
        let d = Double(sr)
        return filteredNoise(seconds, rms: rms, [.highPass(1000, sampleRate: d), .lowPass(6000, sampleRate: d)], hann: true, rng: &rng)
    }

    static func rms(_ x: ArraySlice<Float>) -> Float { sqrtf(x.reduce(0) { $0 + $1 * $1 } / Float(max(1, x.count))) }

    /// Adds `x` at `seconds` into `into`.
    static func mix(_ x: [Float], at seconds: Double, into s: inout [Float]) {
        let o = Int(seconds * Double(sr))
        for (k, v) in x.enumerated() where o + k < s.count { s[o + k] += v }
    }

    /// Fraction of frames of [a, b) (s) that are speech.
    static func speechFraction(_ m: QuickCutMask, _ a: Double, _ b: Double) -> Double {
        let i = Int(a * 100), j = Int(b * 100)
        guard j > i else { return 0 }
        return Double((i..<j).filter { m[$0] }.count) / Double(j - i)
    }

    // MARK: Synthetic signals

    /// Voiced speech, pauses over a noise floor, a breath and a click in pauses, a quieter (−30 dB) speaker.
    @Test func voicedSpeechPausesBreathClickAndQuietSpeaker() {
        var rng = RNG(s: 7)
        var s = Self.noise(11, rms: 0.0005, rng: &rng)
        let speech: [(Double, Double, Float)] = [(1, 2.5, 0.2), (3.5, 5, 0.2), (6.2, 7.5, 0.2), (8.7, 10, 0.2 / 31.6)]
        for (a, b, amp) in speech { Self.mix(Self.voiced(b - a, amp: amp, rng: &rng), at: a, into: &s) }
        Self.mix(Self.breath(0.35, rms: 0.2 * 0.35 * 0.08, rng: &rng), at: 5.425, into: &s)   // ≈ −22 dB under speech
        var click = [Float](repeating: 0, count: 80)
        for k in 0..<80 { click[k] = 0.2 * 2.5 * rng.gauss() * expf(-Float(k) / 12) }
        Self.mix(click, at: 8.1, into: &s)
        let m = QuickCutDetector.mask(samples: s)
        #expect(m.frameCount == 1100)
        #expect(m.hasDynamics)
        for (a, b, _) in speech {
            let f = Self.speechFraction(m, a + 0.03, b - 0.03)
            #expect(f > 0.9, "speech \(a)…\(b): \(f)")
        }
        // pause interiors are blank: lead-in, pauses (with the breath and the click), tail
        for (a, b) in [(0.0, 0.8), (2.75, 3.3), (5.25, 6.0), (7.75, 8.5), (10.25, 11.0)] {
            let f = Self.speechFraction(m, a, b)
            #expect(f == 0, "pause \(a)…\(b): \(f)")
        }
    }

    /// Background noise swinging ±10 dB (traffic): the local floor follows it, pauses are found, speech kept.
    /// Traffic-like rumble (brown noise at 15 dB SNR) swinging ±7.5 dB, as in the bench corpus: the local floor
    /// follows it, so the pauses are found where a global threshold would miss them, and the speech is kept.
    @Test func varyingNoiseFloor() {
        var rng = RNG(s: 11)
        let total = 30.0
        var s = [Float](repeating: 0, count: Int(total) * Self.sr)
        var t = 0.8
        var spans: [(Double, Double)] = []
        while t + 1.6 < total - 0.5 {
            Self.mix(Self.voiced(1.6, amp: 0.15, rng: &rng), at: t, into: &s)
            spans.append((t, t + 1.6)); t += 1.6 + 1.2
        }
        let speechRMS = sqrtf(s.reduce(0) { $0 + $1 * $1 } / Float(s.count) * Float(total) / Float(1.6 * Double(spans.count)))
        var rumble = [Float](repeating: 0, count: s.count)
        var acc: Float = 0
        for i in rumble.indices { acc = 0.995 * acc + 0.1 * rng.gauss(); rumble[i] = acc }
        let rr = sqrtf(rumble.reduce(0) { $0 + $1 * $1 } / Float(rumble.count))
        for i in s.indices {
            let lfo = powf(10, 7.5 * sinf(2 * .pi * 0.07 * Float(i) / Float(Self.sr)) / 20)
            s[i] += rumble[i] / rr * speechRMS / 5.6 * lfo
        }
        let m = QuickCutDetector.mask(samples: s)
        #expect(m.hasDynamics)
        for (a, b) in spans { #expect(Self.speechFraction(m, a + 0.03, b - 0.03) > 0.9, "speech \(a)") }
        var blank = 0.0
        var fractions: [Int] = []
        for (k, sp) in spans.enumerated().dropLast() {
            let f = Self.speechFraction(m, sp.1 + 0.25, spans[k + 1].0 - 0.25)
            blank += 1 - f; fractions.append(Int(f * 100))
        }
        blank /= Double(spans.count - 1)
        print("quickcut rumble: pause interiors blank \(Int(blank * 100)) %, speech % per pause \(fractions)")
        #expect(blank > 0.8)
    }

    @Test func steadyToneAndSilenceHaveNoDynamics() {
        let tone = (0..<(5 * Self.sr)).map { i in 0.3 * sinf(2 * .pi * 220 * Float(i) / Float(Self.sr)) }
        #expect(!QuickCutDetector.mask(samples: tone).hasDynamics)
        let silent = QuickCutDetector.mask(samples: [Float](repeating: 0, count: 3 * Self.sr))
        #expect(!silent.hasDynamics && !silent.hasSpeech && silent.frameCount == 300)
        #expect(QuickCutDetector.mask(samples: []) == .empty)
        #expect(QuickCutDetector.mask(samples: [Float](repeating: 0.1, count: 100)).frameCount == 0)
    }

    /// Unvoiced noise as loud as speech for ≥ 80 ms is kept (conservative), a short unvoiced burst near speech is
    /// attached to it (consonant), one far from speech is not.
    @Test func loudUnvoicedRunsAndAttach() {
        var rng = RNG(s: 3)
        var s = Self.noise(6, rms: 0.0005, rng: &rng)
        Self.mix(Self.voiced(1, amp: 0.2, rng: &rng), at: 1, into: &s)
        Self.mix(Self.sibilant(0.06, rms: 0.05, rng: &rng), at: 2.08, into: &s)   // "s" right after the word
        Self.mix(Self.noise(0.03, rms: 0.05, rng: &rng), at: 3.0, into: &s)    // isolated hiss (< 80 ms)
        Self.mix(Self.noise(0.3, rms: 0.08, rng: &rng), at: 4.5, into: &s)     // loud unvoiced noise, 300 ms
        let m = QuickCutDetector.mask(samples: s)
        #expect(Self.speechFraction(m, 2.09, 2.13) == 1)
        #expect(Self.speechFraction(m, 2.95, 3.1) == 0)
        #expect(Self.speechFraction(m, 4.55, 4.75) > 0.9)
    }

    /// TL-048-fix3, the owner's "1018 (1)" iPhone rushes (heard: the voice stops at 25:25, the slice started at 26:03):
    /// a word ends with a reverberant decay (−150 dB/s down to the room floor) and, 50 ms after the decay crossed
    /// 25 dB under the voice, an exhale (120 ms of broadband hiss 20 dB under the voice). The end of speech is where
    /// the decay crosses the edge level, the same level that places the next onset; the exhale is not speech. Before
    /// the fix the run went on to the end of the hiss (≈ 0.2 s more kept after speech than before it).
    @Test func reverberantTailAndExhaleEndLikeTheOnset() {
        var rng = RNG(s: 21)
        var s = Self.noise(6, rms: 0.00012, rng: &rng)
        var word = Self.voiced(1.2, amp: 0.2, rng: &rng)
        let voiceRMS = Self.rms(word[0..<Int(0.8 * Double(Self.sr))])
        // exponential decay over the last 300 ms: −150 dB/s, like the measured word endings
        let dn = Int(0.3 * Double(Self.sr))
        for k in 0..<dn { word[word.count - dn + k] *= powf(10, -150 * Float(k) / Float(Self.sr) / 20) }
        Self.mix(word, at: 1, into: &s)
        Self.mix(Self.voiced(1.2, amp: 0.2, rng: &rng), at: 3.5, into: &s)   // abrupt onset at 3.5 s
        var d0 = QuickCutDetector()
        d0.feed(s)
        let f0 = d0.finishFeatures()
        let lvl = QuickCutDetector.percentile(f0.full, 0.97) - QuickCutDetector.edgeDrop
        let crossing = (100..<300).last { f0.full[$0] >= lvl }! + 1   // first frame of the decay under the edge level
        // peak ≈ 19 dB under the voice's p97 (the voice's mean is ≈ 5 dB under its p97)
        Self.mix(Self.exhale(0.12, rms: voiceRMS * 0.2, rng: &rng), at: Double(crossing) / 100 + 0.05, into: &s)
        var d = QuickCutDetector()
        d.feed(s)
        let f = d.finishFeatures()
        let mask = QuickCutDetector.mask(f)
        let runs = mask.speechRuns
        #expect(runs.count == 2, "\(runs)")
        guard runs.count == 2 else { return }
        let onset = (300..<f.full.count).first { f.full[$0] >= lvl }!
        #expect(abs(runs[0].upperBound - crossing) <= 1, "end of speech \(runs[0].upperBound) vs decay crossing \(crossing)")
        #expect(abs(runs[1].lowerBound - onset) <= 1, "onset \(runs[1].lowerBound) vs crossing \(onset)")
        #expect(abs(runs[1].lowerBound - 350) <= 2)
        // the exhale is audible (well above the floor) but is not speech
        let hiss = (crossing + 5)..<(crossing + 17)
        #expect(((crossing + 8)..<(crossing + 14)).allSatisfy { f.full[$0] > lvl },
                "the exhale's middle is above the edge level: \(((crossing + 8)..<(crossing + 14)).map { f.full[$0] - lvl })")
        #expect(Self.speechFraction(mask, Double(hiss.lowerBound) / 100, Double(hiss.upperBound) / 100) == 0)
        // at fix2's level (35 dB under the peak) the decay's end and the exhale read as speech: ≥ 150 ms more kept
        let old = QuickCutDetector.mask(f, edgeDrop: 35).speechRuns
        #expect(old.count == 2 && old[0].upperBound - runs[0].upperBound >= 15, "\(old)")
    }

    /// The same edge rule never drops a consonant: a burst + aspiration before the vowel (dip between them), a final /s/
    /// after a closure (dip, then noise above 4 kHz), an /s/ the detection band misses; a breath after the last word
    /// (500 … 2500 Hz noise, 20 dB under the voice) is dropped.
    @Test func consonantsAroundTheVoiceStayBreathsGo() {
        var rng = RNG(s: 4)
        var s = Self.noise(9, rms: 0.0002, rng: &rng)
        let w1 = Self.voiced(0.8, amp: 0.2, rng: &rng)
        let v = Self.rms(w1[...])
        // 1: stop burst (20 ms, −14 dB) at 0.98, 50 ms quiet aspiration, vowel at 1.05 … 1.85, closure 60 ms, final /s/
        Self.mix(Self.noise(0.02, rms: v * 0.2, rng: &rng), at: 0.98, into: &s)
        Self.mix(Self.noise(0.05, rms: v * 0.01, rng: &rng), at: 1.0, into: &s)
        Self.mix(w1, at: 1.05, into: &s)
        Self.mix(Self.sibilant(0.12, rms: v * 0.08, rng: &rng), at: 1.91, into: &s)
        // 2: a word followed (60 ms later) by a breath
        Self.mix(Self.voiced(0.8, amp: 0.2, rng: &rng), at: 4, into: &s)
        Self.mix(Self.breath(0.3, rms: v * 0.1 * 1.6, rng: &rng), at: 4.86, into: &s)
        // 3: a word ending in a quiet, long /s/ (−26 dB) right after the voice
        Self.mix(Self.voiced(0.8, amp: 0.2, rng: &rng), at: 6.5, into: &s)
        Self.mix(Self.sibilant(0.15, rms: v * 0.05, rng: &rng), at: 7.3, into: &s)
        let m = QuickCutDetector.mask(samples: s)
        #expect(Self.speechFraction(m, 0.98, 1.0) == 1, "burst before the vowel")
        #expect(Self.speechFraction(m, 1.93, 2.02) == 1, "final /s/ after a closure")
        #expect(Self.speechFraction(m, 4.92, 5.1) == 0, "breath after the word")
        #expect(Self.speechFraction(m, 7.31, 7.43) == 1, "quiet final /s/")
    }

    /// Feeding in arbitrary chunks gives exactly the whole-signal result.
    @Test func streamingMatchesWholeSignal() {
        var rng = RNG(s: 5)
        var s = Self.noise(8, rms: 0.001, rng: &rng)
        Self.mix(Self.voiced(2, amp: 0.2, rng: &rng), at: 1, into: &s)
        Self.mix(Self.voiced(2, amp: 0.1, rng: &rng), at: 4.5, into: &s)
        let whole = QuickCutDetector.mask(samples: s)
        var d = QuickCutDetector()
        var i = 0
        while i < s.count {
            let n = min(s.count - i, 1 + Int(rng.next() % 9000))
            s.withUnsafeBufferPointer { d.feed(UnsafeBufferPointer(rebasing: $0[i..<i + n])) }
            i += n
        }
        #expect(d.finish() == whole)
    }

    // MARK: Real media

    @Test func realEnglishSpeech() async throws {
        let m = try await QuickCutAnalyzer.compute(url: RealLikeMedia.speech)
        let f = Self.speechFraction(m, 0, m.duration)
        print("quickcut speech_en: \(m.duration) s, speech \(Int(f * 100)) %, runs \(m.speechRuns.count)")
        #expect(m.hasDynamics)
        #expect(f > 0.4 && f < 0.97)
    }

    @Test func realFrenchSpeechKeepsEveryWord() async throws {
        guard let url = Self.benchMedia("speech_fr.wav"), let words = Self.frenchWords() else {
            print("skip: bench/media/speech_fr.wav missing"); return
        }
        let m = try await QuickCutAnalyzer.compute(url: url)
        #expect(m.hasDynamics)
        // every word onset has speech within 150 ms
        let hit = words.filter { w in (Int(w * 100)..<Int(w * 100) + 15).contains { m[$0] } }.count
        print("quickcut speech_fr: \(hit) / \(words.count) word onsets in speech, \(m.speechRuns.count) runs")
        #expect(Double(hit) >= Double(words.count) * 0.97)
    }

    static func benchMedia(_ name: String) -> URL? {
        var u = TestMedia.repoRoot()
        while u.path != "/" {
            let c = u.appendingPathComponent("bench/media").appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: c.path) { return c }
            u.deleteLastPathComponent()
        }
        return nil
    }

    static func frenchWords() -> [Double]? {
        var u = TestMedia.repoRoot()
        while u.path != "/" {
            if let s = try? String(contentsOf: u.appendingPathComponent("bench/speech_fr_words.tsv"), encoding: .utf8) {
                return s.split(separator: "\n").compactMap { l in l.split(separator: "\t").last.flatMap { Double($0) } }
            }
            u.deleteLastPathComponent()
        }
        return nil
    }

    // MARK: Analyzer (cache, dedupe, cancel, speed)

    /// Writes `samples` (16 kHz mono) to a file; AAC (`.m4a`) at `rate` or WAV. Blocking work on GCD (pool deadlock).
    static func write(_ samples: [Float], repeating times: Int = 1, to url: URL, aacRate: Double? = nil) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async {
                c.resume(with: Result {
                    let fmt = AVAudioFormat(standardFormatWithSampleRate: Double(sr), channels: 1)!
                    let settings: [String: Any] = aacRate.map { [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: $0,
                                                                  AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000] } ?? fmt.settings
                    let f = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                    if let rate = aacRate, rate != Double(sr) {
                        // the file's processing format is its own rate: resample through a converter
                        let out = f.processingFormat
                        let conv = AVAudioConverter(from: fmt, to: out)!
                        let block = sr * 10
                        for _ in 0..<times {
                        var i = 0
                        while i < samples.count {
                            let n = min(block, samples.count - i)
                            let inBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
                            inBuf.frameLength = AVAudioFrameCount(n)
                            samples.withUnsafeBufferPointer { p in inBuf.floatChannelData![0].update(from: p.baseAddress! + i, count: n) }
                            let cap = AVAudioFrameCount(Double(n) * rate / Double(sr)) + 64
                            let outBuf = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: cap)!
                            var given = false
                            var err: NSError?
                            _ = conv.convert(to: outBuf, error: &err) { _, status in
                                if given { status.pointee = .noDataNow; return nil }
                                given = true; status.pointee = .haveData; return inBuf
                            }
                            if let err { throw err }
                            try f.write(from: outBuf)
                            i += n
                        }
                        }
                    } else {
                        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count))!
                        buf.frameLength = AVAudioFrameCount(samples.count)
                        samples.withUnsafeBufferPointer { p in buf.floatChannelData![0].update(from: p.baseAddress!, count: samples.count) }
                        try f.write(from: buf)
                    }
                })
            }
        }
    }

    static func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("quickcut-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func asset(_ url: URL, seconds: Double, hash: String = UUID().uuidString) -> MediaAsset {
        MediaAsset(name: url.lastPathComponent, kind: .audio, url: url, duration: Time(seconds), pixelSize: .zero, frameRate: nil,
                   hasVideo: false, hasAudio: true, contentHash: hash)
    }

    @Test func diskCacheAndSharedAnalysis() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var rng = RNG(s: 9)
        var s = Self.noise(5, rms: 0.0005, rng: &rng)
        Self.mix(Self.voiced(1.5, amp: 0.2, rng: &rng), at: 0.5, into: &s)
        Self.mix(Self.voiced(1.5, amp: 0.2, rng: &rng), at: 3, into: &s)
        let url = dir.appendingPathComponent("a.wav")
        try await Self.write(s, to: url)
        let a = Self.asset(url, seconds: 5)
        let an = QuickCutAnalyzer(directory: dir.appendingPathComponent("cache"))
        #expect(an.cached(a) == nil)
        // two concurrent requests share one decode
        async let m1 = an.analyze(a)
        async let m2 = an.analyze(a)
        let (r1, r2) = try await (m1, m2)
        #expect(r1 == r2 && r1.hasSpeech)
        #expect(an.decodes == 1)
        #expect(r1 == QuickCutDetector.mask(samples: s))   // the file decode gives the in-memory result
        let file = dir.appendingPathComponent("cache/\(a.contentHash).\(QuickCutAnalyzer.cacheVersion)")
        #expect(FileManager.default.fileExists(atPath: file.path))
        // a fresh analyzer (next launch) reads it from disk without decoding
        let next = QuickCutAnalyzer(directory: dir.appendingPathComponent("cache"))
        #expect(next.cached(a) == r1)
        _ = try await next.analyze(a)
        #expect(next.decodes == 0)
        // prefetch: no work for analysed media, the rest gets analysed
        let url2 = dir.appendingPathComponent("b.wav")
        try await Self.write(Array(s.reversed()), to: url2)
        let b = Self.asset(url2, seconds: 5)
        await next.prefetch([a, b, b]).value
        #expect(next.decodes == 1 && next.cached(b) != nil)
        // media without audio: empty mask, nothing decoded
        var silent = Self.asset(url, seconds: 5); silent.hasAudio = false
        #expect(next.cached(silent) == .empty)
    }

    /// 30 min of audio (AAC 48 kHz): analysed in ≤ 3 s (release, asserted in perf runs: scripts/perf.sh), cancellable
    /// mid-way. Outside perf runs (debug gate) the file is 5 min to keep the suite light.
    @Test func thirtyMinutesIsFastAndCancellable() async throws {
        let minutes = TimingBudget.enforced ? 30 : 5
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var rng = RNG(s: 1)
        // 20 s pattern of speech + pauses, tiled to 30 min
        var pattern = Self.noise(20, rms: 0.001, rng: &rng)
        var t = 0.5
        while t < 18 { Self.mix(Self.voiced(1.8, amp: 0.2, rng: &rng), at: t, into: &pattern); t += 2.6 }
        let url = dir.appendingPathComponent("long.m4a")
        let w0 = Date()
        try await Self.write(pattern, repeating: minutes * 3, to: url, aacRate: 48000)
        print("quickcut perf: wrote \(minutes) min AAC in \(String(format: "%.1f", Date().timeIntervalSince(w0))) s")

        let t0 = Date()
        let m = try await QuickCutAnalyzer.compute(url: url)
        let secs = Date().timeIntervalSince(t0)
        if minutes == 30 { TimingBudget.metric("unit_quickcut_analyze_30min_s", secs, "s") }
        print("quickcut perf: analysed \(minutes) min in \(String(format: "%.2f", secs)) s")
        #expect(abs(m.duration - Double(minutes * 60)) < 0.5)
        #expect(m.hasDynamics && m.speechRuns.count > minutes * 15)
        if minutes == 30, let limit = TimingBudget.limit(3, "quickcut 30 min") { #expect(secs < limit) }

        // cancel while decoding: stops with CancellationError, no mask cached
        let an = QuickCutAnalyzer(directory: dir.appendingPathComponent("cache"))
        let a = Self.asset(url, seconds: Double(minutes * 60))
        let started = Started()
        let task = Task { try await an.analyze(a) { f in if f > 0.05 { started.set() } } }
        await started.wait()
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(an.cached(a) == nil)
    }

    /// One-shot async signal for the cancellation test (no sleeps).
    final class Started: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func set() {
            let w: [CheckedContinuation<Void, Never>] = lock.withLock { if done { return [] }; done = true; let w = waiters; waiters = []; return w }
            for c in w { c.resume() }
        }
        func wait() async {
            await withCheckedContinuation { c in
                let now = lock.withLock { () -> Bool in if done { return true }; waiters.append(c); return false }
                if now { c.resume() }
            }
        }
    }
}
