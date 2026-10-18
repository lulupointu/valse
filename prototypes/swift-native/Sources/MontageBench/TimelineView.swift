import AppKit
import Metal
import QuartzCore
import CoreText
import MontageEngine

/// GPU-drawn, virtualized timeline canvas: one instanced draw call for every visible clip body,
/// thumbnail placeholder and label (labels come from a Core Text–rendered glyph atlas).
/// This is the approach the real app would use (CapCut-like canvas), not an NSView per clip.
final class TimelineView: NSView {
    struct Clip { var start: Double; var dur: Double; var color: SIMD4<Float>; var label: Int }
    struct Inst { var rect: SIMD4<Float>; var color: SIMD4<Float>; var uv: SIMD4<Float>; var misc: SIMD4<Float> }

    let ctx = MetalContext.shared
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private(set) var tracks: [[Clip]] = []
    var pixelsPerSecond: Double = 40
    var scrollSeconds: Double = 0
    var playhead: Double = 12
    var animate: ((CFTimeInterval) -> Void)?
    var onPresented: ((CFTimeInterval) -> Void)?
    private(set) var cpuFrameMs: [Double] = []
    private var link: CADisplayLink?
    private var atlas: MTLTexture!
    private var buffers: [MTLBuffer] = []
    private var bufIndex = 0
    private let inflight = DispatchSemaphore(value: 3)
    private let maxInst = 16384
    static let cellW = 192, cellH = 32, atlasSize = 2048

    init(frame: NSRect, clipCount: Int, trackCount: Int) {
        super.init(frame: frame)
        wantsLayer = true
        metalLayer.device = ctx.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.maximumDrawableCount = 3
        buffers = (0..<3).map { _ in ctx.device.makeBuffer(length: maxInst * MemoryLayout<Inst>.stride, options: .storageModeShared)! }
        makeClips(count: clipCount, trackCount: trackCount)
        atlas = makeAtlas(count: clipCount)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func makeBackingLayer() -> CALayer { CAMetalLayer() }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let s = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = s
        metalLayer.drawableSize = CGSize(width: bounds.width * s, height: bounds.height * s)
    }

    private func makeClips(count: Int, trackCount: Int) {
        var rng = SplitMix(seed: 42)
        let palette: [SIMD4<Float>] = [[0.16, 0.55, 0.62, 1], [0.85, 0.52, 0.18, 1], [0.52, 0.34, 0.78, 1],
                                       [0.20, 0.62, 0.42, 1], [0.78, 0.30, 0.38, 1], [0.30, 0.45, 0.80, 1]]
        tracks = Array(repeating: [], count: trackCount)
        var t = [Double](repeating: 0, count: trackCount)
        for i in 0..<count {
            let k = i % trackCount
            let gap = rng.next() < 0.3 ? rng.next() * 2 : 0
            let d = 2 + rng.next() * 6
            tracks[k].append(Clip(start: t[k] + gap, dur: d, color: palette[k], label: i))
            t[k] += gap + d
        }
    }
    var totalSeconds: Double { tracks.compactMap { $0.last.map { $0.start + $0.dur } }.max() ?? 0 }

