import Foundation
import MontageCore

/// One track of the built-in royalty-free music library (AU-001 substitute). Everything is synthesized by
/// `MusicLibrary` (no samples, no third-party material), so the tracks are free to use in any export.
public struct MusicTrackDescriptor: Sendable, Identifiable {
    public let id: String
    /// "music.track.<id>"
    public let nameKey: String
    /// Localized via "music.genre.<genre>".
    public let genre: String
    /// Localized via "music.mood.<mood>".
    public let mood: String
    public let bpm: Double
    /// Seconds; always a whole number of 4/4 bars.
    public let duration: Double
    /// English search tags (instruments, feel).
    public let tags: [String]

    // Arrangement inputs (internal).
    let key: Int            // tonic pitch class 0 = C
    let minor: Bool
    let progression: [Int]  // scale degrees (0-based), one chord per bar
    let variant: Int
    let bars: Int

    init(_ id: String, mood: String, bpm: Double, key: Int, minor: Bool = false, progression: [Int], variant: Int = 0, tags: [String]) {
        self.id = id
        nameKey = "music.track.\(id)"
        genre = String(id.split(separator: ".").first ?? "")
        self.mood = mood; self.bpm = bpm; self.key = key; self.minor = minor; self.progression = progression
        self.variant = variant; self.tags = tags
        let bar = 240 / bpm
        var n = Int((45 / bar / 4).rounded()) * 4          // phrases of 4 bars, ≈ 45 s
        while Double(n + 1) * bar > 60 { n -= 4 }
        while Double(n + 1) * bar < 30 { n += 4 }
        bars = n + 1                                        // + final cadence bar
        duration = Double(bars) * bar
    }

    /// Seconds per bar.
    var barSeconds: Double { 240 / bpm }
}

/// Built-in procedural music library. Tracks are synthesized once into ~/Library/Caches/Montage/music/<id>-v<version>.wav
/// (48 kHz stereo 16-bit) and then used like any imported audio file. `file(_:)` is CPU-heavy (~0.5–2 s release per
/// track): call it off the main thread.
public enum MusicLibrary {
    public static let version = 1
    public static let artist = "Montage"
    public static let genres = ["pop", "lofi", "cinematic", "hiphop", "electronic", "acoustic", "corporate", "ambient", "chiptune", "jazz"]
    public static let moods = ["happy", "chill", "energetic", "epic", "romantic", "dreamy", "sad", "tense"]

