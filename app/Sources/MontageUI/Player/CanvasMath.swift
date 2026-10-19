import Foundation
import CoreGraphics
import MontageCore
import MontageEngine

// Pure geometry for the player canvas (no AppKit): viewport mapping, layer hit-testing, handle hit-testing, snapping and
// transform drags. Everything is in canvas pixels (origin top-left, y down) unless named `view…` (points, y down).
// Unit-tested in MontageUITests/CanvasMathTests.

/// Maps canvas pixels ↔ player view points. Zoom 1 = the frame fits the view with `padding` around it.
nonisolated struct PlayerViewport: Equatable {
    var viewSize: CGSize
    var canvas: Size2
    var zoom: Double = 1
    /// Offset of the frame centre from the view centre, in points (pan while zoomed).
    var pan: CGPoint = .zero
    var padding: CGFloat = 16

    static let zoomRange: ClosedRange<Double> = 0.1...8

    var fitScale: Double {
        let w = max(Double(viewSize.width - 2 * padding), 1), h = max(Double(viewSize.height - 2 * padding), 1)
        return min(w / max(canvas.width, 1), h / max(canvas.height, 1))
    }
    /// View points per canvas pixel.
    var scale: Double { fitScale * zoom }

    /// The frame's rectangle in view points.
    var contentRect: CGRect {
        let w = canvas.width * scale, h = canvas.height * scale
        return CGRect(x: Double(viewSize.width) / 2 + Double(pan.x) - w / 2, y: Double(viewSize.height) / 2 + Double(pan.y) - h / 2,
                      width: w, height: h)
    }

    func toView(_ p: Vec2) -> CGPoint {
        let r = contentRect
        return CGPoint(x: Double(r.minX) + p.x * scale, y: Double(r.minY) + p.y * scale)
    }

    func toCanvas(_ p: CGPoint) -> Vec2 {
        let r = contentRect
        return Vec2((Double(p.x) - Double(r.minX)) / scale, (Double(p.y) - Double(r.minY)) / scale)
    }

    /// Keeps at least a quarter of the frame inside the view.
    func clampedPan(_ p: CGPoint) -> CGPoint {
        let w = canvas.width * scale, h = canvas.height * scale
        let mx = max(0, (w + Double(viewSize.width)) / 2 - w / 4), my = max(0, (h + Double(viewSize.height)) / 2 - h / 4)
        return CGPoint(x: min(max(Double(p.x), -mx), mx), y: min(max(Double(p.y), -my), my))
    }
}

/// A visual layer as the canvas sees it (geometry already resolved for the playhead).
nonisolated struct CanvasLayer: Equatable {
    var clipID: ClipID
    var geometry: LayerGeometry
    var isText: Bool
    var isLocked: Bool

    /// Axis-aligned bounds of the rotated layer.
    var bounds: (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        let c = geometry.corners
        return (c.map(\.x).min()!, c.map(\.y).min()!, c.map(\.x).max()!, c.map(\.y).max()!)
    }
}

/// Builds the canvas layers at a time (bottom → top) from the frame evaluator, sizing text/stickers like the renderer.
nonisolated enum CanvasLayers {
    static func at(_ t: Time, project: Project) -> [CanvasLayer] {
        let frame = FrameEvaluator.evaluate(project, at: t)
        let canvas = project.settings.canvasSize
        var locked: Set<TrackID> = []
        for tr in project.timeline.tracks where tr.isLocked { locked.insert(tr.id) }
        var out: [CanvasLayer] = []
        func add(_ l: LayerDescription) {
            guard !l.isCanvasBackground else { return }
            var size: Size2?
            var isText = false
            switch l.source {
            case .text(let t): size = TextMetrics.size(of: t, canvasHeight: canvas.height, canvasWidth: canvas.width); isText = true
            case .sticker(let id): size = TextMetrics.stickerSize(id, side: l.sourceSize.height)
            default: break
            }
            out.append(CanvasLayer(clipID: l.clipID, geometry: l.geometry(canvasSize: canvas, sourceSizeOverride: size),
                                   isText: isText, isLocked: locked.contains(l.trackID)))
        }
        func walk(_ items: [RenderItem]) {
            for item in items {
                switch item {
                case .layer(let l): add(l)
                case .transition(_, let to, _, _, _): add(to)
                case .adjustment: break
                case .nested(let container, let inner):
                    // FX-004 "Apply to ▸ PiP" groups the overlays it processes: their layers stay selectable
                    if container.isEffectGroup { walk(inner) } else { add(container) }   // compound clip: one layer
                }
            }
        }
        walk(frame.items)
        return out
    }

    /// Topmost unlocked layer containing `p`.
    static func hit(_ layers: [CanvasLayer], at p: Vec2) -> CanvasLayer? {
        layers.last { !$0.isLocked && $0.geometry.contains(p) }
    }
}

