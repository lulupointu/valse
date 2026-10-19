import Foundation

/// "Apply to" of an effect (or filter) clip on its own track (FX-004, CapCut `pc_audio_effects_main/pip/all`):
/// which layers below the clip its effects process.
/// - `all`: everything composited below it (default).
/// - `main`: only the main track (with the background / canvas fill under it); overlays are untouched.
/// - `pip`: only the overlay (picture-in-picture) layers between the main track and the effect; the main track is untouched.
public enum EffectScope: String, Codable, Sendable, CaseIterable {
    case all, main, pip
    public var nameKey: String { "fx.scope.\(rawValue)" }
}
