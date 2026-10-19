import AppKit
import MontageCore
import MontageEngine

/// Transparent AppKit view over the Metal player (UX.md §4.2): selection box & handles (move / corner scale / rotate,
/// text ✕ delete), snap guides, rulers & guides, safe zones, inline text editing, zoom & pan.
/// Edits go through store gestures, so a whole drag is one undo step and the preview re-renders live.
final class CanvasOverlayView: NSView {
    let store: EditorStore
    /// Tells the Metal view where the frame goes (view points, origin top-left).
    var onContentRectChange: ((CGRect) -> Void)?

    private enum Drag {
        case none
        case transform(handle: CanvasHandle, clipID: ClipID, base: Clip, layer: CanvasLayer, others: [CanvasLayer],
                       start: Vec2, startView: CGPoint, started: Bool)
        case pan(startPan: CGPoint, startView: CGPoint)
        case guide(id: UUID)
        case newGuide(CanvasGuide.Axis)
        case mask(handle: MaskHandle, clipID: ClipID, target: MaskTarget, base: Mask, frame: MaskFrame, start: Vec2, startView: CGPoint, started: Bool)
    }
    private var drag: Drag = .none
    private var snapLines: [SnapLine] = []
    private var angleLabel: Double?
    /// "Feather 40" / "Round corners 20" pill while dragging a mask button.
    private var maskValueLabel: String?
    private var magnifyBase: (clipID: ClipID, scale: Vec2)?
    private var lastContentRect: CGRect = .zero
    private var mouseMonitor: Any?
    private var textEditor: InlineTextEditor?
    private var tracking: NSTrackingArea?
    private var observing = false
    private var toolDragging = false
    /// Downscaled RGBA sample of the presented frame (set by the container: the Metal player view).
    var frameSampler: (() -> (pixels: [UInt8], width: Int, height: Int)?)?
    private var scopeImage: CGImage?
    private var scopeTimer: Timer?

    static let rulerWidth: CGFloat = 18
    static let accent = NSColor(srgbRed: 0x57 / 255.0, green: 0xBE / 255.0, blue: 0xCB / 255.0, alpha: 1)
    static let guideColor = NSColor(srgbRed: 0xF0 / 255.0, green: 0x4E / 255.0, blue: 0x9B / 255.0, alpha: 0.9)