    // Keys: C=0 C#=1 D=2 Eb=3 E=4 F=5 F#=6 G=7 Ab=8 A=9 Bb=10 B=11.
    public static let all: [MusicTrackDescriptor] = [
        // Pop
        .init("pop.sunny", mood: "happy", bpm: 116, key: 0, progression: [0, 4, 5, 3], tags: ["upbeat", "summer", "synth", "bright", "vlog"]),
        .init("pop.roadtrip", mood: "energetic", bpm: 122, key: 7, progression: [0, 5, 3, 4], variant: 1, tags: ["drive", "travel", "upbeat", "pluck"]),
        .init("pop.crush", mood: "romantic", bpm: 104, key: 4, progression: [3, 0, 4, 5], variant: 2, tags: ["love", "sweet", "pad", "soft"]),
        .init("pop.weekend", mood: "happy", bpm: 120, key: 9, progression: [0, 4, 5, 3], variant: 1, tags: ["party", "fun", "dance", "friends"]),
        // Lo-fi
        .init("lofi.rainy", mood: "chill", bpm: 78, key: 2, progression: [1, 4, 0, 5], tags: ["rain", "study", "relax", "piano", "vinyl"]),
        .init("lofi.coffee", mood: "chill", bpm: 85, key: 5, progression: [0, 5, 3, 4], variant: 1, tags: ["morning", "cafe", "beats", "relax"]),
        .init("lofi.night", mood: "sad", bpm: 72, key: 9, minor: true, progression: [0, 5, 2, 6], tags: ["night", "study", "melancholy", "tape"]),
        .init("lofi.tape", mood: "dreamy", bpm: 80, key: 3, progression: [3, 4, 2, 5], variant: 1, tags: ["nostalgia", "vintage", "vinyl", "bell"]),
        // Cinematic
        .init("cinematic.rise", mood: "epic", bpm: 90, key: 2, minor: true, progression: [0, 5, 2, 6], tags: ["trailer", "orchestral", "drums", "heroic"]),
        .init("cinematic.storm", mood: "tense", bpm: 100, key: 0, minor: true, progression: [0, 6, 5, 6], variant: 1, tags: ["suspense", "action", "dark", "strings"]),
        .init("cinematic.horizon", mood: "epic", bpm: 84, key: 5, progression: [0, 4, 5, 3], variant: 2, tags: ["adventure", "inspiring", "brass", "strings"]),
        .init("cinematic.memories", mood: "sad", bpm: 72, key: 9, minor: true, progression: [0, 3, 5, 4], variant: 2, tags: ["emotional", "piano", "strings", "drama"]),
        // Hip-hop
        .init("hiphop.street", mood: "tense", bpm: 90, key: 7, minor: true, progression: [0, 5, 6, 4], tags: ["trap", "808", "urban", "dark"]),
        .init("hiphop.gold", mood: "energetic", bpm: 94, key: 0, minor: true, progression: [0, 3, 5, 6], variant: 1, tags: ["boom bap", "swag", "808", "confident"]),
        .init("hiphop.sunset", mood: "chill", bpm: 86, key: 5, minor: true, progression: [0, 5, 2, 6], variant: 2, tags: ["smooth", "rnb", "relax", "bell"]),
        // Electronic
        .init("electronic.neon", mood: "energetic", bpm: 124, key: 9, minor: true, progression: [0, 5, 2, 6], tags: ["house", "club", "dance", "synth"]),
        .init("electronic.groove", mood: "happy", bpm: 122, key: 5, progression: [0, 4, 5, 3], variant: 1, tags: ["house", "funky", "organ", "dance"]),
        .init("electronic.midnight", mood: "dreamy", bpm: 120, key: 4, minor: true, progression: [0, 6, 5, 6], variant: 2, tags: ["deep house", "night", "pad", "arp"]),
        .init("electronic.pulse", mood: "energetic", bpm: 126, key: 2, minor: true, progression: [0, 3, 6, 5], tags: ["techno", "workout", "drive", "synth"]),
        // Acoustic
        .init("acoustic.meadow", mood: "happy", bpm: 100, key: 7, progression: [0, 4, 5, 3], tags: ["guitar", "folk", "nature", "sunny"]),
        .init("acoustic.porch", mood: "chill", bpm: 92, key: 2, progression: [0, 3, 0, 4], variant: 1, tags: ["guitar", "country", "relax", "warm"]),
        .init("acoustic.letters", mood: "romantic", bpm: 84, key: 0, progression: [5, 3, 0, 4], variant: 2, tags: ["guitar", "love", "wedding", "flute"]),
        .init("acoustic.rain", mood: "sad", bpm: 88, key: 4, minor: true, progression: [0, 5, 2, 6], tags: ["guitar", "melancholy", "rain", "soft"]),
        // Corporate
        .init("corporate.success", mood: "happy", bpm: 116, key: 0, progression: [0, 4, 5, 3], tags: ["business", "presentation", "piano", "positive"]),
        .init("corporate.inspire", mood: "energetic", bpm: 112, key: 2, progression: [5, 3, 0, 4], variant: 1, tags: ["motivation", "uplifting", "pluck", "tech"]),
        .init("corporate.innovation", mood: "happy", bpm: 120, key: 10, progression: [0, 5, 3, 4], variant: 2, tags: ["technology", "startup", "clean", "modern"]),
        // Ambient
        .init("ambient.clouds", mood: "dreamy", bpm: 64, key: 0, progression: [0, 3, 5, 4], tags: ["calm", "meditation", "pad", "space"]),
        .init("ambient.deep", mood: "chill", bpm: 60, key: 2, minor: true, progression: [0, 5, 3, 6], variant: 1, tags: ["ocean", "relax", "drone", "sleep"]),
        .init("ambient.aurora", mood: "dreamy", bpm: 70, key: 4, progression: [0, 5, 3, 3], variant: 2, tags: ["sky", "bell", "float", "night"]),
        // Chiptune
        .init("chiptune.quest", mood: "energetic", bpm: 140, key: 0, progression: [0, 5, 3, 4], tags: ["8-bit", "game", "retro", "adventure"]),
        .init("chiptune.boss", mood: "tense", bpm: 150, key: 9, minor: true, progression: [0, 5, 6, 4], variant: 1, tags: ["8-bit", "game", "battle", "fast"]),
        .init("chiptune.level", mood: "happy", bpm: 132, key: 7, progression: [0, 3, 4, 0], variant: 2, tags: ["8-bit", "game", "cute", "retro"]),
        // Jazz
        .init("jazz.lounge", mood: "chill", bpm: 112, key: 5, progression: [1, 4, 0, 5], tags: ["swing", "lounge", "piano", "bass"]),
        .init("jazz.cafe", mood: "romantic", bpm: 104, key: 10, progression: [1, 4, 0, 0], variant: 1, tags: ["cafe", "dinner", "sax", "smooth"]),
        .init("jazz.bebop", mood: "energetic", bpm: 150, key: 0, progression: [0, 5, 1, 4], variant: 2, tags: ["swing", "fast", "vibes", "walking bass"]),
        .init("jazz.blue", mood: "sad", bpm: 92, key: 2, minor: true, progression: [1, 4, 0, 0], variant: 1, tags: ["blues", "night", "sax", "late"]),
    ]

    public static func track(id: String) -> MusicTrackDescriptor? { all.first { $0.id == id } }

    /// Tests can redirect the cache.
    nonisolated(unsafe) static var directoryOverride: URL?

    public static var directory: URL {
        directoryOverride ?? MontagePaths.cacheDirectory.appendingPathComponent("music", isDirectory: true)
    }

    public static func url(for d: MusicTrackDescriptor) -> URL { directory.appendingPathComponent("\(d.id)-v\(version).wav") }

    public static func isRendered(_ d: MusicTrackDescriptor) -> Bool { FileManager.default.fileExists(atPath: url(for: d).path) }

    private static let fileLock = NSLock()

