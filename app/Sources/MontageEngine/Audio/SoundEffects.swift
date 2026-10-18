import Foundation
import MontageCore

/// Built-in procedural sound-effect pack (AU-002). Every effect is synthesized (no samples, no licences) once into
/// ~/Library/Caches/Montage/sfx/<id>-v<version>.wav and then used like any imported audio file.
public struct SoundEffectDescriptor: Sendable, Identifiable {
    public let id: String
    public let nameKey: String
    public let category: String
    public let duration: Double
    let render: @Sendable (AudioBuffer) -> Void
}

public enum SoundEffects {
    public static let version = 1
    public static let categories = ["transition", "ui", "impact", "cartoon"]

    public static var directory: URL { MontagePaths.cacheDirectory.appendingPathComponent("sfx", isDirectory: true) }

    public static func url(for d: SoundEffectDescriptor) -> URL { directory.appendingPathComponent("\(d.id)-v\(version).wav") }

    /// File for an effect, synthesizing it on first use.
    public static func file(_ d: SoundEffectDescriptor) throws -> URL {
        let u = url(for: d)
        if FileManager.default.fileExists(atPath: u.path) { return u }
        let b = AudioBuffer(channels: 2, frames: Int(d.duration * 48000), sampleRate: 48000)
        d.render(b)
        // normalize to −1 dBFS peak
        let pk = b.peak
        if pk > 0 { let g = 0.89 / pk; for c in 0..<2 { for i in 0..<b.frames { b[c, i] *= g } } }
        let tmp = directory.appendingPathComponent("tmp-\(UUID().uuidString).wav")
        try AudioFileIO.write(b, to: tmp, format: .wav16)
        try? FileManager.default.removeItem(at: u)
        try FileManager.default.moveItem(at: tmp, to: u)
        return u
    }

    // MARK: synthesis helpers

    static func fill(_ b: AudioBuffer, _ f: (Double, Int) -> (Float, Float)) {
        for i in 0..<b.frames { let (l, r) = f(Double(i) / b.sampleRate, i); b[0, i] = l; b[1, i] = r }
    }
    static func env(_ t: Double, attack: Double, decay: Double) -> Double { t < attack ? t / attack : exp(-(t - attack) / decay) }

    /// Band-limited noise with a moving centre frequency (state-variable filter).
    static func sweptNoise(_ b: AudioBuffer, from f0: Double, to f1: Double, q: Double = 2, amp: (Double) -> Double) {
        var rng = XorShift(), low = 0.0, band = 0.0, low2 = 0.0, band2 = 0.0
        var rng2 = XorShift(s: 0x1234567)
        let dur = Double(b.frames) / b.sampleRate
        fill(b) { t, _ in
            let f = f0 * pow(f1 / f0, t / dur)
            let k = 2 * sin(Double.pi * min(f, 20000) / b.sampleRate)
            let x = Double(rng.next()), y = Double(rng2.next())
            low += k * band; band += k * (x - low - band / q)
            low2 += k * band2; band2 += k * (y - low2 - band2 / q)
            let a = amp(t)
            return (Float(band * a), Float(band2 * a))
        }
    }

    static func tone(_ b: AudioBuffer, _ partials: [(hz: Double, amp: Double, decay: Double)], attack: Double = 0.002,
                     glide: ((Double) -> Double)? = nil) {
        var phases = [Double](repeating: 0, count: partials.count)
        fill(b) { t, _ in
            var s = 0.0
            for (k, p) in partials.enumerated() {
                let f = p.hz * (glide?(t) ?? 1)
                phases[k] += 2 * Double.pi * f / b.sampleRate
                s += sin(phases[k]) * p.amp * env(t, attack: attack, decay: p.decay)
            }
            return (Float(s), Float(s))
        }
    }

    // MARK: catalogue

