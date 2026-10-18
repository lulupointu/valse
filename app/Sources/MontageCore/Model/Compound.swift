import Foundation

public typealias CompoundID = Identifier<CompoundClip>

/// A nested timeline ("Compound clip", TL-021). A clip with `content == .compound(id)` plays this timeline like a media
/// clip plays a file: `sourceStart` is the in-point inside the nested timeline and constant `speed` retimes it. The
/// nested clips reference the project's shared media bin. Rendering (W6/W9): the compositor composites the nested
/// items into one canvas-size layer which then gets the compound clip's transform, opacity, blend mode, mask and
/// effects; the composition decodes the nested media on extra lanes (`CompoundFlattening`). Nesting depth ≤ 4.
public struct CompoundClip: Codable, Sendable, Equatable, Identifiable {
    public var id: CompoundID
    public var name: String
    public var timeline: Timeline
    public init(id: CompoundID = CompoundID(), name: String, timeline: Timeline) {
        self.id = id; self.name = name; self.timeline = timeline
    }
    public var duration: Time { timeline.duration }
}

extension Project {
    public static let maxCompoundDepth = 4

    public func compound(_ id: CompoundID) -> CompoundClip? { compounds?.first { $0.id == id } }

    /// The project seen from inside a compound (same settings, media and compounds; nested timeline).
    public func nested(_ c: CompoundClip) -> Project {
        var p = self
        p.timeline = c.timeline
        return p
    }
}

/// Stable id for a clip of a nested timeline as seen through one compound-clip instance (so the same nested clip
/// shown by two compound clips gets two decode lanes). XOR of the two UUIDs' bytes, with a tag bit.
public func nestedClipID(_ container: ClipID, _ inner: ClipID) -> ClipID {
    var a = container.raw.uuid, b = inner.raw.uuid
    withUnsafeMutableBytes(of: &a) { pa in
        withUnsafeBytes(of: &b) { pb in for i in 0..<16 { pa[i] ^= pb[i] } }
        pa[6] ^= 0x5A
    }
    return ClipID(UUID(uuid: a))
}