    /// File for a track, synthesizing it on first use (blocking, CPU-heavy: call off the main thread).
    public static func file(_ d: MusicTrackDescriptor) throws -> URL { try file(d, seconds: nil) }

    static func file(_ d: MusicTrackDescriptor, seconds: Double?) throws -> URL {
        let u = url(for: d)
        if FileManager.default.fileExists(atPath: u.path) { return u }
        let b = render(d, seconds: seconds)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tmp = directory.appendingPathComponent("tmp-\(UUID().uuidString).wav")
        try AudioFileIO.write(b, to: tmp, format: .wav16)
        try fileLock.withLock {
            if FileManager.default.fileExists(atPath: u.path) { try? FileManager.default.removeItem(at: tmp); return }
            try FileManager.default.moveItem(at: tmp, to: u)
        }
        return u
    }

    /// Synthesizes `d` (whole track, or its first `seconds`) into a 48 kHz stereo buffer.
    public static func render(_ d: MusicTrackDescriptor, seconds: Double? = nil) -> AudioBuffer {
        var a = MusicArranger(d)
        return a.render(seconds: seconds)
    }
}

// MARK: - Styles

enum ChordMode { case sustain, stabs, comp, fingerpick, chipArp, pulse8 }
enum BassMode { case whole, roots8, offbeat, eightOhEight, walking, lofi, octaves, rootFifth }
enum DrumKit { case standard, cinematic, chip, brush }

struct DrumPattern {
    var kick = "", snare = "", clap = "", hat = "", openHat = "", ride = "", shaker = "", rim = ""
    var kit: DrumKit = .standard
}

struct MusicStyle {
    var swing16 = 0.0          // fraction of a 16th the off-16ths are delayed by
    var swing8 = 0.0           // fraction of an 8th the off-8ths are delayed by (jazz)
    var humanize = 0.003       // timing jitter (s)
    var drums: DrumPattern?
    var introHats = true
    var chordInst: MusicInst = .epiano
    var chordMode: ChordMode = .sustain
    var chordVel: Float = 0.3
    var sevenths = false
    var strum = 0.0
    var padInst: MusicInst?
    var padVel: Float = 0.15
    var bassInst: MusicInst = .sineBass
    var bassMode: BassMode = .whole
    var bassVel: Float = 0.5
    var leadInst: MusicInst?
    var leadVel: Float = 0.25
    var leadDensity = 0.45
    var leadSixteenths = false
    var leadOctave = 0
    var arpInst: MusicInst?
    var arpVel: Float = 0.14
    var arpRate = 1            // steps (16ths) per arp note
    var reverb: Float = 0.25
    var roomFeedback: Float = 0.8
    var delay: Float = 0
    var sidechain: Float = 0
    var lofi = false
    var fadeIn = 0.03
    /// Bass and chords already in the intro (no-drum genres build from the pad).
    var fullIntro = false

