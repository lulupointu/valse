import Foundation

extension Clip {
    /// Shifts clip markers (clip-local) after a head trim; markers that fall before the clip start are dropped.
    mutating func shiftMarkers(by d: Time) {
        guard let ms = markers else { return }
        let moved: [Marker] = ms.map { (m0: Marker) -> Marker in var m = m0; m.time = m.time + d; return m }.filter { $0.time >= Time.zero }
        markers = moved.isEmpty ? nil : moved
    }

    /// Clip markers visible inside the clip (timeline time = `start + time`).
    public var visibleMarkers: [Marker] { (markers ?? []).filter { $0.time >= .zero && $0.time <= duration } }
}

extension TimelineOps {
    /// Adds a clip marker at timeline time `t` (TL-025, M with a clip selected). Returns its id.
    @discardableResult
    public static func addClipMarker(_ id: ClipID, at t: Time, color: RGBA? = nil, in tl: inout Timeline) throws -> MarkerID {
        guard let c = tl.clip(id) else { throw EditError.clipNotFound }
        guard t >= c.start, t <= c.end else { throw EditError.invalidTime }
        let local = t - c.start
        var ms = c.markers ?? []
        guard !ms.contains(where: { abs(($0.time - local).ticks) < Time(1.0 / 120).ticks }) else { throw EditError.nothingToDo }
        var m = Marker(time: local)
        if let color { m.color = color }
        ms.append(m)
        ms.sort { $0.time < $1.time }
        tl[clip: id]?.markers = ms
        return m.id
    }

    /// Removes every marker of the given clips ("Delete all markers in clip").
    public static func removeClipMarkers(_ ids: Set<ClipID>, in tl: inout Timeline) throws {
        var did = false
        for id in ids where !(tl.clip(id)?.markers ?? []).isEmpty { tl[clip: id]?.markers = nil; did = true }
        if !did { throw EditError.nothingToDo }
    }

    /// Timeline marker times plus every clip marker (absolute), sorted — for next/previous marker navigation.
    public static func allMarkerTimes(_ tl: Timeline) -> [Time] {
        var out = tl.markers.map(\.time)
        for t in tl.tracks { for c in t.clips { out += c.visibleMarkers.map { c.start + $0.time } } }
        return out.sorted()
    }
}
