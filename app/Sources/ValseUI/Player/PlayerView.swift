import AppKit
@preconcurrency import Metal
import QuartzCore
import CoreVideo
import ValseCore
import ValseEngine

/// Preview surface: CAMetalLayer driven by the display link. Each refresh it pulls the frame for that vsync from the
/// playback engine (AVPlayer clock → A/V sync) and presents it zero-copy; when paused and the project changed without a
/// composition rebuild, it re-renders the current frame from the last decoded sources (instant feedback while dragging
/// sliders). Keeps the last frame for offscreen snapshots (`snapshot()`), so screenshots don't need screen capture.
final class PlayerView: NSView {
    let engine: PlaybackEngine
    var letterbox: RGBA = RGBA(hex: 0x1B1B1C)
    private let ctx = MetalContext.shared
    /// CADisplayLink (macOS 14+) or LegacyDisplayLink (macOS 13).
    private var link: AnyObject?
    private var fallbackTimer: Timer?
    private var needsRerender = true
    private var lastFrame: MTLTexture?
    private var lastPixelBuffer: CVPixelBuffer?
    private var rerenderTarget: MTLTexture?
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    /// Presented frames (stats / tests).
    private(set) var presentedFrames = 0
    /// Drawable colour setup for the current project colour space / screen (`configureColor`).
    private var configuredSpace: ProjectColorSpace?
    private var configuredEDR = false
    private var configuredAmbient: Data?
    private(set) var presentMode: Presenter.Mode = .passthrough
    /// Item time of each decoded frame presented by the display link (dropped-frame telemetry, PB-013).
    var onFramePresented: ((Time) -> Void)?

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
        invalidateLink()
        guard window != nil else { return }
        if #available(macOS 14, *) {
            let l = displayLink(target: self, selector: #selector(tick(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        } else {
            link = LegacyDisplayLink(screen: window?.screen) { [weak self] t in self?.tick(targetTimestamp: t) }
        }
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
        if let (pb, _) = engine.pixelBuffer(forHostTime: CACurrentMediaTime()), let (tex, cv) = frameTexture(pb) {
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
        let size = CGSize(width: max(1, bounds.width * s), height: max(1, bounds.height * s))
        let resized = metalLayer.drawableSize != size
        metalLayer.drawableSize = size
        needsRerender = true
        // resize (C3b flicker): re-present the last frame at the new size inside this layout's CA transaction
        if resized, window != nil, let f = lastFrame { MetalResize.synchronously(metalLayer) { present(f, retain: []) } }
    }

    func requestRedraw() { needsRerender = true }

    /// The last presented frame (renders one if nothing was presented yet), e.g. for the colour oscilloscope.
    var presentedTexture: MTLTexture? {
        if lastFrame == nil { rerender() }
        return lastFrame
    }

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

    /// HLG EDR metadata with the footage's ambient viewing environment (macOS 14+). macOS 13 has no such initializer:
    /// plain `CAEDRMetadata.hlg` (Apple's default ambient), so HLG previews show brighter than AVPlayer (≈ 1.5×, C1).
    static func hlgMetadata(ambient: Data?) -> CAEDRMetadata {
        if #available(macOS 14, *), let ambient { return CAEDRMetadata.hlg(ambientViewingEnvironment: ambient) }
        return CAEDRMetadata.hlg
    }

    private func invalidateLink() {
        if #available(macOS 14, *), let l = link as? CADisplayLink { l.invalidate() }
        (link as? LegacyDisplayLink)?.invalidate()
        link = nil
    }

    @available(macOS 14, *)
    @objc private func tick(_ l: CADisplayLink) { tick(targetTimestamp: l.targetTimestamp) }