    static func of(_ genre: String, variant v: Int) -> MusicStyle {
        var s = MusicStyle()
        switch genre {
        case "lofi":
            s.swing16 = 0.22; s.humanize = 0.008; s.lofi = true; s.sevenths = true; s.strum = 0.018
            s.drums = DrumPattern(kick: "x......x..x.....", snare: "....x.......x...", hat: "x.o.x.o.x.o.x.oo")
            s.chordInst = .epiano; s.chordVel = 0.38
            s.bassInst = .sineBass; s.bassMode = .lofi; s.bassVel = 0.55
            s.leadInst = v == 1 ? .epiano : .bell; s.leadVel = v == 1 ? 0.3 : 0.2; s.leadDensity = 0.32; s.leadOctave = v == 1 ? 0 : 12
            s.reverb = 0.3; s.delay = 0.12
        case "pop":
            s.drums = DrumPattern(kick: "x.......x.x.....", clap: "....x.......x...", hat: "x.x.x.x.x.x.x.x.", openHat: v == 1 ? "..............x." : "",
                                  shaker: v == 2 ? "" : "oooooooooooooooo")
            s.chordInst = v == 2 ? .epiano : .pluck; s.chordMode = v == 2 ? .sustain : .stabs; s.chordVel = v == 2 ? 0.3 : 0.32
            s.padInst = .pad; s.padVel = 0.16
            s.bassInst = .sawBass; s.bassMode = .roots8; s.bassVel = 0.38
            s.leadInst = v == 1 ? .pluck : .lead; s.leadVel = v == 1 ? 0.34 : 0.2; s.leadDensity = 0.5; s.leadOctave = v == 1 ? 12 : 0
            s.arpInst = v == 0 ? .pluck : nil; s.arpRate = 2
            s.reverb = 0.22; s.delay = 0.16; s.sidechain = 0.3
        case "cinematic":
            s.drums = DrumPattern(kick: v == 1 ? "x..x..x.x..x..x." : "x.......x.....x.", snare: v == 1 ? "....x.......x..." : "", kit: .cinematic)
            s.introHats = false; s.fullIntro = true
            s.chordInst = .strings; s.chordVel = 0.34
            s.padInst = .pad; s.padVel = 0.14
            s.bassInst = .sineBass; s.bassMode = .whole; s.bassVel = 0.45
            s.leadInst = v == 2 ? .epiano : .brass; s.leadVel = v == 2 ? 0.34 : 0.26; s.leadDensity = 0.22
            s.arpInst = v == 2 ? nil : .pluck; s.arpVel = 0.15; s.arpRate = 1
            s.reverb = 0.45; s.roomFeedback = 0.86
        case "hiphop":
            s.swing16 = 0.12; s.humanize = 0.004
            s.drums = DrumPattern(kick: "x......x.xx.....", snare: v == 1 ? "....x.......x..." : "", clap: v == 1 ? "" : "....x.......x...",
                                  hat: v == 0 ? "x.x.x.x.x.x.xxxx" : "x.x.x.x.x.x.x.x.")
            s.chordInst = v == 2 ? .epiano : .bell; s.chordVel = v == 2 ? 0.3 : 0.2; s.sevenths = v == 2
            s.padInst = .pad; s.padVel = 0.14
            s.bassInst = .sub808; s.bassMode = .eightOhEight; s.bassVel = 0.7
            s.leadInst = v == 1 ? .flute : .bell; s.leadVel = 0.2; s.leadDensity = 0.3; s.leadOctave = v == 1 ? 0 : 12
            s.reverb = 0.2
        case "electronic":
            s.drums = DrumPattern(kick: "x...x...x...x...", clap: "....x.......x...", hat: "o.o.o.o.o.o.o.o.", openHat: "..x...x...x...x.")
            s.chordInst = v == 1 ? .organ : .pad; s.chordMode = v == 1 ? .stabs : .sustain; s.chordVel = v == 1 ? 0.34 : 0.3
            s.padInst = v == 1 ? .pad : nil; s.padVel = 0.12
            s.bassInst = .sawBass; s.bassMode = .offbeat; s.bassVel = 0.45
            s.leadInst = v == 2 ? .bell : .lead; s.leadVel = 0.2; s.leadDensity = 0.45
            s.arpInst = .pluck; s.arpVel = 0.15; s.arpRate = v == 2 ? 2 : 1
            s.reverb = 0.22; s.delay = 0.18; s.sidechain = 0.6
        case "ambient":
            s.drums = nil; s.fullIntro = true; s.sevenths = true; s.fadeIn = 3
            s.chordInst = .pad; s.chordVel = 0.34
            s.padInst = .strings; s.padVel = 0.12
            s.bassInst = .sineBass; s.bassMode = .whole; s.bassVel = 0.3
            s.leadInst = v == 1 ? .flute : .bell; s.leadVel = 0.18; s.leadDensity = 0.18; s.leadOctave = v == 1 ? 0 : 12
            s.arpInst = .bell; s.arpVel = 0.08; s.arpRate = 2
            s.reverb = 0.6; s.roomFeedback = 0.88; s.delay = 0.25
        case "acoustic":
            s.humanize = 0.006
            s.drums = DrumPattern(kick: "x.......x.......", shaker: "oxoooxoooxoooxoo", rim: "....x.......x...")
            s.chordInst = .guitar; s.chordMode = .fingerpick; s.chordVel = 0.45
            s.bassInst = .upright; s.bassMode = .rootFifth; s.bassVel = 0.45
            s.leadInst = v == 2 ? .flute : (v == 1 ? .bell : .guitar); s.leadVel = v == 0 ? 0.4 : 0.2; s.leadDensity = 0.35
            s.leadOctave = v == 1 ? 12 : 0
            s.reverb = 0.22
        case "corporate":
            s.drums = DrumPattern(kick: "x.......x.......", clap: "....x.......x...", shaker: "oooooooooooooooo")
            s.chordInst = .epiano; s.chordMode = .pulse8; s.chordVel = 0.22
            s.padInst = .pad; s.padVel = 0.14
            s.bassInst = .sawBass; s.bassMode = .roots8; s.bassVel = 0.32
            s.leadInst = v == 1 ? .pluck : .bell; s.leadVel = v == 1 ? 0.3 : 0.2; s.leadDensity = 0.4; s.leadOctave = 12
            s.arpInst = .pluck; s.arpVel = 0.13; s.arpRate = 2
            s.reverb = 0.25; s.delay = 0.14; s.sidechain = 0.2
        case "chiptune":
            s.drums = DrumPattern(kick: "x.......x.x.....", snare: "....x.......x...", hat: "x.x.x.x.x.x.x.x.", kit: .chip)
            s.chordInst = .pulse; s.chordMode = .chipArp; s.chordVel = 0.2
            s.bassInst = .triangle; s.bassMode = .octaves; s.bassVel = 0.55
            s.leadInst = .square; s.leadVel = 0.24; s.leadDensity = 0.6; s.leadSixteenths = v == 1
            s.reverb = 0.05; s.delay = 0.1
        case "jazz":
            s.swing8 = 0.33; s.humanize = 0.009; s.sevenths = true
            s.drums = DrumPattern(kick: "o.......o.......", snare: v == 2 ? "......o.......o." : "", hat: "....x.......x...", ride: "x...x.x.x...x.x.", kit: .brush)
            s.chordInst = .epiano; s.chordMode = .comp; s.chordVel = 0.3
            s.bassInst = .upright; s.bassMode = .walking; s.bassVel = 0.55
            s.leadInst = v == 1 ? .brass : .bell; s.leadVel = v == 1 ? 0.24 : 0.24; s.leadDensity = v == 2 ? 0.6 : 0.45
            s.leadSixteenths = false
            s.reverb = 0.2
        default: break
        }
        return s
    }
}

