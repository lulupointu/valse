import Foundation

/// TL-013 "Link freeze frame clips to original video": a freeze clip with `freezeSource` shows the look of its original
/// clip. `sync` runs after every edit / gesture update (EditSession), so edits on the original (effects, filters,
/// adjustments, position, crop, mask…) reach the freeze frames in the same undo step. Values are taken from the original
/// resolved at its last frame (the frozen moment sits right after it). A link whose original is gone is dropped.
public enum FreezeLinks {
    public static func sync(_ p: inout Project) {
        // fast path: no linked freeze clip (a plain scan, no allocation)
        var any = false
        outer: for t in p.timeline.tracks { for c in t.clips where c.freezeSource != nil { any = true; break outer } }
        guard any else { return }
        let tl = p.timeline
        for ti in tl.tracks.indices {
            for ci in tl.tracks[ti].clips.indices {
                let f = tl.tracks[ti].clips[ci]
                guard let sid = f.freezeSource else { continue }
                guard let s = tl.clip(sid), s.mediaID == f.mediaID else {
                    p.timeline.tracks[ti].clips[ci].freezeSource = nil; continue
                }
                var n = f
                apply(look: s.resolved(at: s.duration), to: &n)
                if n != f { p.timeline.tracks[ti].clips[ci] = n }
            }
        }
    }

    static func apply(look s: Clip, to f: inout Clip) {
        f.transform = s.transform
        f.opacity = s.opacity
        f.blendMode = s.blendMode
        f.crop = s.crop
        f.mask = s.mask
        f.canvas = s.canvas
        f.effects = s.effects
        f.enhance = s.enhance
        f.relight = s.relight
        f.adjustMask = s.adjustMask
    }

    /// Freeze clips linked to `id`.
    public static func linked(to id: ClipID, in tl: Timeline) -> [ClipID] {
        tl.allClips.filter { $0.freezeSource == id }.map(\.id)
    }
}
