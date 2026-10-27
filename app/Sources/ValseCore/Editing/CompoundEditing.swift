import Foundation

/// One level of "edit inside a compound clip" (TL-021, double-click a compound clip): while inside, `Project.timeline`
/// IS the compound's nested timeline (so every editor tool and the preview work on it unchanged) and the frame keeps
/// the parent timeline to return to.
public struct CompoundEditFrame: Codable, Sendable, Equatable {
    public var compoundID: CompoundID
    /// The compound clip that was entered (in `parent`).
    public var clipID: ClipID
    public var parent: Timeline
}

extension Project {
    /// Compound-editing stack (outermost first); nil = editing the project's own timeline.
    public var isInsideCompound: Bool { !(compoundEdit ?? []).isEmpty }
}

public enum CompoundEditing {
    /// Enters the compound clip `id` of the current timeline.
    public static func enter(_ id: ClipID, in p: inout Project) throws {
        guard let c = p.timeline.clip(id), case .compound(let cid) = c.content, let comp = p.compound(cid) else {
            throw EditError.nothingToDo
        }
        guard (p.compoundEdit?.count ?? 0) < Project.maxCompoundDepth else { throw EditError.nothingToDo }
        var stack = p.compoundEdit ?? []
        stack.append(CompoundEditFrame(compoundID: cid, clipID: id, parent: p.timeline))
        p.compoundEdit = stack
        p.timeline = comp.timeline
    }

    /// Leaves the innermost compound: its edited timeline is stored back and the parent comes back; the compound
    /// clip is shortened if the nested timeline no longer covers it.
    public static func exit(_ p: inout Project) throws {
        guard var stack = p.compoundEdit, let f = stack.popLast() else { throw EditError.nothingToDo }
        let edited = p.timeline
        if let i = p.compounds?.firstIndex(where: { $0.id == f.compoundID }) { p.compounds?[i].timeline = edited }
        var parent = f.parent
        if let c = parent.clip(f.clipID) {
            let v = max(c.speed.averageRate, 0.01)
            let available = max(.zero, edited.duration - c.sourceStart) / v
            if available < c.duration {
                let starts = TimelineOps.mainStarts(parent)
                parent[clip: f.clipID]?.duration = max(TimelineOps.minimumClipDuration, available)
                if parent.mainTrackMagnet { TimelineOps.compactMain(&parent, previousStarts: starts) }
            }
        }
        p.timeline = parent
        p.compoundEdit = stack.isEmpty ? nil : stack
    }

    /// Back to the project's own timeline from any depth.
    public static func exitAll(_ p: inout Project) {
        while p.isInsideCompound { try? exit(&p) }
    }

    /// Breadcrumb names, outermost first (compound names).
    public static func path(_ p: Project) -> [String] {
        (p.compoundEdit ?? []).map { f in p.compound(f.compoundID)?.name ?? "" }
    }
}
