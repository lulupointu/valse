import SwiftUI
import AppKit
import MontageCore
import MontageEffects
import MontageEngine

/// Asset-panel drag payloads beyond `DragPayload`'s single items, and the timeline-side handling of them.
extension DragPayload {
    /// Several bin media dragged together (Media tab multi-selection), in order.
    public static func mediaList(_ ids: [MediaID]) -> String {
        "montage-medialist:" + ids.map(\.raw.uuidString).joined(separator: ",")
    }

    public static func parseMediaList(_ s: String) -> [MediaID]? {
        guard s.hasPrefix("montage-medialist:") else { return nil }
        let ids = s.dropFirst("montage-medialist:".count).split(separator: ",").compactMap { MediaID(string: String($0)) }
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

    /// Adds several bin media one after another starting at `time` (default: playhead), as one selection.
    public func addMediaToTimeline(_ ids: [MediaID], at time: Time? = nil, target: InsertTarget = .automatic) {
        var t = time ?? transport.playhead
        var added: Set<ClipID> = []
        for id in ids {
            guard let a = project.asset(id), let c = addToTimeline(id, at: t, target: target) else { continue }
            added.insert(c)
            t = (project.timeline.clip(c)?.end) ?? (t + a.defaultClipDuration)
        }
        if !added.isEmpty { selection = added }
    }
}
