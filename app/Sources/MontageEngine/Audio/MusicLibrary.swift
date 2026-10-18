import Foundation
import MontageCore

/// Built-in royalty-free music pack (Audio ▸ Music, UX_GAPS W8-2): short procedural tracks (pads, bass, arpeggio,
/// drums) composed from a chord progression and a style, synthesized once on first use into the same cache as the
/// sound effects (`SoundEffects.file`). No samples, no licences, fully local.
public enum MusicLibrary {
    public static let genres = ["chill", "upbeat", "cinematic", "lofi"]

    /// Musical recipe of a track.
    struct Style: Sendable {
        var bpm: Double
        /// MIDI note of the key's root (bass octave).
        var root: Int
        /// Chord roots in semitones from `root`, one per bar, with `minor` flags.
        var progression: [(Int, Bool)]
        var kick: [Int] = []          // 16th steps (0…15) per bar
        var snare: [Int] = []
        var hats: [Int] = []
        var bass: [Int] = [0, 8]      // steps where the bass plays the chord root
        var arp: [Int] = []           // steps where the arpeggio plays (cycling chord tones)
        var pad = 0.5                 // pad level
        var swing = 0.0               // 0…0.5 of a 16th, on odd steps
        var bright = 1.0              // harmonic richness of pad / arp
    }

    static func track(_ id: String, _ genre: String, _ s: Style) -> SoundEffectDescriptor {
        let bar = 240 / s.bpm
        let bars = max(1, Int((30 / bar / Double(s.progression.count)).rounded())) * s.progression.count
        return SoundEffectDescriptor(id: "music.\(id)", nameKey: "music.\(id)", category: genre, duration: Double(bars) * bar + 1.5) { b in
            render(s, bars: bars, into: b)
        }
    }

    public static let all: [SoundEffectDescriptor] = [
        track("sunrise", "chill", Style(bpm: 88, root: 36, progression: [(0, false), (7, false), (9, true), (5, false)],
                                        kick: [0, 10], hats: [4, 12], bass: [0, 6, 10], arp: [0, 3, 6, 8, 11, 14], pad: 0.55, bright: 0.7)),
        track("afterglow", "chill", Style(bpm: 96, root: 40, progression: [(0, true), (8, false), (3, false), (10, false)],
                                          kick: [0, 8], snare: [4, 12], hats: [2, 6, 10, 14], bass: [0, 3, 8, 11], arp: [0, 4, 8, 12], pad: 0.5, bright: 0.8)),
        track("citylights", "upbeat", Style(bpm: 120, root: 33, progression: [(0, true), (8, false), (3, false), (10, false)],
                                            kick: [0, 4, 8, 12], snare: [4, 12], hats: [2, 6, 10, 14], bass: [0, 2, 4, 6, 8, 10, 12, 14],
                                            arp: Array(0..<16), pad: 0.35, bright: 1.2)),
        track("summerdrive", "upbeat", Style(bpm: 112, root: 31, progression: [(0, false), (9, true), (5, false), (7, false)],
                                             kick: [0, 6, 8, 14], snare: [4, 12], hats: Array(stride(from: 0, to: 16, by: 2)), bass: [0, 3, 6, 8, 11, 14],
                                             arp: [0, 2, 4, 6, 8, 10, 12, 14], pad: 0.4, bright: 1.1)),
        track("horizon", "cinematic", Style(bpm: 70, root: 38, progression: [(0, true), (8, false), (10, false), (0, true)],
                                            kick: [0], bass: [0], arp: [0, 4, 8, 12], pad: 0.9, bright: 0.9)),
        track("frontier", "cinematic", Style(bpm: 76, root: 36, progression: [(0, true), (5, true), (8, false), (7, false)],
                                             kick: [0, 3, 8], snare: [12], bass: [0, 8], arp: [0, 2, 4, 6, 8, 10, 12, 14], pad: 0.8, bright: 1)),
        track("notebook", "lofi", Style(bpm: 80, root: 41, progression: [(0, false), (9, true), (2, true), (7, false)],
                                        kick: [0, 7, 10], snare: [4, 12], hats: [0, 2, 4, 6, 8, 10, 12, 14], bass: [0, 7, 10],
                                        arp: [0, 3, 6, 10], pad: 0.45, swing: 0.3, bright: 0.5)),
        track("rainyday", "lofi", Style(bpm: 74, root: 38, progression: [(0, true), (5, true), (10, false), (3, false)],
                                        kick: [0, 9], snare: [4, 12], hats: [2, 6, 10, 14], bass: [0, 9], arp: [0, 6, 12], pad: 0.5, swing: 0.25, bright: 0.45)),
    ]

    public static func descriptor(_ id: String) -> SoundEffectDescriptor? { all.first { $0.id == id } }

    // MARK: synthesis

    static func hz(_ midi: Double) -> Double { 440 * pow(2, (midi - 69) / 12) }

