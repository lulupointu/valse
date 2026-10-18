import Testing
import Foundation
import MontageCore
@testable import MontageEngine
import MontageTestSupport

/// Numerical checks of the audio DSP building blocks (offline, no AVFoundation).
@Suite struct AudioDSPTests {
    typealias S = AudioTestSignals

    @Test func biquadLowPassAttenuatesHighs() {
        let k = BiquadCoefficients.lowPass(1000, sampleRate: 48000)
        #expect(abs(k.magnitude(at: 100, sampleRate: 48000) - 1) < 0.02)
        #expect(dB(k.magnitude(at: 8000, sampleRate: 48000)) < -30)
        let b = S.mix(S.sine(200, seconds: 0.5), S.sine(8000, seconds: 0.5))
        LiveChain([.lowPass(hz: 1000)], sampleRate: 48000).process(b)
        #expect(abs(S.amplitude(at: 200, in: b, from: 0.1) - 0.3) < 0.02)
        #expect(S.amplitude(at: 8000, in: b, from: 0.1) < 0.3 * 0.01)
    }

    @Test func graphicEQBoostsItsBand() {
        var gains = [Double](repeating: 0, count: 10); gains[5] = 12   // 1 kHz
        let b = S.mix(S.sine(1000, seconds: 0.5, amplitude: 0.05), S.sine(100, seconds: 0.5, amplitude: 0.05))
        LiveChain([.eq(gains)], sampleRate: 48000).process(b)
        let g1k = dB(S.amplitude(at: 1000, in: b, from: 0.1) / 0.05), g100 = dB(S.amplitude(at: 100, in: b, from: 0.1) / 0.05)
        #expect(abs(g1k - 12) < 1.5, "1 kHz gain \(g1k) dB")
        #expect(abs(g100) < 1, "100 Hz gain \(g100) dB")
    }

    @Test func stftIdentityIsTransparentWithKnownLatency() {
        let x = S.voice(seconds: 0.5)
        let stft = StreamingSTFT(n: 2048, hop: 512, channels: 2, transform: IdentityTransform())
        let y = x.copy()
        y.process(chunk: 333) { stft.process($0) }
        var err: Float = 0
        for i in 4096..<(x.frames - stft.latency) { err = max(err, abs(y[0, i + stft.latency] - x[0, i])) }
        #expect(err < 1e-4, "max error \(err)")
    }

    @Test func pitchShiftMovesFrequencyKeepsDuration() {
        for (semis, expected) in [(12.0, 880.0), (-5.0, 440 * pow(2, -5.0 / 12)), (7.0, 440 * pow(2, 7.0 / 12))] {
            var spec = RenderStageSpec(); spec.pitch = pow(2, semis / 12); spec.formant = spec.pitch   // pure tone: no envelope
            let x = S.sine(440, seconds: 1)
            let y = RenderStageProcessor(spec: spec).render(x)
            #expect(y.frames == x.frames)
            let f = S.dominantFrequency(y, lo: 200, hi: 1200, from: 0.3, to: 0.8)
            #expect(abs(f - expected) < expected * 0.01, "\(semis) st → \(f) Hz, expected \(expected)")
            // level roughly preserved
            #expect(abs(dB(y.rms(seconds: 0.3, 0.8) / x.rms(seconds: 0.3, 0.8))) < 3)
        }
    }

    @Test func formantPreservingShiftKeepsSpectralEnvelope() {
        // voice f0 160 Hz, formant peak ≈ 700 Hz. Up 5 st with formant=1: harmonics near 700 Hz stay the loudest region.
        let x = S.voice(f0: 160, seconds: 1)
        var spec = RenderStageSpec(); spec.pitch = pow(2, 5.0 / 12); spec.formant = 1
        let y = RenderStageProcessor(spec: spec).render(x)
        var chip = RenderStageSpec(); chip.pitch = pow(2, 5.0 / 12); chip.formant = chip.pitch
        let z = RenderStageProcessor(spec: chip).render(x)
        // spectral centroid sampled on the harmonics of the (known) fundamental
        func centroid(_ b: AudioBuffer, _ f0: Double) -> Double {
            var num = 0.0, den = 0.0
            var f = f0
            while f < 4000 { let a = S.amplitude(at: f, in: b, from: 0.3, to: 0.7); num += a * a * f; den += a * a; f += f0 }
            return num / den
        }
        let f1 = 160 * pow(2, 5.0 / 12)
        let c0 = centroid(x, 160), c1 = centroid(y, f1), c2 = centroid(z, f1)
        #expect(abs(c1 - c0) / c0 < 0.15, "formant-preserved centroid \(c1) vs \(c0)")
        #expect(c2 / c0 > 1.2, "chipmunk centroid \(c2) vs \(c0)")
        #expect(abs(S.dominantFrequency(y, lo: 150, hi: 260, from: 0.3, to: 0.7) - 160 * pow(2, 5.0 / 12)) < 4)
    }

    @Test func echoRepeatsImpulse() {
        let b = AudioBuffer(channels: 2, frames: 48000, sampleRate: 48000)
        b[0, 100] = 1; b[1, 100] = 1
        LiveChain([.echo(seconds: 0.25, feedback: 0.5, mix: 0.6)], sampleRate: 48000).process(b)
        #expect(abs(b[0, 100] - 1) < 1e-6)
        #expect(abs(b[0, 100 + 12000] - 0.6) < 0.02)
        #expect(abs(b[0, 100 + 24000] - 0.3) < 0.02)   // feedback
    }