// MARK: - Arranger

struct MusicArranger {
    let d: MusicTrackDescriptor
    let style: MusicStyle
    var rng: MusicRNG
    let step: Double              // 16th seconds
    let scale: [Int]
    let tonic: Int                // MIDI of the tonic around C3

    init(_ d: MusicTrackDescriptor) {
        self.d = d
        style = MusicStyle.of(d.genre, variant: d.variant)
        rng = MusicRNG(musicSeed(d.id))
        step = 60 / d.bpm / 4
        scale = d.minor ? [0, 2, 3, 5, 7, 8, 10] : [0, 2, 4, 5, 7, 9, 11]
        tonic = 48 + d.key
    }

    func pitch(_ degree: Int, base: Int) -> Int {
        let o = Int((Double(degree) / 7).rounded(.down))
        return base + 12 * o + scale[((degree % 7) + 7) % 7]
    }

    @inline(__always) func fold(_ m: Int, _ lo: Int) -> Int {
        var m = m
        while m < lo { m += 12 }
        while m >= lo + 12 { m -= 12 }
        return m
    }

    func chordDegree(_ bar: Int) -> Int { bar == d.bars - 1 ? 0 : d.progression[bar % d.progression.count] }

    /// Chord tones (MIDI, ascending) voiced in [lo, lo+12).
    func chordTones(_ bar: Int, lo: Int = 55) -> [Int] {
        let deg = chordDegree(bar)
        var ds = [deg, deg + 2, deg + 4]
        if style.sevenths && bar != d.bars - 1 { ds.append(deg + 6) }
        return ds.map { fold(pitch($0, base: tonic), lo) }.sorted()
    }

    /// Timeline seconds of a 16th step within a bar (swing applied).
    func time(_ bar: Int, _ s: Double) -> Double {
        var t = (Double(bar) * 16 + s) * step
        let si = Int(s)
        if Double(si) == s {
            if style.swing16 > 0, si % 2 == 1 { t += style.swing16 * step }
            if style.swing8 > 0, si % 4 == 2 { t += style.swing8 * 2 * step }
        }
        return t
    }

    mutating func jitter() -> Double { style.humanize > 0 ? rng.range(-style.humanize, style.humanize) : 0 }

    /// 0 = final cadence, 1 = intro / breakdown, 2 = medium, 3 = full.
    func energy(_ bar: Int) -> Int {
        let n = d.bars
        if bar == n - 1 { return 0 }
        if bar < 2 { return 1 }
        if n >= 20 {
            let bd = ((n - 1) * 3 / 5) / 4 * 4
            if bar >= bd && bar < bd + 2 { return 1 }
        }
        if bar >= n - 3 { return 2 }
        return bar < 4 || bar / 4 == 1 ? 2 : 3
    }

    // MARK: Melody

    struct MotifNote { var step: Int; var len: Int; var off: Int }

    mutating func motif(cadence: Bool) -> [MotifNote] {
        let grid = style.leadSixteenths ? 1 : 2
        var onsets = [0]
        var s = grid
        while s < 32 {
            let strong = s % 8 == 0
            if rng.chance(strong ? min(1, style.leadDensity + 0.3) : style.leadDensity) { onsets.append(s) }
            s += grid
        }
        if cadence {
            onsets = onsets.filter { $0 < 24 }
            onsets.append(24)
        }
        var out: [MotifNote] = []
        var prev = rng.pick([0, 2, 4])
        for (i, o) in onsets.enumerated() {
            let next = i + 1 < onsets.count ? onsets[i + 1] : 32
            var len = min(next - o, 8)
            if i == onsets.count - 1 { len = cadence ? 32 - o : min(32 - o, 6) }
            var off: Int
            if cadence && i == onsets.count - 1 {
                off = rng.pick([0, 7])
            } else if o % 8 == 0 {
                let options = [-3, 0, 2, 4, 7]
                off = options.min { abs($0 - prev) < abs($1 - prev) }!
                if rng.chance(0.3) { off = rng.pick([0, 2, 4]) }
            } else {
                off = max(-3, min(9, prev + rng.pick([-2, -1, -1, 1, 1, 2])))
            }
            // occasional rests keep phrases breathing
            if i > 0, !(cadence && i == onsets.count - 1), rng.chance((1 - style.leadDensity) * 0.25) { prev = off; continue }
            out.append(MotifNote(step: o, len: max(1, len), off: off))
            prev = off
        }
        return out
    }

    // MARK: Score

