import Foundation

/// One undoable step.
public struct HistoryEntry: Sendable {
    public let nameKey: String
    public let before: Project
    public let after: Project
}

/// Project state + undo/redo history.
///
/// History stores whole-project snapshots. `Project` is a tree of value types backed by copy-on-write arrays, so a
/// snapshot shares every unchanged track/clip array with its neighbours: memory per step ≈ the arrays the edit touched.
/// Continuous gestures (slider drags, clip drags) use `beginGesture` / `updateGesture` / `endGesture` so the whole drag
/// becomes ONE undo step while the preview updates live.
public struct EditSession: Sendable {
    public private(set) var project: Project
    public private(set) var undoStack: [HistoryEntry] = []
    public private(set) var redoStack: [HistoryEntry] = []
    /// Increments on every change (edits, undo, redo, gesture updates). Cheap change detection for observers.
    public private(set) var revision: Int = 0
    /// Revision at last save.
    public private(set) var savedRevision: Int = 0
    public var historyLimit: Int = 200

    private var gestureBase: Project?
    private var gestureName: String?

    public init(project: Project) { self.project = project }

    public var canUndo: Bool { !undoStack.isEmpty && gestureBase == nil }
    public var canRedo: Bool { !redoStack.isEmpty && gestureBase == nil }
    public var undoNameKey: String? { undoStack.last?.nameKey }
    public var redoNameKey: String? { redoStack.last?.nameKey }
    public var isDirty: Bool { revision != savedRevision }
    public var isInGesture: Bool { gestureBase != nil }

    /// Applies a command as one undo step. Throws (and leaves the project untouched) if the command fails.
    public mutating func perform(_ command: any EditCommand) throws {
        if gestureBase != nil { endGesture() }
        var p = project
        try command.apply(to: &p)
        FreezeLinks.sync(&p)
        guard p != project else { return }
        commit(nameKey: command.nameKey, before: project, after: p)
    }

    /// Starts a coalesced gesture (e.g. slider drag).
    public mutating func beginGesture(_ nameKey: String) {
        if gestureBase != nil { endGesture() }
        gestureBase = project
        gestureName = nameKey
    }

    /// Live update during a gesture: applied to the base snapshot each time (idempotent drags), no history entry.
    public mutating func updateGesture(_ body: (inout Project) throws -> Void) rethrows {
        guard let base = gestureBase else {
            var p = project; try body(&p); project = p; revision += 1; return
        }
        var p = base
        try body(&p)
        FreezeLinks.sync(&p)
        project = p
        revision += 1
    }

    /// Live cumulative update during a gesture (mutates the current state rather than the base).
    public mutating func updateGestureIncrementally(_ body: (inout Project) throws -> Void) rethrows {
        var p = project; try body(&p); project = p; revision += 1
    }

    public mutating func endGesture() {
        guard let base = gestureBase else { return }
        let name = gestureName ?? "cmd.edit"
        gestureBase = nil; gestureName = nil
        if base != project { commit(nameKey: name, before: base, after: project) }
    }

    public mutating func cancelGesture() {
        guard let base = gestureBase else { return }
        project = base; gestureBase = nil; gestureName = nil; revision += 1
    }

    @discardableResult
    public mutating func undo() -> String? {
        guard gestureBase == nil, let e = undoStack.popLast() else { return nil }
        project = e.before
        redoStack.append(e)
        revision += 1
        return e.nameKey
    }

    @discardableResult
    public mutating func redo() -> String? {
        guard gestureBase == nil, let e = redoStack.popLast() else { return nil }
        project = e.after
        undoStack.append(e)
        revision += 1
        return e.nameKey
    }

    public mutating func markSaved() { savedRevision = revision }

    /// Replaces the project without history (open / recovery / migration).
    public mutating func reset(_ project: Project) {
        self.project = project
        undoStack.removeAll(); redoStack.removeAll()
        gestureBase = nil; gestureName = nil
        revision += 1; savedRevision = revision
    }

    private mutating func commit(nameKey: String, before: Project, after: Project) {
        var a = after
        a.modifiedAt = Date()
        project = a
        undoStack.append(HistoryEntry(nameKey: nameKey, before: before, after: a))
        if undoStack.count > historyLimit { undoStack.removeFirst(undoStack.count - historyLimit) }
        redoStack.removeAll()
        revision += 1
    }
}
