import Testing
import Foundation
import MontageCore
@testable import MontageEngine
import MontageTestSupport

@Suite(.serialized) struct AudioAnalysisTests {
    @Test func loudnessOfReferenceSine() {
        // EBU Tech 3341: stereo 1 kHz sine at −23 dBFS peak on both channels reads −23.0 LUFS.
        let a = pow(10, -23.0 / 20)
        let b = AudioTestSignals.sine(1000, seconds: 5, amplitude: a)
        #expect(abs(AudioAnalysis.loudness(b) - (-23)) < 0.2, "\(AudioAnalysis.loudness(b))")
        let c = AudioTestSignals.sine(1000, seconds: 5, amplitude: a * 2)   // +6 dB
        #expect(abs(AudioAnalysis.loudness(c) - (-23 + 6.02)) < 0.2)
        #expect(AudioAnalysis.loudness(AudioBuffer(channels: 2, frames: 48000, sampleRate: 48000)) == -.infinity)
    }

    static func clicks(_ times: [Double], seconds: Double, sr: Double = AudioAnalysis.onsetSampleRate) -> [Float] {
        var out = [Float](repeating: 0, count: Int(seconds * sr))
        var rng = XorShift()
        for i in out.indices { out[i] = rng.next() * 0.003 }
        for t in times {
            let s = Int(t * sr)
            for k in 0..<Int(0.03 * sr) where s + k < out.count {
                out[s + k] += rng.next() * 0.6 * Float(exp(-Double(k) / (0.006 * sr)))
            }
        }
        return out
    }

    @Test func detectsTempoAndBeats() {
        let truth = stride(from: 0.25, to: 10, by: 0.5).map { $0 }       // 120 BPM
        let r = AudioAnalysis.beats(onsets: AudioAnalysis.onsetEnvelope(Self.clicks(truth, seconds: 10)))
        #expect(abs(r.bpm - 120) < 2, "bpm \(r.bpm)")
        var matched = 0
        for b in r.beats where b > 1 && b < 9 {
            if truth.contains(where: { abs($0 - b) < 0.03 }) { matched += 1 }
        }
        let expected = truth.filter { $0 > 1 && $0 < 9 }.count
        #expect(matched >= expected - 1, "matched \(matched)/\(expected): \(r.beats.prefix(6))")
        #expect(abs(r.strongBeats.count - r.beats.count / 2) <= 1)
    }

    @Test func detectsOtherTempo() {
        let truth = stride(from: 0.1, to: 12, by: 60.0 / 95).map { $0 }   // 95 BPM
        let r = AudioAnalysis.beats(onsets: AudioAnalysis.onsetEnvelope(Self.clicks(truth, seconds: 12)))
        #expect(abs(r.bpm - 95) < 2, "bpm \(r.bpm)")
    }

    @Test func syncOffsetFindsDelay() {
        let times = [0.3, 0.9, 1.25, 2.1, 2.4, 3.3, 4.05, 4.5, 5.6, 6.2]
        let a = Self.clicks(times, seconds: 8)
        let b = Self.clicks(times.map { $0 + 0.37 }, seconds: 8)
        let off = AudioAnalysis.syncOffset(a, b, maxLag: 2)
        #expect(abs(off - (-0.37)) < 0.015, "offset \(off)")
    }
}
