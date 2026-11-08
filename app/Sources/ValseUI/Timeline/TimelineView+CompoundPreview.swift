import AppKit
import ValseCore
import ValseEngine

/// Compound clips on the timeline (BUG-COMPOUND-PREVIEW): the filmstrip shows the compound's rendered frames (every
/// nested layer, effect, text… through the compositor) and the audio band the waveform of its mixed audio, both made in
/// the background by `CompoundPreviewCache` and keyed on the nested content (re-made when it changes).
extension TimelineView {
    /// Filmstrip + audio band of a compound clip. Tile / waveform times map through the compound clip's own
    /// `sourceTime` (in-point and speed inside the nested timeline).
    func drawCompoundStrip(_ c: inout Canvas2D, _ clip: Clip, _ cv: TimelineDrawCache.CompoundView, r: CGRect,
                           bands: TimelineLayout.VideoClipBands, track: Track, layout l: TimelineLayout,
                           alpha: Double, canvas: Size2) {
        guard let pv = cv.preview else { return }
        let cache = CompoundPreviewCache.shared
        let audioStrip = bands.audioStrip
        let stripTop = r.minY + bands.nameBand
        let stripH = r.maxY - audioStrip - stripTop
        let th = Int(stripH * 2)
        let aspect = canvas.height > 0 ? CGFloat(canvas.width / canvas.height) : 16 / 9
        let tileW = max(24, stripH * aspect)
        let startIndex = max(0, Int((TimelineLayout.headerWidth - r.minX) / tileW))
        var i = startIndex
        while r.minX + CGFloat(i) * tileW < min(r.maxX, bounds.width) {
            let x0 = r.minX + CGFloat(i) * tileW
            let tileRect = CGRect(x: x0, y: stripTop, width: min(tileW, r.maxX - x0), height: stripH)
            let tl = min(clip.start + Time(Double(CGFloat(i) * tileW + tileW / 2) / l.pixelsPerSecond), clip.end - Time(ticks: 1))
            let inner = clip.sourceTime(at: tl)
            if let img = cache.cachedThumbnail(key: pv.key, compound: pv.id, at: inner, height: th) {
                c.image(img, in: tileRect, alpha: alpha)
            }
            if !cache.hasThumbnail(key: pv.key, at: inner, height: th) { requestCompoundThumb(pv, at: inner, height: th) }
            i += 1
            if i - startIndex > 200 { break }
        }
        guard audioStrip > 0 else { return }
        let sr = CGRect(x: r.minX, y: r.maxY - audioStrip, width: r.width, height: audioStrip)
        c.rect(sr, RGBA(hex: 0x163A3F, alpha: alpha), radius: 0)
        guard cv.hasAudio, !clip.audio.isMuted, store.project.timeline.isAudible(track) else { return }
        if cache.cachedWaveform(key: pv.key) == nil { requestCompoundWave(pv) }
        guard let w = cache.cachedWaveform(key: pv.key, compound: pv.id) else { return }
        let wr = sr.insetBy(dx: 0, dy: 1)
        let step: CGFloat = 2
        let keyed = clip.hasKeyframes(.volume)
        var x = max(wr.minX, TimelineLayout.headerWidth)
        while x < min(wr.maxX, bounds.width) {
            let tl0 = l.time(atX: x)
            let t0 = clip.sourceTime(at: tl0).seconds, t1 = clip.sourceTime(at: l.time(atX: x + step)).seconds
            // the mix already carries the nested volumes / fades; the compound clip's own volume scales it
            let g = keyed ? ClipVolumeLine.gain(of: clip, at: (tl0 - clip.start).clamped(.zero, clip.duration)) : clip.audio.volume
            let a = CGFloat(w.peak(from: min(t0, t1), to: max(t0, t1)) * g)
            let h = max(1, min(wr.height, CGFloat(TimelineLayout.waveformLevel(Double(a))) * wr.height))
            c.rect(CGRect(x: x, y: wr.maxY - h, width: step - 0.5, height: h), a > 0.95 ? RGBA(hex: 0xE5934A) : Theme.waveformOnVideo)
            x += step
        }
    }

    func requestCompoundThumb(_ pv: (id: CompoundID, nested: Project, key: String), at t: Time, height: Int) {
        let key = "compound-\(pv.key)-\(CompoundPreviewCache.quantize(t))-\(height)"
        guard requestedThumbs.insert(key).inserted else { return }
        let nested = pv.nested, k = pv.key
        Task.detached { [weak self] in
            // a failed render stays requested (no retry storm on every redraw)
            guard await CompoundPreviewCache.shared.thumbnail(nested, key: k, at: t, height: height) != nil else { return }
            await MainActor.run {
                self?.dirty = true
                self?.requestedThumbs.remove(key)
            }
        }
    }

    /// Once per content key (a failed mix is not retried every frame).
    func requestCompoundWave(_ pv: (id: CompoundID, nested: Project, key: String)) {
        guard requestedWaves.insert("compound-\(pv.key)").inserted else { return }
        let nested = pv.nested, k = pv.key
        Task.detached { [weak self] in
            _ = await CompoundPreviewCache.shared.waveform(nested, key: k)
            await MainActor.run { self?.dirty = true }
        }
    }
}
