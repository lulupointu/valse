import AppKit
@preconcurrency import Metal
import QuartzCore
import MontageCore
import MontageEffects
import MontageEngine

/// The timeline canvas: one GPU-drawn, virtualized view (no NSView per clip). Draws ruler, track headers, lanes,
/// clips (filmstrips, waveforms, labels, transitions, keyframes), playhead and drag feedback with `Canvas2D`,
/// and implements scrub / select / move / trim / drop / zoom / scroll.
final class TimelineView: NSView {
    let store: EditorStore
    private let renderer = Canvas2DRenderer()
    private var link: CADisplayLink?
    private var fallbackTimer: Timer?
    private var dirty = true
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private var lastCanvas: Canvas2D?

    // View state
    var scrollTime: Double = 0 { didSet { dirty = true } }
    var scrollY: CGFloat = 0 { didSet { dirty = true } }
    private var layoutCache: TimelineLayout?

    // Interaction state
    private enum Drag {
        case none
        case scrub
        case move(id: ClipID, grab: Time, kind: TrackKind)
        case trim(id: ClipID, edge: TrimEdge)
    }
    private var drag: Drag = .none
    private var snapLine: Time?
    private var dropIndicator: (time: Time, row: Int?)?
    private var hoverTime: Time?
    private var requestedThumbs: Set<String> = []
    private var requestedWaves: Set<String> = []

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

    @objc private func tick() {
        guard dirty, bounds.width > 0 else { return }
        dirty = false
        draw()
    }

    private func followPlayhead() {
        guard store.transport.isPlaying, case .none = drag else { return }
        let l = layoutNow
        let x = l.x(store.transport.playhead)
        if x > bounds.width - 40 || x < TimelineLayout.headerWidth {
            scrollTime = max(0, store.transport.playhead.seconds - 1)
        }
    }

    // MARK: Drawing

    private func draw() {
        let canvas = buildCanvas()
        lastCanvas = canvas
        guard let drawable = metalLayer.nextDrawable(), let cmd = MetalContext.shared.queue.makeCommandBuffer() else { return }
        renderer.encode(canvas, into: drawable.texture, scale: metalLayer.contentsScale, clear: RGBA(hex: 0x1B1B1C), commandBuffer: cmd)
        cmd.present(drawable)
        cmd.commit()
    }

