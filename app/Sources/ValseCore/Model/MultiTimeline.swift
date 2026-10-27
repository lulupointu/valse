import Foundation

public typealias TimelineSlotID = Identifier<TimelineSlot>

/// One timeline of a multi-timeline project (TL-023, CapCut "Multi-timeline"). Each timeline has its own sequence
/// settings (TL-043: ratio, resolution, fps, colour space) and shares the project's media bin and compound clips.
///
/// Storage: `Project.timeline` / `Project.settings` always hold the ACTIVE timeline, so every engine path (evaluator,
/// composition, export, captions…) keeps working unchanged. `Project.timelines` lists every timeline in tab order;
/// the active slot's `timeline` / `settings` are a stale copy refreshed on every switch (`MultiTimelineOps.sync`).
public struct TimelineSlot: Codable, Sendable, Equatable, Identifiable {
    public var id: TimelineSlotID
    public var name: String
    public var timeline: Timeline
    public var settings: ProjectSettings
    public init(id: TimelineSlotID = TimelineSlotID(), name: String, timeline: Timeline, settings: ProjectSettings) {
        self.id = id; self.name = name; self.timeline = timeline; self.settings = settings
    }
}

/// Pure multi-timeline operations (one undo step each through `Edit`).
public enum MultiTimelineOps {
    /// Turns a single-timeline project into a slot list (the current timeline becomes slot 1 named `name`).
    public static func ensureSlots(_ p: inout Project, firstName: String) {
        guard p.timelines?.isEmpty ?? true else { return }
        let s = TimelineSlot(name: firstName, timeline: p.timeline, settings: p.settings)
        p.timelines = [s]
        p.activeTimelineID = s.id
    }

    /// Index of the active slot (nil for a single-timeline project).
    public static func activeIndex(_ p: Project) -> Int? {
        guard let id = p.activeTimelineID else { return nil }
        return p.timelines?.firstIndex { $0.id == id }
    }

    /// Copies the live timeline/settings into the active slot.
    public static func sync(_ p: inout Project) {
        guard let i = activeIndex(p) else { return }
        p.timelines![i].timeline = p.timeline
        p.timelines![i].settings = p.settings
    }

    /// The project with every slot up to date (for saving, "Import project" and tests).
    public static func synced(_ p: Project) -> Project { var q = p; sync(&q); return q }

    /// "New timeline": appends an empty timeline (same sequence settings as the active one, or `settings`) after the
    /// active tab and makes it active. `clips` (from "New timeline with selected items") are copied onto it with
    /// their relative timing and track kinds. Returns the new slot id.
    @discardableResult
    public static func newTimeline(_ p: inout Project, name: String, firstName: String, clips: Set<ClipID> = [],
                                   settings: ProjectSettings? = nil) throws -> TimelineSlotID {
        ensureSlots(&p, firstName: firstName)
        sync(&p)
        var tl = Timeline()
        if !clips.isEmpty { tl = try copySelection(clips, from: p.timeline) }
        let slot = TimelineSlot(name: name, timeline: tl, settings: settings ?? p.settings)
        let at = (activeIndex(p) ?? (p.timelines!.count - 1)) + 1
        p.timelines!.insert(slot, at: at)
        load(&p, slot.id)
        return slot.id
    }

    /// Activates another timeline (the current one is saved into its slot first).
    public static func switchTo(_ p: inout Project, _ id: TimelineSlotID) throws {
        guard p.timelines?.contains(where: { $0.id == id }) == true else { throw EditError.nothingToDo }
        guard id != p.activeTimelineID else { throw EditError.nothingToDo }
        sync(&p)
        load(&p, id)
    }

    private static func load(_ p: inout Project, _ id: TimelineSlotID) {
        guard let s = p.timelines?.first(where: { $0.id == id }) else { return }
        p.timeline = s.timeline
        p.settings = s.settings
        p.activeTimelineID = id
    }

    public static func rename(_ p: inout Project, _ id: TimelineSlotID, to name: String) throws {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let i = p.timelines?.firstIndex(where: { $0.id == id }) else { throw EditError.nothingToDo }
        p.timelines![i].name = n
    }

