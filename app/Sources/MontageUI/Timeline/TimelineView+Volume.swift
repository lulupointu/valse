import AppKit
import MontageCore
import MontageEngine

/// Clip volume line (C3-2, CapCut [10]): a horizontal line over the audio area of a clip (the waveform of an audio-lane
/// clip, the audio strip under a main-track video's filmstrip). Hover = ↕ cursor; drag = volume with a % tooltip, one
/// undo step ("cmd.volume"). Volume keyframes (C3b, CapCut [24]/[26]) are diamonds ON the line, always visible; the
/// line follows the keyframed curve; dragging a diamond moves that keyframe, dragging the line between diamonds moves
/// the keyframes bounding it (`ClipVolumeLine.Grab`).
extension TimelineView {
    /// Audio area carrying the volume line, nil when the clip has no audible media drawn on this row.
    func volumeArea(_ clip: Clip, row: TimelineLayout.Row, track: Track, layout l: TimelineLayout) -> CGRect? {
        guard let asset = drawCache.asset(clip.mediaID)?.asset, asset.hasAudio, !clip.isFreezeFrame else { return nil }
        let r = l.clipRect(clip, row: row).insetBy(dx: 0.5, dy: 0)
        if track.kind == .audio { return TimelineLayout.audioWaveRect(r) }
        // OB-09: any video lane whose audio strip is tall enough (main track; overlay lanes at the tall height).
        let bands = TimelineLayout.videoBands(height: r.height, hasAudio: true, sizing: l.sizing)
        if asset.kind != .audio, track.kind == .video, r.height >= 30, bands.hasVolumeLine {
            return CGRect(x: r.minX, y: r.maxY - bands.audioStrip, width: r.width, height: bands.audioStrip)
        }
        return nil
    }

    /// Height used for the drag sensitivity (a thin strip would be too sensitive).
    static func volumeDragHeight(_ area: CGRect) -> CGFloat { max(area.height, 40) }

    /// Pointer distance (points) that grabs a volume keyframe diamond instead of the line.
    static let volumeKeyframeGrab: CGFloat = 5

    /// Draws the line (the keyframed curve when there are volume keyframes) and the keyframe diamonds on it.
    func drawVolumeLine(_ c: inout Canvas2D, _ clip: Clip, area a: CGRect, layout l: TimelineLayout, dim: Double) {
        let active: Bool = {
            if case .volume(let id, _, _, _) = drag { return id == clip.id }
            return hoverVolumeClip == clip.id
        }()
        let color = RGBA(1, 1, 1, (active ? 0.95 : 0.6) * dim)
        let h: CGFloat = active ? 1.5 : 1
        let x0 = max(a.minX, TimelineLayout.headerWidth), x1 = min(a.maxX, bounds.width)
        guard x1 > x0 else { return }
        guard let ks = clip.keyframes[ParamKey.volume.raw]?.keyframes, !ks.isEmpty else {
            let y = ClipVolumeLine.y(gain: clip.audio.volume, in: a)
            c.rect(CGRect(x: x0, y: y - h / 2, width: x1 - x0, height: h), color)
            return
        }
        // the curve, sampled every 2 pt (same evaluation as the audio render: KeyframeTrack.value)
        var x = x0
        while x < x1 {
            let t = (l.time(atX: x + 1) - clip.start).clamped(.zero, clip.duration)
            let y = ClipVolumeLine.y(gain: ClipVolumeLine.gain(of: clip, at: t), in: a)
            c.rect(CGRect(x: x, y: y - h / 2, width: min(2, x1 - x), height: h), color)
            x += 2
        }
        let sel = ui.selectedKeyframe
        for k in ks {
            let kx = l.x(clip.start + k.time)
            guard kx >= x0 - 5, kx <= x1 + 5 else { continue }
            let ky = ClipVolumeLine.y(gain: k.value.component(0) ?? 1, in: a)
            let r = CGRect(x: kx - 4.5, y: ky - 4.5, width: 9, height: 9)
            if let img = SymbolImages.image("diamond.fill") { c.image(img, in: r, alpha: dim, fill: false) }
            if let s = sel, s.clip == clip.id, s.key == ParamKey.volume.raw, abs((s.time - k.time).ticks) < 1000 {
                c.rect(r.insetBy(dx: 2.5, dy: 2.5), Self.accent, radius: 1)
            }
        }
    }