    @Test func reverbHasDecayingTail() {
        let b = AudioBuffer(channels: 2, frames: 96000, sampleRate: 48000)
        for i in 0..<480 { b[0, i] = 0.5; b[1, i] = 0.5 }
        LiveChain([.reverb(room: 0.8, damp: 0.3, wet: 0.5, width: 1)], sampleRate: 48000).process(b)
        let early = b.rms(seconds: 0.1, 0.3), late = b.rms(seconds: 1.4, 1.9)
        #expect(early > 0.005)
        #expect(late < early)
        #expect(!S.hasNaN(b))
    }

    @Test func compressorReducesLoudSignal() {
        let b = S.sine(1000, seconds: 0.5, amplitude: 0.5)      // ≈ −9 dBFS RMS
        LiveChain([.compressor(thresholdDB: -20, ratio: 4, attackMs: 1, releaseMs: 50, makeupDB: 0)], sampleRate: 48000).process(b)
        let level = dB(b.rms(seconds: 0.2, 0.5))
        #expect(level < -14 && level > -21, "compressed level \(level)")
    }

    @Test func channelModes() {
        let b = AudioBuffer(seconds: 0.1, channels: 2) { c, _ in c == 0 ? 0.5 : -0.25 }
        LiveChain([.channels(.leftToBoth)], sampleRate: 48000).process(b)
        #expect(b[1, 10] == 0.5)
        let m = AudioBuffer(seconds: 0.1, channels: 2) { c, _ in c == 0 ? 0.5 : -0.25 }
        LiveChain([.channels(.mono)], sampleRate: 48000).process(m)
        #expect(abs(m[0, 10] - 0.125) < 1e-6 && abs(m[1, 10] - 0.125) < 1e-6)
    }

    @Test func denoiseRemovesNoiseKeepsTone() {
        // 2 s: noise throughout, 1 kHz tone between 1.0 and 2.0 s
        let noise = S.noise(seconds: 2, amplitude: 0.03)
        let tone = AudioBuffer(seconds: 2, channels: 2) { _, t in t >= 1 ? Float(0.3 * sin(2 * .pi * 1000 * t)) : 0 }
        let x = S.mix(noise, tone)
        var spec = RenderStageSpec(); spec.denoise = 1
        let y = RenderStageProcessor(spec: spec).render(x)
        let before = x.rms(seconds: 0.4, 0.9), after = y.rms(seconds: 0.4, 0.9)
        #expect(dB(after / before) < -15, "noise reduced by \(dB(after / before)) dB")
        let toneIn = S.amplitude(at: 1000, in: x, from: 1.3, to: 1.9), toneOut = S.amplitude(at: 1000, in: y, from: 1.3, to: 1.9)
        #expect(abs(dB(toneOut / toneIn)) < 1.5, "tone changed by \(dB(toneOut / toneIn)) dB")
    }

    @Test func vocalSeparationSplitsCentreFromSides() {
        // 440 Hz centred (vocal), 1500 Hz hard left (instrument)
        let x = AudioBuffer(seconds: 1.5, channels: 2) { c, t in
            Float(0.2 * sin(2 * .pi * 440 * t)) + (c == 0 ? Float(0.2 * sin(2 * .pi * 1500 * t)) : 0)
        }
        var keep = RenderStageSpec(); keep.separation = .keepVocals
        let v = RenderStageProcessor(spec: keep).render(x)
        var remove = RenderStageSpec(); remove.separation = .removeVocals
        let r = RenderStageProcessor(spec: remove).render(x)
        let a = { (b: AudioBuffer, f: Double) in S.amplitude(at: f, in: b, channel: 0, from: 0.5, to: 1.4) }
        #expect(a(v, 440) > 0.15 && a(v, 1500) < 0.03, "vocals: 440=\(a(v, 440)) 1500=\(a(v, 1500))")
        #expect(a(r, 440) < 0.03 && a(r, 1500) > 0.15, "accompaniment: 440=\(a(r, 440)) 1500=\(a(r, 1500))")
    }

    @Test func robotImposesFixedPeriod() {
        var spec = RenderStageSpec(); spec.robotHz = 100
        let y = RenderStageProcessor(spec: spec).render(S.voice(f0: 173, seconds: 1))
        // output energy concentrates on multiples of sr/hop = 48000/480 = 100 Hz
        let onGrid = (2...8).map { S.amplitude(at: Double($0) * 100, in: y, from: 0.3, to: 0.8) }.reduce(0, +)
        let offGrid = (2...8).map { S.amplitude(at: Double($0) * 100 + 50, in: y, from: 0.3, to: 0.8) }.reduce(0, +)
        #expect(onGrid > 3 * offGrid, "on \(onGrid) off \(offGrid)")
    }

    @Test func everyVoicePresetProducesSaneOutput() {
        let x = S.voice(seconds: 0.4)
        for d in VoiceEffects.all {
            let plan = ClipAudioPlan.make({ var a = AudioProps(); a.voice = d.makeEffect(); return a }())
            let y = plan.render.isIdentity ? x.copy() : RenderStageProcessor(spec: plan.render).render(x)
            LiveChain(plan.live, sampleRate: 48000).process(y)
            #expect(!S.hasNaN(y), "\(d.id) NaN")
            #expect(y.peak < 4, "\(d.id) peak \(y.peak)")
            #expect(y.rms(seconds: 0.2, 0.4) > 0.003, "\(d.id) silent")
            #expect(!plan.render.isIdentity || !plan.live.isEmpty, "\(d.id) does nothing")
        }
    }
}