    init(store: EditorStore) {
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = .clear
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var viewport: PlayerViewport {
        PlayerViewport(viewSize: bounds.size, canvas: store.playerUI.preview?.canvas ?? store.project.settings.canvasSize, zoom: store.playerUI.zoom,
                       pan: store.playerUI.pan)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let m = mouseMonitor { NSEvent.removeMonitor(m); mouseMonitor = nil }
        guard window != nil else { return }
        if !observing { observing = true; store.observe { [weak self] in self?.observeState() } }
        // Canvas focus (arrow keys nudge): set by clicks in the canvas, cleared by clicks anywhere else.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            if let self, e.window === self.window {
                let p = self.convert(e.locationInWindow, from: nil)
                let inside = self.bounds.contains(p) && !self.isHiddenOrHasHiddenAncestor
                if self.store.playerUI.canvasHasFocus != inside { self.store.playerUI.canvasHasFocus = inside }
            }
            return e
        }
    }

    override func removeFromSuperview() {
        if let m = mouseMonitor { NSEvent.removeMonitor(m); mouseMonitor = nil }
        super.removeFromSuperview()
    }

    /// Reads everything the overlay draws (Observation tracks it) and schedules a redraw.
    private func observeState() {
        let ui = store.playerUI
        _ = (ui.zoom, ui.pan, ui.showRulers, ui.showGuides, ui.guides, ui.safeZone, ui.editingTextClip)
        _ = ui.canvasTool?.revision
        _ = store.project.settings.canvasSize
        _ = (store.inspectorTab, InspectorUIState.shared.subTab, ui.preview, store.project.duration, ui.scope)
        updateScopeTimer()
        if !store.selection.isEmpty {
            _ = store.project.timeline
            _ = store.transport.playhead
        }
        if let id = ui.editingTextClip, textEditor?.clipID != id { beginTextEditing(id) }
        if ui.editingTextClip == nil, textEditor != nil { endTextEditing() }
        if let ed = textEditor, !store.selection.contains(ed.clipID) { endTextEditing() }
        textEditor.map(layoutTextEditor)
        publishContentRect()
        needsDisplay = true
    }

    private func publishContentRect() {
        let r = viewport.contentRect
        if r != lastContentRect { lastContentRect = r; onContentRectChange?(r) }
    }

    override func layout() {
        super.layout()
        publishContentRect()
        textEditor.map(layoutTextEditor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    // MARK: Model access

    private var layers: [CanvasLayer] { CanvasLayers.at(store.transport.playhead, project: store.project) }

    private var selectedLayers: [CanvasLayer] {
        let sel = store.selection
        guard !sel.isEmpty else { return [] }
        return layers.filter { sel.contains($0.clipID) }
    }

    private func localTime(_ c: Clip) -> Time { (store.transport.playhead - c.start).clamped(.zero, c.duration) }

    /// Mask editing on the canvas (UX.md §5.1): one selected layer with a mask while the inspector shows a Mask sub-tab
    /// (Video ▸ Mask edits `Clip.mask`, Adjust ▸ Mask the grading mask `Clip.adjustMask`).
    private var maskTarget: (layer: CanvasLayer, clip: Clip, mask: Mask, target: MaskTarget)? {
        guard store.selection.count == 1 else { return nil }
        // Adjustment / effect / filter layers have no canvas layer: their effect mask spans the whole canvas.
        let l: CanvasLayer
        if let s = selectedLayers.first { l = s }
        else if let id = store.selection.first, let c = store.project.timeline.clip(id), c.content == .adjustment,
                c.start <= store.transport.playhead, store.transport.playhead < c.end {
            let canvas = store.project.settings.canvasSize
            l = CanvasLayer(clipID: id, geometry: LayerGeometry(sourceSize: canvas, canvasSize: canvas, transform: Transform()),
                            isText: false, isLocked: store.project.timeline.locate(id).map { store.project.timeline.tracks[$0.track].isLocked } ?? false)
        } else { return nil }
        guard !l.isLocked, let clip = store.project.timeline.clip(l.clipID) else { return nil }
        let tab = store.inspectorTab ?? InspectorRegistry.tabs(for: InspectorContext(store: store)).first?.id
        guard let tab, InspectorUIState.shared.subTab[tab] == "mask" else { return nil }
        let target: MaskTarget = ["adjust", "specialEffects", "filter"].contains(tab) ? .adjust : MaskTarget.clip.resolved(clip)
        guard clip[keyPath: target.mask] != nil, let m = clip.resolved(at: localTime(clip))[keyPath: target.mask] else { return nil }
        return (l, clip, m, target)
    }

    private var guideTargets: (x: [Double], y: [Double]) {
        let ui = store.playerUI, canvas = store.project.settings.canvasSize
        guard ui.showGuides else { return ([], []) }
        return (ui.guides.filter { $0.axis == .vertical }.map { $0.position * canvas.width },
                ui.guides.filter { $0.axis == .horizontal }.map { $0.position * canvas.height })
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let vp = viewport
        let r = vp.contentRect
        let ui = store.playerUI

        // empty project (CapCut screenshot 10): no black frame, just the panel colour
        if store.isPlayerEmpty {
            ctx.setFillColor(NSColor(srgbRed: 0x1B / 255.0, green: 0x1B / 255.0, blue: 0x1C / 255.0, alpha: 1).cgColor)
            ctx.fill(bounds)
            return
        }

        drawSafeZone(ui.safeZone, in: r, ctx)
        if ui.scope != .off { drawScope(ctx) }

        if ui.showGuides {
            ctx.setLineWidth(1)
            ctx.setStrokeColor(Self.guideColor.cgColor)
            for g in ui.guides {
                if g.axis == .horizontal {
                    let y = (r.minY + r.height * g.position).rounded() + 0.5
                    ctx.strokeLineSegments(between: [CGPoint(x: r.minX, y: y), CGPoint(x: r.maxX, y: y)])
                } else {
                    let x = (r.minX + r.width * g.position).rounded() + 0.5
                    ctx.strokeLineSegments(between: [CGPoint(x: x, y: r.minY), CGPoint(x: x, y: r.maxY)])
                }
            }
        }

        // Snap lines across the whole frame.
        ctx.setStrokeColor(Self.accent.cgColor)
        ctx.setLineWidth(1)
        for l in snapLines {
            switch l {
            case .vertical(let x):
                let vx = vp.toView(Vec2(x, 0)).x.rounded() + 0.5
                ctx.strokeLineSegments(between: [CGPoint(x: vx, y: r.minY), CGPoint(x: vx, y: r.maxY)])
            case .horizontal(let y):
                let vy = vp.toView(Vec2(0, y)).y.rounded() + 0.5
                ctx.strokeLineSegments(between: [CGPoint(x: r.minX, y: vy), CGPoint(x: r.maxX, y: vy)])
            }
        }

        if let tool = ui.canvasTool {
            ctx.saveGState(); ctx.clip(to: r)
            tool.draw(in: ctx, toView: vp.toView, scale: vp.scale)
            ctx.restoreGState()
            return
        }
        MotionPathDrawing.draw(ctx, viewport: vp, store: store)   // W5: position keyframes path (MontageUI/Keyframes)

        // library / source preview: the timeline's layers aren't on screen, so no selection or mask handles
        if ui.preview != nil { return }

        if let mt = maskTarget {
            drawMask(MaskFrame(layer: mt.layer.geometry, mask: mt.mask), layer: mt.layer, mask: mt.mask, vp, ctx)
            if ui.showRulers { drawRulers(vp, ctx) }
            return
        }

        let sel = selectedLayers
        let single = sel.count == 1 && store.selection.count == 1
        for l in sel {
            let pts = l.geometry.corners.map(vp.toView)
            let path = CGMutablePath()
            path.addLines(between: [pts[0], pts[1], pts[3], pts[2], pts[0]])
            ctx.setStrokeColor((snapLines.isEmpty ? NSColor.white : Self.accent).cgColor)
            ctx.setLineWidth(1)
            ctx.addPath(path); ctx.strokePath()
            guard single, textEditor == nil, !l.isLocked else { continue }
            // corner handles
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.setShadow(offset: .zero, blur: 2, color: NSColor.black.withAlphaComponent(0.5).cgColor)
            for (i, p) in pts.enumerated() where !(l.isText && i == 0) {
                ctx.fillEllipse(in: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
            }
            // text: pill handles on the left / right edge midpoints (wrap width, UX.md §4.2)
            if l.isText {
                for (_, e) in CanvasHandles.edgePills(l.geometry) {
                    let v = vp.toView(e)
                    ctx.saveGState()
                    ctx.translateBy(x: v.x, y: v.y); ctx.rotate(by: l.geometry.rotation)
                    ctx.addPath(CGPath(roundedRect: CGRect(x: -3, y: -8, width: 6, height: 16), cornerWidth: 3, cornerHeight: 3, transform: nil))
                    ctx.fillPath()
                    ctx.restoreGState()
                }
            }
            // rotate button
            let rp = vp.toView(CanvasHandles.rotatePosition(l.geometry, viewScale: vp.scale))
            ctx.fillEllipse(in: CGRect(x: rp.x - 10, y: rp.y - 10, width: 20, height: 20))
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            drawSymbol("arrow.triangle.2.circlepath", at: rp, size: 11)
            // text: ✕ delete on the top-left corner
            if l.isText {
                ctx.setShadow(offset: .zero, blur: 2, color: NSColor.black.withAlphaComponent(0.5).cgColor)
                ctx.fillEllipse(in: CGRect(x: pts[0].x - 8, y: pts[0].y - 8, width: 16, height: 16))
                ctx.setShadow(offset: .zero, blur: 0, color: nil)
                drawSymbol("xmark", at: pts[0], size: 8)
            }
            if let a = angleLabel { drawPill(String(format: "%.0f°", CanvasDrag.displayAngle(a)), at: CGPoint(x: rp.x, y: rp.y + 24), ctx) }
        }

        if ui.showRulers { drawRulers(vp, ctx) }
    }

    /// Dashed white mask outline + centre cross, white corner dots, edge pills, floating round buttons (screenshot 28).
    private func drawMask(_ f: MaskFrame, layer: CanvasLayer, mask: Mask, _ vp: PlayerViewport, _ ctx: CGContext) {
        let shadow = NSColor.black.withAlphaComponent(0.5).cgColor
        // the layer itself: faint outline
        let lp = layer.geometry.corners.map(vp.toView)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
        ctx.setLineWidth(1)
        ctx.addLines(between: [lp[0], lp[1], lp[3], lp[2], lp[0]]); ctx.strokePath()

        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 2, color: shadow)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [5, 4])
        let c = vp.toView(f.center)
        let hx = f.half.x * vp.scale, hy = f.half.y * vp.scale
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.rotate(by: f.rotation)
        let box = CGRect(x: -hx, y: -hy, width: 2 * hx, height: 2 * hy)
        switch f.shape {
        case .linear:
            ctx.strokeLineSegments(between: [CGPoint(x: -hx, y: 0), CGPoint(x: hx, y: 0)])
        case .mirror:
            ctx.strokeLineSegments(between: [CGPoint(x: -hx, y: -hy), CGPoint(x: hx, y: -hy), CGPoint(x: -hx, y: hy), CGPoint(x: hx, y: hy)])
        case .circle:
            ctx.strokeEllipse(in: box)
        case .rectangle:
            let r = min(mask.roundness * min(hx, hy), min(hx, hy))
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: r, cornerHeight: r, transform: nil)); ctx.strokePath()
        case .heart, .star, .text:
            ctx.stroke(box)
        case .pen:
            // the outline itself (same Catmull-Rom path as the raster mask) inside a faint box
            let pts = (f.points ?? []).map { b -> CGPoint in let l = f.boxToLocal(b); return CGPoint(x: l.x * vp.scale, y: l.y * vp.scale) }
            if pts.count >= 3 { ctx.addPath(RasterMasks.smoothClosedPath(pts)); ctx.strokePath() }
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.4).cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(box)
            ctx.restoreGState()
        }
        // centre cross
        ctx.setLineDash(phase: 0, lengths: [3, 3])
        ctx.setLineWidth(1)
        ctx.strokeLineSegments(between: [CGPoint(x: -7, y: 0), CGPoint(x: 7, y: 0), CGPoint(x: 0, y: -7), CGPoint(x: 0, y: 7)])
        // edge pills (drawn in the mask frame so they turn with it)
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.setFillColor(NSColor.white.cgColor)
        for (i, _) in f.edges() {
            let horizontal = i == 0 || i == 2
            let pc = [CGPoint(x: 0, y: -hy), CGPoint(x: hx, y: 0), CGPoint(x: 0, y: hy), CGPoint(x: -hx, y: 0)][i]
            let pill = horizontal ? CGRect(x: pc.x - 9, y: pc.y - 3, width: 18, height: 6) : CGRect(x: pc.x - 3, y: pc.y - 9, width: 6, height: 18)
            ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 3, cornerHeight: 3, transform: nil)); ctx.fillPath()
        }
        ctx.restoreGState()
        // corner dots
        if f.hasBox {
            ctx.setFillColor(NSColor.white.cgColor)
            for p in f.corners.map(vp.toView) { ctx.fillEllipse(in: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)) }
        }
        // pen outline points: hollow dots (drag to reshape)
        if !f.pointPositions.isEmpty {
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.setStrokeColor(NSColor.systemBlue.cgColor)
            ctx.setLineWidth(1.5)
            for p in f.pointPositions.map(vp.toView) {
                let r = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
                ctx.fillEllipse(in: r); ctx.strokeEllipse(in: r)
            }
        }
        // floating buttons
        var buttons: [(Vec2, String)] = [(f.rotateButton(viewScale: vp.scale), "arrow.triangle.2.circlepath"),
                                         (f.featherButton(viewScale: vp.scale), "arrow.up.and.down")]
        if f.hasRoundness { buttons.append((f.roundnessButton(viewScale: vp.scale), "square.dashed")) }
        for (p, sym) in buttons {
            let v = vp.toView(p)
            let r = MaskFrame.buttonRadius
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: CGRect(x: v.x - r, y: v.y - r, width: 2 * r, height: 2 * r))
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            drawSymbol(sym, at: v, size: 10)
            ctx.setShadow(offset: .zero, blur: 2, color: shadow)
        }
        ctx.restoreGState()
        if let a = angleLabel {
            let rb = vp.toView(f.rotateButton(viewScale: vp.scale))
            drawPill(String(format: "%.0f°", a), at: CGPoint(x: rb.x, y: rb.y + 24), ctx)
        }
        if let v = maskValueLabel {
            let fb = vp.toView(f.featherButton(viewScale: vp.scale))
            drawPill(v, at: CGPoint(x: fb.x, y: fb.y - 24), ctx)
        }
    }

    // MARK: Color oscilloscope (W2-6)

    /// Bottom-right panel: dark rounded box, 0/50/100 % grid, the scope image.
    private func drawScope(_ ctx: CGContext) {
        let w = min(240, bounds.width * 0.4), h = w / 2
        let box = CGRect(x: bounds.width - w - 10, y: bounds.height - h - 10, width: w, height: h)
        ctx.saveGState()
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.88).cgColor)
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 6, cornerHeight: 6, transform: nil)); ctx.fillPath()
        let plot = box.insetBy(dx: 6, dy: 6)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
        ctx.setLineWidth(0.5)
        for f in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let y = plot.minY + plot.height * f
            ctx.strokeLineSegments(between: [CGPoint(x: plot.minX, y: y), CGPoint(x: plot.maxX, y: y)])
        }
        if let img = scopeImage {
            // the CG image is drawn bottom-up in this flipped view: flip it back so high values stay at the top
            ctx.translateBy(x: 0, y: plot.maxY + plot.minY); ctx.scaleBy(x: 1, y: -1)
            ctx.setBlendMode(.screen)
            ctx.draw(img, in: plot)
        }
        ctx.restoreGState()
    }

    private func updateScopeTimer() {
        let on = store.playerUI.scope != .off
        if on, scopeTimer == nil {
            refreshScope()
            scopeTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshScope() }
            }
        } else if !on, let t = scopeTimer {
            t.invalidate(); scopeTimer = nil; scopeImage = nil
        }
    }

    private func refreshScope() {
        let mode = store.playerUI.scope
        guard mode != .off, let s = frameSampler?() else { return }
        scopeImage = ScopeAnalyzer.image(rgba: s.pixels, width: s.width, height: s.height, mode: mode)
        needsDisplay = true
    }

    private func drawSymbol(_ name: String, at p: CGPoint, size: CGFloat) {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .bold)) else { return }
        let tinted = NSImage(size: img.size, flipped: false) { rect in
            img.draw(in: rect)
            NSColor.black.withAlphaComponent(0.85).set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: CGRect(x: p.x - img.size.width / 2, y: p.y - img.size.height / 2, width: img.size.width, height: img.size.height))
    }

    private func drawPill(_ text: String, at p: CGPoint, _ ctx: CGContext) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                                                    .foregroundColor: NSColor.white]
        let s = NSAttributedString(string: text, attributes: attrs)
        let sz = s.size()
        let box = CGRect(x: p.x - sz.width / 2 - 6, y: p.y - sz.height / 2 - 3, width: sz.width + 12, height: sz.height + 6)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.75).cgColor)
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 4, cornerHeight: 4, transform: nil)); ctx.fillPath()
        s.draw(at: CGPoint(x: box.minX + 6, y: box.minY + 3))
    }

    private func drawSafeZone(_ z: SafeZone, in r: CGRect, _ ctx: CGContext) {
        guard z != .none else { return }
        func rect(_ n: CGRect) -> CGRect {
            CGRect(x: r.minX + n.minX * r.width, y: r.minY + n.minY * r.height, width: n.width * r.width, height: n.height * r.height)
        }
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        for c in z.covered { ctx.fill(rect(c)) }
        // generic UI mock: action icons in the side column, caption lines at the bottom
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.55).cgColor)
        if let side = z.covered.dropFirst().first {
            let s = rect(side)
            let d = min(s.width * 0.55, s.height / 6)
            for i in 0..<4 {
                ctx.fillEllipse(in: CGRect(x: s.midX - d / 2, y: s.minY + CGFloat(i) * s.height / 4 + (s.height / 4 - d) / 2, width: d, height: d))
            }
        }
        if let bottom = z.covered.last {
            let b = rect(bottom)
            for (i, w) in [0.45, 0.65, 0.35].enumerated() {
                ctx.fill(CGRect(x: b.minX + b.width * 0.05, y: b.minY + b.height * (0.18 + 0.22 * CGFloat(i)),
                                width: b.width * w, height: max(2, b.height * 0.08)))
            }
        }
        if let safe = z.safeRect {
            ctx.setStrokeColor(Self.accent.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [5, 4])
            ctx.stroke(rect(safe))
            if z == .broadcast { ctx.stroke(rect(CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))) }
            ctx.setLineDash(phase: 0, lengths: [])
        }
    }

    private func drawRulers(_ vp: PlayerViewport, _ ctx: CGContext) {
        let w = Self.rulerWidth
        ctx.setFillColor(NSColor(srgbRed: 0x24 / 255.0, green: 0x24 / 255.0, blue: 0x25 / 255.0, alpha: 0.96).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: bounds.width, height: w))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: bounds.height))
        let step = RulerTicks.step(viewScale: vp.scale)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                                                    .foregroundColor: NSColor(white: 0.6, alpha: 1)]
        ctx.setStrokeColor(NSColor(white: 0.5, alpha: 1).cgColor)
        ctx.setLineWidth(1)
        let c0 = vp.toCanvas(CGPoint(x: w, y: w)), c1 = vp.toCanvas(CGPoint(x: bounds.width, y: bounds.height))
        var x = (c0.x / step).rounded(.down) * step
        while x <= c1.x {
            let vx = vp.toView(Vec2(x, 0)).x.rounded() + 0.5
            if vx >= w {
                ctx.strokeLineSegments(between: [CGPoint(x: vx, y: w - 7), CGPoint(x: vx, y: w)])
                NSAttributedString(string: "\(Int(x))", attributes: attrs).draw(at: CGPoint(x: vx + 2, y: 2))
                for k in 1..<5 {
                    let sx = vp.toView(Vec2(x + step * Double(k) / 5, 0)).x.rounded() + 0.5
                    if sx >= w { ctx.strokeLineSegments(between: [CGPoint(x: sx, y: w - 3), CGPoint(x: sx, y: w)]) }
                }
            }
            x += step
        }
        var y = (c0.y / step).rounded(.down) * step
        while y <= c1.y {
            let vy = vp.toView(Vec2(0, y)).y.rounded() + 0.5
            if vy >= w {
                ctx.strokeLineSegments(between: [CGPoint(x: w - 7, y: vy), CGPoint(x: w, y: vy)])
                NSAttributedString(string: "\(Int(y))", attributes: attrs).draw(at: CGPoint(x: 2, y: vy + 1))
                for k in 1..<5 {
                    let sy = vp.toView(Vec2(0, y + step * Double(k) / 5)).y.rounded() + 0.5
                    if sy >= w { ctx.strokeLineSegments(between: [CGPoint(x: w - 3, y: sy), CGPoint(x: w, y: sy)]) }
                }
            }
            y += step
        }
        ctx.setFillColor(NSColor(srgbRed: 0x1B / 255.0, green: 0x1B / 255.0, blue: 0x1C / 255.0, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: w))
    }

    // MARK: Mouse

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        store.playerUI.canvasHasFocus = true
        let v = convert(e.locationInWindow, from: nil)
        if textEditor != nil { store.playerUI.editingTextClip = nil; endTextEditing(); return }
        if store.isPreviewing { store.exitPreview(); return }
        let vp = viewport
        let p = vp.toCanvas(v)
        let ui = store.playerUI
        if let tool = ui.canvasTool { toolDragging = true; tool.mouseDown(at: p); return }

        // rulers → drag out a new guide
        if ui.showRulers, v.y < Self.rulerWidth || v.x < Self.rulerWidth {
            if !ui.guidesLocked { drag = .newGuide(v.y < Self.rulerWidth ? .horizontal : .vertical); ui.showGuides = true }
            return
        }
        // existing guide
        if ui.showGuides, !ui.guidesLocked, let g = guide(near: v, vp) { drag = .guide(id: g.id); return }

        if let mt = maskTarget {
            let f = MaskFrame(layer: mt.layer.geometry, mask: mt.mask)
            // pen outline (MK-002): ⌥-click a point removes it; a click on the outline between two points inserts one
            // there and drags it
            if let pts = f.points {
                if e.modifierFlags.contains(.option), case .point(let i)? = f.hit(p, viewScale: vp.scale) {
                    let t = mt.target
                    store.perform(UpdateClip(mt.clip.id, nameKey: "cmd.mask") { $0[keyPath: t.mask]?.points = MaskFrame.removingPoint(pts, index: i) })
                    return
                }
                if let ins = f.penInsertion(p, viewScale: vp.scale) {
                    var np = pts; np.insert(ins.point, at: ins.index)
                    let t = mt.target, id = mt.clip.id
                    store.beginGesture("cmd.mask")
                    apply(id) { $0[keyPath: t.mask]?.points = np }
                    var base = mt.mask; base.points = np
                    drag = .mask(handle: .point(ins.index), clipID: id, target: t, base: base,
                                 frame: MaskFrame(layer: mt.layer.geometry, mask: base), start: p, startView: v, started: true)
                    needsDisplay = true
                    return
                }
            }
            if let h = f.hit(p, viewScale: vp.scale) {
                drag = .mask(handle: h, clipID: mt.clip.id, target: mt.target, base: mt.mask, frame: f, start: p, startView: v, started: false)
                return
            }
            // inside the masked layer but off the mask: keep the selection (no layer transform while editing the mask)
            if mt.layer.geometry.contains(p) { return }
        }
        let all = layers
        if let sel = selectedLayers.first, store.selection.count == 1, !sel.isLocked,
           let h = CanvasHandles.hit(sel.geometry, isText: sel.isText, at: p, viewScale: vp.scale) {
            if h == .delete { store.deleteSelection(); return }
            if h == .body, e.clickCount == 2, sel.isText { store.playerUI.editingTextClip = sel.clipID; return }
            startTransform(h, sel, all, p, v)
            return
        }
        if let hit = CanvasLayers.hit(all, at: p) {
            store.selection = [hit.clipID]
            if e.clickCount == 2, hit.isText { store.playerUI.editingTextClip = hit.clipID; return }
            startTransform(.body, hit, all, p, v)
            return
        }
        if ui.isZoomed { drag = .pan(startPan: ui.pan, startView: v); NSCursor.closedHand.push(); return }
        store.selection = []
    }

    private func startTransform(_ h: CanvasHandle, _ l: CanvasLayer, _ all: [CanvasLayer], _ p: Vec2, _ v: CGPoint) {
        guard let clip = store.project.timeline.clip(l.clipID) else { return }
        drag = .transform(handle: h, clipID: l.clipID, base: clip, layer: l, others: all.filter { $0.clipID != l.clipID },
                          start: p, startView: v, started: false)
    }

    override func mouseDragged(with e: NSEvent) {
        let v = convert(e.locationInWindow, from: nil)
        let vp = viewport
        let p = vp.toCanvas(v)
        let canvas = store.project.settings.canvasSize
        if toolDragging, let tool = store.playerUI.canvasTool { tool.mouseDragged(at: p); return }
        switch drag {
        case .none:
            return
        case .pan(let startPan, let startView):
            store.playerUI.pan = vp.clampedPan(CGPoint(x: startPan.x + v.x - startView.x, y: startPan.y + v.y - startView.y))
        case .newGuide(let axis):
            let r = vp.contentRect
            let pos = axis == .horizontal ? Double((v.y - r.minY) / r.height) : Double((v.x - r.minX) / r.width)
            let g = CanvasGuide(axis: axis, position: min(max(pos, 0), 1))
            store.playerUI.guides.append(g)
            drag = .guide(id: g.id)
        case .guide(let id):
            guard let i = store.playerUI.guides.firstIndex(where: { $0.id == id }) else { return }
            let r = vp.contentRect
            let g = store.playerUI.guides[i]
            let pos = g.axis == .horizontal ? Double((v.y - r.minY) / r.height) : Double((v.x - r.minX) / r.width)
            store.playerUI.guides[i].position = min(max(pos, 0), 1)
        case .mask(let h, let id, let t, let base, let f, let start, let startView, var started):
            if !started {
                guard hypot(v.x - startView.x, v.y - startView.y) >= 2 else { return }
                store.beginGesture("cmd.mask")
                started = true
                drag = .mask(handle: h, clipID: id, target: t, base: base, frame: f, start: start, startView: startView, started: true)
            }
            guard let clip = store.project.timeline.clip(id) else { return }
            let local = localTime(clip)
            let dy = Double(v.y - startView.y)
            switch h {
            case .body:
                var d = p - start
                if e.modifierFlags.contains(.shift) { d = CanvasDrag.constrained(d) }
                let c = f.movedCenter(base.center, by: d)
                apply(id) { $0.setValue(t.center, .vec2(c), at: local) }
            case .corner, .edge:
                let keep = InspectorUIState.shared.maskLock || e.modifierFlags.contains(.shift)
                let s = f.resized(base.size, handle: h, to: p, keepAspect: keep)
                apply(id) { $0.setValue(t.size, .vec2(s), at: local) }
            case .rotate:
                let r = f.rotated(base.rotation, start: start, current: p, snapping: !e.modifierFlags.contains(.command))
                angleLabel = r
                apply(id) { $0.setValue(t.rotation, .scalar(r), at: local) }
            case .feather:
                let fv = MaskFrame.dragged(base.feather, dy: dy)
                maskValueLabel = "\(tr("prop.maskFeather")) \(Int((fv * 100).rounded()))"
                apply(id) { $0.setValue(t.feather, .scalar(fv), at: local) }
            case .roundness:
                let rv = MaskFrame.dragged(base.roundness, dy: dy)
                maskValueLabel = "\(tr("prop.maskRoundness")) \(Int((rv * 100).rounded()))"
                apply(id) { $0.setValue(t.roundness, .scalar(rv), at: local) }
            case .point(let i):
                let pts = f.movedPoint(f.points ?? [], index: i, to: p)
                apply(id) { $0[keyPath: t.mask]?.points = pts }
            }
            needsDisplay = true
        case .transform(let h, let id, let base, let layer, let others, let start, let startView, var started):
            if !started {
                guard hypot(v.x - startView.x, v.y - startView.y) >= 2 else { return }
                store.beginGesture(h == .rotate ? "cmd.rotate" : (h == .body ? "cmd.move" : "cmd.scale"))
                started = true
                drag = .transform(handle: h, clipID: id, base: base, layer: layer, others: others, start: start,
                                  startView: startView, started: true)
            }
            let snapping = !e.modifierFlags.contains(.command)
            let local = localTime(base)
            switch h {
            case .body:
                var d = p - start
                if e.modifierFlags.contains(.shift) { d = CanvasDrag.constrained(d) }
                snapLines = []
                if snapping {
                    let b = layer.bounds
                    let g = guideTargets
                    let snapper = CanvasSnapper(canvas: canvas, others: others, guidesX: g.x, guidesY: g.y, threshold: 6 / vp.scale)
                    let s = snapper.snapMove(minX: b.minX + d.x, maxX: b.maxX + d.x, minY: b.minY + d.y, maxY: b.maxY + d.y)
                    if e.modifierFlags.contains(.shift) {
                        // keep the constraint: only snap along the free axis
                        if d.x == 0 { d.y += s.delta.y; snapLines = s.lines.filter { if case .horizontal = $0 { return true }; return false } }
                        else { d.x += s.delta.x; snapLines = s.lines.filter { if case .vertical = $0 { return true }; return false } }
                    } else {
                        d = d + s.delta
                        snapLines = s.lines
                    }
                }
                let pos = base.value(.position, at: local)?.vec2 ?? .zero
                let np = CanvasDrag.moved(pos, by: d, canvas: canvas)
                apply(id) { $0.setValue(.position, .vec2(np), at: local) }
            case .corner:
                let s0 = base.value(.scale, at: local)?.vec2 ?? .one
                var s = CanvasDrag.scaled(s0, center: layer.geometry.center, start: start, current: p)
                if snapping, s0.x == s0.y, abs(s.x - 1) < 0.015 { s = .one }
                apply(id) { $0.setValue(.scale, .vec2(s), at: local) }
            case .rotate:
                let r0 = base.value(.rotation, at: local)?.scalar ?? 0
                let r = CanvasDrag.rotated(r0, center: layer.geometry.center, start: start, current: p, snapping: snapping)
                angleLabel = r
                apply(id) { $0.setValue(.rotation, .scalar(r), at: local) }
            case .edge:
                let sx = abs(base.value(.scale, at: local)?.vec2?.x ?? 1)
                let w = CanvasHandles.textBoxWidth(layer.geometry, dragTo: p, layerScale: sx, canvasWidth: canvas.width)
                apply(id) { c in
                    guard case .text(var t) = c.content else { return }
                    t.boxWidth = w
                    c.content = .text(t)
                }
            case .delete:
                break
            }
            needsDisplay = true
        }
    }

    override func mouseUp(with e: NSEvent) {
        if toolDragging {
            toolDragging = false
            store.playerUI.canvasTool?.mouseUp(at: viewport.toCanvas(convert(e.locationInWindow, from: nil)))
            return
        }
        switch drag {
        case .transform(_, _, _, _, _, _, _, let started), .mask(_, _, _, _, _, _, _, let started):
            if started { store.endGesture() }
        case .pan:
            NSCursor.pop()
        case .guide(let id):
            // dropped back on a ruler / outside the frame → delete
            let v = convert(e.locationInWindow, from: nil)
            let r = viewport.contentRect
            let ui = store.playerUI
            if let g = ui.guides.first(where: { $0.id == id }) {
                let outside = g.axis == .horizontal ? (v.y < r.minY - 4 || v.y > r.maxY + 4 || (ui.showRulers && v.y < Self.rulerWidth))
                                                    : (v.x < r.minX - 4 || v.x > r.maxX + 4 || (ui.showRulers && v.x < Self.rulerWidth))
                if outside { ui.guides.removeAll { $0.id == id } }
            }
        default: break
        }
        drag = .none
        snapLines = []
        angleLabel = nil
        maskValueLabel = nil
        needsDisplay = true
    }

    private func apply(_ id: ClipID, _ body: @escaping (inout Clip) -> Void) {
        store.updateGesture { p in
            guard var c = p.timeline.clip(id) else { return }
            body(&c)
            p.timeline[clip: id] = c
        }
    }

    private func guide(near v: CGPoint, _ vp: PlayerViewport) -> CanvasGuide? {
        let r = vp.contentRect
        return store.playerUI.guides.first { g in
            g.axis == .horizontal ? abs(r.minY + r.height * g.position - v.y) <= 4 : abs(r.minX + r.width * g.position - v.x) <= 4
        }
    }

    override func mouseMoved(with e: NSEvent) {
        let v = convert(e.locationInWindow, from: nil)
        let vp = viewport
        let p = vp.toCanvas(v)
        let ui = store.playerUI
        if let eye = store.canvasEyedropper { eye.hover(at: p); NSCursor.crosshair.set(); return }
        if let pen = store.penMaskTool { pen.hover(at: p); NSCursor.crosshair.set(); return }
        if ui.showGuides, !ui.guidesLocked, let g = guide(near: v, vp) {
            (g.axis == .horizontal ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).set(); return
        }
        if let mt = maskTarget, let h = MaskFrame(layer: mt.layer.geometry, mask: mt.mask).hit(p, viewScale: vp.scale) {
            switch h {
            case .body: NSCursor.openHand.set()
            case .corner, .point: NSCursor.crosshair.set()
            case .edge(let i): (i == 0 || i == 2 ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).set()
            case .feather, .roundness: NSCursor.resizeUpDown.set()
            case .rotate: NSCursor.pointingHand.set()
            }
            return
        }
        if let sel = selectedLayers.first, store.selection.count == 1,
           let h = CanvasHandles.hit(sel.geometry, isText: sel.isText, at: p, viewScale: vp.scale) {
            switch h {
            case .body: NSCursor.openHand.set()
            case .corner: NSCursor.crosshair.set()
            case .edge: NSCursor.resizeLeftRight.set()
            case .rotate, .delete: NSCursor.pointingHand.set()
            }
            return
        }
        if CanvasLayers.hit(layers, at: p) != nil { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
    }

    override func mouseExited(with event: NSEvent) { store.canvasEyedropper?.hover(at: nil); NSCursor.arrow.set() }

    // MARK: Scroll / pinch

    override func scrollWheel(with e: NSEvent) {
        let ui = store.playerUI
        if e.modifierFlags.contains(.command) || e.modifierFlags.contains(.option) {
            store.zoomPlayer(by: e.scrollingDeltaY > 0 ? 1.1 : (e.scrollingDeltaY < 0 ? 1 / 1.1 : 1))
            return
        }
        guard ui.isZoomed else { super.scrollWheel(with: e); return }
        let k: CGFloat = e.hasPreciseScrollingDeltas ? 1 : 10
        ui.pan = viewport.clampedPan(CGPoint(x: ui.pan.x + e.scrollingDeltaX * k, y: ui.pan.y + e.scrollingDeltaY * k))
    }

    /// Pinch: scales the selected layer (UX.md §4.2), or zooms the player when nothing is selected.
    override func magnify(with e: NSEvent) {
        guard let sel = selectedLayers.first, store.selection.count == 1, !sel.isLocked,
              let clip = store.project.timeline.clip(sel.clipID) else {
            store.zoomPlayer(by: 1 + e.magnification)
            return
        }
        let local = localTime(clip)
        switch e.phase {
        case .began:
            magnifyBase = (sel.clipID, clip.value(.scale, at: local)?.vec2 ?? .one)
            store.beginGesture("cmd.scale")
        case .changed:
            guard var b = magnifyBase else { return }
            b.scale = Vec2(max(b.scale.x * (1 + e.magnification), 0.01), max(b.scale.y * (1 + e.magnification), 0.01))
            magnifyBase = b
            let s = b.scale
            apply(b.clipID) { $0.setValue(.scale, .vec2(s), at: local) }
        case .ended, .cancelled:
            magnifyBase = nil
            store.endGesture()
        default: break
        }
    }

    // MARK: Context menu (align, fit/fill/stretch, flip, rotate)

    override func menu(for e: NSEvent) -> NSMenu? {
        let p = viewport.toCanvas(convert(e.locationInWindow, from: nil))
        guard let hit = CanvasLayers.hit(layers, at: p) else { return nil }
        if !store.selection.contains(hit.clipID) { store.selection = [hit.clipID] }
        guard let clip = store.project.timeline.clip(hit.clipID) else { return nil }
        let m = NSMenu()
        let alignMenu = NSMenu()
        for a in CanvasAlign.allCases {
            alignMenu.addItem(PlayerMenuAction.item(tr(a.titleKey)) { [weak self] in self?.align(a) })
        }
        let alignItem = NSMenuItem(title: tr("player.align"), action: nil, keyEquivalent: "")
        alignItem.submenu = alignMenu
        m.addItem(alignItem)
        if case .media(let mid) = clip.content, let asset = store.project.asset(mid) {
            m.addItem(.separator())
            for f in CanvasFit.allCases {
                m.addItem(PlayerMenuAction.item(tr(f.titleKey)) { [weak self] in
                    guard let self else { return }
                    let s = f.scale(sourceSize: asset.pixelSize, canvas: self.store.project.settings.canvasSize, crop: clip.crop)
                    self.editSelected("cmd.transform") { c, local in
                        c.setValue(.scale, .vec2(s), at: local)
                        c.setValue(.position, .vec2(.zero), at: local)
                    }
                })
            }
        }
        m.addItem(.separator())
        m.addItem(PlayerMenuAction.item(tr("inspector.flipH")) { [weak self] in self?.editSelected("cmd.transform") { c, _ in c.transform.flipH.toggle() } })
        m.addItem(PlayerMenuAction.item(tr("inspector.flipV")) { [weak self] in self?.editSelected("cmd.transform") { c, _ in c.transform.flipV.toggle() } })
        m.addItem(PlayerMenuAction.item(tr("player.rotate90")) { [weak self] in
            self?.editSelected("cmd.rotate") { c, local in
                let r = c.value(.rotation, at: local)?.scalar ?? 0
                c.setValue(.rotation, .scalar(((r / 90).rounded(.down) + 1) * 90), at: local)
            }
        })
        if hit.isText {
            m.addItem(.separator())
            m.addItem(PlayerMenuAction.item(tr("player.editText")) { [weak self] in self?.store.playerUI.editingTextClip = hit.clipID })
        }
        m.addItem(.separator())
        m.addItem(PlayerMenuAction.item(tr("menu.delete")) { [weak self] in self?.store.deleteSelection() })
        return m
    }

    private func editSelected(_ name: String, _ body: @escaping (inout Clip, Time) -> Void) {
        let ids = store.selection, t = store.transport.playhead
        let box = UncheckedSendable(body)  // runs synchronously on the main actor inside perform
        store.perform(Edit(name) { p in
            for id in ids {
                guard var c = p.timeline.clip(id) else { continue }
                box.value(&c, (t - c.start).clamped(.zero, c.duration))
                p.timeline[clip: id] = c
            }
        })
    }

    private func align(_ a: CanvasAlign) {
        let canvas = store.project.settings.canvasSize
        let byID = Dictionary(layers.map { ($0.clipID, $0) }, uniquingKeysWith: { a, _ in a })
        editSelected("cmd.align") { c, local in
            guard let l = byID[c.id] else { return }
            let d = a.delta(bounds: l.bounds, canvas: canvas)
            let pos = c.value(.position, at: local)?.vec2 ?? .zero
            c.setValue(.position, .vec2(CanvasDrag.moved(pos, by: d, canvas: canvas)), at: local)
        }
    }

    // MARK: Inline text editing (double-click a text layer, UX.md §4.2)

    private func beginTextEditing(_ id: ClipID) {
        endTextEditing()
        guard let clip = store.project.timeline.clip(id), case .text = clip.content else {
            store.playerUI.editingTextClip = nil; return
        }
        if store.selection != [id] { store.selection = [id] }
        let ed = InlineTextEditor(clipID: id, store: store) { [weak self] in
            self?.store.playerUI.editingTextClip = nil
        }
        addSubview(ed.textView)
        textEditor = ed
        layoutTextEditor(ed)
        ed.start()
        window?.makeFirstResponder(ed.textView)
        needsDisplay = true
    }

    private func endTextEditing() {
        guard let ed = textEditor else { return }
        textEditor = nil
        ed.commit()
        ed.textView.removeFromSuperview()
        if window?.firstResponder === ed.textView { window?.makeFirstResponder(self) }
        if store.playerUI.editingTextClip != nil { store.playerUI.editingTextClip = nil }
        needsDisplay = true
    }

    private func layoutTextEditor(_ ed: InlineTextEditor) {
        guard let clip = store.project.timeline.clip(ed.clipID), case .text(let t) = clip.content,
              let l = layers.first(where: { $0.clipID == ed.clipID }) else { return }
        let vp = viewport
        let g = l.geometry
        let c = vp.toView(g.center)
        let w = abs(g.halfSize.x) * 2 * vp.scale, h = abs(g.halfSize.y) * 2 * vp.scale
        let scale = clip.resolved(at: localTime(clip)).transform.scale.y
        ed.layout(text: t, frame: CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h),
                  fontPx: t.fontSize * store.project.settings.canvasSize.height * vp.scale * scale,
                  rotationDegrees: g.rotation * 180 / .pi)
    }

    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53, store.playerUI.isFullscreen { store.setPlayerFullscreen(false); return }
        super.keyDown(with: e)
    }
}

