import AppKit
import Observation
import MontageCore
import MontageEngine

/// Pen mask drawing on the canvas (MK-001 / MK-002, CapCut "Pen": click to add points, click the first point — or
/// double-click — to close the outline). While drawing, a drag after a click moves the point just placed. Closing
/// replaces the selected mask's outline, box and rotation in one undo step (`cmd.mask`); the inspector's Pen tile
/// (or "Redraw") starts the tool, leaving the Mask tab cancels it.
@Observable
@MainActor
final class PenMaskTool: CanvasTool {
    private(set) var revision = 0
    @ObservationIgnored let clipID: ClipID
    @ObservationIgnored let target: MaskTarget
    @ObservationIgnored weak var store: EditorStore?
    /// Clicked points, canvas pixels.
    private(set) var points: [Vec2] = []
    private(set) var hover: Vec2?
    /// View points per canvas pixel, from the last draw (closing distance is in view points).
    @ObservationIgnored private var viewScale = 1.0
    static let closeRadius = 9.0

    init(clipID: ClipID, target: MaskTarget, store: EditorStore) {
        self.clipID = clipID; self.target = target; self.store = store
    }

    /// Whether a click at `p` closes the outline (on the first point, or a double-click on the last one).
    func closes(at p: Vec2) -> Bool {
        guard points.count >= 3 else { return false }
        return (points[0] - p).length * viewScale <= Self.closeRadius || (points[points.count - 1] - p).length * viewScale <= 3
    }

    func mouseDown(at p: Vec2) {
        if closes(at: p) { finish(); return }
        points.append(p); revision += 1
    }
    func mouseDragged(at p: Vec2) {
        guard !points.isEmpty else { return }
        points[points.count - 1] = p; revision += 1
    }
    func mouseUp(at p: Vec2) {}
    func hover(at p: Vec2?) { hover = p; revision += 1 }

    /// Writes the drawn outline into the mask (needs ≥ 3 points) and ends the tool.
    func finish() {
        guard let store else { return }
        defer { store.endPenMask() }
        let canvas = store.project.settings.canvasSize
        let g = MotionTracking.layer(of: clipID, in: store.project, at: store.transport.playhead)?.geometry(canvasSize: canvas)
            ?? LayerGeometry(sourceSize: canvas, canvasSize: canvas, transform: Transform())
        guard let r = PenMaskDrawing.mask(from: points, layer: g) else { return }
        let t = target
        store.perform(UpdateClip(clipID, nameKey: "cmd.mask") { c in
            guard var m = c[keyPath: t.mask] else { return }
            m.shape = .pen; m.center = r.center; m.size = r.size; m.rotation = 0; m.points = r.points
            c[keyPath: t.mask] = m
            c.clearKeyframes([t.center, t.size, t.rotation])
        })
    }

    /// Open polyline through the clicked points, a rubber band to the cursor, white dots (the first one larger, ringed
    /// in the accent colour once the outline can be closed) and a hint pill.
    func draw(in ctx: CGContext, toView: (Vec2) -> CGPoint, scale: Double) {
        viewScale = scale
        let v = points.map(toView)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 2, color: NSColor.black.withAlphaComponent(0.5).cgColor)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5)
        if v.count >= 2 { ctx.addLines(between: v); ctx.strokePath() }
        if let last = v.last, let h = hover {
            ctx.setLineDash(phase: 0, lengths: [4, 4])
            let hv = toView(h)
            ctx.strokeLineSegments(between: [last, closes(at: h) ? v[0] : hv])
            ctx.setLineDash(phase: 0, lengths: [])
        }
        for (i, p) in v.enumerated() {
            let r: CGFloat = i == 0 ? 5 : 4
            let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
            ctx.setFillColor(NSColor.white.cgColor); ctx.fillEllipse(in: rect)
            if i == 0 && points.count >= 3 {
                ctx.setStrokeColor(NSColor(srgbRed: 0x57 / 255.0, green: 0xBE / 255.0, blue: 0xCB / 255.0, alpha: 1).cgColor)
                ctx.setLineWidth(2); ctx.strokeEllipse(in: rect.insetBy(dx: -2, dy: -2))
            }
        }
        ctx.restoreGState()
    }
}

extension EditorStore {
    /// Starts drawing a pen outline for the selected mask of `clipID` (Video ▸ Mask / Adjust ▸ Mask ▸ Pen).
    func beginPenMask(_ clipID: ClipID, target: MaskTarget) {
        endPenMask(); endShapeDraw()
        let t = PenMaskTool(clipID: clipID, target: target, store: self)
        playerUI.canvasTool = t
        engine.pause()
        showToast(tr("mask.pen.hint"))
    }

    func endPenMask() {
        if playerUI.canvasTool is PenMaskTool { playerUI.canvasTool = nil }
    }

    var penMaskTool: PenMaskTool? { playerUI.canvasTool as? PenMaskTool }
}
