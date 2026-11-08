import AppKit
import ValseCore

/// AU-FADE-UI: Final Cut Pro–style audio fade art, drawn with Core Graphics (anti-aliased, at the backing scale) and
/// handed to the GPU timeline canvas as cached images.
/// - Fade overlay: the region the fade takes away (between the top of the audio area and the curve) darkened over the
///   waveform, and the curve itself, from the clip's bottom corner up to the volume line, following the fade shape.
/// - Pin handle: a small teardrop sitting on the volume line at the end of the fade (normal / hover / dragged).
/// - Menu thumbnails: the curve drawn in a small dark tile, one per fade shape (`FadeShapeMenuItemView`).
enum FadeArt {
    /// Order of the fade curve menu (Final Cut Pro).
    static let menuShapes: [(shape: FadeShape, key: String)] = [
        (.linear, "fade.shape.linear"), (.sCurve, "fade.shape.sCurve"),
        (.plus3dB, "fade.shape.plus3dB"), (.minus3dB, "fade.shape.minus3dB"),
    ]

    /// Level of the fade at progress `u` (0 = left of the fade on screen, 1 = right): 0 = silent, 1 = the volume line.
    static func level(_ shape: FadeShape, fadeIn: Bool, u: Double) -> Double { shape.gain(fadeIn ? u : 1 - u) }

    /// Curve points (top-left origin) of a fade spanning `rect` horizontally, from the bottom of `rect` (silent) to
    /// `lineY` (the volume line).
    static func curve(_ shape: FadeShape, fadeIn: Bool, in rect: CGRect, lineY: CGFloat, samples n: Int) -> [CGPoint] {
        let n = max(2, n)
        return (0...n).map { i in
            let u = Double(i) / Double(n)
            return CGPoint(x: rect.minX + rect.width * CGFloat(u),
                           y: rect.maxY - (rect.maxY - lineY) * CGFloat(level(shape, fadeIn: fadeIn, u: u)))
        }
    }

    // MARK: Fade overlay

    private struct OverlayKey: Hashable { let shape: FadeShape; let fadeIn: Bool; let w: Int; let h: Int; let line: Int }
    @MainActor private static var overlays = LRU<OverlayKey, CGImage>(capacity: 48)
    /// Overlays wider than this (pixels) are stretched: very long fades at high zoom stay cheap.
    static let maxOverlayPixels = 4096

