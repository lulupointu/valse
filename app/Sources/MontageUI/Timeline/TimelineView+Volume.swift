import AppKit
import MontageCore
import MontageEngine

/// Clip volume line (C3-2, CapCut [10]): a horizontal line over the audio area of a clip (the waveform of an audio-lane
/// clip, the audio strip under a main-track video's filmstrip). Hover = ↕ cursor; drag = volume with a dB tooltip, one
/// undo step ("cmd.volume"); keyframed volume moves as a whole. Mapping / drag maths: `ClipVolumeLine`.
extension TimelineView {
    /// Audio area carrying the volume line, nil when the clip has no audible media drawn on this row.
    func volumeArea(_ clip: Clip, row: TimelineLayout.Row, track: Track, layout l: TimelineLayout) -> CGRect? {
        guard let asset = drawCache.asset(clip.mediaID)?.asset, asset.hasAudio, !clip.isFreezeFrame else { return nil }
        let r = l.clipRect(clip, row: row).insetBy(dx: 0.5, dy: 0)
        if track.kind == .audio { return CGRect(x: r.minX, y: r.minY + 16, width: r.width, height: r.height - 18) }
        if asset.kind != .audio, track.isMain, r.height >= 60 { return CGRect(x: r.minX, y: r.maxY - 16, width: r.width, height: 16) }
        return nil
    }

    /// Height used for the drag sensitivity (the 16 pt strip would be 5 dB per point).
    static func volumeDragHeight(_ area: CGRect) -> CGFloat { max(area.height, 40) }

    /// Draws the line (a curve when the volume is keyframed). Brighter while hovered / dragged.
    func drawVolumeLine(_ c: inout Canvas2D, _ clip: Clip, area a: CGRect, layout l: TimelineLayout, dim: Double) {
        let active: Bool = {
            if case .volume(let id, _, _) = drag { return id == clip.id }
            return hoverVolumeClip == clip.id
        }()
        let color = RGBA(1, 1, 1, (active ? 0.95 : 0.55) * dim)
        let h: CGFloat = active ? 1.5 : 1
        let x0 = max(a.minX, TimelineLayout.headerWidth), x1 = min(a.maxX, bounds.width)
        guard x1 > x0 else { return }
        if clip.hasKeyframes(.volume) {
            var x = x0
            while x < x1 {
                let t = (l.time(atX: x + 1.5) - clip.start).clamped(.zero, clip.duration)
                let y = ClipVolumeLine.y(gain: ClipVolumeLine.gain(of: clip, at: t), in: a)
                c.rect(CGRect(x: x, y: y - h / 2, width: min(3, x1 - x), height: h), color)
                x += 3
            }
        } else {
            let y = ClipVolumeLine.y(gain: clip.audio.volume, in: a)
            c.rect(CGRect(x: x0, y: y - h / 2, width: x1 - x0, height: h), color)
        }
    }

    /// Clip whose volume line is under `pt` (within `ClipVolumeLine.grabTolerance`, away from the trim edges).
    func volumeLineHit(_ pt: CGPoint, layout l: TimelineLayout) -> (id: ClipID, area: CGRect)? {
        guard pt.x > TimelineLayout.headerWidth, let ri = l.rowIndex(atY: pt.y) else { return nil }
        let row = l.rows[ri]
        let track = store.project.timeline.tracks[row.trackIndex]
        guard !track.isLocked, track.kind == .audio || track.isMain else { return nil }
        let t = l.time(atX: pt.x)
        for clip in track.clips(in: TimeRange(start: t, duration: Time(ticks: 1))).reversed() {
            guard let a = volumeArea(clip, row: row, track: track, layout: l),
                  pt.x > a.minX + TimelineLayout.edgeHandle, pt.x < a.maxX - TimelineLayout.edgeHandle,
                  pt.y >= a.minY - ClipVolumeLine.grabTolerance, pt.y <= a.maxY + ClipVolumeLine.grabTolerance else { continue }
            let y = ClipVolumeLine.y(gain: ClipVolumeLine.gain(of: clip, at: (t - clip.start).clamped(.zero, clip.duration)), in: a)
            if abs(pt.y - y) <= ClipVolumeLine.grabTolerance { return (clip.id, a) }
        }
        return nil
    }

    /// Mouse-down on a volume line: starts the volume gesture.
    func beginVolumeDrag(_ pt: CGPoint, layout l: TimelineLayout) -> Bool {
        guard let hit = volumeLineHit(pt, layout: l), let clip = store.project.timeline.clip(hit.id) else { return false }
        if !store.selection.contains(hit.id) { store.select([hit.id]) }
        drag = .volume(hit.id, grabY: pt.y, origin: clip)
        store.beginGesture("cmd.volume")
        volumeLabel(clip, at: pt, l)
        return true
    }

    func updateVolumeDrag(_ id: ClipID, grabY: CGFloat, origin: Clip, at pt: CGPoint, layout l: TimelineLayout) {
        let tl = store.project.timeline
        guard let loc = tl.locate(id), let row = l.row(for: tl.tracks[loc.track].id),
              let a = volumeArea(origin, row: row, track: tl.tracks[loc.track], layout: l) else { return }
        let db = ClipVolumeLine.draggedDB(from: AudioProps.decibels(origin.audio.volume), dy: pt.y - grabY,
                                          areaHeight: Self.volumeDragHeight(a))
        store.updateGesture { p in
            guard var c = p.timeline.clip(id) else { return }
            ClipVolumeLine.apply(db: db, origin: origin, to: &c)
            p.timeline[clip: id] = c
        }
        if let c = store.project.timeline.clip(id) { volumeLabel(c, at: pt, l) }
    }

    /// dB tooltip ("−7.5dB") next to the pointer: the volume under the pointer.
    private func volumeLabel(_ clip: Clip, at pt: CGPoint, _ l: TimelineLayout) {
        let g = ClipVolumeLine.gain(of: clip, at: (l.time(atX: pt.x) - clip.start).clamped(.zero, clip.duration))
        trimLabel = (pt.x + 34, pt.y, AudioBasicSection.dbFormat(max(ClipVolumeLine.minDB, AudioProps.decibels(g))))
    }
}
