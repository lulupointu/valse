import Foundation
import MontageCore
import MontageEffects
import MontageEngine

/// Face mosaic / blur (AI-051): a `faces` matte (Vision face rectangles, held through drop-outs) on a copy of the clip
/// one track above, with Pixelate or Blur — so only the faces are covered. The copy is linked to the clip (moves with it).
public enum FaceCover {
    public enum Style: String, Sendable, CaseIterable {
        case mosaic, blur
        public var nameKey: String { "faceCover.\(rawValue)" }
        var effectID: String { self == .mosaic ? "montage.effect.pixelate" : "montage.effect.blur" }
    }

    /// The cover clip of `clipID`, if any.
    public static func cover(of clipID: ClipID, in tl: Timeline) -> Clip? {
        tl.allClips.first { $0.linkedTo == clipID && $0.matte?.kind == CutoutMode.faces.kind }
    }

    public static func style(of cover: Clip) -> Style {
        cover.effects.contains { $0.typeID == Style.blur.effectID } ? .blur : .mosaic
    }

    /// Adds (or restyles) the cover clip. Needs the faces matte (`MatteGenerator.generate(_, mode: .faces)`).
    public static func apply(_ style: Style, to clipID: ClipID, in p: inout Project) throws {
        guard let src = p.timeline.clip(clipID), src.mediaID != nil, let d = Registries.effects[style.effectID] else { throw EditError.clipNotFound }
        var fx = d.makeInstance()
        fx.params[style == .mosaic ? "size" : "radius"] = .scalar(style == .mosaic ? 0.55 : 1)
        if var existing = cover(of: clipID, in: p.timeline) {
            existing.effects = [fx]
            p.timeline[clip: existing.id] = existing
            return
        }
        var c = src
        c.id = ClipID()
        c.effects = [fx]
        c.matte = ClipMatte(kind: CutoutMode.faces.kind, feather: 0.2)
        c.audio.isMuted = true
        c.linkedTo = clipID
        c.transitionOut = nil
        c.animations = ClipAnimations()
        c.name = "Face cover"
        c.canvas = nil
        try TimelineOps.insert(c, into: &p, target: .newTrack)
    }

    public static func remove(from clipID: ClipID, in p: inout Project) {
        guard let c = cover(of: clipID, in: p.timeline), let loc = p.timeline.locate(c.id) else { return }
        let tid = p.timeline.tracks[loc.track].id
        p.timeline[clip: c.id] = nil
        p.timeline.tracks.removeAll { $0.id == tid && !$0.isMain && $0.clips.isEmpty }
    }
}
