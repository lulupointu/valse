import Foundation
import ValseCore

/// Glue between the project model and the composition builder for audio (W8).
///
/// Per clip: `ClipAudioPlan.make(clip)` splits the settings into
/// 1. the OFFLINE stage (`RenderStageSpec`: pitch/formant, robot, denoise, enhance, separation) → a rendered,
///    sample-aligned copy of the media's audio (`AudioRenderCache`) that replaces the original in the composition,
/// 2. the LIVE stage (`[LiveNode]`: EQ, voice-filter colour, channels) → the lane's MTAudioProcessingTap,
/// 3. gains (volume / keyframes / fades / loudness normalization / ducking) → AVAudioMix ramps.
/// Speed and pitch-preserving time stretch stay AVFoundation's (spectral time-pitch on the scaled segments), applied
/// after 1 and 2. Preview and export build the same composition, so they sound the same.
public enum AudioPipeline {
    /// Audio file to insert for `clip`. Export waits for the rendered stage; preview uses it when ready and otherwise
    /// plays the original while the render runs (the engine rebuilds on `AudioRenderCache.onReady`).
    static func audioSource(clip: Clip, asset: MediaAsset, original: URL, purpose: RenderPurpose) async throws -> URL {
        let spec = ClipAudioPlan.make(clip).render
        guard !spec.isIdentity else { return original }
        // the input may be a variant of the media (reversed render, transcoded playable copy): cache it separately
        var asset = asset
        if original.standardizedFileURL != asset.url.standardizedFileURL {
            asset.contentHash += "~" + String(original.lastPathComponent.utf8.reduce(UInt64(0xcbf29ce484222325)) { ($0 ^ UInt64($1)) &* 0x100000001b3 }, radix: 16)
            asset.url = original
        }
        switch purpose {
        case .export:
            return try await AudioRenderCache.shared.render(asset, spec: spec)
        case .preview:
            if let u = AudioRenderCache.shared.readyURL(for: asset, spec: spec) { return u }
            AudioRenderCache.shared.request(asset, spec: spec)
            return original
        }
    }

    /// Hashes the parts of a clip's audio that require rebuilding the composition (live parameters are excluded:
    /// the taps pick them up through `AudioMixState`).
    static func combineStructure(_ c: Clip, asset: MediaAsset, into h: inout Hasher) {
        let a = c.audio
        h.combine(a.volume); h.combine(a.fadeIn); h.combine(a.fadeOut); h.combine(a.isMuted); h.combine(a.preservePitch)
        h.combine(a.loudness); h.combine(a.ducking)
        let spec = ClipAudioPlan.make(c).render
        h.combine(spec)
        if !spec.isIdentity { h.combine(AudioRenderCache.shared.readyURL(for: asset, spec: spec) != nil) }
        h.combine(c.keyframes[ParamKey.volume.raw])
    }

    /// Clips whose rendered audio stage is still being computed (for "Processing…" badges).
    public static func pendingRender(_ clip: Clip, asset: MediaAsset) -> Double? {
        let spec = ClipAudioPlan.make(clip).render
        guard !spec.isIdentity, AudioRenderCache.shared.readyURL(for: asset, spec: spec) == nil else { return nil }
        return AudioRenderCache.shared.progress(for: asset, spec: spec) ?? 0
    }
}
