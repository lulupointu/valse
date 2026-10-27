import AppKit
import ValseCore
import ValseEngine

/// Per-revision data the timeline needs every frame (perf, W14): asset lookup by id without copying `MediaAsset`
/// structs or scanning `project.media`, the project duration (scrollbar / scroll clamp), clip label strings and
/// compact per-track clip spans for the level-of-detail path. Invalidated by (project id, edit revision, language) —
/// every model change bumps `EditSession.revision`, so nothing here is rebuilt while only scrolling.
@MainActor
final class TimelineDrawCache {
    final class AssetRef {
        let asset: MediaAsset
        let aspect: CGFloat
        /// Waveform once loaded (looked up lazily; avoids a locked cache lookup per clip per frame).
        var wave: Waveform?
        init(_ a: MediaAsset) {
            asset = a
            aspect = a.pixelSize.height > 0 ? CGFloat(a.pixelSize.width / a.pixelSize.height) : 16 / 9
        }
    }
    /// What the LOD path reads of a clip (plain values, no `Clip` copies; constant-rate source mapping — curves use
    /// their average rate, invisible at LOD sizes).
    struct Span {
        var start: Double, end: Double
        var srcStart: Double, rate: Double, reversed: Bool
        var asset: AssetRef?
        var id: ClipID
        var volume: Double
        var muted: Bool, enabled: Bool
        var colorLabel: Int?
        func source(at t: Double) -> Double {
            let off = min(max(t - start, 0), end - start) * rate
            return reversed ? srcStart + (end - start) * rate - off : srcStart + off
        }
    }
    struct Key: Equatable { let project: ProjectID; let revision: Int; let language: String }
    private(set) var key: Key?
    private(set) var assets: [MediaID: AssetRef] = [:]
    private(set) var duration: Double = 0
    private var media: [MediaAsset] = []
    private var labels: [ClipID: (short: String, long: String)] = [:]
    private var spans: [TrackID: [Span]] = [:]

    func refresh(_ store: EditorStore) {
        let k = Key(project: store.project.id, revision: store.session.revision, language: L10n.shared.language)
        guard k != key else { return }
        let p = store.project
        if p.media != media || key?.project != k.project {
            media = p.media
            var a: [MediaID: AssetRef] = [:]
            a.reserveCapacity(media.count)
            for m in media where a[m.id] == nil { a[m.id] = AssetRef(m) }
            assets = a
        }
        duration = p.duration.seconds
        labels.removeAll(keepingCapacity: true)
        spans.removeAll(keepingCapacity: true)
        key = k
    }

    func asset(_ id: MediaID?) -> AssetRef? { id.flatMap { assets[$0] } }

    /// Spans of `track`'s clips (same order and indices as `track.clips`), built once per revision.
    func spans(_ track: Track) -> [Span] {
        if let s = spans[track.id] { return s }
        var out: [Span] = []
        out.reserveCapacity(track.clips.count)
        for c in track.clips {
            out.append(Span(start: c.start.seconds, end: c.end.seconds, srcStart: c.sourceStart.seconds, rate: c.speed.averageRate,
                            reversed: c.reversed, asset: asset(c.mediaID), id: c.id, volume: Double(c.audio.volume),
                            muted: c.audio.isMuted, enabled: c.isEnabled, colorLabel: c.colorLabel))
        }
        spans[track.id] = out
        return out
    }

    /// (name, "name  1.0s") for the clip's label chip.
    func label(_ clip: Clip, _ make: () -> String) -> (short: String, long: String) {
        if let l = labels[clip.id] { return l }
        let name = make()
        let l = (name, "\(name)  \(TimelineView.durationLabel(clip.duration))")  // W1: FR "1,0 s" chips
        labels[clip.id] = l
        return l
    }
}

/// What `drawClip` / the LOD path read per frame, captured once per frame (no per-clip `store.project` /
/// `store.selection` / `store.jobs` observation-tracked getters).
struct TimelineFrameContext {
    let project: Project
    let selection: Set<ClipID>
    /// Clip id → running/queued job on it (empty almost always).
    let busy: [String: JobInfo]
    /// Drawing a move preview (not the model's timeline): no per-revision span cache.
    var preview = false
}

extension TimelineView {
    /// Clips narrower than this (points) are drawn by the level-of-detail path: contiguous ones merge into one block
    /// with a run-level filmstrip / waveform, no label, badges or per-clip decorations (nothing legible fits anyway).
    static let lodClipWidth: CGFloat = 16

