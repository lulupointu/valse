@preconcurrency import Metal
import CoreGraphics
import Foundation
import MontageCore
import MontageEffects

/// Synchronous small renders for preset previews (transition / animation tiles) and render tests (W5).
///
/// Everything here blocks on the GPU (`waitUntilCompleted`): call it off the main thread (the UI uses a background
/// queue). Frames go through the real shaders (`EffectPipelines`, `FrameRenderer`), so a tile shows exactly what the
/// compositor will render.
public enum PresetPreviewRenderer {
    /// Renders a whole frame description without any decoder (solids, images, text, stickers, or `sources`).
    public static func render(_ frame: FrameDescription, media: [MediaID: MediaAsset] = [:],
                              sources: any FrameSourceProvider = DictionarySourceProvider([:]),
                              width: Int, height: Int) -> CGImage? {
        let ctx = MetalContext.shared
        guard let out = sharedBGRA(width, height), let cmd = ctx.queue.makeCommandBuffer() else { return nil }
        FrameRenderer.shared.encode(frame, media: media, sources: sources, output: out, commandBuffer: cmd)
        cmd.commit()
        cmd.waitUntilCompleted()
        return image(from: out)
    }

    /// Several frame descriptions in one command buffer (one GPU round trip).
    public static func render(_ frames: [FrameDescription], media: [MediaID: MediaAsset] = [:],
                              sources: any FrameSourceProvider = DictionarySourceProvider([:]),
                              width: Int, height: Int) -> [CGImage?] {
        let ctx = MetalContext.shared
        guard let cmd = ctx.queue.makeCommandBuffer() else { return frames.map { _ in nil } }
        let outs = frames.map { f -> MTLTexture? in
            guard let out = sharedBGRA(width, height) else { return nil }
            FrameRenderer.shared.encode(f, media: media, sources: sources, output: out, commandBuffer: cmd)
            return out
        }
        cmd.commit()
        cmd.waitUntilCompleted()
        return outs.map { $0.flatMap(image(from:)) }
    }

    /// One frame of transition `d` from texture `a` to `b` at `progress` (params default to the descriptor's).
    public static func transitionFrame(_ d: TransitionDescriptor, from a: MTLTexture, to b: MTLTexture, progress: Double,
                                       params: [String: ParamValue]? = nil, width: Int, height: Int,
                                       time: Double = 0) -> CGImage? {
        transitionFrames(d, from: a, to: b, progresses: [progress], params: params, width: width, height: height, time: time).first ?? nil
    }

    /// Several frames of one transition in a single command buffer (tile hover loops).
    public static func transitionFrames(_ d: TransitionDescriptor, from a: MTLTexture, to b: MTLTexture, progresses: [Double],
                                        params: [String: ParamValue]? = nil, width: Int, height: Int,
                                        time: Double = 0) -> [CGImage?] {
        let ctx = MetalContext.shared
        guard let pipe = EffectPipelines.shared.transition(d), let cmd = ctx.queue.makeCommandBuffer() else {
            return progresses.map { _ in nil }
        }
        let work = ctx.pool.acquire(width, height)
        var outs: [MTLTexture?] = []
        let renderer = FrameRenderer.shared
        for pr in progresses {
            var fx = FXContextU(time: Float(time), size: SIMD2(Float(width), Float(height)), pass: 0,
                                aspect: Float(width) / Float(max(height, 1)))
            var packed = d.packParams(params ?? d.makeInstance().params)
            var prog = Float(min(max(pr, 0), 1))
            renderer.fullscreen(pipe, target: work, cmd, label: d.id) { enc in
                enc.setFragmentTexture(a, index: 0)
                enc.setFragmentTexture(b, index: 1)
                enc.setFragmentBytes(&packed, length: packed.count * 4, index: 0)
                enc.setFragmentBytes(&fx, length: MemoryLayout<FXContextU>.stride, index: 1)
                enc.setFragmentBytes(&prog, length: 4, index: 2)
            }
            let out = sharedBGRA(width, height)
            if let out { encodeOutput(work, to: out, cmd) }
            outs.append(out)
        }
        cmd.addCompletedHandler { _ in ctx.pool.release(work) }
        cmd.commit()
        cmd.waitUntilCompleted()
        return outs.map { $0.flatMap(image(from:)) }
    }

