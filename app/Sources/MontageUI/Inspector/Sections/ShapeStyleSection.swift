import SwiftUI
import AppKit
import Perception
import MontageCore
import MontageEffects
import MontageEngine

/// Stickers ▸ Basic ▸ Shape (ST-008, shape stickers only): ☐ Fill + colour ‹◇›, ☐ Gradient + end colour, ☐ Stroke +
/// colour ‹◇›, Width ‹◇›, Line style (Solid / Dashed / Dotted), Round corners (rectangles) and "Draw on canvas" (a
/// custom outline clicked point by point). Edits write `Clip.shapeStyle`, starting from the sticker's own look.
struct ShapeStyleSection: View {
    let ctx: InspectorContext

    /// The vector layers of a shape sticker clip (Stickers ▸ Shapes); nil for other clips.
    nonisolated static func baseLayers(_ clip: Clip) -> [VectorLayer]? {
        guard case .sticker(let id) = clip.content, let d = Registries.stickers[id], d.groupKey == "sticker.group.shapes",
              case .vector(let l) = d.source, !l.isEmpty else { return nil }
        return l
    }
    static func applies(_ ctx: InspectorContext) -> Bool { ctx.clip.flatMap(baseLayers) != nil }

    /// The clip's style (its own, or the sticker's look).
    nonisolated static func style(_ clip: Clip) -> ShapeStickerStyle? { clip.shapeStyle ?? baseLayers(clip)?.first?.shapeStyle }

    /// One undo step on the clip's style (materialized from the sticker's look first).
    static func update(_ store: EditorStore, _ id: ClipID, _ body: @escaping (inout Clip, Time) -> Void) {
        store.performInspector(UpdateClip(id, nameKey: "cmd.shapeStyle") { c in
            if c.shapeStyle == nil { c.shapeStyle = style(c) }
            body(&c, Bind.local(store, c))
        })
    }

    static func chrome(_ ctx: InspectorContext) -> InspectorSectionChrome {
        InspectorSectionChrome(reset: {
            guard let id = ctx.clip?.id else { return }
            ctx.store.performInspector(UpdateClip(id, nameKey: "cmd.shapeStyle") { c in
                c.shapeStyle = nil
                c.clearKeyframes([.shapeFill, .shapeStroke, .shapeStrokeWidth])
            })
        }, keyframeKeys: ctx.clip?.shapeStyle != nil ? [.shapeFill, .shapeStroke, .shapeStrokeWidth] : [])
    }