/// What a mouse-down on the selection box grabbed.
nonisolated enum CanvasHandle: Equatable {
    case corner(Int)   // 0 TL, 1 TR, 2 BL, 3 BR
    case rotate
    case delete
    /// Text box edge pill (1 right, 3 left): changes the wrap width (`TextContent.boxWidth`, W2-7).
    case edge(Int)
    case body
}

nonisolated enum CanvasHandles {
    /// Distance of the rotate button's centre below the box (view points), UX.md §4.2.
    static let rotateOffset: Double = 24
    static let cornerRadius: Double = 4
    static let rotateRadius: Double = 10
    static let deleteRadius: Double = 8
    /// Hit slop around handles (points).
    static let slop: Double = 5

    /// Rotate button centre in canvas pixels (below the box in the layer's own frame, so it turns with the layer).
    static func rotatePosition(_ g: LayerGeometry, viewScale: Double) -> Vec2 {
        let d = abs(g.halfSize.y) + rotateOffset / viewScale
        return Vec2(g.center.x - sin(g.rotation) * d, g.center.y + cos(g.rotation) * d)
    }

    static func hit(_ g: LayerGeometry, isText: Bool, at p: Vec2, viewScale: Double) -> CanvasHandle? {
        func near(_ q: Vec2, _ r: Double) -> Bool { (p - q).length * viewScale <= r + slop }
        if near(rotatePosition(g, viewScale: viewScale), rotateRadius) { return .rotate }
        let corners = g.corners
        if isText, near(corners[0], deleteRadius) { return .delete }
        for (i, c) in corners.enumerated() where near(c, cornerRadius) { return .corner(i) }
        if isText { for (i, e) in edgePills(g) where near(e, cornerRadius + 1) { return .edge(i) } }
        if g.contains(p) { return .body }
        return nil
    }

    /// Left / right edge midpoints of a text box (canvas pixels).
    static func edgePills(_ g: LayerGeometry) -> [(Int, Vec2)] {
        let d = Vec2(cos(g.rotation) * abs(g.halfSize.x), sin(g.rotation) * abs(g.halfSize.x))
        return [(1, g.center + d), (3, g.center - d)]
    }

    /// Text wrap width (fraction of the canvas width) when an edge pill is dragged to `p`: the box stays centred, so its
    /// width is twice the distance from the centre along the box's own x axis, in unscaled text pixels.
    static func textBoxWidth(_ g: LayerGeometry, dragTo p: Vec2, layerScale: Double, canvasWidth: Double) -> Double {
        let d = p - g.center
        let lx = abs(d.x * cos(g.rotation) + d.y * sin(g.rotation))
        return min(max(2 * lx / max(abs(layerScale), 0.01) / max(canvasWidth, 1), 0.03), 4)
    }

    /// TX-011 (F3): dragging edge pill `edge` (1 right, 3 left). Default = one-side resize (the opposite edge stays put, so
    /// the box centre moves by half the change); ⌥ = resize from the centre (CapCut "Resize the text box from the center").
    /// Returns the new `boxWidth` (fraction of the canvas width) and the centre shift in canvas px.
    static func textBoxResize(_ g: LayerGeometry, edge: Int, dragTo p: Vec2, fromCenter: Bool, layerScale: Double,
                              canvasWidth: Double) -> (width: Double, shift: Vec2) {
        if fromCenter { return (textBoxWidth(g, dragTo: p, layerScale: layerScale, canvasWidth: canvasWidth), .zero) }
        let axis = Vec2(cos(g.rotation), sin(g.rotation))
        let side: Double = edge == 3 ? -1 : 1
        let fixed = g.center - axis * (side * abs(g.halfSize.x))         // the edge that stays
        let d = p - fixed
        let reach = max(side * (d.x * axis.x + d.y * axis.y), 0)        // drag distance along the box, outward
        let scale = max(abs(layerScale), 0.01)
        let width = min(max(reach / scale / max(canvasWidth, 1), 0.03), 4)
        let newHalf = width * max(canvasWidth, 1) * scale / 2
        let newCenter = fixed + axis * (side * newHalf)
        return (width, newCenter - g.center)
    }
}

