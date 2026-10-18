import Testing
import Foundation
@preconcurrency import AVFoundation
@testable import MontageAI
import MontageCore
import MontageEngine
import MontageTestSupport

/// ML voice isolation (AUSoundIsolation) on bench speech + synthetic noise: the voice stem is much cleaner than
/// the input, and voice + novoice reconstruct the original.
@Suite(.serialized) struct VoiceIsolationTests {
    static func readMono(_ url: URL, seconds: Double) throws -> [Float] {
        let f = try AVAudioFile(forReading: url)
        let n = AVAudioFrameCount(min(Double(f.length), seconds * f.processingFormat.sampleRate))
        let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: n)!
        try f.read(into: b, frameCount: n)
        let ch = Int(f.processingFormat.channelCount)
        return (0..<Int(b.frameLength)).map { i in (0..<ch).reduce(Float(0)) { $0 + b.floatChannelData![$1][i] } / Float(ch) }
    }

    static func energy(_ x: [Float]) -> Double { x.reduce(0) { $0 + Double($1 * $1) } }

    /// The ML stems inside the audio engine's rendered stage (W8 chain): Reduce noise at full strength through
    /// `AudioRenderCache` uses the voice stem when the `AudioML` provider is installed.
    @Test func renderedStageUsesMLVoiceStem() async throws {
        try await HeavyWorkGate.run {   // keep real-time probes / ML tests from starving each other
            guard VoiceIsolator.isAvailable, let speech = AIFixtures.speechFR else { print("skip"); return }
            AudioML.voiceStems = { a, p in try await VoiceIsolator.separate(a, progress: p) }   // not `usedByPlans`: other tests unaffected
            let clean = try Self.readMono(speech, seconds: 6)
            let sr = 48_000.0, n = Int(6 * sr)
            let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("montage-noisy2-\(UUID().uuidString).caf")
            defer { try? FileManager.default.removeItem(at: url) }
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
            buf.frameLength = AVAudioFrameCount(n)
            var up = [Float](repeating: 0, count: n)
            for i in 0..<n {
                up[i] = clean[min(i / 3, clean.count - 1)]
                let noise = Float.random(in: -0.08...0.08)
                buf.floatChannelData![0][i] = up[i] + noise; buf.floatChannelData![1][i] = up[i] + noise
            }
            do { let f = try AVAudioFile(forWriting: url, settings: fmt.settings); try f.write(from: buf) }
            var asset = try await MediaProbe.probe(url)
            asset.contentHash = "test-ml-\(UUID().uuidString.prefix(6))"
            var spec = RenderStageSpec()
            spec.denoise = 1
            spec.mlVoice = true
            let out = try await AudioRenderCache.shared.render(asset, spec: spec)
            let y = try Self.readMono(out, seconds: 6)
            var inP = 0.0, outP = 0.0
            for f in stride(from: 0, to: min(y.count, n) - 960, by: 960) where Self.energy(Array(up[f..<f + 960])) < 1e-4 {
                inP += Self.energy((f..<f + 960).map { buf.floatChannelData![0][$0] }); outP += Self.energy(Array(y[f..<f + 960]))
            }
            let db = 10 * log10(inP / max(outP, 1e-12))
            print("metric ml_denoise_pause_reduction_db=\(db)")
            #expect(db > 15)
            try? FileManager.default.removeItem(at: out)
            for s in VoiceIsolator.Stem.allCases { try? FileManager.default.removeItem(at: AudioStemStore.shared.stemURL(media: asset, kind: s.rawValue)) }
    
        }
    }

    @Test func isolatesSpeechFromNoise() async throws {
        try await HeavyWorkGate.run {   // keep real-time probes / ML tests from starving each other
            guard VoiceIsolator.isAvailable, let speech = AIFixtures.speechFR else { print("skip: AUSoundIsolation or bench media missing"); return }
            // noisy = speech + white noise, 10 s, 48 kHz
            let clean = try Self.readMono(speech, seconds: 10)       // 16 kHz
            let sr = 48_000.0, n = Int(10 * sr)
            var rng = SystemRandomNumberGenerator()
            let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("montage-noisy-\(UUID().uuidString).caf")
            defer { try? FileManager.default.removeItem(at: url) }
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
            buf.frameLength = AVAudioFrameCount(n)
            var cleanUp = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let s = clean[min(i / 3, clean.count - 1)]
                cleanUp[i] = s
                let noise = Float.random(in: -0.08...0.08, using: &rng)
                buf.floatChannelData![0][i] = s + noise; buf.floatChannelData![1][i] = s + noise
            }
            do { let f = try AVAudioFile(forWriting: url, settings: fmt.settings); try f.write(from: buf) }
            var asset = try await MediaProbe.probe(url)
            asset.contentHash = "test-iso-\(UUID().uuidString.prefix(6))"
            try await VoiceIsolator.separate(asset)
            let voice = try Self.readMono(AudioStemStore.shared.readyStem(media: asset, kind: "voice")!, seconds: 10)
            let rest = try Self.readMono(AudioStemStore.shared.readyStem(media: asset, kind: "novoice")!, seconds: 10)
            #expect(abs(voice.count - n) < 4800)
            let m = min(voice.count, n)
            let inErr = Self.energy((0..<m).map { buf.floatChannelData![0][$0] - cleanUp[$0] })
            let outErr = Self.energy((0..<m).map { voice[$0] - cleanUp[$0] })
            if ProcessInfo.processInfo.environment["MONTAGE_DEBUG_ISO"] != nil {
                var best = (0, -Double.infinity)
                for lag in stride(from: -4800, through: 4800, by: 32) {
                    var acc = 0.0
                    for i in stride(from: 5000, to: m - 5000, by: 7) { acc += Double(voice[i + lag] * cleanUp[i]) }
                    if acc > best.1 { best = (lag, acc) }
                }
                print("best lag \(best.0) inE \(inErr) outE \(outErr) cleanE \(Self.energy(cleanUp)) voiceE \(Self.energy(voice))")
            }
            let gain = 10 * log10(inErr / max(outErr, 1e-9))
            // noise left in the pauses (20 ms frames where the clean speech is silent)
            var inPause = 0.0, outPause = 0.0
            for f in stride(from: 0, to: m - 960, by: 960) where Self.energy(Array(cleanUp[f..<f + 960])) < 1e-4 {
                inPause += Self.energy((f..<f + 960).map { buf.floatChannelData![0][$0] })
                outPause += Self.energy(Array(voice[f..<f + 960]))
            }
            let pauseGain = 10 * log10(inPause / max(outPause, 1e-12))
            print("metric voice_isolation_snr_gain_db=\(gain) pause_noise_reduction_db=\(pauseGain)")
            #expect(gain > 2, "isolation should improve SNR (gain \(gain) dB)")
            #expect(pauseGain > 15, "noise in pauses should drop (\(pauseGain) dB)")
            // voice + rest == original
            let recon = Self.energy((0..<m).map { voice[$0] + rest[$0] - buf.floatChannelData![0][$0] })
            #expect(recon / Self.energy(Array(cleanUp.prefix(m))) < 1e-3)
            for s in VoiceIsolator.Stem.allCases { try? FileManager.default.removeItem(at: AudioStemStore.shared.stemURL(media: asset, kind: s.rawValue)) }
    
        }
    }
}