    /// Clip whose volume line (or a volume keyframe on it) is under `pt`, away from the trim edges.
    func volumeLineHit(_ pt: CGPoint, layout l: TimelineLayout) -> (id: ClipID, area: CGRect, grab: ClipVolumeLine.Grab)? {
        guard pt.x > TimelineLayout.headerWidth, let ri = l.rowIndex(atY: pt.y) else { return nil }
        let row = l.rows[ri]
        let track = store.project.timeline.tracks[row.trackIndex]
        guard !track.isLocked, track.kind == .audio || track.kind == .video else { return nil }
        let t = l.time(atX: pt.x)
        let tol = l.duration(points: Self.volumeKeyframeGrab)
        for clip in track.clips(in: TimeRange(start: t - tol, end: t + tol + Time(ticks: 1))).reversed() {
            guard let a = volumeArea(clip, row: row, track: track, layout: l),
                  pt.y >= a.minY - ClipVolumeLine.grabTolerance - 2, pt.y <= a.maxY + ClipVolumeLine.grabTolerance else { continue }
            let local = (t - clip.start).clamped(.zero, clip.duration)
            let g = ClipVolumeLine.grab(clip, at: local, tolerance: tol)
            if case .keyframe(let i) = g, let k = clip.keyframes[ParamKey.volume.raw]?.keyframes[i] {
                let ky = ClipVolumeLine.y(gain: k.value.component(0) ?? 1, in: a)
                if abs(pt.y - ky) <= Self.volumeKeyframeGrab { return (clip.id, a, g) }
            }
            guard pt.x > a.minX + TimelineLayout.edgeHandle, pt.x < a.maxX - TimelineLayout.edgeHandle else { continue }
            let y = ClipVolumeLine.y(gain: ClipVolumeLine.gain(of: clip, at: local), in: a)
            if abs(pt.y - y) <= ClipVolumeLine.grabTolerance {
                if case .keyframe = g { return (clip.id, a, ClipVolumeLine.grab(clip, at: local, tolerance: .zero)) }
                return (clip.id, a, g)
            }
        }
        return nil
    }

    /// Mouse-down on a volume line: starts the volume gesture.
    func beginVolumeDrag(_ pt: CGPoint, layout l: TimelineLayout) -> Bool {
        guard let hit = volumeLineHit(pt, layout: l), let clip = store.project.timeline.clip(hit.id) else { return false }
        if !store.selection.contains(hit.id) { store.select([hit.id]) }
        if case .keyframe(let i) = hit.grab, let k = clip.keyframes[ParamKey.volume.raw]?.keyframes[i] {
            ui.selectedKeyframe = KeyframeRef(clip: clip.id, key: ParamKey.volume.raw, time: k.time)
        }
        drag = .volume(hit.id, grabY: pt.y, origin: clip, grab: hit.grab)
        store.beginGesture("cmd.volume")
        volumeLabel(clip, grab: hit.grab, at: pt, l)
        return true
    }

    func updateVolumeDrag(_ id: ClipID, grabY: CGFloat, origin: Clip, grab: ClipVolumeLine.Grab, at pt: CGPoint, layout l: TimelineLayout) {
        let tl = store.project.timeline
        guard let loc = tl.locate(id), let row = l.row(for: tl.tracks[loc.track].id),
              let a = volumeArea(origin, row: row, track: tl.tracks[loc.track], layout: l) else { return }
        let dy = pt.y - grabY, h = Self.volumeDragHeight(a)
        store.updateGesture { p in
            guard var c = p.timeline.clip(id) else { return }
            ClipVolumeLine.apply(grab: grab, dy: dy, areaHeight: h, origin: origin, to: &c)
            p.timeline[clip: id] = c
        }
        if let c = store.project.timeline.clip(id) { volumeLabel(c, grab: grab, at: pt, l) }
    }

    /// Percent tooltip ("63%") next to the pointer: the grabbed keyframe's value, else the volume under the pointer.
    private func volumeLabel(_ clip: Clip, grab: ClipVolumeLine.Grab, at pt: CGPoint, _ l: TimelineLayout) {
        var g = ClipVolumeLine.gain(of: clip, at: (l.time(atX: pt.x) - clip.start).clamped(.zero, clip.duration))
        if case .keyframe(let i) = grab, let k = clip.keyframes[ParamKey.volume.raw]?.keyframes, i < k.count {
            g = k[i].value.component(0) ?? g
        }
        trimLabel = (pt.x + 34, pt.y, VolumePercent.label(g))   // AU-VOL-PCT: "63%" like iMovie
    }
}
