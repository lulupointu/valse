import Foundation

/// Decode-side view of compound clips: the composition must decode every media clip a nested timeline shows, on the
/// parent timeline's clock. `decodeTracks` returns the project's own tracks followed by one virtual track per nested
/// track of every (enabled) compound clip, recursively, whose clips are the nested clips re-timed into parent time:
/// ids = `nestedClipID(container, inner)` (matching `FrameEvaluator`), trimmed to what the compound shows, speed
/// multiplied by the compound's rate, gain multiplied by the compound's volume. Compound clips play forwards at their
/// average rate (a speed curve on a compound is approximated by its average; reverse is ignored).
public enum CompoundFlattening {
    public static func decodeTracks(_ project: Project, depth: Int = 0) -> [Track] {
        var out = project.timeline.tracks
        // Solo (AU-029): when any track is soloed, every other track is silenced (applied before nesting, so a
        // compound on a silenced track is silenced too).
        if project.timeline.hasSolo { for i in out.indices { out[i].isMuted = !project.timeline.isAudible(out[i]) } }
        // Track volume (TL-018) is baked into the clips' gains, so composition, mixdown, scrub and ducking all follow.
        for i in out.indices where abs(out[i].gain - 1) > 1e-9 { applyGain(out[i].gain, to: &out[i]) }
        guard depth < Project.maxCompoundDepth, !(project.compounds ?? []).isEmpty else { return out }
        for parent in out.prefix(project.timeline.tracks.count) {
            for c in parent.clips where c.isEnabled {
                guard case .compound(let cid) = c.content, let comp = project.compound(cid) else { continue }
                for nt in decodeTracks(project.nested(comp), depth: depth + 1) {
                    var vt = Track(kind: nt.kind, isMain: nt.isMain)
                    vt.id = TrackID(nestedClipID(ClipID(parent.id.raw), ClipID(nt.id.raw)).raw)
                    vt.isMuted = nt.isMuted || parent.isMuted || c.audio.isMuted
                    vt.isHidden = nt.isHidden || parent.isHidden
                    vt.clips = nt.clips.compactMap { retime($0, in: c) }
                    if !vt.clips.isEmpty { out.append(vt) }
                }
            }
        }
        return out
    }

    /// Multiplies every clip's volume (and volume keyframes) of a track by `g`.
    static func applyGain(_ g: Double, to t: inout Track) {
        for ci in t.clips.indices {
            t.clips[ci].audio.volume *= g
            if let k = t.clips[ci].keyframes[ParamKey.volume.raw] {
                t.clips[ci].keyframes[ParamKey.volume.raw] = KeyframeTrack(k.keyframes.map { kf in
                    var kf = kf
                    if let v = kf.value.scalar { kf.value = .scalar(v * g) }
                    return kf
                })
            }
        }
        t.volume = nil
    }

    /// Nested clip `n` as seen through compound clip `c` on the parent timeline (nil when outside what `c` shows).
    static func retime(_ n: Clip, in c: Clip) -> Clip? {
        let v = max(c.speed.averageRate, 0.01)
        let window = TimeRange(start: c.sourceStart, duration: c.duration * v)
        guard let o = n.range.intersection(window), o.duration > .zero, n.isEnabled else { return nil }
        var x = n
        x.id = nestedClipID(c.id, n.id)
        x.start = c.start + (o.start - c.sourceStart) / v
        x.duration = o.duration / v
        let head = o.start - n.start, tail = n.end - o.end
        switch n.speed {
        case .constant(let s):
            x.speed = .constant(s * v)
            x.sourceStart = n.reversed ? n.sourceStart + tail * s : n.sourceStart + head * s
        case .curve(let curve):
            var sub = curve.subcurve(from: head / n.duration, to: (n.duration - tail) / n.duration)
            sub.points = sub.points.map { SpeedPoint($0.x, $0.v * v) }
            x.speed = .curve(sub)
            x.sourceStart = n.reversed
                ? n.sourceStart + n.speed.sourceDuration(forOutput: n.duration) - n.speed.sourceOffset(at: n.duration - tail, outputDuration: n.duration)
                : n.sourceStart + n.speed.sourceOffset(at: head, outputDuration: n.duration)
        }
        x.audio.volume = n.audio.volume * c.audio.volume
        x.audio.isMuted = n.audio.isMuted || c.audio.isMuted
        if var vk = n.keyframes[ParamKey.volume.raw] {
            vk = KeyframeTrack(vk.keyframes.map { var k = $0; k.time = (k.time - head) / v; return k })
            x.keyframes = [ParamKey.volume.raw: vk]
        } else {
            x.keyframes = [:]
        }
        if var tr = x.transitionOut { tr.duration = tr.duration / v; x.transitionOut = tr }
        x.linkedTo = nil
        return x
    }
}
