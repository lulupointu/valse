import SwiftUI
import AppKit
import ValseCore
import ValseEffects
import ValseEngine

/// Asset-panel drag payloads beyond `DragPayload`'s single items, and the timeline-side handling of them.
extension DragPayload {
    /// Several bin media dragged together (Media tab multi-selection), in order.
    public static func mediaList(_ ids: [MediaID]) -> String {
        "valse-medialist:" + ids.map(\.raw.uuidString).joined(separator: ",")
    }

    public static func parseMediaList(_ s: String) -> [MediaID]? {
        guard s.hasPrefix("valse-medialist:") else { return nil }
        let ids = s.dropFirst("valse-medialist:".count).split(separator: ",").compactMap { MediaID(string: String($0)) }
        return ids.isEmpty ? nil : ids
    }
}

/// Registered handlers for library payloads the timeline doesn't know natively (stock, music…). Each returns true
/// when it handled the string.
@MainActor
public enum LibraryDropHandlers {
    public typealias Handler = (_ payload: String, _ store: EditorStore, _ time: Time, _ target: InsertTarget) -> Bool
    public typealias Duration = (_ payload: String, _ store: EditorStore) -> Time?
    public private(set) static var handlers: [Handler] = [mediaListHandler, AudioLibraryPayload.dropHandler, MediaLibraryItems.stockDropHandler]
    public private(set) static var durations: [Duration] = [MediaLibraryItems.stockDropDuration, mediaDuration, AudioLibraryPayload.dropDuration]

    public static func register(_ h: @escaping Handler, duration: Duration? = nil) {
        handlers.append(h)
        if let duration { durations.append(duration) }
    }

    static let mediaListHandler: Handler = { s, store, time, target in
        guard let ids = DragPayload.parseMediaList(s) else { return false }
        store.addMediaToTimeline(ids, at: time, target: target)
        return true
    }

    static let mediaDuration: Duration = { s, store in
        if let ids = DragPayload.parseMediaList(s) {
            return ids.compactMap { store.project.asset($0)?.defaultClipDuration }.reduce(.zero, +)
        }
        switch DragPayload.parse(s) {
        case .media(let id)?: return store.project.asset(id)?.defaultClipDuration
        case .effect?, .sticker?, .text?: return Time(3)
        default: return nil
        }
    }
}

extension EditorStore {
    /// Timeline drop of a library payload not handled natively (multi-media, stock, music). Returns true if handled.
    public func handleLibraryDrop(_ payload: String, at time: Time, target: InsertTarget) -> Bool {
        for h in LibraryDropHandlers.handlers where h(payload, self, time, target) { return true }
        return false
    }

    /// Length of the clip(s) a dragged payload would create (timeline drop ghost), nil = unknown.
    public func dropPreviewDuration(_ payload: String) -> Time? {
        for d in LibraryDropHandlers.durations { if let t = d(payload, self) { return t } }
        return nil
    }

    /// Track kind of the clip(s) a dragged media payload creates (`.audio` / `.video`), nil = not a media payload
    /// (effects, stickers, text… keep the plain drop indicator). Drives the timeline placeholder (C3-1).
    public func dropPreviewKind(_ payload: String) -> TrackKind? {
        if let ids = DragPayload.parseMediaList(payload) {
            let kinds = ids.compactMap { project.asset($0)?.kind }
            if kinds.isEmpty { return nil }
            return kinds.allSatisfy { $0 == .audio } ? .audio : .video
        }
        if case .media(let id)? = DragPayload.parse(payload) {
            return project.asset(id).map { $0.kind == .audio ? .audio : .video }
        }
        if DragPayload.parseStock(payload) != nil { return .video }
        if AudioLibraryPayload.dropDuration(payload, self) != nil { return .audio }
        return nil
    }

    /// Name shown on the drop placeholder (first media's name), nil = none.
    public func dropPreviewTitle(_ payload: String) -> String? {
        let ids = DragPayload.parseMediaList(payload) ?? {
            if case .media(let id)? = DragPayload.parse(payload) { return [id] }
            return []
        }()
        guard let first = ids.first.flatMap({ project.asset($0) }) else { return nil }
        return ids.count > 1 ? "\(first.name) +\(ids.count - 1)" : first.name
    }

    /// Adds several bin media one after another starting at `time` (default: playhead), as one selection.
    /// A "new track" target creates one lane for all of them (the next clips follow on it).
    public func addMediaToTimeline(_ ids: [MediaID], at time: Time? = nil, target: InsertTarget = .automatic) {
        var t = time ?? transport.playhead
        var added: Set<ClipID> = []
        let createsLane: Bool = { if case .newTrack = target { return true }; if case .newTrackAbove = target { return true }; return false }()
        var lane: [Bool: TrackID] = [:]   // audio? → lane created by this drop
        for id in ids {
            guard let a = project.asset(id) else { continue }
            let isAudio = a.kind == .audio
            let tgt = createsLane ? (lane[isAudio].map { InsertTarget.track($0) } ?? target) : target
            guard let c = addToTimeline(id, at: t, target: tgt) else { continue }
            added.insert(c)
            if createsLane, lane[isAudio] == nil, let loc = project.timeline.locate(c) { lane[isAudio] = project.timeline.tracks[loc.track].id }
            t = (project.timeline.clip(c)?.end) ?? (t + a.defaultClipDuration)
        }
        if !added.isEmpty { selection = added }
    }
}