/// A snap line drawn across the whole canvas (canvas pixels).
nonisolated enum SnapLine: Hashable {
    case vertical(Double)
    case horizontal(Double)
}

nonisolated struct CanvasSnapper {
    /// Candidate x / y positions (canvas px): canvas edges & centre, other layers' edges & centres, guides.
    var targetsX: [Double]
    var targetsY: [Double]
    /// Snap distance in canvas pixels (6 pt in view space, UX.md §4.2).
    var threshold: Double

    init(canvas: Size2, others: [CanvasLayer], guidesX: [Double] = [], guidesY: [Double] = [], threshold: Double) {
        var xs = [0, canvas.width / 2, canvas.width], ys = [0, canvas.height / 2, canvas.height]
        for l in others {
            let b = l.bounds
            xs += [b.minX, (b.minX + b.maxX) / 2, b.maxX]
            ys += [b.minY, (b.minY + b.maxY) / 2, b.maxY]
        }
        targetsX = xs + guidesX; targetsY = ys + guidesY
        self.threshold = threshold
    }

    /// Best correction for features (e.g. left / centre / right of the moving box) against targets on one axis.
    static func snap(_ features: [Double], to targets: [Double], threshold: Double) -> (delta: Double, at: Double)? {
        var best: (Double, Double)?
        for f in features {
            for t in targets {
                let d = t - f
                if abs(d) <= threshold, best == nil || abs(d) < abs(best!.0) { best = (d, t) }
            }
        }
        return best.map { (delta: $0.0, at: $0.1) }
    }

    /// Snaps a moving box (axis-aligned bounds after the raw move). Returns the correction and the lines to draw.
    func snapMove(minX: Double, maxX: Double, minY: Double, maxY: Double) -> (delta: Vec2, lines: [SnapLine]) {
        var delta = Vec2.zero
        var lines: [SnapLine] = []
        if let s = Self.snap([minX, (minX + maxX) / 2, maxX], to: targetsX, threshold: threshold) {
            delta.x = s.delta; lines.append(.vertical(s.at))
        }
        if let s = Self.snap([minY, (minY + maxY) / 2, maxY], to: targetsY, threshold: threshold) {
            delta.y = s.delta; lines.append(.horizontal(s.at))
        }
        return (delta, lines)
    }
}

/// Transform drags (move / corner scale / rotate) computed from the gesture's starting state, so repeated updates are
/// idempotent (they feed `EditorStore.updateGesture`).
nonisolated enum CanvasDrag {
    /// Rotation snaps to multiples of 90° within this many degrees.
    static let rotationSnap: Double = 3

    /// New normalized position after moving by `delta` canvas pixels.
    static func moved(_ position: Vec2, by delta: Vec2, canvas: Size2) -> Vec2 {
        Vec2(position.x + delta.x / max(canvas.width, 1), position.y + delta.y / max(canvas.height, 1))
    }

    /// ⇧ while moving: keep only the dominant axis.
    static func constrained(_ d: Vec2) -> Vec2 { abs(d.x) >= abs(d.y) ? Vec2(d.x, 0) : Vec2(0, d.y) }

    /// Uniform scale around the centre: ratio of the pointer's distance to the centre now vs at mouse-down.
    static func scaled(_ scale: Vec2, center: Vec2, start: Vec2, current: Vec2) -> Vec2 {
        let d0 = max((start - center).length, 1e-6)
        let k = max((current - center).length / d0, 0.001)
        return Vec2(max(scale.x * k, 0.01), max(scale.y * k, 0.01))
    }

    /// Rotation (degrees, clockwise) after dragging the rotate handle from `start` to `current` around `center`.
    /// Snaps to 0/90/180/270 unless `snapping` is false.
    static func rotated(_ rotation: Double, center: Vec2, start: Vec2, current: Vec2, snapping: Bool) -> Double {
        let a0 = atan2(start.y - center.y, start.x - center.x), a1 = atan2(current.y - center.y, current.x - center.x)
        var delta = (a1 - a0) * 180 / .pi
        if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
        var r = rotation + delta
        if snapping {
            let nearest = (r / 90).rounded() * 90
            if abs(r - nearest) <= rotationSnap { r = nearest }
        }
        return r
    }

    /// Angle label shown while rotating (normalized to (-180, 180]).
    static func displayAngle(_ r: Double) -> Double {
        var a = r.truncatingRemainder(dividingBy: 360)
        if a > 180 { a -= 360 } else if a <= -180 { a += 360 }
        return a
    }
}

