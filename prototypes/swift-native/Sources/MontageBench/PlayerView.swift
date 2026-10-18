import AppKit
import AVFoundation
import Metal
import QuartzCore
import MontageEngine

/// Preview surface: a CAMetalLayer-backed NSView driven by the display link. Frames are pulled from
/// AVPlayerItemVideoOutput (the composition rendered by MetalCompositor) and drawn zero-copy.
/// Presentation is confirmed with MTLDrawable presented handlers, so "frames shown" means
/// "frames actually presented on screen", not "frames rendered".
final class PlayerView: NSView {
    let ctx = MetalContext.shared
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    var output: AVPlayerItemVideoOutput?
    var debug = ProcessInfo.processInfo.environment["MONTAGE_DEBUG"] != nil
    private var link: CADisplayLink?
    private var retry: (CVPixelBuffer, CMTime)?

    /// Returns the item time we want to show at the next vsync, or nil to show nothing new.
    var wantedTime: ((CADisplayLink, AVPlayerItemVideoOutput) -> CMTime?)?
    /// Accept a pixel buffer whose display time is `t`?
    var accept: ((CMTime) -> Bool)?
    /// Called on main when a frame has been presented (host time, item time).
    var onPresented: ((CFTimeInterval, CMTime) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        metalLayer.device = ctx.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.drawableSize = CGSize(width: 1920, height: 1080)
        metalLayer.maximumDrawableCount = 3
    }
    required init?(coder: NSCoder) { fatalError() }
    override func makeBackingLayer() -> CALayer { CAMetalLayer() }

    func startDisplayLink() {
        let l = displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }
    func stopDisplayLink() { link?.invalidate(); link = nil }

    @objc private func tick(_ l: CADisplayLink) {
        if let (pb, t) = retry { retry = nil; present(pb, itemTime: t); return }
        guard let output, let want = wantedTime?(l, output) else { return }
        guard output.hasNewPixelBuffer(forItemTime: want) else { if debug { Metrics.log("no new pb for \(want.seconds)") }; return }
        var disp = CMTime.invalid
        guard let pb = output.copyPixelBuffer(forItemTime: want, itemTimeForDisplay: &disp) else { return }
        if debug { Metrics.log("got pb disp=\(disp.seconds) want=\(want.seconds)") }
        if let accept, !accept(disp) { return }
        present(pb, itemTime: disp)
    }

    private func present(_ pb: CVPixelBuffer, itemTime: CMTime) {
        guard let (tex, cvTex) = ctx.texture(pb, plane: 0, format: .bgra8Unorm),
              let drawable = metalLayer.nextDrawable(),
              let cmd = ctx.queue.makeCommandBuffer() else { return }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = drawable.texture
        rp.colorAttachments[0].loadAction = .dontCare
        rp.colorAttachments[0].storeAction = .store
        let enc = cmd.makeRenderCommandEncoder(descriptor: rp)!
        enc.setRenderPipelineState(ctx.presentPipeline)
        enc.setFragmentTexture(tex, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        drawable.addPresentedHandler { [weak self] d in
            let t = d.presentedTime
            DispatchQueue.main.async {
                // presentedTime 0 = never reached the screen (e.g. window not yet visible): show it again
                if t > 0 { self?.onPresented?(t, itemTime) } else { self?.retry = (pb, itemTime) }
            }
        }
        cmd.present(drawable)
        cmd.addCompletedHandler { _ in _ = cvTex; _ = pb }
        cmd.commit()
    }
}
