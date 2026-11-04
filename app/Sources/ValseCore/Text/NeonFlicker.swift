import Foundation

// TX-NEON flicker, modelled on real signs: a lit tube is steady (mains flicker is invisible). What reads as "neon"
// is the rare failure: the whole sign stutters while the transformer re-ignites it, or one tired letter / segment
// stutters and sometimes dies for a moment. Each dropout decays over ~45 ms (afterglow), stays down a few frames,
// relights in ~1 frame. Every dropout stays below half brightness ≥ 2 frames at 30 fps (no single-frame aliasing).
//
// Pure function of (mode, clip-local time, seed): preview frame == exported frame. Events are generated per 60 s
// epoch (deterministic RNG seeded by the epoch), so evaluating a time costs a handful of events whatever the clip
// length.

extension TextNeonStyle {
    /// Tube brightness 0…1 at clip-local time `t` (seconds). `faulty`: this unit is the faulty letter / tube (One
    /// letter mode; units that are not faulty stay at exactly 1). Whole text ignores it: every unit shares the level.
    /// `seed`: per-text variation (`flickerSeed(_:)`), so two signs don't stutter in sync.
    public static func flickerLevel(_ mode: TextNeonFlicker, t: Double, faulty: Bool = true, seed: UInt64 = 0) -> Double {
        switch mode {
        case .off: return 1
        case .wholeText: return NeonFlickerEnvelope.level(t: t, profile: .whole, seed: seed)
        case .oneLetter: return faulty ? NeonFlickerEnvelope.level(t: t, profile: .faulty, seed: seed) : 1
        }
    }

    /// Level of glyph `unit` given the text's faulty unit (`faultyUnit(in:)`).
    public static func flickerLevel(_ mode: TextNeonFlicker, t: Double, unit: Int, faultyUnit: Int?, seed: UInt64 = 0) -> Double {
        flickerLevel(mode, t: t, faulty: unit == faultyUnit, seed: seed)
    }

    /// The faulty letter of One letter mode among `candidates` (visible-character indices of letters / digits, in
    /// reading order): the one around 60 % of the way through, the same every time for a given text.
    public static func faultyUnit(candidates: [Int]) -> Int? {
        guard !candidates.isEmpty else { return nil }
        return candidates[Int((Double(candidates.count - 1) * 0.6).rounded())]
    }

    /// `faultyUnit(candidates:)` for a plain string: visible-character index = index among non-whitespace characters
    /// (as the text layout counts them); spaces and punctuation are never faulty.
    public static func faultyUnit(in string: String) -> Int? {
        var vis = 0
        var cands: [Int] = []
        for ch in string where !ch.isWhitespace {
            if ch.isLetter || ch.isNumber { cands.append(vis) }
            vis += 1
        }
        return faultyUnit(candidates: cands)
    }

    /// Stable seed of a text (FNV-1a of its UTF-8, never Swift's per-process `hashValue`).
    public static func flickerSeed(_ string: String) -> UInt64 {
        var h: UInt64 = 0xCBF29CE484222325
        for b in string.utf8 { h = (h ^ UInt64(b)) &* 0x100000001B3 }
        return h
    }
}

/// The flicker envelope: a sequence of events (stutters of dropouts, brownouts) separated by long steady gaps.
enum NeonFlickerEnvelope {
    enum Profile { case whole, faulty }

    /// One dropout: decay to `floor`, hold `off`, relight.
    struct Dropout { var start: Double; var floor: Double; var off: Double }

    static let decay = 0.045, relight = 0.017, epoch = 60.0