    /// Duplicates a timeline (placed after it, becomes active).
    @discardableResult
    public static func duplicate(_ p: inout Project, _ id: TimelineSlotID, name: String) throws -> TimelineSlotID {
        sync(&p)
        guard let i = p.timelines?.firstIndex(where: { $0.id == id }) else { throw EditError.nothingToDo }
        var copy = p.timelines![i]
        copy.id = TimelineSlotID()
        copy.name = name
        copy.timeline = freshIDs(copy.timeline)
        p.timelines!.insert(copy, at: i + 1)
        load(&p, copy.id)
        return copy.id
    }

    /// Deletes a timeline (never the last one). Deleting the active one activates its neighbour.
    public static func delete(_ p: inout Project, _ id: TimelineSlotID) throws {
        guard var slots = p.timelines, slots.count > 1, let i = slots.firstIndex(where: { $0.id == id }) else { throw EditError.nothingToDo }
        let wasActive = id == p.activeTimelineID
        if !wasActive { sync(&p); slots = p.timelines! }
        slots.remove(at: i)
        p.timelines = slots
        if wasActive { load(&p, slots[min(i, slots.count - 1)].id) }
        if slots.count == 1 { p.timelines = nil; p.activeTimelineID = nil }
    }

    /// Moves a tab (drag in the tab strip).
    public static func move(_ p: inout Project, _ id: TimelineSlotID, to index: Int) throws {
        guard var slots = p.timelines, let i = slots.firstIndex(where: { $0.id == id }) else { throw EditError.nothingToDo }
        let s = slots.remove(at: i)
        slots.insert(s, at: min(max(index, 0), slots.count))
        p.timelines = slots
    }

    /// Selected clips as a new timeline: relative timing, track kinds and stacking kept, main-track clips go to the
    /// main track (packed from 0 when the magnet is on), fresh ids, links/groups dropped.
    static func copySelection(_ ids: Set<ClipID>, from src: Timeline) throws -> Timeline {
        let picked = src.tracks.enumerated().flatMap { ti, t in t.clips.filter { ids.contains($0.id) }.map { (ti, $0) } }
        guard let start = picked.map(\.1.start).min() else { throw EditError.nothingToDo }
        var tl = Timeline()
        let main = tl.mainTrackIndex!
        var trackFor: [Int: Int] = [:]
        for ti in src.tracks.indices where picked.contains(where: { $0.0 == ti }) {
            if src.tracks[ti].isMain { trackFor[ti] = main; continue }
            tl.tracks.append(Track(kind: src.tracks[ti].kind))
            trackFor[ti] = tl.tracks.count - 1
        }
        for (ti, c) in picked {
            var n = c
            n.id = ClipID(); n.start = c.start - start; n.linkedTo = nil; n.groupID = nil; n.transitionOut = nil
            tl.tracks[trackFor[ti]!].clips.append(n)
        }
        for i in tl.tracks.indices { tl.tracks[i].sortClips() }
        if !tl.tracks[main].clips.isEmpty {
            var t = Time.zero
            for i in tl.tracks[main].clips.indices { tl.tracks[main].clips[i].start = t; t += tl.tracks[main].clips[i].duration }
        }
        return tl
    }

    /// Same timeline with new track/clip ids (a duplicated timeline must not share clip ids with the original:
    /// caches and selection key on them).
    static func freshIDs(_ src: Timeline) -> Timeline {
        var tl = src
        var map: [ClipID: ClipID] = [:]
        for ti in tl.tracks.indices {
            tl.tracks[ti].id = TrackID()
            for ci in tl.tracks[ti].clips.indices {
                let n = ClipID()
                map[tl.tracks[ti].clips[ci].id] = n
                tl.tracks[ti].clips[ci].id = n
            }
        }
        for ti in tl.tracks.indices {
            for ci in tl.tracks[ti].clips.indices {
                if let l = tl.tracks[ti].clips[ci].linkedTo { tl.tracks[ti].clips[ci].linkedTo = map[l] }
                if let e = tl.tracks[ti].clips[ci].extractedFrom { tl.tracks[ti].clips[ci].extractedFrom = map[e] }
            }
        }
        return tl
    }

    /// Every timeline's tracks (active first): compounds/media in use anywhere in the project.
    public static func allTimelines(_ p: Project) -> [Timeline] {
        [p.timeline] + (p.compoundEdit ?? []).map(\.parent)   // parents while editing inside a compound (TL-021)
            + (p.timelines ?? []).filter { $0.id != p.activeTimelineID }.map(\.timeline)
    }
}