/// NSTextView placed over a text layer: the engine keeps rendering the real text (live, through a store gesture),
/// the view only shows the caret and selection. Esc / click outside commits; the whole edit is one undo step.
@MainActor
final class InlineTextEditor: NSObject, NSTextViewDelegate {
    let clipID: ClipID
    let textView = NSTextView(frame: .zero)
    private let store: EditorStore
    private let onFinish: () -> Void
    private var active = false

    init(clipID: ClipID, store: EditorStore, onFinish: @escaping () -> Void) {
        self.clipID = clipID; self.store = store; self.onFinish = onFinish
        super.init()
        // TextKit 1 with a layout manager that always paints the selection as a translucent blue highlight: AppKit's
        // inactive-window selection colour is an opaque grey that hid the engine-rendered text underneath (W2-2).
        textView.textContainer?.replaceLayoutManager(TranslucentSelectionLayoutManager())
        textView.isRichText = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textColor = .clear
        textView.insertionPointColor = .white
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.allowsUndo = false
        textView.selectedTextAttributes = [.backgroundColor: NSColor(srgbRed: 0.25, green: 0.5, blue: 1, alpha: 0.45)]
        textView.focusRingType = .none
        textView.delegate = self
        textView.setAccessibilityIdentifier("canvas.textEditor")
    }