    private func tick(targetTimestamp: CFTimeInterval) {
        if let (pb, t) = engine.pixelBuffer(forHostTime: targetTimestamp) {
            lastPixelBuffer = pb
            onFramePresented?(t)
            if let (tex, cv) = frameTexture(pb) {
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
        // HDR projects: half-float HLG / PQ code values (like the compositor's output)
        let fmt: MTLPixelFormat = engine.project.settings.colorSpace.isHDR ? .rgba16Float : .bgra8Unorm
        if rerenderTarget?.width != Int(size.width) || rerenderTarget?.height != Int(size.height) || rerenderTarget?.pixelFormat != fmt {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: Int(size.width), height: Int(size.height), mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
            rerenderTarget = ctx.device.makeTexture(descriptor: d)
        }
        guard let target = rerenderTarget, let cmd = ctx.queue.makeCommandBuffer() else { return }
        if engine.renderCurrentFrame(into: target, commandBuffer: cmd) {
            cmd.commit()
            present(target, retain: [])
        } else if let pb = lastPixelBuffer, let (tex, cv) = frameTexture(pb) {
            present(tex, retain: [cv, pb])
        }
    }

    /// Composed frame texture: BGRA8 (SDR projects) or half-float HLG / PQ code values (HDR projects).
    private func frameTexture(_ pb: CVPixelBuffer) -> (MTLTexture, CVMetalTexture)? {
        ctx.texture(pb, plane: 0, format: CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_64RGBAHalf ? .rgba16Float : .bgra8Unorm)
    }

    /// HDR projects on an EDR-capable screen: half-float drawable tagged with the project's Rec.2100 HLG / PQ colour
    /// space (macOS maps it to the screen's headroom). Elsewhere (SDR screens, offscreen UI tests) the present pass
    /// tone-maps to SDR Rec.709 with the same curve as SDR export. SDR projects: plain BGRA8, unchanged.
    private func configureColor() {
        let space = engine.project.settings.colorSpace
        let edr = space.isHDR && (window?.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1
        let ambient = space == .hdrHLG ? engine.hlgAmbientViewingEnvironment : nil
        guard space != configuredSpace || edr != configuredEDR || ambient != configuredAmbient else { return }
        configuredSpace = space; configuredEDR = edr; configuredAmbient = ambient
        if edr {
            metalLayer.pixelFormat = .rgba16Float
            metalLayer.wantsExtendedDynamicRangeContent = true
            metalLayer.colorspace = CGColorSpace(name: space == .hdrPQ ? CGColorSpace.itur_2100_PQ : CGColorSpace.itur_2100_HLG)
            // PQ: reference white (203 nits) = UI white. HLG: the footage's ambient viewing environment (iPhone: 314
            // lux), like AVPlayer / QuickTime — without it the preview is ≈ 1.5 × brighter than Apple shows the clip (C1).
            metalLayer.edrMetadata = space == .hdrPQ
                ? CAEDRMetadata.hdr10(minLuminance: 0.005, maxLuminance: 1000, opticalOutputScale: Float(ColorMath.referenceWhiteNits))
                : Self.hlgMetadata(ambient: ambient)
            presentMode = .passthrough
        } else {
            metalLayer.pixelFormat = .bgra8Unorm
            metalLayer.wantsExtendedDynamicRangeContent = false
            // SDR Rec.709 frames, colour-managed like AVPlayer shows Rec.709 video (QuickTime: ΔE00 1.1 vs 2.4 untagged,
            // which macOS shows as display-native RGB)
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.itur_709)
            metalLayer.edrMetadata = nil
            presentMode = space.isHDR ? .toneMapToSDR(space.transfer) : .passthrough
        }
        // non-EDR screen: the engine composes the HDR project in SDR layer by layer (BUG-SDR-IN-HDR: SDR media keep
        // their look); frames still in flight from the HDR item are tone-mapped (`mode(for:)`)
        engine.rendersHDRAsSDR = space.isHDR && !edr
        needsRerender = true
    }

    /// Present mode for a composed frame: SDR frames (8-bit: SDR projects, or HDR projects composed in SDR for a
    /// non-EDR screen) pass through; half-float HDR code values pass through to an EDR layer, else are tone-mapped.
    private func mode(for frame: MTLTexture) -> Presenter.Mode {
        guard frame.pixelFormat == .rgba16Float else { return .passthrough }
        return presentMode
    }

    /// sRGB UI colour → code values of the Rec.709-tagged SDR drawable (the letterbox matches the panel around it).
    static func rec709(_ c: RGBA) -> RGBA {
        guard let space = CGColorSpace(name: CGColorSpace.itur_709),
              let o = CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1).converted(to: space, intent: .defaultIntent, options: nil),
              let k = o.components, k.count >= 3 else { return c }
        return RGBA(Double(k[0]), Double(k[1]), Double(k[2]), c.a)
    }

    private func present(_ tex: MTLTexture, retain: [Any]) {
        lastFrame = tex
        configureColor()
        guard let drawable = metalLayer.nextDrawable(), let cmd = ctx.queue.makeCommandBuffer() else { return }
        let lb = configuredEDR ? ColorMath.color(letterbox, in: engine.project.settings.colorSpace) : Self.rec709(letterbox)
        Presenter.encode(tex, to: drawable.texture, contentAspect: engine.project.settings.canvasSize.aspect, letterbox: lb,
                         contentRect: pixelRect(scale: metalLayer.contentsScale), mode: mode(for: tex),
                         commandBuffer: cmd)
        let hold = UncheckedSendable(retain)
        cmd.addCompletedHandler { _ in _ = hold }
        MetalResize.present(drawable, cmd, on: metalLayer)
        presentedFrames += 1
    }

    /// Offscreen render of what the view shows (for window snapshots / tests).
    func snapshot() -> CGImage? {
        let s = window?.backingScaleFactor ?? 2
        let w = max(1, Int(bounds.width * s)), h = max(1, Int(bounds.height * s))
        // Make sure we have a frame even if the display link never ran (window occluded / not on screen).
        if lastFrame == nil { rerender() }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        guard let out = ctx.makeReadbackTexture(d), let cmd = ctx.queue.makeCommandBuffer() else { return nil }
        if let frame = lastFrame {
            // always SDR (HDR projects tone-mapped like on an SDR screen)
            let space = engine.project.settings.colorSpace
            Presenter.encode(frame, to: out, contentAspect: engine.project.settings.canvasSize.aspect, letterbox: letterbox,
                             contentRect: pixelRect(scale: s),
                             mode: space.isHDR && frame.pixelFormat == .rgba16Float ? .toneMapToSDR(space.transfer) : .passthrough,
                             commandBuffer: cmd)
        }
        ctx.synchronizeForReadback(out, cmd)
        cmd.commit(); cmd.waitUntilCompleted()
        return TextureReadback.cgImage(out)
    }
}

enum TextureReadback {
    /// BGRA8 readback texture (`MetalContext.makeReadbackTexture`, synchronized) → CGImage.
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
