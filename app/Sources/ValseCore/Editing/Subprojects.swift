import Foundation

/// Subprojects (TL-022 / MI-019): the project's compound clips listed in Media ▸ Subprojects, re-usable on the timeline
/// (each use is another compound clip playing the same nested timeline), renamable, and importable from another
/// project (its timeline + its own compounds come in as subprojects, media merged by content hash).
public enum Subprojects {
    /// A new compound clip of subproject `cid` at `t` (inserted like media: main track when free, else a new track).
    @discardableResult
    public static func insert(_ cid: CompoundID, at t: Time, in p: inout Project) throws -> ClipID {
        guard let comp = p.compound(cid), comp.duration > .zero else { throw EditError.nothingToDo }
        // a subproject can't be placed inside itself (while editing it)
        if (p.compoundEdit ?? []).contains(where: { $0.compoundID == cid }) { throw EditError.nothingToDo }
        var c = Clip(content: .compound(cid), start: t, duration: comp.duration)
        c.name = comp.name
        _ = try TimelineOps.insert(c, into: &p, target: .automatic)
        return c.id
    }

    public static func rename(_ cid: CompoundID, to name: String, in p: inout Project) throws {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let i = p.compounds?.firstIndex(where: { $0.id == cid }) else { throw EditError.nothingToDo }
        p.compounds?[i].name = n
    }

    /// How many clips use each subproject (all timelines, incl. nested ones).
    public static func useCounts(_ p: Project) -> [CompoundID: Int] {
        var out: [CompoundID: Int] = [:]
        let timelines = MultiTimelineOps.allTimelines(p) + (p.compounds ?? []).map(\.timeline)
        for tl in timelines { for c in tl.allClips { if case .compound(let id) = c.content { out[id, default: 0] += 1 } } }
        return out
    }

    /// Media referenced inside subprojects (compound timelines) but by no clip of any top-level timeline.
    public static func mediaOnlyInSubprojects(_ p: Project) -> Set<MediaID> {
        func media(_ tls: [Timeline]) -> Set<MediaID> { Set(tls.flatMap(\.allClips).compactMap(\.mediaID)) }
        return media((p.compounds ?? []).map(\.timeline)).subtracting(media(MultiTimelineOps.allTimelines(p)))
    }

    /// Imports `src` (another project) as subprojects: its root timeline becomes compound `name`, its compounds come
    /// along (fresh ids), media are merged (an asset already in the bin — same content hash — is reused).
    /// Returns the root subproject id.
    @discardableResult
    public static func importProject(_ src: Project, name: String, into p: inout Project) throws -> CompoundID {
        var root = src
        CompoundEditing.exitAll(&root)
        guard root.timeline.duration > .zero || !(root.compounds ?? []).isEmpty else { throw EditError.nothingToDo }
        // media
        var mediaMap: [MediaID: MediaID] = [:]
        let byHash = Dictionary(p.media.map { ($0.contentHash, $0.id) }, uniquingKeysWith: { a, _ in a })
        let existingIDs = Set(p.media.map(\.id))
        for var a in root.media {
            if let same = byHash[a.contentHash] { mediaMap[a.id] = same; continue }
            let old = a.id
            if existingIDs.contains(a.id) { a.id = MediaID() }
            a.folderID = nil
            mediaMap[old] = a.id
            p.media.append(a)
        }
        // compounds (fresh ids, remapped references)
        var compMap: [CompoundID: CompoundID] = [:]
        for c in root.compounds ?? [] { compMap[c.id] = CompoundID() }
        func remap(_ tl: Timeline) -> Timeline {
            var t = MultiTimelineOps.freshIDs(tl)
            for ti in t.tracks.indices {
                for ci in t.tracks[ti].clips.indices {
                    switch t.tracks[ti].clips[ci].content {
                    case .media(let m): t.tracks[ti].clips[ci].content = .media(mediaMap[m] ?? m)
                    case .compound(let c): t.tracks[ti].clips[ci].content = .compound(compMap[c] ?? c)
                    default: break
                    }
                }
            }
            return t
        }
        var comps = p.compounds ?? []
        for c in root.compounds ?? [] { comps.append(CompoundClip(id: compMap[c.id]!, name: c.name, timeline: remap(c.timeline))) }
        let rootID = CompoundID()
        var nested = remap(root.timeline)
        nested.mainTrackMagnet = false
        comps.append(CompoundClip(id: rootID, name: name, timeline: nested))
        p.compounds = comps
        return rootID
    }
}

/// Compound clip presets (TL-021 "Save preset", up to 99): a compound's nested timeline with the compounds and media
/// it uses, saved outside the project so any project can add it (media referenced by file, merged by content hash).
public struct CompoundPreset: Codable, Sendable, Equatable, Identifiable {
    public static let maxCount = 99
    public var id: UUID
    public var name: String
    public var created: Date
    public var compound: CompoundClip
    public var nested: [CompoundClip]
    public var media: [MediaAsset]

    /// Preset of compound `cid` of `p` (with every compound and media it uses, recursively).
    public static func make(_ cid: CompoundID, from p: Project, name: String? = nil, date: Date = Date()) -> CompoundPreset? {
        guard let c = p.compound(cid) else { return nil }
        var comps: [CompoundClip] = [], mediaIDs = Set<MediaID>(), seen: Set<CompoundID> = [cid]
        var queue = [c.timeline]
        while let tl = queue.popLast() {
            for clip in tl.allClips {
                if let m = clip.mediaID { mediaIDs.insert(m) }
                if case .compound(let k) = clip.content, !seen.contains(k), let kc = p.compound(k) {
                    seen.insert(k); comps.append(kc); queue.append(kc.timeline)
                }
            }
        }
        return CompoundPreset(id: UUID(), name: name ?? c.name, created: date, compound: c, nested: comps,
                              media: p.media.filter { mediaIDs.contains($0.id) })
    }

    /// The preset as a small project (for `Subprojects.importProject`).
    public var asProject: Project {
        var p = Project()
        p.name = name
        p.media = media
        p.compounds = nested
        p.timeline = compound.timeline
        return p
    }
}
