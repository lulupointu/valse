import Foundation
import ValseCore

/// Parameter of a voice preset. Values are 0…100 like CapCut's sliders; 50 = the preset's designed sound for
/// pitch/timbre, 100 = full strength for "strength"-type parameters.
public struct VoiceParamSpec: Sendable, Hashable {
    public let key: String
    public let nameKey: String
    public let defaultValue: Double
    public init(_ key: String, default d: Double) { self.key = key; nameKey = "voice.param.\(key)"; defaultValue = d }
    public static let pitch = VoiceParamSpec("pitch", default: 50)
    public static let timbre = VoiceParamSpec("timbre", default: 50)
    public static let strength = VoiceParamSpec("strength", default: 100)
    public static let room = VoiceParamSpec("room", default: 50)
}

public enum VoiceCategory: String, Sendable, CaseIterable {
    /// "Voice filters"
    case filter
    /// "Voice characters" (DSP approximations of CapCut's AI voices: pitch + formant + colour)
    case character
    public var nameKey: String { "voice.category.\(rawValue)" }
}

/// What a preset does: an offline-rendered part (pitch/formant/robot…) and a live chain.
public struct VoiceDesign: Sendable, Hashable {
    public var pitchSemitones: Double = 0
    /// Formant ratio (1 = keep timbre, > 1 = smaller/younger, < 1 = bigger/deeper).
    public var formant: Double = 1
    /// Extra pitch-shifted voices mixed with the dry voice (semitones), e.g. a major chord.
    public var harmony: [Double] = []
    public var robotHz: Double?
    public var whisper = false
    public var denoise: Double?
    public var live: [LiveNode] = []
    public init() {}
}

/// A voice changer preset ("Voice filters" / "Voice characters").
public struct VoiceEffectDescriptor: Sendable, Identifiable {
    public let id: String
    public let nameKey: String
    public let category: VoiceCategory
    /// SF Symbol for the tile.
    public let symbol: String
    public let params: [VoiceParamSpec]
    let design: @Sendable ([String: Double]) -> VoiceDesign

    public func makeEffect() -> VoiceEffect {
        VoiceEffect(typeID: id, params: Dictionary(uniqueKeysWithValues: params.map { ($0.key, $0.defaultValue) }))
    }
    public func design(for effect: VoiceEffect) -> VoiceDesign {
        var p = Dictionary(uniqueKeysWithValues: params.map { ($0.key, $0.defaultValue) })
        for (k, v) in effect.params { p[k] = v }
        return design(p)
    }
}

/// Registry of voice changer presets (AU-011). Add a preset with ONE entry in `filters` or `characters` plus its
/// name in Audio.strings (en + fr).
public enum VoiceEffects {
    public static var all: [VoiceEffectDescriptor] { filters + characters }
    public static func descriptor(_ id: String) -> VoiceEffectDescriptor? { byID[id] }
    private static let byID: [String: VoiceEffectDescriptor] = Dictionary(uniqueKeysWithValues: (filters + characters).map { ($0.id, $0) })

    // MARK: helpers

    /// Strength 0…1 from params.
    static func s(_ p: [String: Double]) -> Double { min(max((p["strength"] ?? 100) / 100, 0), 1) }
    /// Pitch slider (0…100, 50 = designed) → semitones offset ±6.
    static func dp(_ p: [String: Double]) -> Double { ((p["pitch"] ?? 50) - 50) / 50 * 6 }
    /// Timbre slider → formant multiplier ×/÷ 1.41.
    static func dt(_ p: [String: Double]) -> Double { pow(2, ((p["timbre"] ?? 50) - 50) / 50 * 0.5) }
    static func room(_ p: [String: Double]) -> Double { min(max((p["room"] ?? 50) / 100, 0), 1) }

    static func fx(_ id: String, _ symbol: String, params: [VoiceParamSpec] = [.strength],
                   _ design: @escaping @Sendable ([String: Double]) -> VoiceDesign) -> VoiceEffectDescriptor {
        VoiceEffectDescriptor(id: "valse.voice.\(id)", nameKey: "voice.\(id)", category: .filter, symbol: symbol, params: params, design: design)
    }
    static func character(_ id: String, _ symbol: String, pitch: Double, formant: Double, live: [LiveNode] = [],
                          robot: Double? = nil) -> VoiceEffectDescriptor {
        VoiceEffectDescriptor(id: "valse.voice.\(id)", nameKey: "voice.\(id)", category: .character, symbol: symbol,
                              params: [.pitch, .timbre]) { p in
            var d = VoiceDesign()
            d.pitchSemitones = pitch + dp(p); d.formant = formant * dt(p); d.live = live; d.robotHz = robot
            return d
        }
    }
    static func shifted(_ semis: Double, _ formant: Double, _ live: [LiveNode] = []) -> @Sendable ([String: Double]) -> VoiceDesign {
        { p in var d = VoiceDesign(); d.pitchSemitones = semis + dp(p); d.formant = formant * dt(p); d.live = live; return d }
    }
    static func live(_ build: @escaping @Sendable (Double, [String: Double]) -> [LiveNode]) -> @Sendable ([String: Double]) -> VoiceDesign {
        { p in var d = VoiceDesign(); d.live = build(s(p), p); return d }
    }