    func buildCanvas() -> Canvas2D {
        var c = Canvas2D()
        let l = layoutNow
        layoutCache = l
        let p = store.project
        let W = bounds.width, H = bounds.height
        let headerW = TimelineLayout.headerWidth
        let fps = p.settings.frameRate.fps

        // Lanes
        c.clip = CGRect(x: headerW, y: TimelineLayout.rulerHeight, width: W - headerW, height: H - TimelineLayout.rulerHeight)
        for row in l.rows {
            c.rect(CGRect(x: headerW, y: row.y, width: W - headerW, height: row.height),
                   row.isMain ? RGBA(hex: 0x242425) : RGBA(hex: 0x1E1E1F), radius: 0)
        }
        if l.rows.count == 1, p.timeline.mainTrack?.clips.isEmpty == true {
            let row = l.rows[0]
            c.text(tr("timeline.emptyHint"), at: CGPoint(x: headerW + 16, y: row.y + row.height / 2 - 7), size: 12, weight: .regular,
                   color: RGBA(hex: 0x7A7A7A))
        }

        // Clips
        let visible = l.visibleRange
        for row in l.rows {
            let track = p.timeline.tracks[row.trackIndex]
            for clip in track.clips(in: visible) {
                drawClip(&c, clip, row: row, track: track, layout: l)
            }
            // transition markers between main clips
            if row.isMain {
                for (i, clip) in track.clips.enumerated() where i + 1 < track.clips.count {
                    let x = l.x(clip.end - (clip.transitionOut?.duration ?? .zero) / 2.0)
                    guard x > headerW - 10, x < W + 10 else { continue }
                    let has = clip.transitionOut != nil
                    let r = CGRect(x: x - 9, y: row.y + row.height / 2 - 9, width: 18, height: 18)
                    c.rect(r, has ? RGBA(hex: 0x57BECB) : RGBA(1, 1, 1, 0.0), radius: 4)
                    if has { c.text("⧓", at: CGPoint(x: x - 5, y: row.y + row.height / 2 - 8), size: 11, color: .white) }
                }
            }
        }

        // Drop indicator / snap line
        if let d = dropIndicator {
            let x = l.x(d.time)
            c.rect(CGRect(x: x - 1, y: TimelineLayout.rulerHeight, width: 2, height: H), RGBA(hex: 0x57BECB))
            if let ri = d.row, ri < l.rows.count {
                let r = l.rows[ri]
                c.rect(CGRect(x: headerW, y: r.y, width: W - headerW, height: r.height), RGBA(0.34, 0.75, 0.8, 0.12))
            }
        }
        if let s = snapLine {
            c.rect(CGRect(x: l.x(s) - 0.5, y: TimelineLayout.rulerHeight, width: 1, height: H), RGBA(hex: 0x57BECB))
        }

        // Ruler
        c.clip = CGRect(x: headerW, y: 0, width: W - headerW, height: TimelineLayout.rulerHeight)
        c.rect(CGRect(x: headerW, y: 0, width: W - headerW, height: TimelineLayout.rulerHeight), RGBA(hex: 0x1B1B1C))
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

        // Headers
        c.clip = CGRect(x: 0, y: TimelineLayout.rulerHeight, width: headerW, height: H)
        c.rect(CGRect(x: 0, y: 0, width: headerW, height: H), RGBA(hex: 0x1F1F20))
        for row in l.rows {
            let track = p.timeline.tracks[row.trackIndex]
            let r = CGRect(x: 4, y: row.y, width: headerW - 8, height: row.height)
            if row.isMain {
                // "Cover" button next to the clips (UX.md §6.3)
                let b = CGRect(x: r.maxX - 48, y: r.midY - 18, width: 44, height: 36)
                c.rect(b, RGBA(hex: 0x2A2A2A), radius: 4)
                let w = c.measure(tr("timeline.cover"), size: 10)
                c.text(tr("timeline.cover"), at: CGPoint(x: b.midX - w / 2, y: b.midY - 6), size: 10, weight: .medium, color: RGBA(hex: 0xE6E6E6))
            } else {
                let icons = headerIcons(track)
                var x = r.minX + 2
                for (sym, on) in icons {
                    if let img = SymbolImages.image(sym) {
                        c.image(img, in: CGRect(x: x, y: r.midY - 7, width: 14, height: 14), alpha: on ? 0.95 : 0.45, fill: false)
                    }
                    x += 20
                }
            }
        }
        c.clip = CGRect(x: 0, y: 0, width: headerW, height: TimelineLayout.rulerHeight)
        c.rect(CGRect(x: 0, y: 0, width: headerW, height: TimelineLayout.rulerHeight), RGBA(hex: 0x1B1B1C))

        // Playhead
        c.clip = CGRect(x: headerW, y: 0, width: W - headerW, height: H)
        let px = l.x(store.transport.playhead)
        c.rect(CGRect(x: px - 0.75, y: 6, width: 1.5, height: H), .white)
        c.rect(CGRect(x: px - 5, y: 2, width: 10, height: 10), .white, radius: 3)
        c.rect(CGRect(x: px - 2.5, y: 10, width: 5, height: 5), .white, radius: 1)
        if let h = hoverTime, case .none = drag {
            c.rect(CGRect(x: l.x(h) - 0.5, y: TimelineLayout.rulerHeight, width: 1, height: H), RGBA(1, 1, 1, 0.25))
        }
        return c
    }

