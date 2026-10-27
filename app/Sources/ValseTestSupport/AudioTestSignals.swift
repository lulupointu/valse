import Foundation
import ValseCore
import ValseEngine

/// Test signals and spectral measurements for audio DSP tests.
public enum AudioTestSignals {
    public static func sine(_ hz: Double, seconds: Double = 1, amplitude: Double = 0.3, sampleRate: Double = 48000, channels: Int = 2) -> AudioBuffer {
        AudioBuffer(seconds: seconds, sampleRate: sampleRate, channels: channels) { _, t in Float(amplitude * sin(2 * .pi * hz * t)) }
    }

    /// Harmonic "voice-like" tone: sawtooth-ish harmonics with a formant-shaped envelope and slight vibrato.
    public static func voice(f0: Double = 160, seconds: Double = 1, sampleRate: Double = 48000) -> AudioBuffer {
        AudioBuffer(seconds: seconds, sampleRate: sampleRate, channels: 2) { _, t in
            // 1 % vibrato at 5 Hz (integrated phase)
            let ph = 2 * .pi * f0 * (t + 0.01 * (1 - cos(2 * .pi * 5 * t)) / (2 * .pi * 5))
            var s = 0.0
            var h = 1
            while Double(h) * f0 < 8000 {
                let fh = Double(h) * f0
                let formant = exp(-pow((fh - 700) / 400, 2)) + 0.6 * exp(-pow((fh - 1200) / 500, 2)) + 0.3 * exp(-pow((fh - 2600) / 700, 2))
                s += formant / Double(h).squareRoot() * sin(ph * Double(h))
                h += 1
            }
            return Float(s * 0.15)
        }
    }

    /// White noise (deterministic).
    public static func noise(seconds: Double = 1, amplitude: Double = 0.05, sampleRate: Double = 48000, channels: Int = 2, seed: UInt64 = 1) -> AudioBuffer {
        var s = seed &* 0x9E3779B97F4A7C15 | 1
        return AudioBuffer(seconds: seconds, sampleRate: sampleRate, channels: channels) { _, _ in
            s ^= s << 13; s ^= s >> 7; s ^= s << 17
            return Float((Double(s >> 11) / Double(1 << 53) * 2 - 1) * amplitude * 1.7320508)
        }
    }

    /// Sum of buffers (same length/channels as the first).
    public static func mix(_ a: AudioBuffer, _ others: AudioBuffer...) -> AudioBuffer {
        let out = AudioBuffer(channels: a.channels, frames: a.frames, sampleRate: a.sampleRate)
        for c in 0..<a.channels { for i in 0..<a.frames { out[c, i] = a[c, i] } }
        for o in others { for c in 0..<min(a.channels, o.channels) { for i in 0..<min(a.frames, o.frames) { out[c, i] += o[c, i] } } }
        return out
    }

    /// Magnitude of the DFT at `hz` over [from, to) seconds (Goertzel, Hann window), normalized so a sine of amplitude A
    /// reads ≈ A.
    public static func amplitude(at hz: Double, in b: AudioBuffer, channel: Int = 0, from: Double = 0, to: Double? = nil) -> Double {
        let s0 = Int(from * b.sampleRate), s1 = min(b.frames, Int((to ?? Double(b.frames) / b.sampleRate) * b.sampleRate))
        let n = s1 - s0
        guard n > 16 else { return 0 }
        let w = 2 * Double.pi * hz / b.sampleRate
        var re = 0.0, im = 0.0, wsum = 0.0
        for i in 0..<n {
            let win = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n - 1))
            let x = Double(b[channel, s0 + i]) * win
            re += x * cos(w * Double(i)); im -= x * sin(w * Double(i)); wsum += win
        }
        return 2 * sqrt(re * re + im * im) / wsum
    }

    /// Frequency of the strongest spectral peak in [lo, hi] Hz (1 Hz resolution search refined by golden section).
    public static func dominantFrequency(_ b: AudioBuffer, lo: Double = 50, hi: Double = 5000, channel: Int = 0,
                                         from: Double = 0, to: Double? = nil) -> Double {
        var best = lo, bestA = -1.0
        var f = lo
        while f <= hi {
            let a = amplitude(at: f, in: b, channel: channel, from: from, to: to)
            if a > bestA { bestA = a; best = f }
            f += max(1, f * 0.01)
        }
        var a = max(lo, best - max(1, best * 0.01)), c = min(hi, best + max(1, best * 0.01))
        for _ in 0..<20 {
            let m1 = a + (c - a) * 0.382, m2 = a + (c - a) * 0.618
            if amplitude(at: m1, in: b, channel: channel, from: from, to: to) > amplitude(at: m2, in: b, channel: channel, from: from, to: to) { c = m2 } else { a = m1 }
        }
        return (a + c) / 2
    }

    /// Time (s) of the first sample whose |value| exceeds `threshold`.
    public static func onset(_ b: AudioBuffer, threshold: Float = 0.05, channel: Int = 0) -> Double? {
        for i in 0..<b.frames where abs(b[channel, i]) > threshold { return Double(i) / b.sampleRate }
        return nil
    }

    public static func hasNaN(_ b: AudioBuffer) -> Bool {
        for c in 0..<b.channels { for i in 0..<b.frames where !b[c, i].isFinite { return true } }
        return false
    }
}

extension TestProject {
    /// Imports a synthetic sine audio file (stereo, 0.3 amplitude) and inserts it on an audio track.
    @discardableResult
    public mutating func addAudio(seconds: Double = 2, hz: Double = 440, at start: Time = .zero,
                                  target: InsertTarget = .automatic) async throws -> ClipID {
        try await addMedia(try await TestMedia.audio(seconds: seconds, hz: hz), at: start, target: target)
    }

    /// Writes `buffer` to a temporary WAV, imports and inserts it.
    @discardableResult
    public mutating func addAudio(_ buffer: AudioBuffer, at start: Time = .zero, target: InsertTarget = .automatic) async throws -> ClipID {
        let url = TestMedia.directory.appendingPathComponent("buf-\(UUID().uuidString).wav")
        try AudioFileIO.write(buffer, to: url, format: .wav24)
        return try await addMedia(url, at: start, target: target)
    }

    /// The project audio mix through the export path.
    public func mixdown(seconds: Double? = nil) async throws -> AudioBuffer {
        try await AudioMixdown.render(project, range: seconds.map { TimeRange(start: .zero, duration: Time($0)) })
    }
}