    mutating func score() -> (notes: [MusicNote], hits: [DrumHit]) {
        var notes: [MusicNote] = []
        var hits: [DrumHit] = []
        let st = style
        let barLen = d.barSeconds
        let n = d.bars
        let motifA = motif(cadence: false), motifB = motif(cadence: true), motifC = motif(cadence: true)
        var leadBase = 60 + d.key
        if leadBase < 62 { leadBase += 12 }
        leadBase += st.leadOctave
        let leadRev: Float = st.reverb > 0.4 ? 0.5 : 0.3
        let leadDelay: Float = st.delay > 0 ? 0.6 : 0

        for bar in 0..<n {
            let e = energy(bar)
            let tones = chordTones(bar)
            let deg = chordDegree(bar)
            let t0 = Double(bar) * barLen
            let isLast = bar == n - 1
            let root = pitch(deg, base: tonic)

            // Pad layer
            if let pad = st.padInst, e >= 1 || isLast {
                for (k, m) in tones.enumerated() {
                    notes.append(MusicNote(start: t0, length: isLast ? barLen * 0.9 : barLen * 1.0, midi: Double(m - (pad == .strings ? 0 : 12)),
                                           velocity: st.padVel * (e == 3 ? 1 : 0.8), inst: pad, pan: k % 2 == 0 ? -0.55 : 0.55, reverb: 0.5))
                }
            }

            // Chords
            let cv = st.chordVel * (e == 3 ? 1 : (e == 2 ? 0.9 : 0.8))
            func chordNote(_ s: Double, _ len: Double, _ m: Int, _ k: Int, _ v: Float) {
                let spread = Float(k) / Float(max(1, tones.count - 1)) * 0.6 - 0.3
                notes.append(MusicNote(start: max(0, time(bar, s) + Double(k) * st.strum), length: len, midi: Double(m), velocity: v,
                                       inst: st.chordInst, pan: spread, reverb: 0.3))
            }
            switch isLast ? .sustain : st.chordMode {
            case .sustain:
                for (k, m) in tones.enumerated() { chordNote(0, isLast ? barLen * 0.9 : barLen * 0.98, m, k, cv) }
            case .stabs:
                let steps: [Double] = d.variant == 0 ? [0, 3, 6, 10, 12] : [2, 6, 10, 14]
                for s in steps { for (k, m) in tones.enumerated() { chordNote(s, step * 1.6, m, k, cv * (s == 0 ? 1 : 0.85)) } }
            case .comp:
                let patterns: [[Double]] = [[0, 6], [3, 10], [2, 8, 14], [0, 7, 11], [4, 10]]
                let p = patterns[rng.int(patterns.count)]
                for s in p { for (k, m) in tones.enumerated() { chordNote(s, step * rng.range(1.5, 3), m, k, cv * Float(rng.range(0.8, 1))) } }
            case .fingerpick:
                let low = fold(root, 43)
                let seq = [low, tones[0], tones.count > 1 ? tones[1] : tones[0], tones.last! + (tones.last! < 64 ? 12 : 0)]
                let order = [0, 2, 1, 3, 2, 1, 3, 2]
                for (j, o) in order.enumerated() {
                    notes.append(MusicNote(start: time(bar, Double(j * 2)) + jitter(), length: step * 5, midi: Double(seq[o]),
                                           velocity: cv * (j % 4 == 0 ? 1 : 0.75), inst: .guitar, pan: o == 0 ? 0 : (o % 2 == 0 ? -0.3 : 0.3), reverb: 0.3))
                }
            case .chipArp:
                let arp = tones + [tones[0] + 12]
                for j in 0..<32 {
                    notes.append(MusicNote(start: time(bar, Double(j) * 0.5), length: step * 0.45, midi: Double(arp[j % arp.count] + 12),
                                           velocity: cv, inst: .pulse, pan: -0.2, reverb: 0.05))
                }
            case .pulse8:
                for j in 0..<8 { for (k, m) in tones.enumerated() { chordNote(Double(j * 2), step * 1.7, m + 12 > 76 ? m : m + 12, k, cv * (j % 2 == 0 ? 1 : 0.7)) } }
            }

            // Bass
            let bassOn = e >= 2 || isLast || (st.fullIntro && bar >= 1) || (e == 1 && bar >= 2)
            if bassOn {
                let r = fold(root, st.bassInst == .sub808 ? 34 : 36)
                let fifth = fold(pitch(deg + 4, base: tonic), r)
                let bv = st.bassVel
                func bass(_ s: Double, _ len: Double, _ m: Int, _ v: Float = 1) {
                    notes.append(MusicNote(start: time(bar, s), length: len, midi: Double(m), velocity: bv * v, inst: st.bassInst, pan: 0, reverb: 0.02))
                }
                switch isLast ? .whole : st.bassMode {
                case .whole: bass(0, barLen * 0.95, r)
                case .roots8: for j in 0..<8 { bass(Double(j * 2), step * 1.7, j == 7 && rng.chance(0.5) ? r + 12 : r, j % 2 == 0 ? 1 : 0.8) }
                case .offbeat: for s in [2.0, 6, 10, 14] { bass(s, step * 1.5, r) }
                case .eightOhEight:
                    let ks = (st.drums?.kick ?? "x").enumerated().filter { $0.element != "." }.map { $0.offset }
                    for (j, s) in ks.enumerated() {
                        let next = j + 1 < ks.count ? ks[j + 1] : 16
                        let m = j == ks.count - 1 && rng.chance(0.4) ? fifth : r
                        bass(Double(s), step * Double(next - s) * 0.95, m)
                    }
                case .walking:
                    let nextRoot = fold(pitch(chordDegree(bar + 1), base: tonic), 36)
                    let third = fold(pitch(deg + 2, base: tonic), r)
                    let line = [r, rng.chance(0.5) ? third : fifth, rng.chance(0.5) ? fifth : third, nextRoot + (rng.chance(0.5) ? 1 : -1)]
                    for (j, m) in line.enumerated() { bass(Double(j * 4), step * 3.6, m, j == 0 ? 1 : 0.85) }
                case .lofi: bass(0, step * 6.5, r); bass(10, step * 4, rng.chance(0.5) ? fifth : r, 0.85)
                case .octaves: for j in 0..<8 { bass(Double(j * 2), step * 1.6, j % 2 == 0 ? r : r + 12) }
                case .rootFifth: bass(0, step * 7.5, r); bass(8, step * 7.5, fifth, 0.85)
                }
            }

            // Arpeggio
            if let arpInst = st.arpInst, (e == 3 || (st.fullIntro && e >= 1 && bar >= 2)) && !isLast {
                let arp = chordTones(bar, lo: 62) + [chordTones(bar, lo: 62)[0] + 12]
                let count = 16 / st.arpRate
                let up = [0, 1, 2, 3, 2, 1]
                for j in 0..<count {
                    let m = arp[up[j % up.count] % arp.count]
                    notes.append(MusicNote(start: time(bar, Double(j * st.arpRate)), length: step * Double(st.arpRate) * 0.8, midi: Double(m),
                                           velocity: st.arpVel * (j % 4 == 0 ? 1 : 0.8), inst: arpInst, pan: j % 2 == 0 ? -0.45 : 0.45,
                                           reverb: 0.35, delay: st.delay > 0 ? 0.4 : 0))
                }
            }

            // Lead
            if let leadInst = st.leadInst, e >= 2, bar >= 4, !isLast {
                let phrase = bar / 4, local = bar % 4
                let second = phrase % 2 == 0 ? motifB : motifC
                let notesHere: [MotifNote] = local < 2 ? motifA.filter { $0.step / 16 == local } : second.filter { $0.step / 16 == local - 2 }
                for mn in notesHere {
                    let s = Double(mn.step % 16)
                    let m = pitch(deg + mn.off, base: leadBase)
                    notes.append(MusicNote(start: max(0, time(bar, s) + jitter()), length: step * Double(mn.len) * 0.92, midi: Double(m),
                                           velocity: st.leadVel * Float(rng.range(0.85, 1)), inst: leadInst, pan: 0.12,
                                           reverb: leadRev, delay: leadDelay))
                }
            }

            // Drums
            if let dp = st.drums {
                hits += drums(dp, bar: bar, energy: e)
            }
        }
        return (notes, hits)
    }