    private func headerIcons(_ t: Track) -> [(String, Bool)] {
        var out: [(String, Bool)] = [(t.isLocked ? "lock.fill" : "lock.open", t.isLocked)]
        if t.kind.isVisual { out.append((t.isHidden ? "eye.slash" : "eye", !t.isHidden)) }
        if t.kind == .audio || t.kind == .video { out.append((t.isMuted ? "speaker.slash" : "speaker.wave.2", !t.isMuted)) }
        return out
    }

    private func drawClip(_ c: inout Canvas2D, _ clip: Clip, row: TimelineLayout.Row, track: Track, layout l: TimelineLayout) {
        let r = l.clipRect(clip, row: row).insetBy(dx: 0.5, dy: 0)
        guard r.maxX > TimelineLayout.headerWidth, r.minX < bounds.width else { return }
        let p = store.project
        let base = Theme.clipColor(track.kind)
        let asset = clip.mediaID.flatMap { p.asset($0) }
        let selected = store.selection.contains(clip.id)
        c.rect(r, clip.isEnabled ? base : base.mix(RGBA(0.2, 0.2, 0.2), 0.6), radius: 4)

        // Filmstrip
        if let asset, asset.kind != .audio, r.height >= 30 {
            let th = Int(r.height * 2)
            let aspect = asset.pixelSize.height > 0 ? asset.pixelSize.width / asset.pixelSize.height : 16 / 9
            let tileW = max(24, r.height * CGFloat(aspect))
            let startIndex = max(0, Int((TimelineLayout.headerWidth - r.minX) / tileW))
            var i = startIndex
            while r.minX + CGFloat(i) * tileW < min(r.maxX, bounds.width) {
                let x0 = r.minX + CGFloat(i) * tileW
                let tileRect = CGRect(x: x0, y: r.minY, width: min(tileW, r.maxX - x0), height: r.height)
                let tl = clip.start + Time(Double(CGFloat(i) * tileW + tileW / 2) / l.pixelsPerSecond)
                let st = asset.kind == .image ? Time.zero : clip.sourceTime(at: min(tl, clip.end))
                if let img = ThumbnailCache.shared.cached(asset, at: st, height: th) {
                    c.image(img, in: tileRect, alpha: clip.isEnabled ? 1 : 0.4)
                } else {
                    requestThumb(asset, at: st, height: th)
                }
                i += 1
                if i - startIndex > 200 { break }
            }
        }
        // Waveform (audio clips)
        if let asset, asset.kind == .audio || (track.kind == .audio && asset.hasAudio) {
            if let w = WaveformCache.shared.cached(asset) {
                let mid = r.midY + 4
                let step: CGFloat = 2
                var x = max(r.minX, TimelineLayout.headerWidth)
                while x < min(r.maxX, bounds.width) {
                    let t0 = clip.sourceTime(at: l.time(atX: x)).seconds, t1 = clip.sourceTime(at: l.time(atX: x + step)).seconds
                    let a = CGFloat(w.peak(from: min(t0, t1), to: max(t0, t1))) * clip.audio.volume
                    let h = max(1, min(r.height - 16, a * (r.height - 16)))
                    c.rect(CGRect(x: x, y: mid - h / 2, width: step - 0.5, height: h), Theme.waveform)
                    x += step
                }
            } else {
                requestWave(asset)
            }
        }
        // Label chip: name + duration
        let name = clipName(clip, asset: asset)
        let labelX = max(r.minX, TimelineLayout.headerWidth) + 4
        let room = r.maxX - labelX - 4
        if room > 14 {
            let label = r.width > 90 ? "\(name)  \(Timecode.shortDuration(clip.duration))" : name
            let w = min(c.measure(label) + 8, room)
            c.rect(CGRect(x: labelX, y: r.minY + 3, width: w, height: 15), RGBA(0, 0, 0, 0.35), radius: 3)
            c.text(label, at: CGPoint(x: labelX + 4, y: r.minY + 3.5), size: 10.5, color: .white, maxWidth: w - 8)
        }
        // Speed badge
        if !clip.speed.isNormal, r.width > 60 {
            let s = String(format: "%.1fx", clip.speed.averageRate)
            c.text(s, at: CGPoint(x: r.maxX - c.measure(s) - 6, y: r.minY + 3.5), size: 10, color: RGBA(hex: 0xF2C230))
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
        // Selection + keyframes
        if selected {
            c.rect(r, .white, radius: 4, border: 1.5)
            for (_, track) in clip.keyframes {
                for k in track.keyframes {
                    let x = l.x(clip.start + k.time)
                    c.text("◆", at: CGPoint(x: x - 4, y: r.maxY - 13), size: 9, color: RGBA(1, 1, 1, 0.9))
                }
            }
        }
    }

    private func clipName(_ clip: Clip, asset: MediaAsset?) -> String {
        switch clip.content {
        case .text(let t): return t.string.replacingOccurrences(of: "\n", with: " ")
        case .sticker(let id): return Registries.stickers[id].map { tr($0.nameKey) } ?? id
        case .adjustment: return clip.effects.first.flatMap { Registries.effects[$0.typeID] }.map { tr($0.nameKey) } ?? tr("tab.adjustment")
        case .solid: return tr("clip.solid")
        case .media: return clip.name ?? asset?.name ?? ""
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

    // MARK: Mouse

    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    override func mouseDown(with e: NSEvent) {
        let pt = point(e)
        let l = layoutNow
        let tl = store.project.timeline
        switch l.hitTest(pt, timeline: tl) {
        case .ruler, .none, .newTrack:
            drag = .scrub
            store.selection = []
            store.seek(to: l.time(atX: pt.x), exact: false)
        case .track:
            store.selection = []
            drag = .scrub
            store.seek(to: l.time(atX: pt.x), exact: false)
        case .header(let ri):
            headerClick(ri, x: pt.x, layout: l)
        case .clip(let id, let region, let ri):
            guard let clip = tl.clip(id) else { return }
            if e.modifierFlags.contains(.shift) || e.modifierFlags.contains(.command) {
                if store.selection.contains(id) { store.selection.remove(id) } else { store.selection.insert(id) }
            } else if !store.selection.contains(id) {
                store.selection = [id]
            }
            let kind = l.rows[ri].kind
            if tl.tracks[l.rows[ri].trackIndex].isLocked { return }
            switch region {
            case .leadingEdge: drag = .trim(id: id, edge: .head); store.beginGesture("cmd.trim")
            case .trailingEdge: drag = .trim(id: id, edge: .tail); store.beginGesture("cmd.trim")
            case .body:
                drag = .move(id: id, grab: l.time(atX: pt.x) - clip.start, kind: kind)
                store.beginGesture("cmd.move")
            }
        }
        dirty = true
    }

    override func mouseDragged(with e: NSEvent) {
        let pt = point(e)
        let l = layoutNow
        autoscroll(pt)
        switch drag {
        case .none: break
        case .scrub:
            store.seek(to: l.time(atX: pt.x), exact: false)
        case .trim(let id, let edge):
            var t = l.time(atX: pt.x)
            snapLine = nil
            if store.project.timeline.snapping, !e.modifierFlags.contains(.command) {
                let s = l.snap(t, timeline: store.project.timeline, playhead: store.transport.playhead, excluding: [id])
                t = s.0; if s.snapped { snapLine = t }
            }
            store.updateGesture { p in try TimelineOps.trim(id, edge: edge, to: t, in: &p) }
            if let c = store.project.timeline.clip(id) { store.seek(to: edge == .head ? c.start : c.end - Time(ticks: 1), exact: false) }
        case .move(let id, let grab, let kind):
            guard let clip = store.project.timeline.clip(id) else { return }
            var start = max(.zero, l.time(atX: pt.x) - grab)
            snapLine = nil
            if store.project.timeline.snapping, !e.modifierFlags.contains(.command) {
                let a = l.snap(start, timeline: store.project.timeline, playhead: store.transport.playhead, excluding: [id])
                let b = l.snap(start + clip.duration, timeline: store.project.timeline, playhead: store.transport.playhead, excluding: [id])
                if a.snapped && (!b.snapped || abs((a.0 - start).ticks) <= abs((b.0 - start - clip.duration).ticks)) { start = a.0; snapLine = a.0 }
                else if b.snapped { start = b.0 - clip.duration; snapLine = b.0 }
            }
            let hit = l.hitTest(pt, timeline: store.project.timeline)
            var target: TrackID?
            var newTrack = false
            switch hit {
            case .track(let ri), .clip(_, _, let ri):
                let row = l.rows[ri]
                if Self.compatible(row.kind, kind) { target = row.trackID }
            case .newTrack(let above): newTrack = above && kind != .audio || !above && kind == .audio
            default: break
            }
            store.updateGesture { p in
                var tid = target
                if newTrack { tid = TimelineOps.addTrack(kind == .video ? .video : kind, to: &p.timeline) }
                try TimelineOps.move(id, to: start, track: tid, in: &p.timeline)
            }
        }
        dirty = true
    }

    override func mouseUp(with e: NSEvent) {
        switch drag {
        case .scrub: store.seek(to: layoutNow.time(atX: point(e).x), exact: true)
        case .move, .trim: store.endGesture()
        case .none: break
        }
        drag = .none
        snapLine = nil
        dirty = true
    }

    override func mouseMoved(with e: NSEvent) {
        let pt = point(e)
        let l = layoutNow
        hoverTime = pt.x > TimelineLayout.headerWidth ? l.time(atX: pt.x) : nil
        switch l.hitTest(pt, timeline: store.project.timeline) {
        case .clip(_, .leadingEdge, _), .clip(_, .trailingEdge, _): NSCursor.resizeLeftRight.set()
        default: NSCursor.arrow.set()
        }
        dirty = true
    }

    override func mouseExited(with event: NSEvent) { hoverTime = nil; dirty = true }

    override func rightMouseDown(with e: NSEvent) {
        let pt = point(e)
        if case .clip(let id, _, _) = layoutNow.hitTest(pt, timeline: store.project.timeline) {
            if !store.selection.contains(id) { store.selection = [id] }
            let m = NSMenu()
            m.addItem(MenuAction.item(tr("menu.split"), key: "b") { [weak self] in self?.store.splitAtPlayhead() })
            m.addItem(MenuAction.item(tr("menu.delete"), key: "") { [weak self] in self?.store.deleteSelection() })
            m.addItem(.separator())
            m.addItem(MenuAction.item(tr("menu.toggleClip"), key: "") { [weak self] in
                guard let self else { return }
                let ids = self.store.selection
                self.store.perform(Edit("cmd.editClip") { p in for i in ids { p.timeline[clip: i]?.isEnabled.toggle() } })
            })
            NSMenu.popUpContextMenu(m, with: e, for: self)
        }
    }

    private func headerClick(_ ri: Int, x: CGFloat, layout l: TimelineLayout) {
        let row = l.rows[ri]
        guard !row.isMain else { return }
        let track = store.project.timeline.tracks[row.trackIndex]
        let icons = headerIcons(track)
        let idx = Int((x - 6) / 20)
        guard idx >= 0, idx < icons.count else { return }
        let sym = icons[idx].0
        let tid = track.id
        store.perform(Edit("cmd.timelineOption") { p in
            guard let i = p.timeline.trackIndex(tid) else { return }
            if sym.hasPrefix("lock") { p.timeline.tracks[i].isLocked.toggle() }
            else if sym.hasPrefix("eye") { p.timeline.tracks[i].isHidden.toggle() }
            else { p.timeline.tracks[i].isMuted.toggle() }
        })
    }

    private func autoscroll(_ pt: CGPoint) {
        if pt.x > bounds.width - 20 { scrollTime += 8 / store.pixelsPerSecond }
        else if pt.x < TimelineLayout.headerWidth + 10 && scrollTime > 0 { scrollTime = max(0, scrollTime - 8 / store.pixelsPerSecond) }
    }

    static func compatible(_ track: TrackKind, _ clip: TrackKind) -> Bool {
        if track == clip { return true }
        let adj: Set<TrackKind> = [.effect, .filter, .adjustment]
        return adj.contains(track) && adj.contains(clip)
    }

    // MARK: Scroll & zoom

    override func scrollWheel(with e: NSEvent) {
        if e.modifierFlags.contains(.command) {
            zoom(by: e.scrollingDeltaY > 0 ? 1.1 : 1 / 1.1, around: point(e).x)
            return
        }
        let dx = e.modifierFlags.contains(.option) ? e.scrollingDeltaY : e.scrollingDeltaX
        let dy = e.modifierFlags.contains(.option) ? 0 : e.scrollingDeltaY
        if dx != 0 { scrollTime = max(0, scrollTime - Double(dx) / store.pixelsPerSecond) }
        if dy != 0 {
            let maxY = max(0, layoutNow.contentHeight - bounds.height)
            scrollY = min(max(0, scrollY - dy), maxY)
        }
    }

    override func magnify(with e: NSEvent) { zoom(by: 1 + e.magnification, around: point(e).x) }

    func zoom(by k: Double, around x: CGFloat) {
        let l = layoutNow
        let anchor = l.time(atX: x).seconds
        store.zoom(by: k)
        scrollTime = max(0, anchor - Double(x - TimelineLayout.headerWidth) / store.pixelsPerSecond)
    }

    // MARK: Drag & drop

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let pt = convert(sender.draggingLocation, from: nil)
        let l = layoutNow
        var t = l.time(atX: pt.x)
        let s = l.snap(t, timeline: store.project.timeline, playhead: store.transport.playhead)
        t = s.0
        dropIndicator = (t, l.rowIndex(atY: pt.y))
        dirty = true
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { dropIndicator = nil; dirty = true }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { dropIndicator = nil; dirty = true }
        let pt = convert(sender.draggingLocation, from: nil)
        let l = layoutNow
        let time = dropIndicator?.time ?? l.time(atX: pt.x)
        let hit = l.hitTest(pt, timeline: store.project.timeline)
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            store.importFiles(urls, thenInsertAt: time, target: insertTarget(hit, l))
            return true
        }
        guard let s = pb.string(forType: .string), let payload = DragPayload.parse(s) else { return false }
        switch payload {
        case .media(let id):
            store.addToTimeline(id, at: time, target: insertTarget(hit, l))
        case .effect(let typeID):
            guard let d = Registries.effects[typeID] else { return false }
            if case .clip(let cid, _, _) = hit { store.selection = [cid] } else { store.selection = []; store.seek(to: time) }
            store.applyEffect(d)
        case .transition(let typeID):
            guard let d = Registries.transitions[typeID] else { return false }
            if case .clip(let cid, _, _) = hit { store.selection = [cid] }
            store.applyTransition(d)
        case .sticker(let id):
            store.seek(to: time); store.addGeneratorClip(.sticker(id: id))
        case .text(let styleID):
            store.seek(to: time); store.addText(style: Registries.textStyles[styleID])
        }
        return true
    }

    private func insertTarget(_ hit: TimelineLayout.Hit, _ l: TimelineLayout) -> InsertTarget {
        switch hit {
        case .track(let ri), .clip(_, _, let ri):
            let row = l.rows[ri]
            return row.isMain ? .automatic : .track(row.trackID)
        case .newTrack(above: true): return .newTrack
        default: return .automatic
        }
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
    private static var cache: [String: CGImage] = [:]
    static func image(_ name: String) -> CGImage? {
        if let c = cache[name] { return c }
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 28, weight: .regular)) else { return nil }
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
    static func item(_ title: String, key: String, _ body: @escaping () -> Void) -> NSMenuItem {
        let a = MenuAction(body)
        let i = NSMenuItem(title: title, action: #selector(run), keyEquivalent: key)
        i.target = a
        i.representedObject = a
        return i
    }
}
