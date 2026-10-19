@preconcurrency import Metal
import Foundation
import MontageCore
import MontageEffects

/// FX-002 body effects on plain video / FX-008 magic cutout.
///
/// A clip whose `ClipMatte.bodyOnly` is set keeps its full frame; its body effects (`effect.group.body`: outline, aura,
/// shadow, clones, magic cutout…) run on a copy cut out by the person matte (`src` = the person, `backdrop` input = the
/// whole frame), and the result is put back over the un-cut layer (straight-alpha over). Until the matte is ready the
/// body effects are skipped (no outline around the frame border).
extension FrameRenderer {
    static let bodyGroupKey = "effect.group.body"

    static func isBodyEffect(_ e: ResolvedEffect) -> Bool { Registries.effects[e.typeID]?.groupKey == bodyGroupKey }

    func applyBodyEffects(_ m: ClipMatte, layer l: LayerDescription, to base: MTLTexture, uv cu: ConvertUniforms,
                          media: [MediaID: MediaAsset], sources: any FrameSourceProvider, cmd: MTLCommandBuffer,
                          scratch: FrameScratch, acquire: (Int, Int) -> MTLTexture) -> MTLTexture {
        var cutMatte = m
        cutMatte.bodyOnly = nil
        let cut = applyMatte(cutMatte, layer: l, to: base, uv: cu, media: media, sources: sources, cmd: cmd,
                             scratch: scratch, acquire: acquire)
        guard cut !== base else { return base }   // matte not ready yet
        let body = l.effects.filter(Self.isBodyEffect)
        let fx = applyEffects(body, to: cut, time: l.localTime, cmd: cmd, acquire: acquire, recycle: scratch.recycle, backdrop: base)
        let out = acquire(base.width, base.height)
        fullscreen(F4Pipelines.shared.straightOver, target: out, cmd, label: "body-over") { enc in
            enc.setFragmentTexture(fx, index: 0); enc.setFragmentTexture(base, index: 1)
        }
        if fx !== cut { scratch.recycle(fx) }
        scratch.recycle(cut)
        scratch.recycle(base)
        return out
    }
}