    /// GPU time (ms) of one transition pass at `width`×`height` (perf budget checks).
    public static func transitionGPUTime(_ d: TransitionDescriptor, from a: MTLTexture, to b: MTLTexture, progress: Double,
                                         width: Int, height: Int, repeats: Int = 4) -> Double? {
        let ctx = MetalContext.shared
        guard let pipe = EffectPipelines.shared.transition(d), let cmd = ctx.queue.makeCommandBuffer() else { return nil }
        let work = ctx.pool.acquire(width, height)
        for _ in 0..<repeats {
            var fx = FXContextU(time: 0, size: SIMD2(Float(width), Float(height)), pass: 0, aspect: Float(width) / Float(height))
            var packed = d.packParams(d.makeInstance().params)
            var prog = Float(progress)
            FrameRenderer.shared.fullscreen(pipe, target: work, cmd, label: d.id) { enc in
                enc.setFragmentTexture(a, index: 0)
                enc.setFragmentTexture(b, index: 1)
                enc.setFragmentBytes(&packed, length: packed.count * 4, index: 0)
                enc.setFragmentBytes(&fx, length: MemoryLayout<FXContextU>.stride, index: 1)
                enc.setFragmentBytes(&prog, length: 4, index: 2)
            }
        }
        cmd.commit()
        cmd.waitUntilCompleted()
        ctx.pool.release(work)
        return (cmd.gpuEndTime - cmd.gpuStartTime) * 1000 / Double(repeats)
    }

    // MARK: Sample pictures (the "A" and "B" clips of every preview)

    /// "A": mountains at sunset. "B": sea with a lighthouse. Distinct palettes so every transition reads clearly.
    public static func sampleTextures(width: Int, height: Int) -> (MTLTexture, MTLTexture)? {
        guard let a = texture(width, height, drawSunset), let b = texture(width, height, drawSea) else { return nil }
        return (a, b)
    }