    // MARK: Voice filters (CapCut list order first, then classic effects)

    public static let filters: [VoiceEffectDescriptor] = [
        fx("fullerVoice", "person.wave.2", live { s, _ in [.lowShelf(hz: 160, db: 5 * s), .peak(hz: 280, q: 1, db: 2 * s),
                                                           .compressor(thresholdDB: -22, ratio: 1 + 2 * s, attackMs: 8, releaseMs: 120, makeupDB: 3 * s), .limiter] }),
        fx("helium", "balloon", params: [.pitch, .timbre], shifted(4, 1.38)),
        fx("micEcho", "mic", live { s, _ in [.highPass(hz: 120), .echo(seconds: 0.16, feedback: 0.35, mix: 0.45 * s)] }),
        fx("clearVocals", "waveform.and.magnifyingglass", live { s, _ in [.highPass(hz: 90), .lowShelf(hz: 220, db: -2 * s), .peak(hz: 3000, q: 0.9, db: 3.5 * s),
                                                                              .highShelf(hz: 9000, db: 2.5 * s), .compressor(thresholdDB: -20, ratio: 2.5, attackMs: 5, releaseMs: 100, makeupDB: 2 * s), .limiter] }),
        fx("cosmicBot", "sparkles", params: [.strength]) { p in
            var d = VoiceDesign(); d.robotHz = 92
            d.live = [.chorus(rate: 0.3, depthMs: 4, baseMs: 12, feedback: 0.3, mix: 0.5 * s(p)), .reverb(room: 0.55, damp: 0.3, wet: 0.25 * s(p), width: 1)]
            return d
        },
        fx("voiceCrisper", "wand.and.stars", live { s, _ in [.highPass(hz: 100), .peak(hz: 2500, q: 1, db: 2 * s), .highShelf(hz: 5000, db: 6 * s), .limiter] }),
        fx("brokenMic", "mic.slash", live { s, _ in [.bandPass(hz: 1800, q: 1.1), .distortion(drive: 1 + 7 * s, mix: s), .bitcrush(bits: 16 - 8 * s, downsample: 1 + 2 * s),
                                                     .noise(level: 0.004 * s, crackle: 0.7 * s), .gain(db: 6)] }),
        fx("teenager", "figure.wave", params: [.pitch, .timbre], shifted(3, 1.12)),
        fx("magicChords", "music.quarternote.3", params: [.strength]) { p in
            var d = VoiceDesign(); d.harmony = s(p) > 0 ? [4, 7] : []
            d.live = [.reverb(room: 0.5, damp: 0.4, wet: 0.15 * s(p), width: 1), .limiter]
            return d
        },
        fx("studioMic", "music.mic", live { s, _ in [.highPass(hz: 80), .lowShelf(hz: 120, db: 2 * s), .peak(hz: 4000, q: 1, db: 2 * s),
                                                     .compressor(thresholdDB: -18, ratio: 2.5, attackMs: 6, releaseMs: 120, makeupDB: 2 * s),
                                                     .reverb(room: 0.25, damp: 0.6, wet: 0.08 * s, width: 0.8), .limiter] }),
        fx("bassBoost", "speaker.wave.3", live { s, _ in [.lowShelf(hz: 120, db: 9 * s), .limiter] }),
        fx("voiceFocus", "scope", live { s, _ in [.highPass(hz: 150), .lowPass(hz: 9000 - 2000 * s), .peak(hz: 2000, q: 1, db: 3 * s),
                                                  .compressor(thresholdDB: -20, ratio: 3, attackMs: 5, releaseMs: 100, makeupDB: 2 * s), .limiter] }),
        fx("fullVoice", "person.fill", live { s, _ in [.lowShelf(hz: 200, db: 3 * s), .peak(hz: 1000, q: 0.8, db: 1.5 * s),
                                                       .compressor(thresholdDB: -20, ratio: 2, attackMs: 8, releaseMs: 120, makeupDB: 1.5 * s), .limiter] }),
        fx("bassMic", "mic.fill", live { s, _ in [.lowShelf(hz: 180, db: 6 * s), .lowPass(hz: 7000), .compressor(thresholdDB: -20, ratio: 2.5, attackMs: 8, releaseMs: 120, makeupDB: 1), .limiter] }),
        fx("ghostVoice", "moon.stars", params: [.strength]) { p in
            var d = VoiceDesign(); d.whisper = true
            d.live = [.chorus(rate: 0.2, depthMs: 6, baseMs: 18, feedback: 0.2, mix: 0.4), .reverb(room: 0.85, damp: 0.3, wet: 0.5 * s(p), width: 1)]
            return d
        },
        fx("superReverb", "building.columns", params: [.strength, .room]) { p in
            var d = VoiceDesign(); d.live = [.reverb(room: 0.7 + 0.29 * room(p), damp: 0.25, wet: 0.6 * s(p), width: 1)]; return d
        },
        fx("underwater", "drop", live { s, _ in [.lowPass(hz: 2000 - 1400 * s), .chorus(rate: 0.7, depthMs: 8, baseMs: 10, feedback: 0.4, mix: 0.6 * s),
                                                 .reverb(room: 0.6, damp: 0.8, wet: 0.3 * s, width: 1), .gain(db: 3)] }),
        fx("superBass", "speaker.zzz", params: [.pitch, .timbre]) { p in
            var d = shifted(-5, 0.85)(p); d.live = [.lowShelf(hz: 150, db: 6), .limiter]; return d
        },
        fx("paAnnouncer", "megaphone", live { s, _ in [.highPass(hz: 400), .lowPass(hz: 3800), .distortion(drive: 1 + 2 * s, mix: 0.8),
                                                       .echo(seconds: 0.28, feedback: 0.25, mix: 0.25 * s), .reverb(room: 0.8, damp: 0.4, wet: 0.3 * s, width: 1), .gain(db: 4)] }),
        fx("madGremlin", "theatermasks", params: [.pitch, .timbre]) { p in
            var d = shifted(8, 1.6)(p); d.live = [.distortion(drive: 2.5, mix: 0.5), .limiter]; return d
        },
        fx("crystalClear", "diamond") { p in
            var d = VoiceDesign(); d.denoise = 0.4 * s(p)
            d.live = [.highPass(hz: 80), .highShelf(hz: 8000, db: 4 * s(p)), .peak(hz: 3000, q: 1, db: 1.5 * s(p)), .limiter]
            return d
        },
        fx("highResolution", "4k.tv", live { s, _ in [.highShelf(hz: 10000, db: 4 * s), .peak(hz: 3500, q: 1, db: 2 * s), .limiter] }),
        fx("sonicDestructor", "bolt", live { s, _ in [.bitcrush(bits: 12 - 6 * s, downsample: 1 + 3 * s), .distortion(drive: 1 + 8 * s, mix: 1),
                                                     .ringMod(hz: 30, mix: 0.3 * s), .gain(db: -3), .limiter] }),
        fx("echo", "dot.radiowaves.right", params: [.strength, .room]) { p in
            var d = VoiceDesign(); d.live = [.echo(seconds: 0.2 + 0.4 * room(p), feedback: 0.5, mix: 0.55 * s(p))]; return d
        },
        fx("megaphone", "megaphone.fill", live { s, _ in [.highPass(hz: 550), .lowPass(hz: 3000), .distortion(drive: 1 + 4 * s, mix: 1), .gain(db: 6), .limiter] }),
        fx("robot", "cpu") { p in
            var d = VoiceDesign(); d.robotHz = 110; d.live = [.ringMod(hz: 55, mix: 0.25 * s(p))]; return d
        },
        fx("chipmunk", "hare", params: [.pitch], shifted(9, pow(2, 9.0 / 12))),
        fx("deep", "tortoise", params: [.pitch, .timbre], shifted(-5, 0.82)),
        fx("vinyl", "opticaldisc", live { s, _ in [.highPass(hz: 120), .lowPass(hz: 6500), .noise(level: 0.003 * s, crackle: 0.8 * s), .lowShelf(hz: 300, db: 2)] }),
        fx("lofi", "radio", live { s, _ in [.bitcrush(bits: 14 - 5 * s, downsample: 1 + 2 * s), .lowPass(hz: 6000 - 2000 * s), .noise(level: 0.002 * s, crackle: 0)] }),
        fx("lowBattery", "battery.25", params: [.strength]) { p in
            var d = VoiceDesign(); d.pitchSemitones = -1.5 * s(p)
            d.live = [.bitcrush(bits: 10 - 3 * s(p), downsample: 1 + 4 * s(p)), .tremolo(rate: 9, depth: 0.45 * s(p)), .lowPass(hz: 3200)]
            return d
        },
        fx("tremble", "waveform.path", live { s, _ in [.chorus(rate: 6, depthMs: 2.5 * s, baseMs: 4, feedback: 0, mix: 1), .tremolo(rate: 6.5, depth: 0.5 * s)] }),
        fx("bigHouse", "house", params: [.strength, .room]) { p in
            var d = VoiceDesign(); d.live = [.reverb(room: 0.6 + 0.35 * room(p), damp: 0.35, wet: 0.4 * s(p), width: 1)]; return d
        },
        fx("telephone", "phone", live { s, _ in [.highPass(hz: 300 + 200 * s), .lowPass(hz: 3400), .distortion(drive: 1 + s, mix: 0.6), .gain(db: 3)] }),
        fx("radio", "antenna.radiowaves.left.and.right", live { s, _ in [.highPass(hz: 250), .lowPass(hz: 4500), .compressor(thresholdDB: -24, ratio: 4, attackMs: 3, releaseMs: 80, makeupDB: 4),
                                                                         .noise(level: 0.003 * s, crackle: 0.1 * s)] }),
        fx("cave", "mountain.2", live { s, _ in [.echo(seconds: 0.11, feedback: 0.55, mix: 0.4 * s), .reverb(room: 0.8, damp: 0.5, wet: 0.35 * s, width: 1)] }),
        fx("stadium", "sportscourt", live { s, _ in [.reverb(room: 0.92, damp: 0.2, wet: 0.45 * s, width: 1), .echo(seconds: 0.45, feedback: 0.3, mix: 0.25 * s)] }),
        fx("electronic", "waveform.badge.plus", live { s, _ in [.ringMod(hz: 180, mix: 0.45 * s), .chorus(rate: 1.5, depthMs: 2, baseMs: 3, feedback: 0.6, mix: 0.5 * s)] }),
        fx("alien", "antenna.radiowaves.left.and.right.circle", params: [.pitch, .timbre]) { p in
            var d = shifted(3, 0.75)(p); d.live = [.ringMod(hz: 32, mix: 0.3), .chorus(rate: 0.5, depthMs: 5, baseMs: 8, feedback: 0.4, mix: 0.4)]; return d
        },
    ]

