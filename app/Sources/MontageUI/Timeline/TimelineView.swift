import AppKit
@preconcurrency import Metal
import QuartzCore
import MontageCore
import MontageEffects
import MontageEngine

/// The timeline canvas: one GPU-drawn, virtualized view (no NSView per clip). Draws ruler, markers, in/out range,
/// track headers, lanes, clips (filmstrips, waveforms, labels, badges, transitions, keyframes, beats, fades), playhead
/// and drag feedback (snap line, insertion lines, marquee) with `Canvas2D`. Input lives in TimelineView+Input.swift,
/// context menus in TimelineMenus.swift. Per-frame work is O(visible clips).
final class TimelineView: NSView {
    let store: EditorStore
    let renderer = Canvas2DRenderer()
    var link: CADisplayLink?
    var fallbackTimer: Timer?
    var dirty = true
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    var ui: TimelineUIState { store.timelineUI }
    var scrollTime: Double {
        get { ui.scrollTime }
        set { ui.scrollTime = max(0, newValue); dirty = true }
    }
    var scrollY: CGFloat {
        get { CGFloat(ui.scrollY) }
        set { ui.scrollY = Double(newValue); dirty = true }
    }

    // MARK: Interaction state
    struct MoveDrag {
        var anchor: ClipID
        var ids: Set<ClipID>
        /// Time under the cursor at mouse-down, and the anchor clip's start then.
        var grabTime: Time
        var anchorStart: Time
        var anchorDuration: Time
        var kind: TrackKind
        var duplicate: Bool
        /// When the drag created a new track: the track (in the gesture base) it was inserted above.
        var newTrackAbove: TrackID??
    }
    enum Drag {
        case none
        case pending(CGPoint, ClipID, TimelineLayout.ClipRegion, Int)
        case scrub
        case move(MoveDrag)
        case trim(ids: [ClipID], anchor: ClipID, edge: TrimEdge, origin: Time)
        case roll(left: ClipID)
        case slip(id: ClipID, startX: CGFloat)
        case marquee(origin: CGPoint, current: CGPoint, base: Set<ClipID>)
        case transition(left: ClipID, edge: TrimEdge, startX: CGFloat, original: Time)
        case keyframe(KeyframeRef, startX: CGFloat)
        case marker(MarkerID, startX: CGFloat, original: Time)
        case fade(ClipID, fadeIn: Bool)
        case trackReorder(TrackID, y: CGFloat)
        case scrollbar(grab: CGFloat)
    }
    var drag: Drag = .none
    var snapIndex: SnapIndex?
    var snapLine: Time?
    var dropIndicator: (time: Time, row: Int?)?
    var insertionSlot: Int?
    var hoverPoint: CGPoint?
    var hoverClip: ClipID?
    var hoverTime: Time?
    /// Preview axis: playhead to restore when the mouse leaves.
    var previewAnchor: Time?
    var trimLabel: (x: CGFloat, y: CGFloat, text: String)?
    /// Ids created by the latest ⌥-drag duplicate gesture update.
    var duplicatedIDs: [ClipID] = []
    var requestedThumbs: Set<String> = []
    var requestedWaves: Set<String> = []

    static let accent = RGBA(hex: 0x57BECB)

    init(store: EditorStore) {
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
        metalLayer.device = MetalContext.shared.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
        metalLayer.isOpaque = true
        registerForDraggedTypes([.string, .fileURL])
        store.observe { [weak self] in
            guard let self else { return }
            _ = self.store.session.revision
            _ = self.store.selection
            _ = self.store.pixelsPerSecond
            _ = self.store.transport.playhead
            _ = self.ui.scrollTime; _ = self.ui.scrollY; _ = self.ui.tool
            _ = self.ui.selectedTransition; _ = self.ui.selectedMarker; _ = self.ui.selectedKeyframe
            self.dirty = true
            self.followPlayhead()
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func makeBackingLayer() -> CALayer { CAMetalLayer() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate(); link = nil
        guard window != nil else { return }
        let l = displayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
        updateTrackingAreas()
        // The display link pauses while the window is occluded (e.g. launched behind other apps for screenshots):
        // keep drawing at a low rate then.
        fallbackTimer?.invalidate()
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let w = self.window, !w.occlusionState.contains(.visible) else { return }
                self.tick()
            }
        }
    }