    mutating func drums(_ p: DrumPattern, bar: Int, energy e: Int) -> [DrumHit] {
        var out: [DrumHit] = []
        let kit = p.kit
        func kind(_ k: DrumKind) -> DrumKind {
            switch (kit, k) {
            case (.cinematic, .kick): return .taiko
            case (.chip, .kick): return .chipKick
            case (.chip, .snare), (.chip, .clap): return .chipSnare
            case (.chip, .hat), (.chip, .openHat), (.chip, .shaker): return .chipHat
            case (.brush, .snare): return .brush
            default: return k
            }
        }
        func lane(_ pat: String, _ k: DrumKind, _ vel: Float, pan: Float = 0) {
            for (i, c) in pat.enumerated() where c != "." {
                let v: Float = c == "x" ? vel : vel * 0.55
                out.append(DrumHit(time: max(0, time(bar, Double(i)) + jitter() * 0.5), kind: kind(k), velocity: v * Float(rng.range(0.9, 1)), pan: pan))
            }
        }
        if e == 0 {
            out.append(DrumHit(time: time(bar, 0), kind: kind(.kick), velocity: 0.9))
            if kit != .brush { out.append(DrumHit(time: time(bar, 0), kind: kit == .chip ? .chipSnare : .crash, velocity: 0.6, pan: 0.2)) }
            return out
        }
        if e == 1 {
            guard style.introHats, bar >= 1 || kit == .brush else { return out }
            lane(p.hat, .hat, 0.5, pan: 0.25); lane(p.shaker, .shaker, 0.6, pan: -0.25); lane(p.ride, .ride, 0.5, pan: 0.3)
            return out
        }
        let fill = e == 3 && bar % 4 == 3 && rng.chance(0.6)
        lane(p.kick, .kick, kit == .brush ? 0.45 : 0.95)
        lane(fill ? String(p.snare.prefix(12)) : p.snare, .snare, kit == .brush ? 0.6 : 0.8)
        lane(fill ? String(p.clap.prefix(12)) : p.clap, .clap, 0.75)
        lane(p.rim, .rim, 0.6, pan: -0.15)
        lane(p.hat, .hat, 0.55, pan: 0.25)
        lane(p.shaker, .shaker, 0.6, pan: -0.25)
        lane(p.ride, .ride, 0.55, pan: 0.3)
        if e == 3 { lane(p.openHat, .openHat, 0.5, pan: 0.2) }
        if e == 3 && bar % 4 == 0 && kit != .brush { out.append(DrumHit(time: time(bar, 0), kind: kit == .chip ? .chipSnare : .crash, velocity: 0.55, pan: -0.2)) }
        if fill {
            for (j, s) in [12.0, 13, 14, 15].enumerated() {
                out.append(DrumHit(time: time(bar, s), kind: kind(kit == .cinematic ? .kick : .snare), velocity: 0.45 + 0.12 * Float(j)))
            }
        }
        return out
    }