    func frameContext() -> TimelineFrameContext {
        var busy: [String: JobInfo] = [:]
        for j in store.jobs where (j.state == .running || j.state == .queued) {
            // the running job wins over a queued one on the same clip (EditorStore.clipJob, same as the inspector)
            if let s = j.subject, busy[s] == nil || (busy[s]?.state == .queued && j.state == .running) { busy[s] = j }
        }
        guard let mp = movePreview else { return TimelineFrameContext(project: store.project, selection: store.selection, busy: busy) }
        var p = store.project
        p.timeline = mp
        return TimelineFrameContext(project: p, selection: store.selection, busy: busy, preview: true)
    }

    /// Draws the visible clips of one row: full detail for clips ≥ `lodClipWidth`, merged runs for tiny ones.
    func drawClips(_ c: inout Canvas2D, row: TimelineLayout.Row, track: Track, layout l: TimelineLayout, dim: Double,
                   ctx: TimelineFrameContext) {
        let vis = track.clips(in: l.visibleRange).indices
        guard !vis.isEmpty else { return }
        if ctx.preview {   // move preview: plain per-clip drawing (the span cache is per model revision)
            for k in vis { drawClip(&c, track.clips[k], row: row, track: track, layout: l, dim: dim, ctx: ctx) }
            return
        }
        let spans = drawCache.spans(track)
        guard spans.count == track.clips.count else { return }
        let pps = l.pixelsPerSecond
        func isBusy(_ k: Int) -> Bool { !ctx.busy.isEmpty && ctx.busy[spans[k].id.description] != nil }
        var i = vis.lowerBound
        while i < vis.upperBound {
            if CGFloat((spans[i].end - spans[i].start) * pps) >= Self.lodClipWidth || isBusy(i) {
                drawClip(&c, track.clips[i], row: row, track: track, layout: l, dim: dim, ctx: ctx)
                i += 1
                continue
            }
            // Extend the run while clips stay tiny and contiguous (gap < 1 pt).
            var j = i + 1
            var end = spans[i].end
            while j < vis.upperBound {
                guard CGFloat((spans[j].end - spans[j].start) * pps) < Self.lodClipWidth,
                      CGFloat((spans[j].start - end) * pps) < 1, !isBusy(j) else { break }
                end = max(end, spans[j].end)
                j += 1
            }
            drawRun(&c, spans, i..<j, end: end, row: row, track: track, layout: l, dim: dim, ctx: ctx)
            i = j
        }
    }

