import SwiftUI
import AppKit
import Observation
import MontageCore
import MontageEngine
import MontageAI

/// Brush mask painting (CL-012 Adjust mask "Quick brush" / "Quick eraser"): while the tool is on, a drag on the player
/// paints (or erases) a round stroke into the selected brush mask — one undo step per stroke. Brush size and mode are
/// per-session UI state (`MaskBrushState`).
@Observable
@MainActor
final class MaskBrushState {
    static let shared = MaskBrushState()
    /// 1…100 (100 = a brush a quarter of the layer height in radius).
    var size: Double = 30
    var erase = false
    /// Smart brush (CL-012): a stroke selects the whole object(s) under it (Vision instance / person segmentation).
    var smart = false
    /// A smart-brush selection is being computed.
    var busy = false
    var radius: Double { max(size, 1) / 100 * 0.25 }
    var mode: String {
        get { erase ? "erase" : (smart ? "smart" : "brush") }
        set { erase = newValue == "erase"; smart = newValue == "smart" }
    }
}

/// Canvas ↔ mask-box mapping of a brush mask over a layer (pure, unit-tested).
nonisolated enum MaskBrushMapping {
    /// Canvas pixel → mask-box units of mask `m` over layer `g`.
    static func boxPoint(_ p: Vec2, layer g: LayerGeometry, mask m: Mask) -> Vec2 {
        let w = max(abs(g.halfSize.x) * 2, 1), h = max(abs(g.halfSize.y) * 2, 1)
        let l = MaskFrame.rotate(p - g.center, -g.rotation)
        let u = Vec2(l.x / w - m.center.x, l.y / h - m.center.y)
        // mask rotation is in layer-normalized space as the rasterizer draws it (pixel units, then size)
        let px = MaskFrame.rotate(Vec2(u.x * w, u.y * h), -m.rotation * .pi / 180)
        return Vec2(px.x / max(abs(m.size.x) * w, 1e-6), px.y / max(abs(m.size.y) * h, 1e-6))
    }
}

@Observable
@MainActor
final class MaskBrushTool: CanvasTool {
    private(set) var revision = 0
    @ObservationIgnored let clipID: ClipID
    @ObservationIgnored let target: MaskTarget
    @ObservationIgnored weak var store: EditorStore?
    /// Stroke being painted (canvas pixels).
    private(set) var current: [Vec2] = []
    private(set) var hover: Vec2?
    @ObservationIgnored private var viewScale = 1.0

    init(clipID: ClipID, target: MaskTarget, store: EditorStore) { self.clipID = clipID; self.target = target; self.store = store }

    /// Layer the mask lives on (adjustment / effect layers: the whole canvas).
    func layerGeometry() -> LayerGeometry? {
        guard let store else { return nil }
        let canvas = store.project.settings.canvasSize
        return MotionTracking.layer(of: clipID, in: store.project, at: store.transport.playhead)?.geometry(canvasSize: canvas)
            ?? LayerGeometry(sourceSize: canvas, canvasSize: canvas, transform: Transform())
    }

    func mouseDown(at p: Vec2) { current = [p]; revision += 1 }
    func mouseDragged(at p: Vec2) {
        // skip sub-pixel moves (keeps strokes small)
        if let last = current.last, (last - p).length * viewScale < 1.5 { return }
        current.append(p); hover = p; revision += 1
    }
    func mouseUp(at p: Vec2) {
        defer { current = []; revision += 1 }
        guard let store, !current.isEmpty, let g = layerGeometry(),
              let c = store.project.timeline.clip(clipID), let m = c.resolved(at: Bind.local(store, c))[keyPath: target.mask] else { return }
        let st = MaskBrushState.shared
        let stroke = MaskStroke(points: current.map { MaskBrushMapping.boxPoint($0, layer: g, mask: m) },
                                radius: st.radius, erase: st.erase)
        let t = target
        if st.smart && !st.erase && c.mediaID != nil {
            smartStroke(stroke, clip: c, mask: m)
            return
        }
        store.perform(UpdateClip(clipID, nameKey: st.erase ? "cmd.maskErase" : "cmd.maskBrush") { c in
            let prev = c[keyPath: t.mask]?.strokes ?? []
            c[keyPath: t.mask]?.strokes = prev + [stroke]
            c[keyPath: t.mask]?.propagation = nil   // painted again: the tracked shape is stale (Track mask again)
        })
    }

    /// Smart brush (CL-012): the object(s) under the stroke on this frame become a filled region of the mask.
    func smartStroke(_ stroke: MaskStroke, clip c: Clip, mask m: Mask) {
        guard let store, !MaskBrushState.shared.busy else { return }
        let project = store.project, id = clipID, t = target
        let source = c.sourceTime(at: store.transport.playhead.clamped(c.start, c.end - Time(ticks: 1)))
        let rot = c.mediaID.flatMap(project.asset)?.sourceRotation ?? 0
        MaskBrushState.shared.busy = true
        Task { @MainActor in
            defer { MaskBrushState.shared.busy = false }
            do {
                let raw = try await SmartMask.smartRegion(project: project, clipID: id, mask: t.mask, stroke: stroke, source: source)
                let region = MaskContours.rawToBox(raw, mask: m, clip: c, rotation: rot)
                var picked = stroke; picked.region = region
                let s = picked
                store.perform(UpdateClip(id, nameKey: "cmd.maskSmartBrush") { c in
                    let prev = c[keyPath: t.mask]?.strokes ?? []
                    c[keyPath: t.mask]?.strokes = prev + [s]
                    c[keyPath: t.mask]?.propagation = nil
                })
            } catch {
                store.showToast(tr("mask.smart.none"), error: true)
            }
        }
    }
    func hover(at p: Vec2?) { hover = p; revision += 1 }