extension TimelineOps {
    /// "Create compound clip" (⌥G): moves the selected clips into a new nested timeline (relative timing, track kinds
    /// and stacking order kept; main-track clips go to the nested main track) and puts one compound clip spanning their
    /// range where they were (on the main track if any was there, else on the lowest selected track).
    @discardableResult
    public static func createCompound(_ ids: Set<ClipID>, name: String, in project: inout Project) throws -> ClipID {
        var tl = project.timeline
        let picked = tl.tracks.enumerated().flatMap { (ti, t) in t.clips.filter { ids.contains($0.id) }.map { (ti, $0) } }
        guard !picked.isEmpty else { throw EditError.nothingToDo }
        guard picked.allSatisfy({ !tl.tracks[$0.0].isLocked }) else { throw EditError.trackLocked }
        let start = picked.map(\.1.start).min()!, end = picked.map(\.1.end).max()!
        // nested timeline
        var nested = Timeline()
        nested.mainTrackMagnet = false
        let mainIndex = nested.mainTrackIndex!
        var trackFor: [Int: Int] = [:]
        for ti in tl.tracks.indices where picked.contains(where: { $0.0 == ti }) {
            if tl.tracks[ti].isMain { trackFor[ti] = mainIndex; continue }
            var t = Track(kind: tl.tracks[ti].kind)
            t.isMuted = tl.tracks[ti].isMuted; t.isHidden = tl.tracks[ti].isHidden
            nested.tracks.append(t)
            trackFor[ti] = nested.tracks.count - 1
        }
        if !picked.contains(where: { tl.tracks[$0.0].isMain }) {
            // no main-track clip: the lowest selected visual track becomes the nested main track
            if let lowest = picked.map(\.0).filter({ tl.tracks[$0].kind == .video }).min(), let ni = trackFor[lowest] {
                nested.tracks[mainIndex].clips = []
                trackFor[lowest] = mainIndex
                nested.tracks.remove(at: ni)
                for (k, v) in trackFor where v > ni { trackFor[k] = v - 1 }
            }
        }
        for (ti, c) in picked {
            var n = c
            n.start = c.start - start
            n.linkedTo = nil; n.groupID = nil
            nested.tracks[trackFor[ti]!].clips.append(n)
        }
        for i in nested.tracks.indices { nested.tracks[i].sortClips() }
        nested.tracks.removeAll { !$0.isMain && $0.clips.isEmpty }

        let compound = CompoundClip(name: name, timeline: nested)
        var cc = Clip(content: .compound(compound.id), start: start, duration: end - start)
        // remove the originals, then insert the compound where they were
        let host = picked.first { tl.tracks[$0.0].isMain }?.0 ?? picked.filter { tl.tracks[$0.0].kind == .video }.map(\.0).min()
        let oldMainStarts = mainStarts(tl)
        for ti in tl.tracks.indices { tl.tracks[ti].clips.removeAll { ids.contains($0.id) } }
        if let h = host, tl.tracks[h].isMain {
            let idx = tl.tracks[h].clips.firstIndex { $0.start >= start } ?? tl.tracks[h].clips.count
            tl.tracks[h].clips.insert(cc, at: idx)
            if tl.mainTrackMagnet { compactMain(&tl, previousStarts: oldMainStarts) }
        } else {
            let tid = host.map { tl.tracks[$0].id } ?? addTrack(.video, to: &tl)
            let hi = tl.trackIndex(tid)!
            if tl.linkage { cc.linkedTo = mainClip(at: start, in: tl)?.id }
            if fits(cc.range, in: tl.tracks[hi]) {
                tl.tracks[hi].clips.append(cc); tl.tracks[hi].sortClips()
            } else {
                let nt = addTrack(.video, to: &tl, above: hi)
                tl.tracks[tl.trackIndex(nt)!].clips.append(cc)
            }
        }
        removeEmptyTracks(&tl)
        project.compounds = (project.compounds ?? []) + [compound]
        project.timeline = tl
        return cc.id
    }

    /// "Undo compound clip": puts the nested clips back on the parent timeline at the compound's position (trimmed to
    /// what the compound shows). Only for 1× compounds; the compound's own look (transform, effects…) is dropped.
    public static func explodeCompound(_ id: ClipID, in project: inout Project) throws {
        guard let c = project.timeline.clip(id), case .compound(let cid) = c.content, let comp = project.compound(cid) else {
            throw EditError.clipNotFound
        }
        guard c.speed.isNormal else { throw EditError.invalidTime }
        var tl = project.timeline
        let loc = tl.locate(id)!
        let onMain = tl.tracks[loc.track].isMain
        let oldMainStarts = mainStarts(tl)
        tl.tracks[loc.track].clips.remove(at: loc.clip)
        let window = TimeRange(start: c.sourceStart, duration: c.duration)
        let shift = c.start - c.sourceStart
        var placedMain: [Clip] = []
        for nt in comp.timeline.tracks {
            var moved: [Clip] = []
            for n in nt.clips where n.range.overlaps(window) {
                var x = n
                x.id = ClipID()
                x.start = n.start + shift
                moved.append(x)
            }
            guard !moved.isEmpty else { continue }
            if nt.isMain && onMain { placedMain += moved; continue }
            let kid = addTrack(nt.kind, to: &tl, above: loc.track)
            tl.tracks[tl.trackIndex(kid)!].clips = moved.sorted { $0.start < $1.start }
        }
        if !placedMain.isEmpty {
            let mi = tl.mainTrackIndex!
            tl.tracks[mi].clips += placedMain
            tl.tracks[mi].sortClips()
            if tl.mainTrackMagnet { compactMain(&tl, previousStarts: oldMainStarts) }
        }
        removeEmptyTracks(&tl)
        project.timeline = tl
        if !MultiTimelineOps.allTimelines(project).contains(where: { $0.tracks.contains { $0.clips.contains { $0.content == .compound(cid) } } }) {
            project.compounds?.removeAll { $0.id == cid }
        }
    }
}