    public static let all: [SoundEffectDescriptor] = [
        .init(id: "whoosh", nameKey: "sfx.whoosh", category: "transition", duration: 0.9) { b in
            sweptNoise(b, from: 300, to: 3000, q: 1.5) { t in sin(Double.pi * min(1, t / 0.9)) * 0.9 }
        },
        .init(id: "swish", nameKey: "sfx.swish", category: "transition", duration: 0.35) { b in
            sweptNoise(b, from: 1500, to: 6000, q: 2) { t in sin(Double.pi * min(1, t / 0.35)) }
        },
        .init(id: "riser", nameKey: "sfx.riser", category: "transition", duration: 3) { b in
            sweptNoise(b, from: 200, to: 8000, q: 3) { t in pow(t / 3, 2) * 0.7 }
            var ph = 0.0
            for i in 0..<b.frames {
                let t = Double(i) / 48000
                ph += 2 * Double.pi * (110 * pow(2, t * 1.3)) / 48000
                let v = Float(sin(ph) * pow(t / 3, 1.5) * 0.3)
                b[0, i] += v; b[1, i] += v
            }
        },
        .init(id: "downlifter", nameKey: "sfx.downlifter", category: "transition", duration: 2) { b in
            sweptNoise(b, from: 6000, to: 150, q: 2.5) { t in exp(-t * 1.2) * 0.8 }
        },
        .init(id: "impact", nameKey: "sfx.impact", category: "impact", duration: 1.5) { b in
            tone(b, [(55, 1, 0.45), (110, 0.4, 0.2)], glide: { 1 + 1.5 * exp(-$0 * 30) })
            let n = AudioBuffer(channels: 2, frames: b.frames, sampleRate: 48000)
            sweptNoise(n, from: 4000, to: 300, q: 0.8) { t in exp(-t * 18) * 1.5 }
            for c in 0..<2 { for i in 0..<b.frames { b[c, i] += n[c, i] } }
        },
        .init(id: "boom", nameKey: "sfx.boom", category: "impact", duration: 2.5) { b in
            tone(b, [(40, 1, 0.9), (62, 0.5, 0.5)], glide: { 1 + 2 * exp(-$0 * 20) })
        },
        .init(id: "punch", nameKey: "sfx.punch", category: "impact", duration: 0.4) { b in
            tone(b, [(90, 1, 0.08), (180, 0.3, 0.05)], glide: { 1 + exp(-$0 * 60) })
            let n = AudioBuffer(channels: 2, frames: b.frames, sampleRate: 48000)
            sweptNoise(n, from: 2500, to: 800, q: 0.7) { t in exp(-t * 40) * 2 }
            for c in 0..<2 { for i in 0..<b.frames { b[c, i] += n[c, i] } }
        },
        .init(id: "pop", nameKey: "sfx.pop", category: "ui", duration: 0.15) { b in
            tone(b, [(600, 1, 0.03)], attack: 0.001, glide: { 1 + 1.5 * exp(-$0 * 80) })
        },
        .init(id: "click", nameKey: "sfx.click", category: "ui", duration: 0.05) { b in
            sweptNoise(b, from: 3000, to: 2000, q: 1) { t in exp(-t * 300) * 3 }
        },
        .init(id: "beep", nameKey: "sfx.beep", category: "ui", duration: 0.3) { b in
            fill(b) { t, _ in let v = Float(sin(2 * .pi * 1000 * t) * (t < 0.28 ? 0.6 : 0) * min(1, t / 0.005)); return (v, v) }
        },
        .init(id: "ding", nameKey: "sfx.ding", category: "ui", duration: 2) { b in
            tone(b, [(1318, 1, 0.8), (2637, 0.3, 0.4), (3951, 0.12, 0.25), (1975, 0.2, 0.6)])
        },
        .init(id: "notification", nameKey: "sfx.notification", category: "ui", duration: 0.7) { b in
            fill(b) { t, _ in
                let f = t < 0.15 ? 880.0 : 1318.5
                let local = t < 0.15 ? t : t - 0.15
                let v = Float(sin(2 * .pi * f * t) * env(local, attack: 0.004, decay: 0.12) * 0.7)
                return (v, v)
            }
        },
        .init(id: "typing", nameKey: "sfx.typing", category: "ui", duration: 2) { b in
            var rng = XorShift()
            var next = 0.0, last = -1.0
            fill(b) { t, _ in
                if t >= next { last = t; next = t + 0.08 + Double(abs(rng.next())) * 0.12 }
                let d = t - last
                let v = d >= 0 && d < 0.02 ? rng.next() * Float(exp(-d * 250)) * 0.8 : 0
                return (v, v)
            }
        },
        .init(id: "shutter", nameKey: "sfx.shutter", category: "ui", duration: 0.35) { b in
            var rng = XorShift()
            fill(b) { t, _ in
                let a = exp(-t * 80) + (t > 0.12 ? exp(-(t - 0.12) * 60) * 0.8 : 0)
                let v = rng.next() * Float(a)
                return (v, v)
            }
        },
        .init(id: "glitch", nameKey: "sfx.glitch", category: "transition", duration: 0.6) { b in
            var rng = XorShift(), hold: Float = 0, cnt = 0
            fill(b) { t, i in
                cnt -= 1
                if cnt <= 0 { hold = rng.next(); cnt = 20 + Int(abs(rng.next()) * 400) }
                let gate: Float = sin(t * 90) > -0.2 ? 1 : 0
                let v = (hold * 0.5 + Float(sin(Double(i) * 0.3)) * 0.3) * gate
                return (v, -v)
            }
        },
        .init(id: "boing", nameKey: "sfx.boing", category: "cartoon", duration: 0.8) { b in
            tone(b, [(220, 1, 0.3)], glide: { 1 + 0.6 * sin($0 * 40) * exp(-$0 * 5) + $0 * 0.8 })
        },
        .init(id: "laser", nameKey: "sfx.laser", category: "cartoon", duration: 0.5) { b in
            tone(b, [(1800, 1, 0.2), (3600, 0.3, 0.1)], glide: { exp(-$0 * 5) })
        },
        .init(id: "slideWhistleUp", nameKey: "sfx.slideUp", category: "cartoon", duration: 0.9) { b in
            tone(b, [(500, 1, 2)], attack: 0.03, glide: { 1 + $0 * 1.5 })
        },
        .init(id: "heartbeat", nameKey: "sfx.heartbeat", category: "impact", duration: 1.6) { b in
            fill(b) { t, _ in
                func thump(_ t0: Double) -> Double { let d = t - t0; return d < 0 ? 0 : sin(2 * .pi * 55 * d) * exp(-d * 18) }
                let v = Float(thump(0.05) + 0.7 * thump(0.33) + thump(0.85) + 0.7 * thump(1.13))
                return (v, v)
            }
        },
    ]

    public static func descriptor(_ id: String) -> SoundEffectDescriptor? { all.first { $0.id == id } }
}