    /// One block for a run of tiny contiguous clips: background, cut lines (when ≥ 3 pt apart), filmstrip tiles sampled
    /// across the run, waveform sampled across the run, per-clip colour labels / disabled tint / selection.
    private func drawRun(_ c: inout Canvas2D, _ run: [TimelineDrawCache.Span], _ range: Range<Int>, end: Double,
                         row: TimelineLayout.Row, track: Track, layout l: TimelineLayout, dim: Double, ctx: TimelineFrameContext) {
        let f = range.lowerBound
        let pps = l.pixelsPerSecond
        let x0 = l.x(Time(run[f].start))
        let r = CGRect(x: x0, y: row.y, width: max(1, CGFloat((end - run[f].start) * pps)), height: row.height).insetBy(dx: 0.5, dy: 0)
        guard r.maxX > TimelineLayout.headerWidth, r.minX < bounds.width else { return }
        func xOf(_ t: Double) -> CGFloat { x0 + CGFloat((t - run[f].start) * pps) }
        var bg = Theme.clipColor(Self.displayKind(track))  // W1 lane colours (effect / filter / adjustment)
        bg.a = dim
        c.rect(r, bg, radius: r.width > 8 ? 4 : 1)
        // Per-clip exceptions (colour label, disabled) as plain rects.
        for k in range where run[k].colorLabel != nil || !run[k].enabled {
            var col = bg
            if let li = run[k].colorLabel, li >= 0, li < Self.labelColors.count { col = Self.labelColors[li]; col.a = dim }
            if !run[k].enabled { col = col.mix(RGBA(0.2, 0.2, 0.2), 0.6); col.a = 0.45 * dim }
            c.rect(CGRect(x: xOf(run[k].start), y: r.minY, width: max(1, CGFloat((run[k].end - run[k].start) * pps)), height: r.height), col)
        }
        let visL = max(r.minX, TimelineLayout.headerWidth), visR = min(r.maxX, bounds.width)
        // Filmstrip: tiles at the lane-height aspect, each showing the clip under its centre.
        if track.kind != .audio, r.height >= 30, let fa = run[f].asset, fa.asset.kind != .audio {
            let bands = TimelineLayout.videoBands(height: r.height, hasAudio: fa.asset.hasAudio, sizing: .preset(track.heightPreset))   // OB-09: every track
            let audioStrip = bands.audioStrip
            let stripTop = r.minY + bands.nameBand
            let stripH = r.maxY - audioStrip - stripTop
            let th = Int(stripH * 2)
            let tileW = max(24, stripH * fa.aspect)
            var k = f
            var tx = r.minX + max(0, ((visL - r.minX) / tileW).rounded(.down)) * tileW
            var n = 0
            while tx < visR, n < 200 {
                let tileRect = CGRect(x: tx, y: stripTop, width: min(tileW, r.maxX - tx), height: stripH)
                let t = l.time(atX: tx + tileRect.width / 2).seconds
                while k < range.upperBound - 1, run[k].end <= t { k += 1 }
                if let a = run[k].asset, a.asset.kind != .audio {
                    let st = a.asset.kind == .image ? Time.zero : Time(run[k].source(at: t))
                    if let img = ThumbnailCache.shared.cached(a.asset, at: st, height: th) {
                        c.image(img, in: tileRect, alpha: dim)
                    } else {
                        requestThumb(a.asset, at: st, height: th)
                    }
                }
                tx += tileW; n += 1
            }
            if audioStrip > 0 {
                let sr = CGRect(x: r.minX, y: r.maxY - audioStrip, width: r.width, height: audioStrip)
                c.rect(sr, RGBA(hex: 0x163A3F, alpha: dim), radius: 0)
                if store.project.timeline.isAudible(track) {
                    drawRunWaveform(&c, run, range, in: sr.insetBy(dx: 0, dy: 1), layout: l, color: Theme.waveformOnVideo, scale: 1)
                }
            }
        }
        if track.kind == .audio {
            drawRunWaveform(&c, run, range, in: TimelineLayout.audioWaveRect(r), layout: l, color: Theme.waveform, scale: 1)
        }
        // Cut lines between clips, only where they stay ≥ 3 pt apart (otherwise the block reads as one dense strip).
        var lastCut = r.minX
        for k in range.dropFirst() {
            let x = xOf(run[k].start)
            guard x - lastCut >= 3, x > visL, x < visR else { continue }
            c.rect(CGRect(x: x - 0.5, y: r.minY, width: 1, height: r.height), RGBA(0, 0, 0, 0.45))
            lastCut = x
        }
        if !ctx.selection.isEmpty {
            for k in range where ctx.selection.contains(run[k].id) {
                let cr = CGRect(x: xOf(run[k].start), y: r.minY, width: max(2, CGFloat((run[k].end - run[k].start) * pps)), height: r.height)
                c.rect(cr, Theme.TL.selection, radius: 1, border: 1.5)
            }
        }
    }

    /// Waveform across a run: one bar per 2 pt, each from the clip under it (monotonic walk, O(run + bars)).
    private func drawRunWaveform(_ c: inout Canvas2D, _ run: [TimelineDrawCache.Span], _ range: Range<Int>, in wr: CGRect,
                                 layout l: TimelineLayout, color: RGBA, scale: Double) {
        let step: CGFloat = 2
        let dt = Double(step) / l.pixelsPerSecond
        let hot = RGBA(hex: 0xE5934A)
        var x = max(wr.minX, TimelineLayout.headerWidth)
        let xEnd = min(wr.maxX, bounds.width)
        var t0 = l.time(atX: x).seconds
        var k = range.lowerBound
        while x < xEnd {
            defer { x += step; t0 += dt }
            while k < range.upperBound - 1, run[k].end <= t0 { k += 1 }
            let s = run[k]
            guard t0 >= s.start, !s.muted, let a = s.asset, a.asset.hasAudio else { continue }
            if a.wave == nil {
                a.wave = WaveformCache.shared.cached(a.asset)
                if a.wave == nil { requestWave(a.asset); continue }
            }
            guard let w = a.wave else { continue }
            let s0 = s.source(at: t0), s1 = s.source(at: t0 + dt)
            let amp = w.peak(from: min(s0, s1), to: max(s0, s1)) * s.volume * scale
            let h = max(1, min(wr.height, CGFloat(TimelineLayout.waveformLevel(amp)) * wr.height))
            c.rect(CGRect(x: x, y: wr.maxY - h, width: step - 0.5, height: h), amp > 0.95 ? hot : color)   // one-sided (C3b)
        }
    }
}
