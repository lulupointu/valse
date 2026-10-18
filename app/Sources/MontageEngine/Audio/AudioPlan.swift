import Foundation
import MontageCore

/// Parameters of the OFFLINE-rendered stage of a clip's audio: everything that needs look-ahead or adds latency
/// (pitch/formant shift, robot/whisper, noise reduction, voice enhancement, vocal separation). The stage renders the
/// whole media file once per distinct spec (cached by content hash + spec), with latency compensated, so the
/// rendered file is sample-aligned with the source and both preview and export insert it in place of the original.
public struct RenderStageSpec: Hashable, Codable, Sendable {
    public var separation: VocalSeparation?
    public var denoise: Double?
    public var enhance: Double?
    /// Pitch ratio (1 = unchanged).
    public var pitch: Double = 1
    /// Formant ratio (1 = timbre unchanged).
    public var formant: Double = 1
    /// Extra voices, semitones.
    public var harmony: [Double] = []
    public var robotHz: Double?
    public var whisper = false

    public init() {}

    public var isIdentity: Bool {
        separation == nil && denoise == nil && enhance == nil && abs(pitch - 1) < 1e-4 && abs(formant - 1) < 1e-4
            && harmony.isEmpty && robotHz == nil && !whisper
    }

    /// Stable cache key (bumped `version` invalidates every rendered file when the DSP changes).
    public static let version = 1
    public var cacheKey: String {
        let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys
        let data = (try? enc.encode(self)) ?? Data()
        var h: UInt64 = 0xcbf29ce484222325
        for b in data { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return "v\(Self.version)-\(String(h, radix: 16))"
    }
}

/// How the engine processes one clip's audio (derived from `AudioProps`; pure).
public struct ClipAudioPlan: Hashable, Sendable {
    public var render: RenderStageSpec
    /// Live (tap) chain, applied after the rendered stage, before the mix gain/fades.
    public var live: [LiveNode]
    /// Static gain multiplier (loudness normalization).
    public var staticGain: Double

    public static func make(_ a: AudioProps) -> ClipAudioPlan {
        var r = RenderStageSpec()
        var live: [LiveNode] = []
        if a.channels != .stereo { live.append(.channels(a.channels)) }
        r.separation = a.separation
        if let s = a.noiseReduction { r.denoise = min(max(s, 0), 1) }
        if let e = a.enhanceVoice { r.enhance = min(max(e, 0), 1) }
        var semis = min(max(a.pitch, -24), 24)
        if let v = a.voice, let d = VoiceEffects.descriptor(v.typeID) {
            let design = d.design(for: v)
            semis += design.pitchSemitones
            r.formant = design.formant
            r.harmony = design.harmony
            r.robotHz = design.robotHz
            r.whisper = design.whisper
            if let dn = design.denoise, r.denoise == nil { r.denoise = dn }
            live += design.live
        }
        r.pitch = pow(2, semis / 12)
        if let eq = a.eq, !eq.isFlat { live.insert(.eq(eq.gains), at: a.channels != .stereo ? 1 : 0) }
        return ClipAudioPlan(render: r, live: live, staticGain: a.loudness?.gain ?? 1)
    }

    public var hasLive: Bool { !live.isEmpty }

    /// Plan for a clip, including "Change pitch" with speed (pitch follows speed when `preservePitch` is off).
    /// That is rendered as a pitch shift by the (average) rate before the spectral time stretch, so the result
    /// equals varispeed without AVFoundation's varispeed path (which stalls AVAssetReaderAudioMixOutput on sped-up
    /// segments).
    public static func make(_ clip: Clip) -> ClipAudioPlan {
        var p = make(clip.audio)
        if !clip.audio.preservePitch && !clip.speed.isNormal {
            let r = min(max(clip.speed.averageRate, 0.25), 4)
            p.render.pitch *= r
            p.render.formant *= r
        }
        return p
    }
}