    /// Image covering the fade region (`size` points, top = top of the audio area), `lineY` = volume line from its top.
    @MainActor static func overlay(_ shape: FadeShape, fadeIn: Bool, size: CGSize, lineY: CGFloat, scale: CGFloat) -> CGImage? {
        let w = min(maxOverlayPixels, Int((size.width * scale).rounded())), h = Int((size.height * scale).rounded())
        guard w >= 1, h >= 1 else { return nil }
        let line = Int((min(max(lineY, 0), size.height) * scale).rounded())
        let key = OverlayKey(shape: shape, fadeIn: fadeIn, w: w, h: h, line: line)
        if let img = overlays[key] { return img }
        guard let ctx = bitmap(w, h) else { return nil }
        // the image is stretched to `size`: draw in pixels, keep the stroke ~1.25 pt thick
        let r = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
        let pts = curve(shape, fadeIn: fadeIn, in: r, lineY: CGFloat(line), samples: max(16, min(256, w / 2)))
        let shade = CGMutablePath()
        shade.move(to: CGPoint(x: 0, y: 0)); shade.addLine(to: CGPoint(x: r.maxX, y: 0))
        for p in pts.reversed() { shade.addLine(to: p) }
        shade.closeSubpath()
        ctx.addPath(shade)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.42))
        ctx.fillPath()
        let stroke = CGMutablePath()
        stroke.addLines(between: pts)
        ctx.addPath(stroke)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
        ctx.setLineWidth(1.25 * scale)
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.strokePath()
        guard let img = ctx.makeImage() else { return nil }
        overlays[key] = img
        return img
    }

    // MARK: Pin handle

    enum PinState: Hashable { case normal, hover, active }
    /// Teardrop: circle of `pinRadius` with its tip `pinTip` below the centre; the centre sits `pinLift` above the line.
    static let pinRadius: CGFloat = 5, pinTip: CGFloat = 9.5, pinLift: CGFloat = 2.5
    /// Room around the drawn shape for the outline and shadow.
    static let pinMargin: CGFloat = 1.5
    /// Pins never sit closer than this to the clip edge (they would cover the trim handle at fade 0).
    static let pinEdgeInset: CGFloat = 6

    /// Image rect of the pin for a fade ending at `x` on a volume line at `lineY`, kept inside `area` vertically when
    /// it has room.
    static func pinRect(x: CGFloat, lineY: CGFloat, area: CGRect) -> CGRect {
        var cy = lineY - pinLift
        cy = min(cy, area.maxY - pinTip)          // tip stays inside the audio area
        cy = max(cy, area.minY + pinRadius - 2)   // top of the circle may only peek above it
        let m = pinMargin
        return CGRect(x: x - pinRadius - m, y: cy - pinRadius - m, width: 2 * (pinRadius + m), height: pinRadius + pinTip + 2 * m)
    }

    @MainActor private static var pins: [PinKey: CGImage] = [:]
    private struct PinKey: Hashable { let state: PinState; let scale: Int }

    @MainActor static func pin(_ state: PinState, scale: CGFloat) -> CGImage? {
        let key = PinKey(state: state, scale: Int((scale * 4).rounded()))
        if let img = pins[key] { return img }
        let m = pinMargin, r = pinRadius
        let sizePt = CGSize(width: 2 * (r + m), height: r + pinTip + 2 * m)
        guard let ctx = bitmap(Int((sizePt.width * scale).rounded()), Int((sizePt.height * scale).rounded())) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        let c = CGPoint(x: r + m, y: r + m)
        let path = teardrop(center: c, radius: r, tip: pinTip)
        let accent = Theme.TL.accent
        let fill: CGColor = switch state {
        case .normal: CGColor(gray: 0.86, alpha: 1)
        case .hover: CGColor(gray: 1, alpha: 1)
        case .active: accent.cgColor
        }
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 0.5), blur: 1.5, color: CGColor(gray: 0, alpha: 0.6))
        ctx.addPath(path); ctx.setFillColor(fill); ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(path)
        ctx.setStrokeColor(state == .hover ? accent.cgColor : CGColor(gray: 0, alpha: 0.55))
        ctx.setLineWidth(state == .hover ? 1 : 0.75)
        ctx.strokePath()
        // the grip: a short vertical tick in the middle
        ctx.setStrokeColor(state == .active ? CGColor(gray: 1, alpha: 1) : CGColor(gray: 0.22, alpha: 1))
        ctx.setLineWidth(1.25); ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: c.x, y: c.y - 2.5)); ctx.addLine(to: CGPoint(x: c.x, y: c.y + 4))
        ctx.strokePath()
        guard let img = ctx.makeImage() else { return nil }
        pins[key] = img
        return img
    }

    /// Circle at `center` with a point `tip` below it (top-left origin).
    static func teardrop(center c: CGPoint, radius r: CGFloat, tip d: CGFloat) -> CGPath {
        let theta = acos(min(1, r / d))           // tangent points seen from the tip
        let a0 = CGFloat.pi / 2 + theta, a1 = CGFloat.pi / 2 - theta + 2 * .pi
        let p = CGMutablePath()
        p.move(to: CGPoint(x: c.x, y: c.y + d))
        let n = 48
        for i in 0...n {
            let a = a0 + (a1 - a0) * CGFloat(i) / CGFloat(n)
            p.addLine(to: CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a)))
        }
        p.closeSubpath()
        return p
    }

    // MARK: Menu thumbnails

    /// Draws a fade curve thumbnail in `rect` of the current (flipped or not) NSGraphicsContext: a dark tile, the
    /// level before / after the fade as a dim flat segment, the curve itself brighter.
    static func drawThumbnail(_ shape: FadeShape, fadeIn: Bool, in rect: NSRect, highlighted: Bool, dark: Bool, flipped: Bool) {
        let tile = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        NSColor(white: 0, alpha: highlighted || dark ? 0.55 : 0.75).setFill()
        tile.fill()
        let inner = rect.insetBy(dx: 0, dy: 4)
        let flat = rect.width * 0.24
        // fade-out: flat at the top then the curve down to the bottom-right; fade-in mirrored
        let curveRect = fadeIn ? NSRect(x: inner.minX, y: inner.minY, width: inner.width - flat, height: inner.height)
                               : NSRect(x: inner.minX + flat, y: inner.minY, width: inner.width - flat, height: inner.height)
        func viewY(_ topLeftY: CGFloat) -> CGFloat { flipped ? topLeftY : rect.minY + rect.maxY - topLeftY }
        let top = viewY(inner.minY)
        let flatPath = NSBezierPath()
        flatPath.move(to: NSPoint(x: fadeIn ? curveRect.maxX : inner.minX, y: top))
        flatPath.line(to: NSPoint(x: fadeIn ? inner.maxX : curveRect.minX, y: top))
        flatPath.lineWidth = 2; flatPath.lineCapStyle = .butt
        NSColor(white: 0.45, alpha: 1).setStroke()
        flatPath.stroke()
        let pts = curve(shape, fadeIn: fadeIn, in: curveRect, lineY: curveRect.minY, samples: 40)
        let path = NSBezierPath()
        for (i, p) in pts.enumerated() {
            let q = NSPoint(x: p.x, y: viewY(p.y))
            if i == 0 { path.move(to: q) } else { path.line(to: q) }
        }
        path.lineWidth = 2; path.lineCapStyle = .round; path.lineJoinStyle = .round
        (highlighted ? NSColor.controlAccentColor.blended(withFraction: 0.5, of: .white) ?? .white
                     : NSColor(white: 0.72, alpha: 1)).setStroke()
        path.stroke()
    }

    // MARK: Helpers

    /// Premultiplied sRGB bitmap with a top-left origin.
    private static func bitmap(_ w: Int, _ h: Int) -> CGContext? {
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        ctx.setAllowsAntialiasing(true); ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high
        return ctx
    }
}