    public static func texture(from image: CGImage) -> MTLTexture? {
        texture(image.width, image.height) { cg, w, h in cg.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h)) }
    }

    static func texture(_ w: Int, _ h: Int, _ draw: (CGContext, CGFloat, CGFloat) -> Void) -> MTLTexture? {
        guard let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let data = cg.data else { return nil }
        draw(cg, CGFloat(w), CGFloat(h))
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = .shaderRead
        guard let tex = MetalContext.shared.device.makeTexture(descriptor: d) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: w * 4)
        return tex
    }

    /// CG origin is bottom-left; drawing code below uses y-up.
    static func drawSunset(_ cg: CGContext, _ w: CGFloat, _ h: CGFloat) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let sky = CGGradient(colorsSpace: space, colors: [CGColor(red: 0.98, green: 0.62, blue: 0.30, alpha: 1),
                                                           CGColor(red: 0.85, green: 0.32, blue: 0.42, alpha: 1),
                                                           CGColor(red: 0.22, green: 0.16, blue: 0.42, alpha: 1)] as CFArray,
                             locations: [0, 0.45, 1])!
        cg.drawLinearGradient(sky, start: CGPoint(x: 0, y: h * 0.3), end: CGPoint(x: 0, y: h), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        cg.setFillColor(CGColor(red: 1, green: 0.88, blue: 0.45, alpha: 1))
        cg.fillEllipse(in: CGRect(x: w * 0.58, y: h * 0.42, width: h * 0.26, height: h * 0.26))
        cg.setFillColor(CGColor(red: 0.30, green: 0.14, blue: 0.30, alpha: 1))
        cg.beginPath(); cg.move(to: CGPoint(x: -w * 0.1, y: 0)); cg.addLine(to: CGPoint(x: w * 0.32, y: h * 0.62))
        cg.addLine(to: CGPoint(x: w * 0.75, y: 0)); cg.closePath(); cg.fillPath()
        cg.setFillColor(CGColor(red: 0.16, green: 0.08, blue: 0.20, alpha: 1))
        cg.beginPath(); cg.move(to: CGPoint(x: w * 0.35, y: 0)); cg.addLine(to: CGPoint(x: w * 0.78, y: h * 0.5))
        cg.addLine(to: CGPoint(x: w * 1.2, y: 0)); cg.closePath(); cg.fillPath()
        cg.setFillColor(CGColor(red: 0.98, green: 0.95, blue: 0.95, alpha: 1))
        cg.beginPath(); cg.move(to: CGPoint(x: w * 0.25, y: h * 0.53)); cg.addLine(to: CGPoint(x: w * 0.32, y: h * 0.62))
        cg.addLine(to: CGPoint(x: w * 0.39, y: h * 0.53)); cg.closePath(); cg.fillPath()
    }

    static func drawSea(_ cg: CGContext, _ w: CGFloat, _ h: CGFloat) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let sky = CGGradient(colorsSpace: space, colors: [CGColor(red: 0.72, green: 0.90, blue: 0.98, alpha: 1),
                                                           CGColor(red: 0.30, green: 0.62, blue: 0.92, alpha: 1)] as CFArray,
                             locations: [0, 1])!
        cg.drawLinearGradient(sky, start: CGPoint(x: 0, y: h * 0.4), end: CGPoint(x: 0, y: h), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        let sea = CGGradient(colorsSpace: space, colors: [CGColor(red: 0.02, green: 0.25, blue: 0.45, alpha: 1),
                                                           CGColor(red: 0.08, green: 0.48, blue: 0.66, alpha: 1)] as CFArray,
                             locations: [0, 1])!
        cg.saveGState(); cg.clip(to: CGRect(x: 0, y: 0, width: w, height: h * 0.4))
        cg.drawLinearGradient(sea, start: .zero, end: CGPoint(x: 0, y: h * 0.4), options: [])
        cg.restoreGState()
        // lighthouse
        let tw = w * 0.11, tx = w * 0.2
        cg.setFillColor(CGColor(red: 0.97, green: 0.97, blue: 0.95, alpha: 1))
        cg.fill(CGRect(x: tx, y: h * 0.32, width: tw, height: h * 0.45))
        cg.setFillColor(CGColor(red: 0.86, green: 0.18, blue: 0.16, alpha: 1))
        for i in 0..<3 { cg.fill(CGRect(x: tx, y: h * (0.40 + 0.12 * CGFloat(i)), width: tw, height: h * 0.05)) }
        cg.fill(CGRect(x: tx - tw * 0.15, y: h * 0.77, width: tw * 1.3, height: h * 0.06))
        // boat
        cg.setFillColor(CGColor(red: 1, green: 0.85, blue: 0.2, alpha: 1))
        cg.beginPath(); cg.move(to: CGPoint(x: w * 0.6, y: h * 0.3)); cg.addLine(to: CGPoint(x: w * 0.68, y: h * 0.52))
        cg.addLine(to: CGPoint(x: w * 0.76, y: h * 0.3)); cg.closePath(); cg.fillPath()
        cg.setFillColor(CGColor(red: 0.98, green: 0.98, blue: 0.98, alpha: 0.8))
        for i in 0..<5 { cg.fill(CGRect(x: w * CGFloat(i) * 0.22, y: h * (0.12 + 0.05 * CGFloat(i % 2)), width: w * 0.12, height: h * 0.012)) }
    }

    // MARK: Helpers

    static func sharedBGRA(_ w: Int, _ h: Int) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: max(w, 1), height: max(h, 1), mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        return MetalContext.shared.device.makeTexture(descriptor: d)
    }

    /// Premultiplied working texture → opaque BGRA8 over black.
    static func encodeOutput(_ src: MTLTexture, to out: MTLTexture, _ cmd: MTLCommandBuffer) {
        var bg = SIMD4<Float>(0, 0, 0, 1)
        FrameRenderer.shared.fullscreen(MetalContext.shared.outputBGRA, target: out, cmd, label: "preview-output") { enc in
            enc.setFragmentTexture(src, index: 0)
            enc.setFragmentBytes(&bg, length: 16, index: 0)
        }
    }

    static func image(from tex: MTLTexture) -> CGImage? {
        let w = tex.width, h = tex.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