    // MARK: Render

    mutating func render(seconds: Double?) -> AudioBuffer {
        let sr = 48000.0
        let full = d.duration
        let total = min(full, seconds ?? full)
        let frames = Int(total * sr)
        let (notes, hits) = score()
        let music = MusicBus(frames: frames)
        let drumsBus = MusicBus(frames: frames, sharing: music)
        for (i, n) in notes.enumerated() { MusicVoices.render(n, into: music, seed: UInt32(truncatingIfNeeded: i &* 7919 &+ 17)) }
        for (i, h) in hits.enumerated() { MusicVoices.drum(h, into: drumsBus, seed: UInt32(truncatingIfNeeded: i &* 104_729 &+ 3)) }

        let out = AudioBuffer(channels: 2, frames: frames, sampleRate: sr)
        let L = out.pointer(0), R = out.pointer(1)

        // Sidechain pumping from the kicks.
        let kicks = hits.filter { $0.kind == .kick || $0.kind == .chipKick }.map { Int($0.time * sr) }.sorted()
        var ki = 0, lastKick = -1_000_000
        let depth = style.sidechain, scTau = Float(0.13 * sr)
        for i in 0..<frames {
            while ki < kicks.count && kicks[ki] <= i { lastKick = kicks[ki]; ki += 1 }
            var g: Float = 1
            if depth > 0 { g = 1 - depth * exp(-Float(i - lastKick) / scTau) }
            L[i] = music.L[i] * g + drumsBus.L[i]
            R[i] = music.R[i] * g + drumsBus.R[i]
        }
        MusicMaster.reverb(music.S, frames: frames, into: out, wet: style.reverb, feedback: style.roomFeedback)
        MusicMaster.pingPong(music.D, frames: frames, into: out, delaySeconds: step * 3, feedback: 0.38, wet: style.delay)
        master(out, frames: frames)
        return out
    }

    /// Lo-fi colour, compressor, soft clip, fades, −1 dBFS peak normalization.
    mutating func master(_ out: AudioBuffer, frames: Int) {
        let sr: Float = 48000
        let L = out.pointer(0), R = out.pointer(1)
        if style.lofi {
            var noise = Noise32(UInt32(truncatingIfNeeded: musicSeed(d.id)))
            var l1: Float = 0, l2: Float = 0, r1: Float = 0, r2: Float = 0, hiss: Float = 0
            let a = MusicVoices.coef(4200)
            for i in 0..<frames {
                l1 += a * (L[i] - l1); l2 += a * (l1 - l2)
                r1 += a * (R[i] - r1); r2 += a * (r1 - r2)
                let nz = noise.next()
                hiss += 0.15 * (nz - hiss)
                var crackle: Float = 0
                if nz > 0.9993 { crackle = noise.next() * 0.25 }
                L[i] = l2 + hiss * 0.006 + crackle
                R[i] = r2 + hiss * 0.006 + crackle * 0.8
            }
        }
        // Compressor (stereo-linked, peak follower).
        var env: Float = 0
        let att = exp(-1 / (0.005 * sr)), rel = exp(-1 / (0.15 * sr))
        var peak: Float = 0
        for i in 0..<frames { peak = max(peak, abs(L[i]), abs(R[i])) }
        let th = max(peak * 0.35, 1e-6), ratio: Float = 3
        for i in 0..<frames {
            let x = max(abs(L[i]), abs(R[i]))
            env = x > env ? att * env + (1 - att) * x : rel * env + (1 - rel) * x
            let g: Float = env > th ? pow(th / env, 1 - 1 / ratio) : 1
            L[i] *= g; R[i] *= g
        }
        // Soft clip after normalizing the hottest peak to ~1.
        peak = 0
        for i in 0..<frames { peak = max(peak, abs(L[i]), abs(R[i])) }
        let pre: Float = peak > 0 ? 1.1 / peak : 1
        for i in 0..<frames { L[i] = tanh(L[i] * pre); R[i] = tanh(R[i] * pre) }
        // Fades.
        let fin = max(1, Int(style.fadeIn * Double(sr)))
        for i in 0..<min(fin, frames) { let g = Float(i) / Float(fin); L[i] *= g; R[i] *= g }
        let totalFrames = Int(d.duration * Double(sr))
        let foutStart = totalFrames - Int(2.5 * sr)
        if frames > foutStart {
            for i in max(0, foutStart)..<frames {
                let x = Float(i - foutStart) / Float(totalFrames - foutStart)
                let g = 0.5 + 0.5 * cos(Float.pi * min(1, x))
                L[i] *= g; R[i] *= g
            }
        }
        // −1 dBFS
        peak = 0
        for i in 0..<frames { peak = max(peak, abs(L[i]), abs(R[i])) }
        if peak > 0 {
            let g = 0.89 / peak
            for i in 0..<frames { L[i] *= g; R[i] *= g }
        }
    }
}
