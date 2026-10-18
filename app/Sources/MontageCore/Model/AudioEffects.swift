import Foundation

// Audio processing settings of a clip (W8). All of them live in `AudioProps` and are applied identically in preview
// and export by MontageEngine/Audio (see ARCHITECTURE.md "Audio pipeline").

/// Voice changer selection (CapCut "Voice changer ▸ Voice filters / Voice characters"): a preset id from the engine's
/// `VoiceEffects` registry (e.g. "montage.voice.helium") plus its parameter values (keys from the preset's specs).
public struct VoiceEffect: Hashable, Codable, Sendable {
    public var typeID: String
    public var params: [String: Double]
    public init(typeID: String, params: [String: Double] = [:]) { self.typeID = typeID; self.params = params }
}

/// Channel matrix (CapCut "Fill channel").
public enum ChannelMode: String, Codable, Sendable, CaseIterable {
    case stereo
    /// Left channel copied to both sides.
    case leftToBoth
    /// Right channel copied to both sides.
    case rightToBoth
    /// (L + R) / 2 on both sides.
    case mono
    case swap
    public var nameKey: String { "audio.channels.\(rawValue)" }
}

/// 10-band graphic equalizer (peaking filters, ±12 dB).
public struct AudioEQ: Hashable, Codable, Sendable {
    public static let frequencies: [Double] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    public static let gainRange: ClosedRange<Double> = -12...12
    /// dB per band, same order as `frequencies`.
    public var gains: [Double]
    /// Preset the gains came from, for UI highlighting ("montage.eq.voice"…), nil = custom.
    public var presetID: String?
    public init(gains: [Double] = Array(repeating: 0, count: AudioEQ.frequencies.count), presetID: String? = nil) {
        self.gains = gains; self.presetID = presetID
    }
    public var isFlat: Bool { gains.allSatisfy { abs($0) < 0.01 } }
}

/// "Loudness normalization": the clip's integrated loudness (ITU-R BS.1770 / EBU R128) is measured once over its
/// source range and a static gain brings it to `targetLUFS`.
public struct LoudnessNormalization: Hashable, Codable, Sendable {
    public static let targets: [Double] = [-23, -16, -14]
    public var targetLUFS: Double
    /// Measured integrated loudness of the clip's source range (nil until analysed).
    public var measuredLUFS: Double?
    /// Source range the measurement was made on (re-measure when the clip is trimmed).
    public var measuredRange: TimeRange?
    public init(targetLUFS: Double = -23, measuredLUFS: Double? = nil, measuredRange: TimeRange? = nil) {
        self.targetLUFS = targetLUFS; self.measuredLUFS = measuredLUFS; self.measuredRange = measuredRange
    }
    /// Linear gain to apply (1 until measured; capped at +20 dB, silence stays silent).
    public var gain: Double {
        guard let m = measuredLUFS, m.isFinite, m > -70 else { return 1 }
        return pow(10, min(20, targetLUFS - m) / 20)
    }
}

/// "Isolate voice" / "Separate audio".
public enum VocalSeparation: String, Codable, Sendable, CaseIterable {
    case keepVocals, removeVocals
    public var nameKey: String { "audio.separation.\(rawValue)" }
}

/// Auto-lower this clip while other audio (voice) plays.
public struct AudioDucking: Hashable, Codable, Sendable {
    /// Attenuation while ducked, dB (negative).
    public var amountDB: Double
    public init(amountDB: Double = -12) { self.amountDB = amountDB }
}

/// Auto-detected beats of a music clip (CapCut "Beats 1 / Beats 2"). Times are MEDIA (source) times so markers follow
/// trims and moves; use `Clip.beatTimes()` for timeline positions.
public struct BeatMarkers: Hashable, Codable, Sendable {
    /// 1 = strong beats only (sparser), 2 = every beat.
    public var level: Int
    /// Every detected beat, source time, sorted.
    public var beats: [Time]
    /// Subset used for level 1 (every other beat, phase with the strongest onsets).
    public var strongBeats: [Time]
    /// Estimated tempo.
    public var bpm: Double
    public init(level: Int = 1, beats: [Time] = [], strongBeats: [Time] = [], bpm: Double = 0) {
        self.level = level; self.beats = beats; self.strongBeats = strongBeats; self.bpm = bpm
    }
    public var active: [Time] { level >= 2 ? beats : strongBeats }
}

extension Clip {
    /// Timeline times of the clip's active beat markers that fall inside the clip.
    public func beatTimes() -> [Time] {
        guard let b = audio.beats else { return [] }
        let src = sourceRange
        var out: [Time] = []
        for s in b.active where src.contains(s) {
            // invert the time remap (monotonic) by bisection on the clip-local output time
            var lo = Time.zero, hi = duration
            for _ in 0..<40 {
                let mid = Time(ticks: (lo.ticks + hi.ticks) / 2)
                let v = sourceTime(at: start + mid)
                if reversed ? v > s : v < s { lo = mid } else { hi = mid }
            }
            let t = start + hi
            if range.contains(t) { out.append(t) }
        }
        return out.sorted()
    }
}
