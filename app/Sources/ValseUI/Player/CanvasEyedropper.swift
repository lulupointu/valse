import AppKit
import Perception
import ValseCore
import ValseEngine

/// Canvas eyedropper (UX.md §5.1 Chroma key, screenshot 125): a loupe ring follows the mouse over the video and a click
/// samples the frame — only the video, never the rest of the screen (W2-8, replaces the system `NSColorSampler`).
/// The frame is rendered once when the tool starts, with the effect being edited switched off (picking the key colour
/// of an already keyed clip samples the original pixels, not the transparent hole).
@Perceptible
@MainActor
final class CanvasEyedropperTool: CanvasTool {
    private(set) var revision = 0
    @PerceptionIgnored private var pixels: [UInt8] = []
    @PerceptionIgnored private var size = (w: 0, h: 0)
    @PerceptionIgnored let canvas: Size2
    @PerceptionIgnored private let onPick: (RGBA) -> Void
    private(set) var hover: Vec2?

    init(canvas: Size2, onPick: @escaping (RGBA) -> Void) {
        self.canvas = canvas
        self.onPick = onPick
    }

    var isReady: Bool { !pixels.isEmpty }

    func setFrame(_ img: CGImage) {
        let w = img.width, h = img.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info) else { return }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        pixels = buf
        size = (w, h)
        revision += 1
    }

    /// Colour of the frame at a canvas point (nil outside the frame or before the render is ready).
    func color(at p: Vec2) -> RGBA? {
        guard isReady, p.x >= 0, p.y >= 0, p.x < canvas.width, p.y < canvas.height else { return nil }
        let x = min(Int(p.x / canvas.width * Double(size.w)), size.w - 1), y = min(Int(p.y / canvas.height * Double(size.h)), size.h - 1)
        let i = (y * size.w + x) * 4
        return RGBA(Double(pixels[i]) / 255, Double(pixels[i + 1]) / 255, Double(pixels[i + 2]) / 255, 1)
    }

    func hover(at p: Vec2?) { hover = p; revision += 1 }

    func mouseDown(at p: Vec2) {
        guard let c = color(at: p) else { return }
        onPick(c)
    }
    func mouseDragged(at p: Vec2) { hover(at: p) }
    func mouseUp(at p: Vec2) {}

    /// Loupe: a ring filled with the colour under the cursor, a thin white/black outline and a centre dot.
    func draw(in ctx: CGContext, toView: (Vec2) -> CGPoint, scale: Double) {
        guard let h = hover, let c = color(at: h) else { return }
        let v = toView(h)
        let r: CGFloat = 22
        let ring = CGRect(x: v.x - r, y: v.y - r, width: 2 * r, height: 2 * r)
        ctx.saveGState()
        ctx.resetClip()
        ctx.setShadow(offset: .zero, blur: 4, color: NSColor.black.withAlphaComponent(0.5).cgColor)
        ctx.setStrokeColor(NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1).cgColor)
        ctx.setLineWidth(9)
        ctx.strokeEllipse(in: ring.insetBy(dx: 4.5, dy: 4.5))
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: ring)
        ctx.strokeEllipse(in: ring.insetBy(dx: 9, dy: 9))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: v.x - 1.5, y: v.y - 1.5, width: 3, height: 3))
        ctx.restoreGState()
    }
}

extension EditorStore {
    var canvasEyedropper: CanvasEyedropperTool? { playerUI.canvasTool as? CanvasEyedropperTool }

    /// Starts the canvas eyedropper: the next click on the video picks a colour (`onPick`), Esc cancels.
    /// `disabling` switches that effect of `clip` off in the sampled frame (e.g. the chroma key being edited).
    public func pickCanvasColor(disabling effect: EffectInstanceID? = nil, in clip: ClipID? = nil, _ onPick: @escaping (RGBA) -> Void) {
        exitPreview()
        var p = project
        if let effect, let clip, var c = p.timeline.clip(clip), let i = c.effects.firstIndex(where: { $0.id == effect }) {
            c.effects[i].isEnabled = false
            p.timeline[clip: clip] = c
        }
        let tool = CanvasEyedropperTool(canvas: p.settings.canvasSize) { [weak self] color in
            self?.endCanvasColorPick()
            onPick(color)
        }
        playerUI.canvasTool = tool
        showToast(tr("player.eyedropper.hint"))
        let t = transport.playhead
        let frozen = p
        Task {
            let img = try? await Task.detached { try await StillFrameExporter.image(project: frozen, at: t, shortSide: 720) }.value
            if let img, self.playerUI.canvasTool === tool { tool.setFrame(img) }
        }
    }

    public func endCanvasColorPick() {
        if canvasEyedropper != nil { playerUI.canvasTool = nil }
    }
}