    override func layout() {
        super.layout()
        let s = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = s
        metalLayer.drawableSize = CGSize(width: max(1, bounds.width * s), height: max(1, bounds.height * s))
        if bounds.width > 0 { ui.viewWidth = Double(bounds.width) }
        dirty = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    var layoutNow: TimelineLayout {
        TimelineLayout(timeline: store.project.timeline, pixelsPerSecond: store.pixelsPerSecond, scrollTime: scrollTime,
                       scrollY: scrollY, viewSize: bounds.size)
    }

    @objc func tick() {
        guard dirty, bounds.width > 0 else { return }
        dirty = false
        draw()
    }

    func followPlayhead() {
        guard store.transport.isPlaying, case .none = drag else { return }
        let l = layoutNow
        let x = l.x(store.transport.playhead)
        if x > bounds.width - 40 || x < TimelineLayout.headerWidth {
            scrollTime = max(0, store.transport.playhead.seconds - 1)
        }
    }

    /// Total scrollable duration (timeline + 30 % slack, at least the visible span).
    var scrollableDuration: Double {
        let l = layoutNow
        return max(store.project.duration.seconds * 1.3 + 5, l.visibleRange.duration.seconds + scrollTime)
    }

    // MARK: Drawing

    private func draw() {
        let canvas = buildCanvas()
        guard let drawable = metalLayer.nextDrawable(), let cmd = MetalContext.shared.queue.makeCommandBuffer() else { return }
        renderer.encode(canvas, into: drawable.texture, scale: metalLayer.contentsScale, clear: RGBA(hex: 0x1B1B1C), commandBuffer: cmd)
        cmd.present(drawable)
        cmd.commit()
    }

    func buildCanvas() -> Canvas2D {
        var c = Canvas2D()
        let l = layoutNow
        let p = store.project
        let tl = p.timeline
        let W = bounds.width, H = bounds.height
        let headerW = TimelineLayout.headerWidth
        let fps = p.settings.frameRate.fps
        let accent = Self.accent

        // Lanes
        c.clip = CGRect(x: headerW, y: TimelineLayout.rulerHeight, width: W - headerW, height: H - TimelineLayout.rulerHeight)
        for row in l.rows {
            let track = tl.tracks[row.trackIndex]
            c.rect(CGRect(x: headerW, y: row.y, width: W - headerW, height: row.height),
                   row.isMain ? RGBA(hex: 0x242425) : RGBA(hex: 0x1E1E1F), radius: 0)
            _ = track
        }
        if l.rows.count == 1, tl.mainTrack?.clips.isEmpty == true {
            let row = l.rows[0]
            let r = CGRect(x: headerW + 8, y: row.y + 4, width: min(W - headerW - 16, 600), height: row.height - 8)
            c.rect(r, RGBA(1, 1, 1, 0.03), radius: 6)
            c.rect(r, RGBA(1, 1, 1, 0.18), radius: 6, border: 1)
            c.text(tr("timeline.emptyHint"), at: CGPoint(x: r.minX + 16, y: r.midY - 7), size: 12, weight: .regular,
                   color: RGBA(hex: 0x7A7A7A))
        }

        // Clips
        let visible = l.visibleRange
        for row in l.rows {
            let track = tl.tracks[row.trackIndex]
            let dim: Double = track.isHidden ? 0.4 : 1
            for clip in track.clips(in: visible) {
                drawClip(&c, clip, row: row, track: track, layout: l, dim: dim)
            }
            // transitions straddling cuts
            for clip in track.clips(in: visible) {
                guard let r = l.transitionRect(clip, row: row) else { continue }
                let sel = ui.selectedTransition == clip.id
                c.rect(r, RGBA(1, 1, 1, sel ? 0.45 : 0.28), radius: 3)
                if sel { c.rect(r, .white, radius: 3, border: 1.5) }
                if let img = SymbolImages.image("arrow.left.and.right.righttriangle.left.righttriangle.right.fill") ?? SymbolImages.image("rectangle.split.2x1") {
                    let s = min(14, r.height - 4)
                    if r.width >= s { c.image(img, in: CGRect(x: r.midX - s / 2, y: r.midY - s / 2, width: s, height: s), alpha: 0.95, fill: false) }
                }
            }
            if track.isLocked {
                // hatch: diagonal-ish stripes approximated with thin translucent bars
                let lane = CGRect(x: headerW, y: row.y, width: W - headerW, height: row.height)
                c.rect(lane, RGBA(0, 0, 0, 0.25))
                var x = lane.minX - CGFloat(Int(scrollTime * l.pixelsPerSecond) % 8)
                while x < lane.maxX { c.rect(CGRect(x: x, y: lane.minY, width: 1, height: lane.height), RGBA(1, 1, 1, 0.06)); x += 8 }
            }
        }

        // Linkage indicator for selected linked clips
        if let mi = l.mainRowIndex {
            let mainRow = l.rows[mi]
            for id in store.selection {
                guard let clip = tl.clip(id), clip.linkedTo != nil, let loc = tl.locate(id), let row = l.row(for: tl.tracks[loc.track].id) else { continue }
                let x = l.x(clip.start)
                let (y0, y1) = row.y < mainRow.y ? (row.maxY, mainRow.y) : (mainRow.maxY, row.y)
                if y1 > y0 { c.rect(CGRect(x: x - 0.5, y: y0, width: 1, height: y1 - y0), RGBA(1, 1, 1, 0.45)) }
            }
        }

        // Drop indicator / snap line / insertion line / marquee
        if let d = dropIndicator {
            let x = l.x(d.time)
            c.rect(CGRect(x: x - 1, y: TimelineLayout.rulerHeight, width: 2, height: H), accent)
            if let ri = d.row, ri < l.rows.count {
                let r = l.rows[ri]
                c.rect(CGRect(x: headerW, y: r.y, width: W - headerW, height: r.height), RGBA(0.34, 0.75, 0.8, 0.12))
            }
        }
        if let s = snapLine {
            c.rect(CGRect(x: l.x(s) - 0.5, y: TimelineLayout.rulerHeight, width: 1, height: H), accent)
        }
        if let slot = insertionSlot {
            let y: CGFloat
            if l.rows.isEmpty { y = TimelineLayout.rulerHeight + 10 }
            else if slot == 0 { y = l.rows[0].y - 3 }
            else if slot >= l.rows.count { y = l.rows[l.rows.count - 1].maxY + 2 }
            else { y = (l.rows[slot - 1].maxY + l.rows[slot].y) / 2 - 1 }
            c.rect(CGRect(x: headerW, y: y, width: W - headerW, height: 2), accent)
        }
        if case .marquee(let o, let cur, _) = drag {
            let r = CGRect(x: min(o.x, cur.x), y: min(o.y, cur.y), width: abs(cur.x - o.x), height: abs(cur.y - o.y))
            c.rect(r, RGBA(0.34, 0.75, 0.8, 0.12))
            c.rect(r, accent, border: 1)
        }
        // Split-mode blade preview
        if ui.tool == .split, let hp = hoverPoint, hp.x > headerW, case .none = drag {
            c.rect(CGRect(x: hp.x - 0.5, y: TimelineLayout.rulerHeight, width: 1, height: H), accent)
        }
        if let t = trimLabel {
            let w = c.measure(t.text, size: 10) + 10
            let r = CGRect(x: min(max(t.x - w / 2, headerW), W - w - 2), y: max(TimelineLayout.rulerHeight + 2, t.y - 20), width: w, height: 16)
            c.rect(r, RGBA(0, 0, 0, 0.85), radius: 4)
            c.text(t.text, at: CGPoint(x: r.minX + 5, y: r.minY + 1.5), size: 10, color: .white, mono: true)
        }

        // Ruler
        c.clip = CGRect(x: headerW, y: 0, width: W - headerW, height: TimelineLayout.rulerHeight)
        c.rect(CGRect(x: headerW, y: 0, width: W - headerW, height: TimelineLayout.rulerHeight), RGBA(hex: 0x1B1B1C))
        if tl.inPoint != nil || tl.outPoint != nil {
            let x0 = l.x(tl.inPoint ?? .zero), x1 = l.x(tl.outPoint ?? max(p.duration, tl.inPoint ?? .zero))
            c.rect(CGRect(x: x0, y: 0, width: max(1, x1 - x0), height: TimelineLayout.rulerHeight), RGBA(0.34, 0.75, 0.8, 0.22))
            if tl.inPoint != nil { c.rect(CGRect(x: x0, y: 0, width: 2, height: TimelineLayout.rulerHeight), accent) }
            if tl.outPoint != nil { c.rect(CGRect(x: x1 - 2, y: 0, width: 2, height: TimelineLayout.rulerHeight), accent) }
        }
        // Render cache bar (W12, PB-005): green under the ruler where the preview is pre-rendered
        for r in store.renderedPreviewRanges() {
            let x0 = l.x(r.start), x1 = l.x(r.end)
            c.rect(CGRect(x: x0, y: TimelineLayout.rulerHeight - 2, width: max(1, x1 - x0), height: 2), RGBA(0.33, 0.8, 0.45, 1))
        }
        let (major, minor) = TimelineLayout.tickStep(pixelsPerSecond: l.pixelsPerSecond, fps: fps)
        var t = (scrollTime / minor).rounded(.down) * minor
        let end = scrollTime + Double(W) / l.pixelsPerSecond
        while t <= end {
            let x = l.x(Time(t))
            let isMajor = abs((t / major).rounded() * major - t) < minor / 4
            c.rect(CGRect(x: x, y: isMajor ? 14 : 20, width: 1, height: isMajor ? 10 : 4), RGBA(hex: 0x5A5A5A))
            if isMajor {
                c.text(Self.rulerLabel(t, fps: fps, step: major), at: CGPoint(x: x + 3, y: 2), size: 10, weight: .regular,
                       color: RGBA(hex: 0x8A8A8A), mono: true)
            }
            t += minor
        }
        // Markers
        for m in tl.markers {
            let x = l.x(m.time)
            guard x > headerW - 10, x < W + 10 else { continue }
            let sel = ui.selectedMarker == m.id
            c.rect(CGRect(x: x - 4, y: 12, width: 8, height: 9), m.color, radius: 2)
            c.rect(CGRect(x: x - 0.5, y: 12, width: 1, height: 12), m.color)
            if sel { c.rect(CGRect(x: x - 5, y: 11, width: 10, height: 11), .white, radius: 2, border: 1) }
            if !m.label.isEmpty, l.pixelsPerSecond > 8 {
                c.text(m.label, at: CGPoint(x: x + 6, y: 11), size: 9, color: m.color, maxWidth: 120)
            }
        }

        // Headers
        c.clip = CGRect(x: 0, y: TimelineLayout.rulerHeight, width: headerW, height: H)
        c.rect(CGRect(x: 0, y: 0, width: headerW, height: H), RGBA(hex: 0x1F1F20))
        for row in l.rows {
            let track = tl.tracks[row.trackIndex]
            let r = CGRect(x: 4, y: row.y, width: headerW - 8, height: row.height)
            if case .trackReorder(let id, _) = drag, id == track.id { c.rect(r, RGBA(1, 1, 1, 0.08), radius: 4) }
            for item in headerItems(track, row: row) {
                if let img = SymbolImages.image(item.symbol) {
                    c.image(img, in: item.rect, alpha: item.on ? 1 : 0.5, fill: false)
                }
            }
            if row.isMain {
                // "Cover" button next to the clips (UX.md §6.3)
                let b = coverButtonRect(row)
                c.rect(b, RGBA(hex: 0x2A2A2A), radius: 4)
                if let img = SymbolImages.image("pencil") { c.image(img, in: CGRect(x: b.midX - 6, y: b.minY + 5, width: 12, height: 12), alpha: 0.9, fill: false) }
                let w = c.measure(tr("timeline.cover"), size: 10)
                c.text(tr("timeline.cover"), at: CGPoint(x: b.midX - w / 2, y: b.midY + 1), size: 10, weight: .medium, color: RGBA(hex: 0xE6E6E6))
            }
        }
        c.clip = CGRect(x: 0, y: 0, width: headerW, height: TimelineLayout.rulerHeight)
        c.rect(CGRect(x: 0, y: 0, width: headerW, height: TimelineLayout.rulerHeight), RGBA(hex: 0x1B1B1C))

        // Horizontal scrollbar
        c.clip = CGRect(x: headerW, y: 0, width: W - headerW, height: H)
        if let thumb = scrollbarThumb(l) {
            c.rect(thumb, RGBA(hex: 0x373738), radius: 3)
        }

        // Playhead
        let shown = previewAnchor ?? store.transport.playhead
        let px = l.x(shown)
        c.rect(CGRect(x: px - 0.75, y: 6, width: 1.5, height: H), .white)
        c.rect(CGRect(x: px - 5, y: 2, width: 10, height: 10), .white, radius: 3)
        c.rect(CGRect(x: px - 2.5, y: 10, width: 5, height: 5), .white, radius: 1)
        if let h = hoverTime, case .none = drag, ui.tool == .select {
            c.rect(CGRect(x: l.x(h) - 0.5, y: TimelineLayout.rulerHeight, width: 1, height: H),
                   ui.previewAxis ? RGBA(1, 1, 1, 0.55) : RGBA(1, 1, 1, 0.2))
        }
        return c
    }

    func scrollbarThumb(_ l: TimelineLayout) -> CGRect? {
        let total = scrollableDuration
        let vis = l.visibleRange.duration.seconds
        guard total > vis + 0.01 else { return nil }
        let trackW = l.clipAreaWidth - 8
        let w = max(30, trackW * CGFloat(vis / total))
        let x = TimelineLayout.headerWidth + 4 + (trackW - w) * CGFloat(scrollTime / max(total - vis, 0.001))
        return CGRect(x: x, y: bounds.height - TimelineLayout.scrollbarHeight, width: w, height: 6)
    }

    func coverButtonRect(_ row: TimelineLayout.Row) -> CGRect {
        CGRect(x: TimelineLayout.headerWidth - 48, y: row.y + row.height / 2 - 18, width: 44, height: 36)
    }

    struct HeaderItem { let id: String; let symbol: String; let on: Bool; let rect: CGRect }

    /// Track header controls (UX.md §6.3): type icon · lock · eye · speaker · ⋯ (main track: no type icon, Cover button).
    func headerItems(_ t: Track, row: TimelineLayout.Row) -> [HeaderItem] {
        var items: [(String, String, Bool)] = []
        if !t.isMain { items.append(("type", Self.typeSymbol(t.kind), false)) }
        items.append(("lock", t.isLocked ? "lock.fill" : "lock.open", t.isLocked))
        if t.kind.isVisual { items.append(("eye", t.isHidden ? "eye.slash" : "eye", t.isHidden)) }
        if t.kind == .audio || t.kind == .video { items.append(("mute", t.isMuted ? "speaker.slash" : "speaker.wave.2", t.isMuted)) }
        if t.kind == .audio || t.kind == .video { items.append(("more", "ellipsis", false)) }
        let step: CGFloat = t.isMain ? 17 : 21
        return items.enumerated().map { i, it in
            HeaderItem(id: it.0, symbol: it.1, on: it.0 == "type" ? false : it.2,
                       rect: CGRect(x: 6 + CGFloat(i) * step, y: row.y + row.height / 2 - 7, width: 14, height: 14))
        }
    }

    static func typeSymbol(_ k: TrackKind) -> String {
        switch k {
        case .video: return "play.rectangle"
        case .audio: return "music.note"
        case .text: return "textformat"
        case .sticker: return "face.smiling"
        case .effect: return "sparkles"
        case .filter: return "camera.filters"
        case .adjustment: return "slider.horizontal.3"
        }
    }

    private func drawClip(_ c: inout Canvas2D, _ clip: Clip, row: TimelineLayout.Row, track: Track, layout l: TimelineLayout, dim: Double) {
        let r = l.clipRect(clip, row: row).insetBy(dx: 0.5, dy: 0)
        guard r.maxX > TimelineLayout.headerWidth, r.minX < bounds.width else { return }
        let p = store.project
        var base = Theme.clipColor(track.kind)
        if let li = clip.colorLabel, li >= 0, li < Self.labelColors.count { base = Self.labelColors[li] }
        let asset = clip.mediaID.flatMap { p.asset($0) }
        let selected = store.selection.contains(clip.id)
        let alpha = (clip.isEnabled ? 1 : 0.45) * dim
        var bg = clip.isEnabled ? base : base.mix(RGBA(0.2, 0.2, 0.2), 0.6)
        bg.a = alpha
        c.rect(r, bg, radius: 4)
        let visL = max(r.minX, TimelineLayout.headerWidth)

        // Filmstrip
        if let asset, asset.kind != .audio, track.kind != .audio, r.height >= 30 {
            let audioStrip: CGFloat = track.isMain && asset.hasAudio && r.height >= 60 ? 16 : 0
            let stripTop = r.minY + (r.height >= 60 ? 18 : 0)
            let stripH = r.maxY - audioStrip - stripTop
            let th = Int(stripH * 2)
            let aspect = asset.pixelSize.height > 0 ? asset.pixelSize.width / asset.pixelSize.height : 16 / 9
            let tileW = max(24, stripH * CGFloat(aspect))
            let startIndex = max(0, Int((TimelineLayout.headerWidth - r.minX) / tileW))
            var i = startIndex
            while r.minX + CGFloat(i) * tileW < min(r.maxX, bounds.width) {
                let x0 = r.minX + CGFloat(i) * tileW
                let tileRect = CGRect(x: x0, y: stripTop, width: min(tileW, r.maxX - x0), height: stripH)
                let tl = clip.start + Time(Double(CGFloat(i) * tileW + tileW / 2) / l.pixelsPerSecond)
                let st = asset.kind == .image ? Time.zero : clip.sourceTime(at: min(tl, clip.end))
                if let img = ThumbnailCache.shared.cached(asset, at: st, height: th) {
                    c.image(img, in: tileRect, alpha: alpha)
                } else {
                    requestThumb(asset, at: st, height: th)
                }
                i += 1
                if i - startIndex > 200 { break }
            }
            if audioStrip > 0 {
                let sr = CGRect(x: r.minX, y: r.maxY - audioStrip, width: r.width, height: audioStrip)
                c.rect(sr, RGBA(hex: 0x163A3F, alpha: alpha), radius: 0)
                if !clip.audio.isMuted && !track.isMuted { drawWaveform(&c, clip, asset: asset, in: sr, layout: l, color: Theme.waveformOnVideo, scale: 0.9) }
            }
        }
        // Waveform (audio clips)
        if let asset, track.kind == .audio, asset.hasAudio {
            let wr = CGRect(x: r.minX, y: r.minY + 16, width: r.width, height: r.height - 18)
            let scale = track.waveformScale ?? 0.3
            drawWaveform(&c, clip, asset: asset, in: wr, layout: l, color: Theme.waveform, scale: 0.7 * max(0.3, scale) / 0.3)
            // volume line
            let vy = wr.maxY - CGFloat(min(clip.audio.volume, 2) / 2) * wr.height
            c.rect(CGRect(x: visL, y: vy, width: r.maxX - visL, height: 1), RGBA(1, 1, 1, 0.35))
            // fades
            if clip.audio.fadeIn > .zero {
                let w = CGFloat(clip.audio.fadeIn.seconds * l.pixelsPerSecond)
                c.rect(CGRect(x: r.minX, y: r.minY, width: min(w, r.width), height: r.height), RGBA(0, 0, 0, 0.28), radius: 4)
            }
            if clip.audio.fadeOut > .zero {
                let w = min(CGFloat(clip.audio.fadeOut.seconds * l.pixelsPerSecond), r.width)
                c.rect(CGRect(x: r.maxX - w, y: r.minY, width: w, height: r.height), RGBA(0, 0, 0, 0.28), radius: 4)
            }
        }
        // Label chip: icon + name + duration
        let name = clipName(clip, asset: asset)
        var labelX = visL + 4
        let room = r.maxX - labelX - 4
        if room > 14 {
            if !(asset != nil), let img = SymbolImages.image(Self.typeSymbol(track.kind)), room > 30, r.height < 30 {
                c.image(img, in: CGRect(x: labelX, y: r.minY + 4, width: 12, height: 12), alpha: 0.9 * dim, fill: false)
                labelX += 15
            }
            let label = r.width > 90 ? "\(name)  \(Timecode.shortDuration(clip.duration))" : name
            let w = min(c.measure(label) + 8, r.maxX - labelX - 4)
            if w > 8 {
                c.rect(CGRect(x: labelX, y: r.minY + 2.5, width: w, height: 15), RGBA(1, 1, 1, 0.15 * dim), radius: 3)
                c.text(label, at: CGPoint(x: labelX + 4, y: r.minY + 3), size: 10.5, color: RGBA(1, 1, 1, dim), maxWidth: w - 8)
            }
        }
        // Badges (right side of the name strip): speed, reversed, freeze, muted, effects, group
        var bx = r.maxX - 4
        func badge(_ symbol: String, _ text: String? = nil, color: RGBA = .white) {
            var w: CGFloat = 12
            if let text { w += c.measure(text, size: 9.5) + 3 }
            guard bx - w > labelX + 30 else { return }
            bx -= w
            if let img = SymbolImages.image(symbol) { c.image(img, in: CGRect(x: bx, y: r.minY + 4, width: 11, height: 11), alpha: 0.95 * dim, fill: false) }
            if let text { c.text(text, at: CGPoint(x: bx + 13, y: r.minY + 3.5), size: 9.5, color: color) }
            bx -= 4
        }
        if r.width > 40 {
            if !clip.speed.isNormal && !clip.isFreezeFrame {
                if case .curve = clip.speed { badge("waveform.path.ecg", tr("timeline.badge.curve"), color: RGBA(hex: 0xF2C230)) }
                else { badge("gauge.with.needle", String(format: "%.1fx", clip.speed.averageRate), color: RGBA(hex: 0xF2C230)) }
            }
            if clip.reversed { badge("arrow.uturn.backward") }
            if clip.audio.isMuted && asset?.hasAudio == true && !clip.isFreezeFrame { badge("speaker.slash") }
            if !clip.effects.isEmpty, clip.mediaID != nil || { if case .text = clip.content { return true }; return false }() { badge("sparkles") }
            if clip.groupID != nil { badge("square.on.square") }
            if !clip.isEnabled { badge("eye.slash") }
        }
        // Speed curve: dotted line in the name strip
        if case .curve = clip.speed, r.width > 60 {
            var x = visL + 2
            while x < r.maxX - 2 { c.rect(CGRect(x: x, y: r.minY + 19, width: 2, height: 1), RGBA(hex: 0xF2C230, alpha: 0.7)); x += 5 }
        }
        // Animation ramps
        if let a = clip.animations.inAnim {
            let w = CGFloat(a.duration.seconds * l.pixelsPerSecond)
            c.rect(CGRect(x: r.minX, y: r.maxY - 4, width: min(w, r.width), height: 4), RGBA(1, 1, 1, 0.35), radius: 1)
        }
        if let a = clip.animations.outAnim {
            let w = min(CGFloat(a.duration.seconds * l.pixelsPerSecond), r.width)
            c.rect(CGRect(x: r.maxX - w, y: r.maxY - 4, width: w, height: 4), RGBA(1, 1, 1, 0.35), radius: 1)
        }
        if clip.animations.combo != nil { c.rect(CGRect(x: r.minX, y: r.maxY - 3, width: r.width, height: 3), RGBA(1, 1, 1, 0.22)) }
        // Beat markers (yellow dots under the clip)
        if let beats = clip.beats {
            for b in beats {
                let x = l.x(clip.start + b)
                guard x > visL - 3, x < r.maxX + 3 else { continue }
                c.rect(CGRect(x: x - 2.5, y: r.maxY - 6, width: 5, height: 5), RGBA(hex: 0xF2C230), radius: 2.5)
            }
        }
        // Hover trim handles
        if hoverClip == clip.id, !selected, r.width > 24, ui.tool == .select {
            c.rect(CGRect(x: r.minX, y: r.minY, width: 5, height: r.height), RGBA(1, 1, 1, 0.55), radius: 2)
            c.rect(CGRect(x: r.maxX - 5, y: r.minY, width: 5, height: r.height), RGBA(1, 1, 1, 0.55), radius: 2)
        }
        // Selection + keyframes + fade handles
        if selected {
            c.rect(r, .white, radius: 4, border: 1.5)
            if r.width > 24 {
                c.rect(CGRect(x: r.minX + 1, y: r.midY - 8, width: 3, height: 16), .white, radius: 1.5)
                c.rect(CGRect(x: r.maxX - 4, y: r.midY - 8, width: 3, height: 16), .white, radius: 1.5)
            }
            let ky = r.maxY - TimelineLayout.keyframeBand / 2 - 1
            let img = SymbolImages.image("diamond.fill")
            for (key, track) in clip.keyframes {
                for k in track.keyframes {
                    let x = l.x(clip.start + k.time)
                    guard x >= r.minX - 4, x <= r.maxX + 4 else { continue }
                    let isSel = ui.selectedKeyframe.map { $0.clip == clip.id && $0.key == key && abs(($0.time - k.time).ticks) < 1000 } ?? false
                    if let img {
                        c.image(img, in: CGRect(x: x - 5, y: ky - 5, width: 10, height: 10), alpha: 1, fill: false)
                        if isSel { c.rect(CGRect(x: x - 2.5, y: ky - 2.5, width: 5, height: 5), Self.accent, radius: 1) }
                    }
                }
            }
            if track.kind == .audio {
                for fadeIn in [true, false] {
                    let fr = fadeHandleRect(clip, rect: r, fadeIn: fadeIn, layout: l)
                    c.rect(fr, .white, radius: fr.width / 2)
                }
            }
        }
        // Background processing on this clip (reverse render, stabilization, AI…): CapCut shows progress on the clip.
        if let job = store.jobs.first(where: { $0.subject == clip.id.description && ($0.state == .running || $0.state == .queued) }) {
            c.rect(r, RGBA(0, 0, 0, 0.55), radius: 4)
            let bar = CGRect(x: r.minX + 6, y: r.maxY - 8, width: max(0, (r.width - 12) * job.progress), height: 3)
            c.rect(CGRect(x: r.minX + 6, y: r.maxY - 8, width: max(0, r.width - 12), height: 3), RGBA(1, 1, 1, 0.25), radius: 1.5)
            c.rect(bar, Self.accent, radius: 1.5)
            c.text("\(tr(job.titleKey)) \(Int(job.progress * 100)) %", at: CGPoint(x: r.minX + 6, y: r.midY - 6), size: 10.5,
                   color: .white, maxWidth: max(0, r.width - 12))
        }
    }

    func fadeHandleRect(_ clip: Clip, rect r: CGRect, fadeIn: Bool, layout l: TimelineLayout) -> CGRect {
        let off = CGFloat((fadeIn ? clip.audio.fadeIn : clip.audio.fadeOut).seconds * l.pixelsPerSecond)
        let x = fadeIn ? r.minX + 6 + off : r.maxX - 6 - off
        return CGRect(x: x - 4, y: r.minY + 2, width: 8, height: 8)
    }

    private func drawWaveform(_ c: inout Canvas2D, _ clip: Clip, asset: MediaAsset, in wr: CGRect, layout l: TimelineLayout, color: RGBA, scale: Double) {
        guard let w = WaveformCache.shared.cached(asset) else { requestWave(asset); return }
        let mid = wr.midY
        let step: CGFloat = 2
        var x = max(wr.minX, TimelineLayout.headerWidth)
        while x < min(wr.maxX, bounds.width) {
            let t0 = clip.sourceTime(at: l.time(atX: x)).seconds, t1 = clip.sourceTime(at: l.time(atX: x + step)).seconds
            let a = CGFloat(w.peak(from: min(t0, t1), to: max(t0, t1))) * clip.audio.volume * scale
            let h = max(1, min(wr.height, a * wr.height))
            c.rect(CGRect(x: x, y: mid - h / 2, width: step - 0.5, height: h), a > 0.95 ? RGBA(hex: 0xE5934A) : color)
            x += step
        }
    }

    static let labelColors: [RGBA] = [RGBA(hex: 0x8E3B46), RGBA(hex: 0x9C6B30), RGBA(hex: 0x3F7D4E), RGBA(hex: 0x2F6690), RGBA(hex: 0x6B4E9B)]

    func clipName(_ clip: Clip, asset: MediaAsset?) -> String {
        if clip.isFreezeFrame { return tr("timeline.freeze") }
        switch clip.content {
        case .text(let t): return t.string.replacingOccurrences(of: "\n", with: " ")
        case .sticker(let id): return Registries.stickers[id].map { tr($0.nameKey) } ?? id
        case .adjustment: return clip.effects.first.flatMap { Registries.effects[$0.typeID] }.map { tr($0.nameKey) } ?? tr("tab.adjustment")
        case .solid: return tr("clip.solid")
        case .media: return clip.name ?? asset?.name ?? ""
        case .compound(let id): return clip.name ?? store.project.compound(id)?.name ?? tr("clip.compound")
        }
    }

    private func requestThumb(_ a: MediaAsset, at t: Time, height: Int) {
        let key = "\(a.contentHash)-\(Int(t.seconds / ThumbnailCache.quantum))-\(height)"
        guard requestedThumbs.insert(key).inserted else { return }
        Task { [weak self] in
            _ = await ThumbnailCache.shared.thumbnail(a, at: t, height: height)
            self?.dirty = true
            self?.requestedThumbs.remove(key)
        }
    }

    private func requestWave(_ a: MediaAsset) {
        guard requestedWaves.insert(a.contentHash).inserted else { return }
        Task { [weak self] in _ = await WaveformCache.shared.waveform(a); self?.dirty = true }
    }

    static func rulerLabel(_ t: Double, fps: Double, step: Double) -> String {
        let total = Int(t.rounded(.down))
        let mm = total / 60, ss = total % 60
        if step < 1 {
            let f = Int(((t - Double(total)) * fps).rounded())
            return f == 0 ? String(format: "%02d:%02d", mm, ss) : "\(f)f"
        }
        return String(format: "%02d:%02d", mm, ss)
    }

    // MARK: Snapshot

    /// Offscreen render of the timeline (window snapshots / tests).
    func snapshot() -> CGImage? {
        let s = window?.backingScaleFactor ?? 2
        let w = max(1, Int(bounds.width * s)), h = max(1, Int(bounds.height * s))
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
        guard let out = MetalContext.shared.device.makeTexture(descriptor: d), let cmd = MetalContext.shared.queue.makeCommandBuffer() else { return nil }
        renderer.encode(buildCanvas(), into: out, scale: s, clear: RGBA(hex: 0x1B1B1C), commandBuffer: cmd)
        cmd.commit(); cmd.waitUntilCompleted()
        return TextureReadback.cgImage(out)
    }
}

/// SF Symbols rendered once to white CGImages for GPU drawing.
@MainActor
enum SymbolImages {
    private static var cache: [String: CGImage?] = [:]
    static func image(_ name: String) -> CGImage? {
        if let c = cache[name] { return c }
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 28, weight: .regular)) else { cache[name] = .some(nil); return nil }
        let size = NSSize(width: 40, height: 40)
        let img = NSImage(size: size, flipped: false) { r in
            base.draw(in: r.insetBy(dx: 4, dy: 4))
            NSColor.white.set()
            r.fill(using: .sourceAtop)
            return true
        }
        var rect = CGRect(origin: .zero, size: size)
        let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        cache[name] = cg
        return cg
    }
}

/// Closure-backed NSMenuItem.
final class MenuAction: NSObject {
    let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
    @objc func run() { body() }
    static func item(_ title: String, key: String, _ mods: NSEvent.ModifierFlags = .command, enabled: Bool = true,
                     checked: Bool = false, _ body: @escaping () -> Void) -> NSMenuItem {
        let a = MenuAction(body)
        let i = NSMenuItem(title: title, action: enabled ? #selector(run) : nil, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.target = enabled ? a : nil
        i.representedObject = a
        i.isEnabled = enabled
        i.state = checked ? .on : .off
        return i
    }
}
