import Foundation

/// Schema 1 → 2 (TR-MODEL-CAPCUT): transitions used to OVERLAP their clips (the incoming clip started d before the
/// outgoing one ended, the main-track magnet packed the overlap, overlay tracks slid the right clip left). CapCut's
/// model butts the clips and centres the transition on the cut. Each old overlap of `o` between A and B becomes a cut
/// at its centre: A keeps its start and loses `o/2` at its tail; B starts `o/2` later and its in point moves by `o/2`
/// (the trimmed parts become handles). The timeline length, the transition window and which source frame shows at
/// every instant stay identical; the transition's duration becomes `o`.
public enum TransitionModelMigration {
    /// Converts every overlapping transition pair of `tl` (main and overlay tracks).
    public static func migrate(_ tl: inout Timeline) {
        for ti in tl.tracks.indices { migrate(&tl.tracks[ti]) }
    }

    static func migrate(_ track: inout Track) {
        guard track.clips.count > 1 else { return }
        for i in 0..<(track.clips.count - 1) {
            guard var tr = track.clips[i].transitionOut else { continue }
            let overlap = track.clips[i].end - track.clips[i + 1].start
            guard overlap.ticks > 1 else { continue }   // already butted (or a gap): nothing moved for it
            let half = Time(ticks: overlap.ticks / 2)
            trimTail(&track.clips[i], by: half)
            trimHead(&track.clips[i + 1], by: overlap - half)
            tr.duration = overlap
            track.clips[i].transitionOut = tr
        }
    }

    /// Shortens the clip's end by `h` (start kept), keeping the source mapping of what remains.
    static func trimTail(_ c: inout Clip, by h: Time) {
        let d = c.duration, nd = c.duration - h
        guard nd.ticks > 0, d.ticks > 0 else { return }
        let oldSource = c.sourceDuration
        if case .curve(let curve) = c.speed { c.speed = .curve(curve.subcurve(from: 0, to: nd / d)) }
        c.duration = nd
        // reversed: the tail shows the source's start, which is what goes
        if c.reversed { c.sourceStart += oldSource - c.sourceDuration }
    }

    /// Moves the clip's start `h` later (end kept), keeping the source mapping of what remains.
    static func trimHead(_ c: inout Clip, by h: Time) {
        let d = c.duration, nd = c.duration - h
        guard nd.ticks > 0, d.ticks > 0 else { return }
        let off = c.speed.sourceOffset(at: h, outputDuration: d)
        if case .curve(let curve) = c.speed { c.speed = .curve(curve.subcurve(from: h / d, to: 1)) }
        if !c.reversed { c.sourceStart += off }
        c.start += h
        c.duration = nd
        for k in c.keyframes.keys { c.keyframes[k]?.shift(by: -h) }
        c.shiftMarkers(by: -h)
    }

    /// The JSON step (`ProjectMigrator.steps[1]`): every timeline of the project file — the active one, compound
    /// clips' nested timelines, the other timeline tabs and the compound-editing parents.
    static func migrateJSON(_ obj: inout [String: Any]) throws {
        func fix(_ value: Any?) throws -> Any? {
            guard let value, JSONSerialization.isValidJSONObject(value) else { return value }
            let data = try JSONSerialization.data(withJSONObject: value)
            var tl = try ProjectPackage.decoder().decode(Timeline.self, from: data)
            migrate(&tl)
            return try JSONSerialization.jsonObject(with: ProjectPackage.encoder().encode(tl))
        }
        obj["timeline"] = try fix(obj["timeline"])
        for (key, field) in [("compounds", "timeline"), ("timelines", "timeline"), ("compoundEdit", "parent")] {
            guard var list = obj[key] as? [[String: Any]] else { continue }
            for i in list.indices { list[i][field] = try fix(list[i][field]) }
            obj[key] = list
        }
    }
}