    private func makeAtlas(count: Int) -> MTLTexture {
        let n = Self.atlasSize
        let cg = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n,
                           space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        cg.setFillColor(gray: 0, alpha: 1); cg.fill(CGRect(x: 0, y: 0, width: n, height: n))
        let font = CTFontCreateUIFontForLanguage(.system, 22, nil)!
        let cols = n / Self.cellW
        for i in 0..<count {
            let col = i % cols, row = i / cols
            let s = String(format: NSLocalizedString("timeline.clipLabel", comment: ""), i + 1)
            let attr = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: CGColor(gray: 1, alpha: 1)])
            let line = CTLineCreateWithAttributedString(attr)
            cg.textPosition = CGPoint(x: col * Self.cellW + 4, y: n - (row + 1) * Self.cellH + 9)
            CTLineDraw(line, cg)
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: n, height: n, mipmapped: false)
        let tex = ctx.device.makeTexture(descriptor: d)!
        tex.replace(region: MTLRegionMake2D(0, 0, n, n), mipmapLevel: 0, withBytes: cg.data!, bytesPerRow: n)
        return tex
    }

    func startDisplayLink() {
        let l = displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }
    func stopDisplayLink() { link?.invalidate(); link = nil }

    @objc private func tick(_ l: CADisplayLink) {
        animate?(l.targetTimestamp)
        draw()
    }

    func draw() {
        let s = Float(window?.backingScaleFactor ?? 2)
        let W = Float(metalLayer.drawableSize.width), H = Float(metalLayer.drawableSize.height)
        guard W > 0, inflight.wait(timeout: .now() + 0.1) == .success else { return }
        guard let drawable = metalLayer.nextDrawable(), let cmd = ctx.queue.makeCommandBuffer() else { inflight.signal(); return }
        let t0 = CACurrentMediaTime()  // CPU cost of building + encoding the frame (excludes drawable wait)
        let buf = buffers[bufIndex]; bufIndex = (bufIndex + 1) % buffers.count
        let p = buf.contents().bindMemory(to: Inst.self, capacity: maxInst)
        var n = 0
        func add(_ r: SIMD4<Float>, _ c: SIMD4<Float>, kind: Float = 0, radius: Float = 0, uv: SIMD4<Float> = .zero) {
            guard n < maxInst else { return }
            p[n] = Inst(rect: r, color: c, uv: uv, misc: [kind, radius, 0, 0]); n += 1
        }
        let headerW: Float = 90 * s, rulerH: Float = 24 * s, trackH: Float = 56 * s, gap: Float = 6 * s
        let pps = pixelsPerSecond, left = scrollSeconds
        let viewSeconds = Double((W - headerW) / s) / pps
        let toX = { (sec: Double) -> Float in headerW + Float((sec - left) * pps) * s }
        // ruler ticks (adaptive interval)
        let steps: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
        let step = steps.first { $0 * pps >= 60 } ?? 600
        var tk = (left / step).rounded(.down) * step
        while tk < left + viewSeconds {
            add([toX(tk), rulerH * 0.4, 1 * s, rulerH * 0.6], [0.45, 0.45, 0.48, 1]); tk += step
        }
        // tracks
        let cols = Self.atlasSize / Self.cellW
        let cellUW = Float(Self.cellW) / Float(Self.atlasSize), cellUH = Float(Self.cellH) / Float(Self.atlasSize)
        let labelW = Float(Self.cellW) / 2 * s, labelH = Float(Self.cellH) / 2 * s
        for (k, clips) in tracks.enumerated() {
            let y = rulerH + gap + Float(k) * (trackH + gap)
            add([headerW, y, W - headerW, trackH], [0.13, 0.13, 0.15, 1])
            // binary search first clip whose end >= left
            var lo = 0, hi = clips.count
            while lo < hi { let m = (lo + hi) / 2; if clips[m].start + clips[m].dur < left { lo = m + 1 } else { hi = m } }
            var i = lo
            while i < clips.count, clips[i].start < left + viewSeconds {
                let c = clips[i]; i += 1
                let x0 = max(toX(c.start), headerW), x1 = toX(c.start + c.dur)
                let w = x1 - x0 - 1 * s
                if w < 1 { continue }
                add([x0, y, w, trackH], c.color, radius: min(4 * s, w / 2))
                if w > 8 * s {
                    let th = min(w - 4 * s, 64 * s)
                    add([x0 + 2 * s, y + 18 * s, th, trackH - 20 * s], c.color, kind: 1)
                }
                if w > 24 * s {
                    let lw = min(labelW, w - 6 * s)
                    let u0 = Float(c.label % cols) * cellUW, v0 = Float(c.label / cols) * cellUH
                    add([x0 + 4 * s, y + 1 * s, lw, labelH], [1, 1, 1, 0.95], kind: 2,
                        uv: [u0, v0, u0 + cellUW * lw / labelW, v0 + cellUH])
                }
            }
        }
        // track headers + playhead
        for k in 0..<tracks.count {
            add([0, rulerH + gap + Float(k) * (trackH + gap), headerW - 2 * s, trackH], [0.18, 0.18, 0.2, 1])
        }
        add([toX(playhead), 0, 2 * s, H], [0.0, 0.76, 0.80, 1])

        encodeDraw(cmd, target: drawable.texture, buf: buf, count: n, W: W, H: H)
        drawable.addPresentedHandler { [weak self] d in
            let t = d.presentedTime
            guard t > 0 else { return }
            DispatchQueue.main.async { self?.onPresented?(t) }
        }
        cpuFrameMs.append((CACurrentMediaTime() - t0) * 1000)
        cmd.present(drawable)
        cmd.addCompletedHandler { [inflight] _ in inflight.signal() }
        cmd.commit()
        lastFrame = (buf, n, W, H)
    }

    private var lastFrame: (MTLBuffer, Int, Float, Float)?

    private func encodeDraw(_ cmd: MTLCommandBuffer, target: MTLTexture, buf: MTLBuffer, count n: Int, W: Float, H: Float) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1)
        rp.colorAttachments[0].storeAction = .store
        let enc = cmd.makeRenderCommandEncoder(descriptor: rp)!
        enc.setRenderPipelineState(ctx.timelinePipeline)
        enc.setVertexBuffer(buf, offset: 0, index: 0)
        var vp = SIMD2<Float>(W, H)
        enc.setVertexBytes(&vp, length: 8, index: 1)
        enc.setFragmentTexture(atlas, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: n)
        enc.endEncoding()
    }

    /// Headless verification: re-render the last frame offscreen and write a PNG (no Screen Recording permission needed).
    func snapshot(to url: URL) {
        guard let (buf, n, W, H) = lastFrame else { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(W), height: Int(H), mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
        let tex = ctx.device.makeTexture(descriptor: d)!
        let cmd = ctx.queue.makeCommandBuffer()!
        encodeDraw(cmd, target: tex, buf: buf, count: n, W: W, H: H)
        cmd.commit(); cmd.waitUntilCompleted()
        writePNG(tex, url)
    }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func nextU() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func next() -> Double { Double(nextU() >> 11) / Double(1 << 53) }
}

func writePNG(_ tex: MTLTexture, _ url: URL) {
    let w = tex.width, h = tex.height
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    tex.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    let cs = CGColorSpaceCreateDeviceRGB()
    let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
    let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs, bitmapInfo: info)!
    let img = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: img)
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
}
