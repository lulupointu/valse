import AppKit
@preconcurrency import Metal
import QuartzCore
import CoreVideo
import MontageCore
import MontageEngine

/// Preview surface: CAMetalLayer driven by the display link. Each refresh it pulls the frame for that vsync from the
/// playback engine (AVPlayer clock → A/V sync) and presents it zero-copy; when paused and the project changed without a
/// composition rebuild, it re-renders the current frame from the last decoded sources (instant feedback while dragging
/// sliders). Keeps the last frame for offscreen snapshots (`snapshot()`), so screenshots don't need screen capture.
final class PlayerView: NSView {
    let engine: PlaybackEngine
    var letterbox: RGBA = RGBA(hex: 0x1B1B1C)
    private let ctx = MetalContext.shared
    private var link: CADisplayLink?
    private var fallbackTimer: Timer?
    private var needsRerender = true
    private var lastFrame: MTLTexture?
    private var lastPixelBuffer: CVPixelBuffer?
    private var rerenderTarget: MTLTexture?
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    /// Presented frames (stats / tests).
    private(set) var presentedFrames = 0

    init(engine: PlaybackEngine) {
        self.engine = engine
        super.init(frame: .zero)
        wantsLayer = true
        metalLayer.device = ctx.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.maximumDrawableCount = 3
        metalLayer.isOpaque = true
        engine.onRedrawNeeded = { [weak self] in self?.needsRerender = true }
        engine.onItemReplaced = { [weak self] in self?.needsRerender = true }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func makeBackingLayer() -> CALayer { CAMetalLayer() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate(); link = nil
        guard window != nil else { return }
        let l = displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        needsRerender = true
        fallbackTimer?.invalidate()
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let w = self.window, !w.occlusionState.contains(.visible) else { return }
                self.fallbackTick()
            }
        }
    }

    /// Occluded-window path: present new frames / re-render without a display link.
    private func fallbackTick() {
        if let (pb, _) = engine.pixelBuffer(forHostTime: CACurrentMediaTime()), let (tex, cv) = ctx.texture(pb, plane: 0, format: .bgra8Unorm) {
            lastPixelBuffer = pb
            present(tex, retain: [cv, pb])
            needsRerender = false
        } else if needsRerender && !engine.isPlaying {
            needsRerender = false
            rerender()
        }
    }

    override func layout() {
        super.layout()
        let s = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = s
        metalLayer.drawableSize = CGSize(width: max(1, bounds.width * s), height: max(1, bounds.height * s))
        needsRerender = true
    }

    func requestRedraw() { needsRerender = true }

    /// Where the frame is drawn (view points, origin top-left), set by the canvas overlay (zoom / pan / padding).
    /// nil = aspect-fit to the whole view.
    var contentRect: CGRect? {
        didSet {
            if contentRect != oldValue { needsRerender = true }  // paused: re-render at the new place next refresh
        }
    }

    private func pixelRect(scale s: CGFloat) -> CGRect? {
        contentRect.map { CGRect(x: $0.minX * s, y: $0.minY * s, width: $0.width * s, height: $0.height * s) }
    }

    @objc private func tick(_ l: CADisplayLink) {
        if let (pb, _) = engine.pixelBuffer(forHostTime: l.targetTimestamp) {
            lastPixelBuffer = pb
            if let (tex, cv) = ctx.texture(pb, plane: 0, format: .bgra8Unorm) {
                present(tex, retain: [cv, pb])
                needsRerender = false
            }
            return
        }
        if needsRerender && !engine.isPlaying {
            needsRerender = false
            rerender()
        }
    }

    /// Re-renders the playhead frame with the latest project (no decode).
    private func rerender() {
        let size = engine.renderSize
        if rerenderTarget?.width != Int(size.width) || rerenderTarget?.height != Int(size.height) {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(size.width), height: Int(size.height), mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
            rerenderTarget = ctx.device.makeTexture(descriptor: d)
        }
        guard let target = rerenderTarget, let cmd = ctx.queue.makeCommandBuffer() else { return }
        if engine.renderCurrentFrame(into: target, commandBuffer: cmd) {
            cmd.commit()
            present(target, retain: [])
        } else if let pb = lastPixelBuffer, let (tex, cv) = ctx.texture(pb, plane: 0, format: .bgra8Unorm) {
            present(tex, retain: [cv, pb])
        }
    }

    private func present(_ tex: MTLTexture, retain: [Any]) {
        lastFrame = tex
        guard let drawable = metalLayer.nextDrawable(), let cmd = ctx.queue.makeCommandBuffer() else { return }
        Presenter.encode(tex, to: drawable.texture, contentAspect: engine.project.settings.canvasSize.aspect, letterbox: letterbox,
                         contentRect: pixelRect(scale: metalLayer.contentsScale),
                         commandBuffer: cmd)
        cmd.present(drawable)
        let hold = UncheckedSendable(retain)
        cmd.addCompletedHandler { _ in _ = hold }
        cmd.commit()
        presentedFrames += 1
    }

    /// Offscreen render of what the view shows (for window snapshots / tests).
    func snapshot() -> CGImage? {
        let s = window?.backingScaleFactor ?? 2
        let w = max(1, Int(bounds.width * s)), h = max(1, Int(bounds.height * s))
        // Make sure we have a frame even if the display link never ran (window occluded / not on screen).
        if lastFrame == nil { rerender() }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
        guard let out = ctx.device.makeTexture(descriptor: d), let cmd = ctx.queue.makeCommandBuffer() else { return nil }
        if let frame = lastFrame {
            Presenter.encode(frame, to: out, contentAspect: engine.project.settings.canvasSize.aspect, letterbox: letterbox,
                             contentRect: pixelRect(scale: s), commandBuffer: cmd)
        }
        cmd.commit(); cmd.waitUntilCompleted()
        return TextureReadback.cgImage(out)
    }
}

enum TextureReadback {
    /// BGRA8 shared texture → CGImage.
    static func cgImage(_ tex: MTLTexture) -> CGImage? {
        let w = tex.width, h = tex.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: info),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