    var body: some View {
        WithPerceptionTracking {
            if let clip = ctx.clip, let base = Self.baseLayers(clip)?.first, let s0 = Self.style(clip) {
                let store = ctx.store, id = clip.id
                let s = clip.shapeStyle != nil ? (clip.resolved(at: ctx.localTime).shapeStyle ?? s0) : s0
                let lineOnly = base.isStrokeOnly
                VStack(alignment: .leading, spacing: 2) {
                    if !lineOnly {
                        InlineRow(label: tr("shape.fill"), triplet: AnyView(KeyframeTriplet(ctx: ctx, keys: [.shapeFill], enabled: clip.shapeStyle?.fill != nil))) {
                            CapCheckbox(isOn: Binding(get: { s.fill != nil }, set: { on in
                                Self.update(store, id) { c, _ in c.shapeStyle?.fill = on ? (base.shapeStyle.fill ?? .white) : nil
                                    if !on { c.clearKeyframes([.shapeFill]) } }
                            })).testID("shape.fill.toggle")
                            Spacer().frame(width: 10)
                            if let f = s.fill {
                                ColorSwatchButton(color: f, eyedropper: store, testID: "shape.fill") { col in
                                    Self.update(store, id) { c, t in c.setValue(.shapeFill, .color(col), at: t) }
                                }
                            }
                        }
                        InlineRow(label: tr("shape.gradient"), enabled: s.fill != nil) {
                            CapCheckbox(isOn: Binding(get: { s.fillEnd != nil }, set: { on in
                                Self.update(store, id) { c, _ in c.shapeStyle?.fillEnd = on ? Self.gradientEnd(s.fill ?? .white) : nil }
                            }), enabled: s.fill != nil).testID("shape.gradient.toggle")
                            Spacer().frame(width: 10)
                            if let e = s.fillEnd {
                                ColorSwatchButton(color: e, eyedropper: store, testID: "shape.gradient") { col in
                                    Self.update(store, id) { c, _ in c.shapeStyle?.fillEnd = col }
                                }
                            }
                        }
                    }
                    InlineRow(label: tr(lineOnly ? "shape.color" : "shape.stroke"),
                              triplet: AnyView(KeyframeTriplet(ctx: ctx, keys: [.shapeStroke], enabled: clip.shapeStyle?.stroke != nil))) {
                        if !lineOnly {
                            CapCheckbox(isOn: Binding(get: { s.stroke != nil }, set: { on in
                                Self.update(store, id) { c, _ in
                                    c.shapeStyle?.stroke = on ? (base.shapeStyle.stroke ?? Self.contrast(s.fill)) : nil
                                    if on, (c.shapeStyle?.strokeWidth ?? 0) < 0.005 { c.shapeStyle?.strokeWidth = 0.04 }
                                    if !on { c.clearKeyframes([.shapeStroke, .shapeStrokeWidth]) }
                                }
                            })).testID("shape.stroke.toggle")
                            Spacer().frame(width: 10)
                        }
                        if let st = s.stroke {
                            ColorSwatchButton(color: st, eyedropper: store, testID: "shape.stroke") { col in
                                Self.update(store, id) { c, t in c.setValue(.shapeStroke, .color(col), at: t) }
                            }
                        }
                    }
                    if s.stroke != nil {
                        ClipParamRow(ctx: ctx, label: tr("shape.strokeWidth"),
                                     spec: RowSpec(range: 1...(ShapeStickerStyle.maxStrokeWidth * 100), format: { String(Int($0.rounded())) }),
                                     get: { c, t in (c.value(.shapeStrokeWidth, at: t)?.scalar ?? Self.style(c)?.strokeWidth ?? 0.04) * 100 },
                                     set: { c, v, t in
                                         if c.shapeStyle == nil { c.shapeStyle = Self.style(c) }
                                         c.setValue(.shapeStrokeWidth, .scalar(v / 100), at: t)
                                     },
                                     dependsOnTime: { $0.hasKeyframes(.shapeStrokeWidth) }, keyframeKeys: [.shapeStrokeWidth],
                                     gestureName: "cmd.shapeStyle", testID: "slider.shape.strokeWidth")
                        InlineRow(label: tr("shape.dash")) {
                            SegmentedTabs(ShapeStickerStyle.Dash.allCases.map { ($0.rawValue, tr("shape.dash.\($0.rawValue)")) },
                                          selection: Binding(get: { s.dash.rawValue }, set: { v in
                                              guard let d = ShapeStickerStyle.Dash(rawValue: v), d != s.dash else { return }
                                              Self.update(store, id) { c, _ in c.shapeStyle?.dash = d }
                                          }))
                            .frame(maxWidth: 200)
                            .testID("shape.dash")
                        }
                    }
                    if s.points == nil, base.shape == .rect || base.shape == .roundedRect {
                        ClipParamRow(ctx: ctx, label: tr("shape.corner"), spec: RowSpec(range: 0...50, format: { String(Int($0.rounded())) }),
                                     get: { c, _ in (Self.style(c)?.cornerRadius ?? (base.shape == .roundedRect ? 0.16 : 0)) * 100 },
                                     set: { c, v, _ in
                                         if c.shapeStyle == nil { c.shapeStyle = Self.style(c) }
                                         c.shapeStyle?.cornerRadius = v / 100
                                     }, gestureName: "cmd.shapeStyle", testID: "slider.shape.corner")
                    }
                    let drawing = store.shapeDrawTool?.clipID == id
                    Button {
                        if drawing { store.endShapeDraw() } else { store.beginShapeDraw(id) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: drawing ? "xmark" : "pencil.tip").font(.system(size: 12, weight: .semibold))
                            Text(loc: drawing ? "shape.draw.cancel" : "shape.draw").font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(.white).padding(.horizontal, 14).frame(height: 26)
                        .background(drawing ? Theme.accentDim : Theme.buttonSecondary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)
                    .testID("shape.draw")
                }
                .onDisappear { store.endShapeDraw() }
            }
        }
    }

    /// A darker shade of `c` for a new gradient's bottom.
    static func gradientEnd(_ c: RGBA) -> RGBA { RGBA(c.r * 0.55, c.g * 0.55, c.b * 0.55, c.a) }
    /// Black stroke on light fills, white on dark ones.
    static func contrast(_ c: RGBA?) -> RGBA {
        guard let c else { return .white }
        return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b > 0.5 ? RGBA(0.08, 0.08, 0.08) : .white
    }
}

// MARK: - Draw a custom outline on the canvas

/// Custom shape outline (ST-008 "Click to start drawing"): click points on the player, click the first point (or
/// double-click) to close. The sticker's square is refitted around the outline (position + uniform scale), so the
/// shape stays exactly where it was drawn.
nonisolated enum ShapeDrawing {
    /// Margin kept inside the sticker square so strokes aren't clipped.
    static let margin = 0.08

    /// Unit-square outline points + the sticker transform change for points clicked at canvas pixels `pts` over the
    /// sticker layer `g` (current position / scale). nil with fewer than 3 points.
    static func fit(_ pts: [Vec2], layer g: LayerGeometry, position: Vec2, scale: Vec2, canvas: Size2)
        -> (points: [Vec2], position: Vec2, scale: Vec2)? {
        guard pts.count >= 3 else { return nil }
        let side = Vec2(max(abs(g.halfSize.x) * 2, 1), max(abs(g.halfSize.y) * 2, 1))
        // sticker-square units, centred (−0.5…0.5 = the current square)
        let u = pts.map { p -> Vec2 in let l = MaskFrame.rotate(p - g.center, -g.rotation); return Vec2(l.x / side.x, l.y / side.y) }
        let x0 = u.map(\.x).min()!, x1 = u.map(\.x).max()!, y0 = u.map(\.y).min()!, y1 = u.map(\.y).max()!
        let c = Vec2((x0 + x1) / 2, (y0 + y1) / 2)
        let extent = max(x1 - x0, y1 - y0, 0.02) / (1 - 2 * margin)
        let points = u.map { Vec2(($0.x - c.x) / extent + 0.5, ($0.y - c.y) / extent + 0.5) }
        let shift = MaskFrame.rotate(Vec2(c.x * side.x, c.y * side.y), g.rotation)
        let newPos = Vec2(position.x + shift.x / max(canvas.width, 1), position.y + shift.y / max(canvas.height, 1))
        return (points, newPos, Vec2(scale.x * extent, scale.y * extent))
    }
}

@Perceptible
@MainActor
final class ShapeDrawTool: CanvasTool {
    private(set) var revision = 0
    @PerceptionIgnored let clipID: ClipID
    @PerceptionIgnored weak var store: EditorStore?
    private(set) var points: [Vec2] = []
    private(set) var hover: Vec2?
    @PerceptionIgnored private var viewScale = 1.0

