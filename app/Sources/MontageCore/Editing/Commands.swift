import Foundation

/// A user-visible edit. `apply` mutates the project or throws (leaving it untouched).
/// Undo/redo is snapshot based (`EditSession`), so commands never implement an inverse.
/// To add an edit: write a struct conforming to `EditCommand` (or use `Edit(nameKey:) { project in … }`).
public protocol EditCommand: Sendable {
    /// Localization key of the undo menu label, e.g. "cmd.split" → "Split" / "Fractionner".
    var nameKey: String { get }
    func apply(to project: inout Project) throws
}

/// Closure-based command for one-off edits.
public struct Edit: EditCommand {
    public let nameKey: String
    let body: @Sendable (inout Project) throws -> Void
    public init(_ nameKey: String, _ body: @escaping @Sendable (inout Project) throws -> Void) {
        self.nameKey = nameKey; self.body = body
    }
    public func apply(to project: inout Project) throws { try body(&project) }
}

/// Edits one clip in place (property changes from the inspector).
public struct UpdateClip: EditCommand {
    public let nameKey: String
    public let clipID: ClipID
    let body: @Sendable (inout Clip) -> Void
    public init(_ clipID: ClipID, nameKey: String = "cmd.editClip", _ body: @escaping @Sendable (inout Clip) -> Void) {
        self.clipID = clipID; self.nameKey = nameKey; self.body = body
    }
    public func apply(to project: inout Project) throws {
        guard var c = project.timeline.clip(clipID) else { throw EditError.clipNotFound }
        body(&c)
        project.timeline[clip: clipID] = c
    }
}

public struct AddMedia: EditCommand {
    public let nameKey = "cmd.import"
    public let assets: [MediaAsset]
    public init(_ assets: [MediaAsset]) { self.assets = assets }
    public func apply(to project: inout Project) throws {
        let existing = Set(project.media.map(\.contentHash))
        let fresh = assets.filter { !existing.contains($0.contentHash) || $0.contentHash.isEmpty }
        guard !fresh.isEmpty else { throw EditError.nothingToDo }
        project.media.append(contentsOf: fresh)
    }
}

public struct InsertClip: EditCommand {
    public let nameKey: String
    public let clip: Clip
    public let target: InsertTarget
    public init(_ clip: Clip, target: InsertTarget = .automatic, nameKey: String = "cmd.addClip") {
        self.clip = clip; self.target = target; self.nameKey = nameKey
    }
    public func apply(to project: inout Project) throws { try TimelineOps.insert(clip, into: &project, target: target) }
}

public struct MoveClip: EditCommand {
    public let nameKey = "cmd.move"
    public let clipID: ClipID
    public let start: Time
    public let track: TrackID?
    public init(_ clipID: ClipID, to start: Time, track: TrackID? = nil) { self.clipID = clipID; self.start = start; self.track = track }
    public func apply(to project: inout Project) throws {
        try TimelineOps.move(clipID, to: start, track: track, in: &project.timeline)
    }
}

public struct TrimClip: EditCommand {
    public let nameKey = "cmd.trim"
    public let clipID: ClipID
    public let edge: TrimEdge
    public let time: Time
    public init(_ clipID: ClipID, edge: TrimEdge, to time: Time) { self.clipID = clipID; self.edge = edge; self.time = time }
    public func apply(to project: inout Project) throws { try TimelineOps.trim(clipID, edge: edge, to: time, in: &project) }
}

/// Splits the given clips (or, if empty, every clip under the playhead on unlocked tracks) at `time`.
public struct SplitClips: EditCommand {
    public let nameKey = "cmd.split"
    public let clipIDs: [ClipID]
    public let time: Time
    public init(_ clipIDs: [ClipID], at time: Time) { self.clipIDs = clipIDs; self.time = time }
    public func apply(to project: inout Project) throws {
        let ids = clipIDs.isEmpty
            ? project.timeline.tracks.filter { !$0.isLocked }.flatMap { $0.clips(at: time).map(\.id) }
            : clipIDs
        var did = false
        for id in ids {
            if (try? TimelineOps.split(id, at: time, in: &project.timeline)) != nil { did = true }
        }
        if !did { throw EditError.invalidTime }
    }
}

public struct DeleteClips: EditCommand {
    public let nameKey = "cmd.delete"
    public let clipIDs: Set<ClipID>
    public init(_ clipIDs: Set<ClipID>) { self.clipIDs = clipIDs }
    public func apply(to project: inout Project) throws { try TimelineOps.delete(clipIDs, in: &project.timeline) }
}

public struct SetSpeed: EditCommand {
    public let nameKey = "cmd.speed"
    public let clipID: ClipID
    public let speed: Speed
    public init(_ clipID: ClipID, _ speed: Speed) { self.clipID = clipID; self.speed = speed }
    public func apply(to project: inout Project) throws { try TimelineOps.setSpeed(clipID, speed, in: &project.timeline) }
}

public struct SetTransition: EditCommand {
    public let nameKey = "cmd.transition"
    public let clipID: ClipID
    public let transition: TransitionInstance?
    public init(_ clipID: ClipID, _ transition: TransitionInstance?) { self.clipID = clipID; self.transition = transition }
    public func apply(to project: inout Project) throws {
        try TimelineOps.setTransition(clipID, transition, in: &project.timeline)
    }
}

public struct SetTimelineOption: EditCommand {
    public enum Option: Sendable { case magnet(Bool), linkage(Bool), snapping(Bool) }
    public let nameKey = "cmd.timelineOption"
    public let option: Option
    public init(_ option: Option) { self.option = option }
    public func apply(to project: inout Project) throws {
        switch option {
        case .magnet(let on):
            project.timeline.mainTrackMagnet = on
            if on { TimelineOps.compactMain(&project.timeline) }
        case .linkage(let on): project.timeline.linkage = on
        case .snapping(let on): project.timeline.snapping = on
        }
    }
}

public struct UpdateSettings: EditCommand {
    public let nameKey = "cmd.projectSettings"
    let body: @Sendable (inout ProjectSettings) -> Void
    public init(_ body: @escaping @Sendable (inout ProjectSettings) -> Void) { self.body = body }
    public func apply(to project: inout Project) throws { body(&project.settings) }
}
