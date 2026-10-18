import Testing
import Foundation
@preconcurrency import AVFoundation
@testable import MontageAI
import MontageCore
import MontageEngine
import MontageTestSupport

/// HTDemucs (demucs.cpp sidecar) on speech + a synthetic instrument: the vocals stem keeps the voice and drops the tone.
@Suite(.serialized) struct StemSeparationTests {
    /// Power of a frequency (Goertzel) in a mono signal.
    static func tone(_ x: [Float], hz: Double, sr: Double) -> Double {
        let k = 2 * cos(2 * Double.pi * hz / sr)
        var s1 = 0.0, s2 = 0.0
        for v in x { let s = Double(v) + k * s1 - s2; s2 = s1; s1 = s }
        return (s1 * s1 + s2 * s2 - k * s1 * s2) / Double(max(x.count, 1))
    }

    @Test func vocalsStemDropsTheInstrument() async throws {
        try await HeavyWorkGate.run {
            // ~45 s: opt-in (MONTAGE_SLOW_TESTS=1), like the 4K perf tests
            guard ProcessInfo.processInfo.environment["MONTAGE_SLOW_TESTS"] == "1" else { print("skip: set MONTAGE_SLOW_TESTS=1"); return }
            guard DemucsRuntime.isAvailable, let speech = AIFixtures.speechFR else { print("skip: demucs runtime/model or bench media missing"); return }
            let clean = try VoiceIsolationTests.readMono(speech, seconds: 6)
            let sr = 44_100.0, n = Int(6 * sr)
            let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("montage-music-\(UUID().uuidString).caf")
            defer { try? FileManager.default.removeItem(at: url) }
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
            buf.frameLength = AVAudioFrameCount(n)
            for i in 0..<n {
                let s = clean[min(Int(Double(i) * 16_000 / sr), clean.count - 1)]
                // a plucked 110 Hz "bass" note every half second
                let t = Double(i) / sr, ph = t.truncatingRemainder(dividingBy: 0.5)
                let bass = Float(0.3 * sin(2 * .pi * 110 * t) * exp(-ph * 4))
                buf.floatChannelData![0][i] = s + bass; buf.floatChannelData![1][i] = s + bass
            }
            do { let f = try AVAudioFile(forWriting: url, settings: fmt.settings); try f.write(from: buf) }
            var asset = try await MediaProbe.probe(url)
            asset.contentHash = "test-demucs-\(UUID().uuidString.prefix(6))"
            let clock = ContinuousClock(), t0 = clock.now
            try await StemSeparator.separate(asset)
            print("metric demucs_rtf=\((clock.now - t0) / .seconds(6))")
            let vocals = try VoiceIsolationTests.readMono(AudioStemStore.shared.readyStem(media: asset, kind: StemSeparator.Stem.vocals.storeKind)!, seconds: 6)
            let bassStem = try VoiceIsolationTests.readMono(AudioStemStore.shared.readyStem(media: asset, kind: StemSeparator.Stem.bass.storeKind)!, seconds: 6)
            let mixMono = (0..<n).map { buf.floatChannelData![0][$0] }
            let inTone = Self.tone(mixMono, hz: 110, sr: sr)
            let vTone = Self.tone(vocals, hz: 110, sr: 48_000), bTone = Self.tone(bassStem, hz: 110, sr: 48_000)
            print("metric demucs_110hz_in=\(inTone) vocals=\(vTone) bass=\(bTone)")
            #expect(vTone < inTone * 0.1, "tone should leave the vocals stem")
            #expect(VoiceIsolationTests.energy(vocals) > VoiceIsolationTests.energy(Array(clean.prefix(96_000))) * 0.2, "voice kept")
            for s in StemSeparator.Stem.allCases { try? FileManager.default.removeItem(at: AudioStemStore.shared.stemURL(media: asset, kind: s.storeKind)) }
        }
    }
}