    init(clipID: ClipID, store: EditorStore) { self.clipID = clipID; self.store = store }

    func closes(at p: Vec2) -> Bool {
        guard points.count >= 3 else { return false }
        return (points[0] - p).length * viewScale <= PenMaskTool.closeRadius || (points[points.count - 1] - p).length * viewScale <= 3
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

    func finish() {
        guard let store else { return }
        defer { store.endShapeDraw() }
        let canvas = store.project.settings.canvasSize
        guard let c = store.project.timeline.clip(clipID),
              let l = MotionTracking.layer(of: clipID, in: store.project, at: store.transport.playhead) else { return }
        let local = Bind.local(store, c)
        let pos = c.value(.position, at: local)?.vec2 ?? c.transform.position
        let sc = c.value(.scale, at: local)?.vec2 ?? c.transform.scale
        guard let r = ShapeDrawing.fit(points, layer: l.geometry(canvasSize: canvas), position: pos, scale: sc, canvas: canvas) else { return }
        store.performInspector(UpdateClip(clipID, nameKey: "cmd.shapeStyle") { c in
            if c.shapeStyle == nil { c.shapeStyle = ShapeStyleSection.style(c) }
            c.shapeStyle?.points = r.points
            c.shapeStyle?.cornerRadius = nil
            c.setValue(.position, .vec2(r.position), at: local)
            c.setValue(.scale, .vec2(r.scale), at: local)
        })
    }

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
            ctx.strokeLineSegments(between: [last, closes(at: h) ? v[0] : toView(h)])
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
    func beginShapeDraw(_ clipID: ClipID) {
        endShapeDraw(); endPenMask()
        playerUI.canvasTool = ShapeDrawTool(clipID: clipID, store: self)
        engine.pause()
        showToast(tr("shape.draw.hint"))
    }
    func endShapeDraw() { if playerUI.canvasTool is ShapeDrawTool { playerUI.canvasTool = nil } }
    var shapeDrawTool: ShapeDrawTool? { playerUI.canvasTool as? ShapeDrawTool }
}