    /// Brush ring at the cursor (dashed when erasing) and the stroke being painted (translucent).
    func draw(in ctx: CGContext, toView: (Vec2) -> CGPoint, scale: Double) {
        viewScale = scale
        guard let g = layerGeometry() else { return }
        let r = CGFloat(MaskBrushState.shared.radius * abs(g.halfSize.y) * 2 * scale)
        let erase = MaskBrushState.shared.erase
        ctx.saveGState()
        if current.count >= 1 {
            let v = current.map(toView)
            ctx.setStrokeColor((erase ? NSColor.black : NSColor(srgbRed: 0x57 / 255.0, green: 0xBE / 255.0, blue: 0xCB / 255.0, alpha: 1))
                .withAlphaComponent(0.45).cgColor)
            ctx.setLineWidth(2 * r); ctx.setLineCap(.round); ctx.setLineJoin(.round)
            ctx.move(to: v[0]); if v.count == 1 { ctx.addLine(to: v[0]) } else { for q in v.dropFirst() { ctx.addLine(to: q) } }
            ctx.strokePath()
        }
        if let h = hover {
            let c = toView(h)
            ctx.setShadow(offset: .zero, blur: 2, color: NSColor.black.withAlphaComponent(0.6).cgColor)
            ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(1.5)
            if erase { ctx.setLineDash(phase: 0, lengths: [4, 3]) }
            ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        }
        ctx.restoreGState()
    }
}

extension EditorStore {
    func beginMaskBrush(_ clipID: ClipID, target: MaskTarget) {
        endMaskBrush(); endPenMask(); endShapeDraw()
        playerUI.canvasTool = MaskBrushTool(clipID: clipID, target: target, store: self)
        engine.pause()
    }
    func endMaskBrush() { if playerUI.canvasTool is MaskBrushTool { playerUI.canvasTool = nil } }
    var maskBrushTool: MaskBrushTool? { playerUI.canvasTool as? MaskBrushTool }
}

/// Mask ▸ Brush: [Quick brush | Quick eraser], Brush size, Paint on canvas / Done, Clear.
struct MaskBrushControls: View {
    let ctx: InspectorContext
    let clip: Clip
    let target: MaskTarget
    let strokes: Int

    var body: some View {
        let store = ctx.store
        let st = MaskBrushState.shared
        let painting = store.maskBrushTool?.clipID == clip.id
        VStack(alignment: .leading, spacing: 4) {
            // Smart brush needs a frame to segment: media clips only (not adjustment / effect layers)
            let tabs: [(id: String, title: String)] = clip.mediaID != nil
                ? [("brush", tr("mask.brush.paint")), ("smart", tr("mask.brush.smart")), ("erase", tr("mask.brush.erase"))]
                : [("brush", tr("mask.brush.paint")), ("erase", tr("mask.brush.erase"))]
            SegmentedTabs(tabs, selection: Binding(get: { clip.mediaID == nil && st.smart ? "brush" : st.mode }, set: { st.mode = $0 }))
                .testID("mask.brush.mode")
            SliderRow(tr("mask.brush.size"), range: 1...100, display: { String(Int($0.rounded())) }, testID: "slider.mask.brush.size",
                      get: { st.size }, set: { st.size = $0 }, onBegin: {}, onEnd: {})
            HStack(spacing: 8) {
                Button {
                    if painting { store.endMaskBrush() } else { store.beginMaskBrush(clip.id, target: target) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: painting ? "checkmark" : "paintbrush.pointed").font(.system(size: 12, weight: .semibold))
                        Text(loc: painting ? "mask.brush.done" : "mask.brush.start").font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white).padding(.horizontal, 14).frame(height: 26)
                    .background(painting ? Theme.accentDim : Theme.buttonSecondary, in: Capsule())
                }
                .buttonStyle(.plain)
                .testID("mask.brush.start")
                if st.busy {
                    ProgressView().controlSize(.small).testID("mask.smart.busy")
                    Text(loc: "mask.smart.busy").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
                if strokes > 0 {
                    Button {
                        let t = target
                        store.perform(UpdateClip(clip.id, nameKey: "cmd.maskErase") {
                            $0[keyPath: t.mask]?.strokes = []; $0[keyPath: t.mask]?.propagation = nil
                        })
                    } label: {
                        Text(loc: "mask.brush.clear").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .testID("mask.brush.clear")
                }
            }
            if let p = clip[keyPath: target.mask]?.propagation, !p.samples.isEmpty {
                // MK-004: the painted region follows the object through the clip
                HStack(spacing: 6) {
                    Image(systemName: "scope").font(.system(size: 11)).foregroundStyle(Theme.accent)
                    Text(verbatim: tr("mask.propagated", p.samples.count)).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                        .testID("mask.propagated")
                    Button {
                        let t = target
                        store.perform(UpdateClip(clip.id, nameKey: "cmd.maskTrackRemove") { $0[keyPath: t.mask]?.propagation = nil })
                    } label: { Text(loc: "mask.propagated.remove").font(.system(size: 11)).foregroundStyle(Theme.textTertiary) }
                    .buttonStyle(.plain).testID("mask.propagated.remove")
                }
            }
            if strokes == 0 { HintText(text: tr(st.smart && clip.mediaID != nil ? "mask.smart.hint" : "mask.brush.hint")) }
            else if st.smart && clip.mediaID != nil { HintText(text: tr("mask.smart.hint")) }
        }
        .padding(.bottom, 6)
    }
}
