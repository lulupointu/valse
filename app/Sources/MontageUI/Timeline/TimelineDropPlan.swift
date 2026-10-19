import CoreGraphics
import MontageCore

/// Where a media drag from the library would land on the timeline (C3-1, CapCut [6]/[7]): drives the grey placeholder
/// drawn while dragging and the drop itself, so what you see is what you get. Pure (unit-tested).
///
/// - On the magnetic main track: ripple insert at the clip boundary nearest the pointer (the following clips are drawn
///   pushed right by the placeholder's length).
/// - On a compatible lane where it fits: on that lane at the (snapped) pointer time.
/// - Between two lanes / above the top lane / on a lane where it doesn't fit: a new lane at that place.
/// - Audio goes to an audio lane where it fits, else a new audio lane at the bottom.
public struct TimelineDropPlan: Equatable {
    public enum Placement: Equatable {
        /// Inserted into the magnetic main track before clip `index` (clips.count = at the end).
        case main(index: Int)
        /// Onto the existing lane `row` (layout row index).
        case lane(row: Int)
        /// On a new lane above layout row `slot` (rows.count = below every row).
        case newLane(slot: Int)
    }

    public var placement: Placement
    /// Timeline start of the (first) dropped clip.
    public var start: Time
    public var duration: Time
    /// What the drop passes to the insert commands.
    public var target: InsertTarget

    public init(placement: Placement, start: Time, duration: Time, target: InsertTarget) {
        self.placement = placement; self.start = start; self.duration = duration; self.target = target
    }

    /// Main-track clips at or after this index are pushed right by `duration` in the preview.
    public var rippleIndex: Int? { if case .main(let i) = placement { return i }; return nil }

    /// - Parameters:
    ///   - time: pointer time (already snapped by the caller when snapping is on).
    ///   - kind: `.audio` for audio media, `.video` for video / images.
    ///   - mainProbe: time that picks the main-track boundary (moves use the clip's centre, like CapCut); default `time`.
    ///   - home: layout row of the track a moved clip comes from (text / sticker / effect clips stay there when the
    ///     pointer is over a lane they can't go on).
    public static func plan(layout l: TimelineLayout, timeline tl: Timeline, point pt: CGPoint, time: Time,
                            duration: Time, kind: TrackKind, mainProbe: Time? = nil, home: Int? = nil) -> TimelineDropPlan {
        let range = TimeRange(start: time, duration: duration)
        func fits(_ ri: Int) -> Bool {
            let t = tl.tracks[l.rows[ri].trackIndex]
            return !t.isLocked && t.clips.allSatisfy { !$0.range.overlaps(range) }
        }
        if kind != .audio && kind != .video {
            // text / sticker / effect layers: their own kind of lane, a new lane at a boundary, never the main track
            if let slot = l.insertionSlot(atY: pt.y), slot < l.rows.count, l.rows[slot].kind != .audio {
                return .init(placement: .newLane(slot: slot), start: time, duration: duration, target: .newTrackAbove(l.rows[slot].trackID))
            }
            if let first = l.rows.first, pt.y < first.y {
                return .init(placement: .newLane(slot: 0), start: time, duration: duration, target: .newTrackAbove(first.trackID))
            }
            let ri = l.rowIndex(atY: pt.y).flatMap { l.rows[$0].kind == kind && !tl.tracks[l.rows[$0].trackIndex].isLocked ? $0 : nil } ?? home
            guard let ri else { return .init(placement: .newLane(slot: 0), start: time, duration: duration, target: .newTrack) }
            if fits(ri) { return .init(placement: .lane(row: ri), start: time, duration: duration, target: .track(l.rows[ri].trackID)) }
            return .init(placement: .newLane(slot: ri), start: time, duration: duration, target: .newTrackAbove(l.rows[ri].trackID))
        }
        if kind == .audio {
            if let ri = l.rowIndex(atY: pt.y), l.rows[ri].kind == .audio, l.insertionSlot(atY: pt.y) == nil, fits(ri) {
                return .init(placement: .lane(row: ri), start: time, duration: duration, target: .track(l.rows[ri].trackID))
            }
            if let ri = l.rows.indices.first(where: { l.rows[$0].kind == .audio && fits($0) }), l.insertionSlot(atY: pt.y) == nil {
                return .init(placement: .lane(row: ri), start: time, duration: duration, target: .track(l.rows[ri].trackID))
            }
            return .init(placement: .newLane(slot: l.rows.count), start: time, duration: duration, target: .newTrack)
        }
        // Visual media. A lane boundary above a visual row = a new lane right there.
        if let slot = l.insertionSlot(atY: pt.y), slot < l.rows.count, l.rows[slot].kind != .audio {
            return .init(placement: .newLane(slot: slot), start: time, duration: duration,
                         target: .newTrackAbove(l.rows[slot].trackID))
        }
        if let ri = l.rowIndex(atY: pt.y) {
            let row = l.rows[ri]
            if row.isMain { return mainPlan(l, tl, time: time, duration: duration, probe: mainProbe) }
            if row.kind == .video, !tl.tracks[row.trackIndex].isLocked {
                if fits(ri) { return .init(placement: .lane(row: ri), start: time, duration: duration, target: .track(row.trackID)) }
                return .init(placement: .newLane(slot: ri), start: time, duration: duration, target: .newTrackAbove(row.trackID))
            }
            if row.kind != .audio {   // text / sticker / effect lane: a new video lane above it
                return .init(placement: .newLane(slot: ri), start: time, duration: duration, target: .newTrackAbove(row.trackID))
            }
        }
        if let first = l.rows.first, pt.y < first.y {
            return .init(placement: .newLane(slot: 0), start: time, duration: duration, target: .newTrackAbove(first.trackID))
        }
        return mainPlan(l, tl, time: time, duration: duration, probe: mainProbe)
    }

    /// Ripple insert on the main track (or a plain placement when the magnet is off / there is no main row).
    static func mainPlan(_ l: TimelineLayout, _ tl: Timeline, time: Time, duration: Time, probe: Time? = nil) -> TimelineDropPlan {
        guard let mi = tl.mainTrackIndex, let ri = l.rows.firstIndex(where: { $0.trackIndex == mi }) else {
            return .init(placement: .newLane(slot: 0), start: time, duration: duration, target: .automatic)
        }
        let main = tl.tracks[mi]
        guard tl.mainTrackMagnet else {
            return .init(placement: .lane(row: ri), start: time, duration: duration, target: .automatic)
        }
        let index = TimelineOps.magneticIndex(for: probe ?? time, in: main)
        let start = index < main.clips.count ? main.clips[index].start : (main.clips.last?.end ?? .zero)
        return .init(placement: .main(index: index), start: start, duration: duration, target: .automatic)
    }
}