    static func render(_ s: Style, bars: Int, into b: AudioBuffer) {
        let sr = b.sampleRate
        let step = 60 / s.bpm / 4
        var rng = XorShift(s: 0x51F15EED)
        let L = b.pointer(0), R = b.pointer(1)
        let dt = 1 / sr
        func add(_ t0: Double, _ dur: Double, pan: Double = 0, _ sample: (Double) -> Double) {
            let i0 = max(0, Int(t0 * sr)), n = min(b.frames - i0, Int(dur * sr))
            guard n > 0 else { return }
            let gl = Float(min(1, 1 - pan)), gr = Float(min(1, 1 + pan))
            var t = 0.0
            for k in 0..<n {
                let v = Float(sample(t)); t += dt
                L[i0 + k] += v * gl; R[i0 + k] += v * gr
            }
        }
        // pad wavetable: one cycle of the harmonic mix (cheap per-sample lookup instead of N sines)
        let tableSize = 2048
        let harmonics = max(1, Int(2 + s.bright * 3))
        let table: [Double] = (0..<tableSize).map { i in
            let th = 2 * Double.pi * Double(i) / Double(tableSize)
            return (1...harmonics).reduce(0.0) { $0 + sin(th * Double($1)) / Double($1 * $1) }
        }
        func stepTime(_ bar: Int, _ st: Int) -> Double {
            Double(bar * 16 + st) * step + (st % 2 == 1 ? s.swing * step : 0)
        }
        let barDur = step * 16
        for bar in 0..<bars {
            let (deg, minor) = s.progression[bar % s.progression.count]
            let chordRoot = Double(s.root + deg)
            let tones = [0.0, minor ? 3 : 4, 7, minor ? 10 : 11]       // 7th chords
            let t0 = Double(bar) * barDur
            // pad: 4 voices, slow attack, slight detune spread across the stereo field
            if s.pad > 0 {
                for (v, iv) in tones.enumerated() {
                    let f = hz(chordRoot + 24 + iv)
                    let pan = (Double(v) - 1.5) * 0.3
                    let inc = f * (1 + 0.002 * Double(v)) * Double(tableSize) / sr
                    var phase = 0.0
                    let gain = 0.06 * s.pad
                    table.withUnsafeBufferPointer { tb in
                        add(t0, barDur + 0.6, pan: pan) { t in
                            let envv = min(1, t / 0.35) * (t > barDur ? max(0, 1 - (t - barDur) / 0.6) : 1)
                            let x = tb[Int(phase)]
                            phase += inc; if phase >= Double(tableSize) { phase -= Double(tableSize) }
                            return x * envv * gain
                        }
                    }
                }
            }
            // bass
            for st in s.bass {
                let f = hz(chordRoot)
                add(stepTime(bar, st), step * 2.2) { t in
                    (sin(2 * .pi * f * t) + 0.3 * sin(4 * .pi * f * t)) * exp(-t * 3.5) * min(1, t / 0.004) * 0.32
                }
            }
            // arpeggio (pluck), cycling chord tones over two octaves
            for (k, st) in s.arp.enumerated() {
                let iv = tones[k % tones.count] + (k / tones.count % 2 == 1 ? 12 : 0)
                let f = hz(chordRoot + 36 + iv)
                let pan = sin(Double(k) * 1.3) * 0.4
                add(stepTime(bar, st), 0.5, pan: pan) { t in
                    (sin(2 * .pi * f * t) + 0.35 * s.bright * sin(4 * .pi * f * t) + 0.12 * s.bright * sin(6 * .pi * f * t))
                        * exp(-t * 7) * min(1, t / 0.003) * 0.09
                }
            }
            // drums
            for st in s.kick {
                add(stepTime(bar, st), 0.35) { t in sin(2 * .pi * (45 * t + 90 * (1 - exp(-t * 25)) / 25)) * exp(-t * 9) * 0.55 }
            }
            for st in s.snare {
                var lp = 0.0
                var r = rng
                add(stepTime(bar, st), 0.22) { t in
                    let n = Double(r.next()); lp += 0.5 * (n - lp)
                    return ((n - lp) * 0.8 + sin(2 * .pi * 190 * t) * 0.3) * exp(-t * 18) * 0.28
                }
                rng = r
            }
            for st in s.hats {
                var prev = 0.0
                var r = rng
                add(stepTime(bar, st), 0.06, pan: 0.25) { t in
                    let n = Double(r.next()); let hp = n - prev; prev = n
                    return hp * exp(-t * 70) * 0.07
                }
                rng = r
            }
        }
        // fade out the tail
        let fade = 1.5, total = Double(b.frames) / sr
        let i0 = Int((total - fade) * sr)
        for i in max(0, i0)..<b.frames {
            let g = Float(max(0, 1 - Double(i - i0) / (fade * sr)))
            b[0, i] *= g; b[1, i] *= g
        }
    }
}