/// Tiny least-recently-used cache.
struct LRU<K: Hashable, V> {
    let capacity: Int
    private var values: [K: V] = [:]
    private var order: [K] = []
    init(capacity: Int) { self.capacity = capacity }
    var count: Int { values.count }
    subscript(_ k: K) -> V? {
        get { values[k] }
        set {
            order.removeAll { $0 == k }
            values[k] = newValue
            guard newValue != nil else { return }
            order.append(k)
            if order.count > capacity { values[order.removeFirst()] = nil }
        }
    }
}

/// One row of the fade curve menu: check mark, curve thumbnail, label (Final Cut Pro). The item keeps its title,
/// state, target and action, so keyboard navigation, type-select, accessibility and the UI test driver work as usual.
final class FadeShapeMenuItemView: NSView {
    let shape: FadeShape
    let fadeIn: Bool
    static let size = NSSize(width: 168, height: 34)
    static let thumb = NSSize(width: 40, height: 26)

    init(shape: FadeShape, fadeIn: Bool) {
        self.shape = shape; self.fadeIn = fadeIn
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        autoresizingMask = [.width]
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var allowsVibrancy: Bool { false }

    /// Tests / previews: draw as highlighted without a menu tracking session.
    var highlightOverride: Bool?
    /// The item this view belongs to (set by the menu builder; `enclosingMenuItem` is used when AppKit provides it).
    weak var menuItem: NSMenuItem?
    private var item: NSMenuItem? { enclosingMenuItem ?? menuItem }
    private var highlighted: Bool { highlightOverride ?? item?.isHighlighted ?? false }

    override func draw(_ dirtyRect: NSRect) {
        guard let item else { return }
        let hl = highlighted && item.isEnabled
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if hl {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 4, yRadius: 4).fill()
        }
        let textColor: NSColor = hl ? .white : (item.isEnabled ? .labelColor : .disabledControlTextColor)
        if item.state == .on {
            let check = NSAttributedString(string: "✓", attributes: [.font: NSFont.menuFont(ofSize: 13), .foregroundColor: textColor])
            let s = check.size()
            check.draw(at: NSPoint(x: 11, y: (bounds.height - s.height) / 2))
        }
        let t = NSRect(x: 28, y: (bounds.height - Self.thumb.height) / 2, width: Self.thumb.width, height: Self.thumb.height)
        FadeArt.drawThumbnail(shape, fadeIn: fadeIn, in: t, highlighted: hl, dark: dark, flipped: true)
        let label = NSAttributedString(string: item.title, attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: textColor])
        let s = label.size()
        label.draw(at: NSPoint(x: t.maxX + 10, y: (bounds.height - s.height) / 2))
    }

    override func mouseUp(with event: NSEvent) {
        guard let item, item.isEnabled, let menu = item.menu else { return }
        menu.cancelTracking()
        if let i = menu.items.firstIndex(of: item) { menu.performActionForItem(at: i) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsDisplay = true
    }
}