    // MARK: Voice characters

    public static let characters: [VoiceEffectDescriptor] = [
        character("monster", "flame", pitch: -8, formant: 0.72, live: [.distortion(drive: 1.6, mix: 0.4), .lowShelf(hz: 150, db: 3), .limiter]),
        character("giant", "figure.stand", pitch: -6, formant: 0.8, live: [.reverb(room: 0.65, damp: 0.4, wet: 0.2, width: 1)]),
        character("elf", "leaf", pitch: 6, formant: 1.25),
        character("squirrel", "hare.fill", pitch: 10, formant: 1.5),
        character("littleGirl", SFSymbolCompat.compat("figure.child"), pitch: 5, formant: 1.2),
        character("lady", "figure.dress.line.vertical.figure", pitch: 4, formant: 1.14),
        character("youngMan", "figure.walk", pitch: -3, formant: 0.92),
        character("uncle", "mustache", pitch: -4, formant: 0.88),
        character("oldMan", "figure.roll", pitch: -2, formant: 0.9, live: [.tremolo(rate: 5, depth: 0.2), .lowPass(hz: 8000)]),
        character("baby", "teddybear", pitch: 8, formant: 1.35),
        character("santa", "gift", pitch: -5, formant: 0.86, live: [.lowShelf(hz: 200, db: 2), .reverb(room: 0.4, damp: 0.5, wet: 0.12, width: 1)]),
        character("villain", "eye", pitch: -4, formant: 0.84, live: [.distortion(drive: 1.3, mix: 0.3), .reverb(room: 0.75, damp: 0.3, wet: 0.25, width: 1)]),
        character("android", "desktopcomputer", pitch: 0, formant: 1, live: [.chorus(rate: 0.5, depthMs: 2, baseMs: 6, feedback: 0.3, mix: 0.3)], robot: 130),
    ]
}
