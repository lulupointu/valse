import Foundation
import CoreGraphics
import MontageCore

// On-canvas mask editing (UX.md §5.1 Mask, screenshot 28): pure geometry (no AppKit), unit-tested in CanvasMathTests.
// The mask lives in layer-normalized coordinates (`Mask`: centre offset and size in units of the layer's width/height,
// rotation in degrees clockwise, relative to the layer); the shader (CoreShaders `maskAlpha`) uses the same mapping.

/// What a mouse-down on the mask overlay grabbed.
nonisolated enum MaskHandle: Equatable {
    /// Inside the mask (or on the line of a linear mask): move.
    case body
    /// Corner 0 TL, 1 TR, 2 BL, 3 BR (mask frame): resize both sides around the centre.
    case corner(Int)
    /// Edge 0 top, 1 right, 2 bottom, 3 left: resize one dimension around the centre.
    case edge(Int)
    /// Floating round buttons: rotate (below), feather (above, drag up/down), round corners (top-left, rectangle only).
    case rotate, feather, roundness
    /// Pen mask outline point `i` (`Mask.points`): drag to reshape.
    case point(Int)
}

/// The mask's frame in canvas pixels for one layer.
nonisolated struct MaskFrame: Equatable {
    let shape: MaskShape
    /// Mask centre in canvas pixels.
    let center: Vec2
    /// Half extents in the mask's own frame (canvas pixels). Linear masks: (reach, 0); mirror: (reach, band / 2).
    let half: Vec2
    /// Total rotation (layer + mask), radians clockwise.
    let rotation: Double
    /// Layer size (canvas pixels) and rotation (radians), to convert edits back into layer units.
    let layerSize: Vec2
    let layerCenter: Vec2
    let layerRotation: Double
    /// Pen mask outline points in mask-box units (−0.5…0.5, y down); nil for other shapes.
    let points: [Vec2]?

    /// View-point offsets of the floating buttons from the box.
    static let buttonOffset: Double = 26
    static let buttonRadius: Double = 11
    static let cornerRadius: Double = 4
    static let slop: Double = 5

    init(layer g: LayerGeometry, mask m: Mask) {
        shape = m.shape
        let w = abs(g.halfSize.x) * 2, h = abs(g.halfSize.y) * 2
        layerSize = Vec2(w, h)
        layerCenter = g.center
        layerRotation = g.rotation
        let off = Self.rotate(Vec2(m.center.x * w, m.center.y * h), g.rotation)
        center = g.center + off
        rotation = g.rotation + m.rotation * .pi / 180
        points = m.shape == .pen ? (m.points ?? Mask.defaultPenPoints) : nil
        let reach = (w * w + h * h).squareRoot() / 2
        switch m.shape {
        case .linear: half = Vec2(reach, 0)
        case .mirror: half = Vec2(reach, abs(m.size.y) * h / 2)
        default: half = Vec2(abs(m.size.x) * w / 2, abs(m.size.y) * h / 2)
        }
    }

    static func rotate(_ v: Vec2, _ a: Double) -> Vec2 {
        let c = cos(a), s = sin(a)
        return Vec2(v.x * c - v.y * s, v.x * s + v.y * c)
    }

    /// Mask-frame point (centre-relative, unrotated) → canvas pixels.
    func toCanvas(_ local: Vec2) -> Vec2 { center + Self.rotate(local, rotation) }
    /// Canvas pixels → mask frame.
    func toLocal(_ p: Vec2) -> Vec2 { Self.rotate(p - center, -rotation) }

    var hasBox: Bool { shape != .linear && shape != .mirror }
    var hasRoundness: Bool { shape == .rectangle }

    /// Mask-box point (−0.5…0.5 units) → mask frame (centre-relative canvas pixels, unrotated).
    func boxToLocal(_ b: Vec2) -> Vec2 { Vec2(b.x * 2 * half.x, b.y * 2 * half.y) }
    /// Pen outline points in canvas pixels.
    var pointPositions: [Vec2] { (points ?? []).map { toCanvas(boxToLocal($0)) } }

    /// Corners TL, TR, BL, BR in canvas pixels.
    var corners: [Vec2] { [Vec2(-half.x, -half.y), Vec2(half.x, -half.y), Vec2(-half.x, half.y), Vec2(half.x, half.y)].map(toCanvas) }

    /// Edge midpoints top, right, bottom, left (only those that resize this shape).
    func edges() -> [(Int, Vec2)] {
        let all = [(0, Vec2(0, -half.y)), (1, Vec2(half.x, 0)), (2, Vec2(0, half.y)), (3, Vec2(-half.x, 0))]
        switch shape {
        case .linear, .pen: return []  // pen: its outline points sit on the box edges
        case .mirror: return all.filter { $0.0 == 0 || $0.0 == 2 }.map { ($0.0, toCanvas($0.1)) }
        default: return all.map { ($0.0, toCanvas($0.1)) }
        }
    }

    /// Floating button centres in canvas pixels.
    func rotateButton(viewScale vs: Double) -> Vec2 { toCanvas(Vec2(0, half.y + Self.buttonOffset / vs)) }
    func featherButton(viewScale vs: Double) -> Vec2 { toCanvas(Vec2(0, -half.y - Self.buttonOffset / vs)) }
    func roundnessButton(viewScale vs: Double) -> Vec2 {
        toCanvas(Vec2(-half.x - Self.buttonOffset * 0.75 / vs, -half.y - Self.buttonOffset * 0.75 / vs))
    }

    func hit(_ p: Vec2, viewScale vs: Double) -> MaskHandle? {
        func near(_ q: Vec2, _ r: Double) -> Bool { (p - q).length * vs <= r + Self.slop }
        if near(rotateButton(viewScale: vs), Self.buttonRadius) { return .rotate }
        if near(featherButton(viewScale: vs), Self.buttonRadius) { return .feather }
        if hasRoundness, near(roundnessButton(viewScale: vs), Self.buttonRadius) { return .roundness }
        for (i, q) in pointPositions.enumerated() where near(q, Self.cornerRadius + 1) { return .point(i) }
        if hasBox { for (i, c) in corners.enumerated() where near(c, Self.cornerRadius) { return .corner(i) } }
        for (i, e) in edges() where near(e, Self.cornerRadius + 1) { return .edge(i) }
        let l = toLocal(p)
        switch shape {
        case .linear: if abs(l.y) * vs <= 10, abs(l.x) <= half.x { return .body }
        case .mirror: if abs(l.y) <= half.y + 6 / vs, abs(l.x) <= half.x { return .body }
        default: if abs(l.x) <= half.x, abs(l.y) <= half.y { return .body }
        }
        return nil
    }

    // MARK: Edits (return new Mask values in layer units)

    /// New mask centre (layer units) after moving the mask by `delta` canvas pixels from `start` centre.
    func movedCenter(_ base: Vec2, by delta: Vec2) -> Vec2 {
        let d = Self.rotate(delta, -layerRotation)
        return Vec2(base.x + d.x / max(layerSize.x, 1), base.y + d.y / max(layerSize.y, 1))
    }

    /// New size (layer units) when a corner / edge handle is dragged to canvas point `p` (symmetric around the centre).
    /// `keepAspect` (aspect-lock chain or ⇧) keeps the width:height ratio of `base` on corner drags.
    func resized(_ base: Vec2, handle: MaskHandle, to p: Vec2, keepAspect: Bool) -> Vec2 {
        let l = toLocal(p)
        let w = max(2 * abs(l.x) / max(layerSize.x, 1), 0.01), h = max(2 * abs(l.y) / max(layerSize.y, 1), 0.01)
        switch handle {
        case .corner:
            guard keepAspect, base.x > 1e-6, base.y > 1e-6 else { return Vec2(w, h) }
            let k = max(w / base.x, h / base.y)
            return Vec2(base.x * k, base.y * k)
        case .edge(let i): return i == 0 || i == 2 ? Vec2(base.x, h) : Vec2(w, base.y)
        default: return base
        }
    }

    /// Pen outline after dragging point `i` to canvas point `p` (mask-box units, kept within twice the box).
    func movedPoint(_ base: [Vec2], index i: Int, to p: Vec2) -> [Vec2] {
        guard base.indices.contains(i) else { return base }
        let l = toLocal(p)
        var out = base
        out[i] = Vec2(min(max(l.x / max(2 * half.x, 1e-6), -1), 1), min(max(l.y / max(2 * half.y, 1e-6), -1), 1))
        return out
    }

    /// New mask rotation (degrees) when the rotate button is dragged from `start` to `p` (canvas px); snaps to 0/90/180/270.
    func rotated(_ base: Double, start: Vec2, current p: Vec2, snapping: Bool) -> Double {
        let a0 = atan2(start.y - center.y, start.x - center.x), a1 = atan2(p.y - center.y, p.x - center.x)
        var r = base + (a1 - a0) * 180 / .pi
        r = (r + 180).truncatingRemainder(dividingBy: 360)
        if r < 0 { r += 360 }
        r -= 180
        if snapping {
            for t in [-180.0, -90, 0, 90, 180] where abs(r - t) < 3 { r = t }
        }
        return r
    }

    /// Feather / roundness from a vertical drag of `dy` view points (up = more), 0…1.
    static func dragged(_ base: Double, dy: Double) -> Double { min(max(base - dy / 150, 0), 1) }
}