/// Canvas alignment (context menu): moves a layer so its bounds touch the canvas edge / centre.
nonisolated enum CanvasAlign: String, CaseIterable {
    case left, centerH, right, top, centerV, bottom

    var titleKey: String { "player.align.\(rawValue)" }

    /// Position correction (canvas px) for a layer with axis-aligned bounds `b`.
    func delta(bounds b: (minX: Double, minY: Double, maxX: Double, maxY: Double), canvas: Size2) -> Vec2 {
        switch self {
        case .left: return Vec2(-b.minX, 0)
        case .right: return Vec2(canvas.width - b.maxX, 0)
        case .centerH: return Vec2(canvas.width / 2 - (b.minX + b.maxX) / 2, 0)
        case .top: return Vec2(0, -b.minY)
        case .bottom: return Vec2(0, canvas.height - b.maxY)
        case .centerV: return Vec2(0, canvas.height / 2 - (b.minY + b.maxY) / 2)
        }
    }
}

extension LayerGeometry {
    /// Uniform scale that turns an aspect-fit layer (scale 1) into an aspect-fill one.
    nonisolated static func fillScale(sourceSize: Size2, canvasSize: Size2, crop: CropRect = CropRect()) -> Double {
        let sw = max(sourceSize.width * (1 - crop.left - crop.right), 1), sh = max(sourceSize.height * (1 - crop.top - crop.bottom), 1)
        let fit = min(canvasSize.width / sw, canvasSize.height / sh)
        let fill = max(canvasSize.width / sw, canvasSize.height / sh)
        return fill / max(fit, 1e-9)
    }
}

/// CV-010: Fit / Fill / Stretch a media layer to the canvas.
nonisolated enum CanvasFit: String, CaseIterable {
    case fit, fill, stretch
    var titleKey: String { "player.fit.\(rawValue)" }

    func scale(sourceSize: Size2, canvas: Size2, crop: CropRect) -> Vec2 {
        switch self {
        case .fit: return .one
        case .fill:
            let k = LayerGeometry.fillScale(sourceSize: sourceSize, canvasSize: canvas, crop: crop)
            return Vec2(k, k)
        case .stretch:
            let sw = max(sourceSize.width * (1 - crop.left - crop.right), 1), sh = max(sourceSize.height * (1 - crop.top - crop.bottom), 1)
            let fit = min(canvas.width / sw, canvas.height / sh)
            return Vec2(canvas.width / (sw * fit), canvas.height / (sh * fit))
        }
    }
}

/// Social-media safe zones (PB-010): generic UI mock-ups, no brand assets. Rectangles in normalized canvas units.
public nonisolated enum SafeZone: String, CaseIterable {
    case none, tiktok, reels, shorts, broadcast
    var titleKey: String { "player.safe.\(rawValue)" }

    /// Areas covered by the platform UI (drawn shaded) — normalized (x, y, w, h).
    var covered: [CGRect] {
        switch self {
        case .none: return []
        case .tiktok: return [CGRect(x: 0, y: 0, width: 1, height: 0.07), CGRect(x: 0.86, y: 0.42, width: 0.14, height: 0.42),
                              CGRect(x: 0, y: 0.82, width: 1, height: 0.18)]
        case .reels: return [CGRect(x: 0, y: 0, width: 1, height: 0.08), CGRect(x: 0.87, y: 0.5, width: 0.13, height: 0.36),
                             CGRect(x: 0, y: 0.84, width: 1, height: 0.16)]
        case .shorts: return [CGRect(x: 0, y: 0, width: 1, height: 0.06), CGRect(x: 0.86, y: 0.45, width: 0.14, height: 0.4),
                              CGRect(x: 0, y: 0.85, width: 1, height: 0.15)]
        case .broadcast: return []
        }
    }

    /// Recommended safe rectangle (dashed outline).
    var safeRect: CGRect? {
        switch self {
        case .none: return nil
        case .tiktok: return CGRect(x: 0.06, y: 0.08, width: 0.78, height: 0.73)
        case .reels: return CGRect(x: 0.06, y: 0.09, width: 0.8, height: 0.74)
        case .shorts: return CGRect(x: 0.06, y: 0.07, width: 0.78, height: 0.77)
        case .broadcast: return CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)  // action safe; title safe drawn inside
        }
    }
}

/// Player ruler tick spacing (canvas px) so labels stay ≥ ~50 pt apart.
nonisolated enum RulerTicks {
    static func step(viewScale: Double) -> Double {
        for s in [10.0, 20, 50, 100, 200, 250, 500, 1000, 2000] where s * viewScale >= 50 { return s }
        return 5000
    }
}