    /// SplitMix64.
    struct RNG {
        var s: UInt64
        mutating func next() -> Double {
            s &+= 0x9E3779B97F4A7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            z ^= z >> 31
            return Double(z >> 11) / Double(1 << 53)
        }
        mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * next() }
        mutating func int(_ a: Int, _ b: Int) -> Int { min(a + Int(next() * Double(b - a + 1)), b) }
    }

    static func level(t: Double, profile: Profile, seed: UInt64) -> Double {
        guard t.isFinite, t >= 0 else { return 1 }
        let e = Int(t / epoch)
        let t0 = Double(e) * epoch
        var r = RNG(s: seed ^ (UInt64(e) &* 0xD1B54A32D192ED03) ^ (profile == .whole ? 0x57 : 0xFA17))
        _ = r.next()
        // first event: never in the first second of the clip; later epochs pick up mid-gap
        var cursor = t0 + (e == 0 ? (profile == .whole ? r.range(1.0, 3.0) : r.range(0.6, 2.0))
                                 : (profile == .whole ? r.range(1.5, 4.0) : r.range(0.8, 2.5)))
        let end = t0 + epoch - 0.5
        while cursor < end {
            if t < cursor { return 1 }
            let ev = event(at: cursor, profile: profile, &r)
            if ev.end > end { return 1 }   // events never straddle an epoch
            if t < ev.end { return ev.level(t) }
            cursor = ev.end + (profile == .whole ? r.range(3.0, 7.0) : r.range(1.5, 4.0))
        }
        return 1
    }

    struct Event {
        var dropouts: [Dropout] = []
        /// Soft dip instead of dropouts: start, duration, depth.
        var brownout: (start: Double, length: Double, depth: Double)?
        var end: Double

        func level(_ t: Double) -> Double {
            if let b = brownout {
                let x = (t - b.start) / b.length
                guard x > 0, x < 1 else { return 1 }
                let s = sin(.pi * x)
                return 1 - b.depth * s * s
            }
            for d in dropouts {
                let tau = t - d.start
                if tau < 0 { return 1 }
                if tau < decay {   // fast drop then an afterglow tail
                    let x = 1 - tau / decay
                    return d.floor + (1 - d.floor) * x * x
                }
                if tau < decay + d.off { return d.floor }
                if tau < decay + d.off + relight { return d.floor + (1 - d.floor) * (tau - decay - d.off) / relight }
            }
            return 1
        }
    }

    /// A burst of `n` dropouts from `start`; lit gaps between them are a couple of frames.
    static func stutter(_ n: Int, from start: Double, floor: ClosedRange<Double>, _ r: inout RNG,
                        into ds: inout [Dropout]) -> Double {
        var s = start
        for i in 0..<n {
            let off = r.range(0.04, 0.065)
            ds.append(Dropout(start: s, floor: r.range(floor.lowerBound, floor.upperBound), off: off))
            s += decay + off + relight
            if i < n - 1 { s += r.range(0.035, 0.075) }
        }
        return s
    }

    static func event(at start: Double, profile: Profile, _ r: inout RNG) -> Event {
        var ds: [Dropout] = []
        switch profile {
        case .whole:
            if r.next() < 0.2 {   // brownout: the whole sign sags softly
                let len = r.range(0.22, 0.3)
                return Event(brownout: (start, len, r.range(0.35, 0.45)), end: start + len)
            }
            let end = stutter(r.int(2, 4), from: start, floor: 0.05...0.2, &r, into: &ds)
            return Event(dropouts: ds, end: end)
        case .faulty:
            if r.next() < 0.3 {   // the letter dies for a moment, then relights with a stutter
                var s = stutter(r.int(1, 2), from: start, floor: 0.03...0.15, &r, into: &ds)
                s += r.range(0.04, 0.07)
                let dead = r.range(0.6, 1.5)
                ds.append(Dropout(start: s, floor: 0.02, off: dead))
                s += decay + dead + relight + r.range(0.04, 0.07)
                let end = stutter(r.int(1, 2), from: s, floor: 0.02...0.1, &r, into: &ds)
                return Event(dropouts: ds, end: end)
            }
            let end = stutter(r.int(2, 4), from: start, floor: 0.03...0.15, &r, into: &ds)
            return Event(dropouts: ds, end: end)
        }
    }
}