    func start() {
        guard let c = store.project.timeline.clip(clipID), case .text(let t) = c.content else { return }
        active = true
        store.beginGesture("cmd.textEdit")
        textView.string = t.string
        textView.selectAll(nil)
    }

    func layout(text t: TextContent, frame: CGRect, fontPx: Double, rotationDegrees: Double) {
        let font = TextMetrics.font(t, fontPx: max(fontPx, 1)) as NSFont
        textView.font = font
        textView.alignment = t.alignment == .left ? .left : (t.alignment == .right ? .right : .center)
        let pad = TextMetrics.padding(t, fontPx: max(fontPx, 1))
        textView.textContainerInset = NSSize(width: 0, height: pad)
        textView.frameCenterRotation = 0
        textView.frame = frame.insetBy(dx: CGFloat(pad) - 2, dy: 0)
        textView.frameCenterRotation = -rotationDegrees
    }

    func textDidChange(_ notification: Notification) {
        let s = textView.string
        let id = clipID
        store.updateGesture { p in
            guard var c = p.timeline.clip(id), case .text(var t) = c.content else { return }
            t.setString(s)   // keeps per-range styles on their characters (text engine)
            c.content = .text(t)
            p.timeline[clip: id] = c
        }
    }

    func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) { onFinish(); return true }
        return false
    }

    func commit() {
        guard active else { return }
        active = false
        store.endGesture()
    }
}

/// Paints every selection highlight (active or inactive window) as CapCut's translucent blue, so the real rendered text
/// stays visible under the inline editor.
nonisolated final class TranslucentSelectionLayoutManager: NSLayoutManager {
    nonisolated(unsafe) static let selection = NSColor(srgbRed: 0.25, green: 0.5, blue: 1, alpha: 0.45)
    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
                                          forCharacterRange charRange: NSRange, color: NSColor) {
        Self.selection.setFill()
        super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: Self.selection)
    }
}

/// Closure-backed NSMenuItem target.
final class PlayerMenuAction: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }

    static func item(_ title: String, _ handler: @escaping () -> Void) -> NSMenuItem {
        let target = PlayerMenuAction(handler)
        let i = NSMenuItem(title: title, action: #selector(fire), keyEquivalent: "")
        i.target = target
        i.representedObject = target
        return i
    }
}
