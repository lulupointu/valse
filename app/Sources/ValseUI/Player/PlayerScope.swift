import AppKit
import CoreImage
@preconcurrency import Metal
import ValseEngine

/// Player ☰ ▸ Color oscilloscope (UX.md §4.1, screenshot 107; W2-6): a luma waveform or an RGB parade of the frame in
/// the player, drawn in the bottom-right corner of the canvas. Updated a few times per second from a 256-px-wide
/// sample of the presented frame, so it costs next to nothing on a MacBook Air.
public enum ScopeMode: String, CaseIterable, Sendable {
    case off, waveform, parade
    /// CL-016: Cb/Cr vectorscope (square, skin-tone line) and RGB histogram.
    case vectorscope, histogram
    var titleKey: String { "player.scope.\(rawValue)" }
    /// Square plot (vectorscope) instead of 2:1.
    var isSquare: Bool { self == .vectorscope }
}

nonisolated enum ScopeAnalyzer {
    static let levels = 128

    /// Scope image (RGBA, premultiplied, `columns` × `levels`, top row = white) from RGBA8 pixels.
    /// Waveform: one column per image column, luma (Rec. 709). Parade: R, G and B side by side, a third of the width each.
    static func image(rgba: [UInt8], width w: Int, height h: Int, mode: ScopeMode) -> CGImage? {
        guard w > 0, h > 0, mode != .off, rgba.count >= w * h * 4 else { return nil }
        if mode == .vectorscope { return vectorscope(rgba: rgba, width: w, height: h) }
        if mode == .histogram { return histogram(rgba: rgba, width: w, height: h) }
        let cols = mode == .parade ? w * 3 : w
        var counts = [UInt32](repeating: 0, count: cols * levels)
        let L = Double(levels - 1)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let r = Double(rgba[i]) / 255, g = Double(rgba[i + 1]) / 255, b = Double(rgba[i + 2]) / 255
                if mode == .waveform {
                    let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    counts[Int((l * L).rounded()) * cols + x] += 1
                } else {
                    counts[Int((r * L).rounded()) * cols + x] += 1
                    counts[Int((g * L).rounded()) * cols + w + x] += 1
                    counts[Int((b * L).rounded()) * cols + 2 * w + x] += 1
                }
            }
        }
        // intensity: a column where every pixel has the same level saturates; sqrt keeps thin traces visible
        let full = Double(max(h, 1)) * 0.25
        var out = [UInt8](repeating: 0, count: cols * levels * 4)
        for lv in 0..<levels {
            let row = levels - 1 - lv   // high values at the top
            for c in 0..<cols {
                let n = counts[lv * cols + c]
                guard n > 0 else { continue }
                let a = min(1, (Double(n) / full).squareRoot() + 0.15)
                let tint: (Double, Double, Double)
                if mode == .waveform { tint = (0.75, 1, 0.8) }
                else { tint = c < w ? (1, 0.35, 0.35) : (c < 2 * w ? (0.4, 1, 0.45) : (0.45, 0.6, 1)) }
                let o = (row * cols + c) * 4
                out[o] = UInt8(tint.0 * a * 255); out[o + 1] = UInt8(tint.1 * a * 255); out[o + 2] = UInt8(tint.2 * a * 255)
                out[o + 3] = UInt8(a * 255)
            }
        }
        guard let provider = CGDataProvider(data: Data(out) as CFData) else { return nil }
        return CGImage(width: cols, height: levels, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: cols * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

nonisolated extension ScopeAnalyzer {
    static let vectorSize = 128

    /// Vectorscope position (0…1, y down) of an sRGB colour: Rec. 709 Cb → x, Cr → up, ±0.5 = the edge.
    static func vectorPoint(r: Double, g: Double, b: Double) -> (x: Double, y: Double) {
        let cb = -0.1146 * r - 0.3854 * g + 0.5 * b, cr = 0.5 * r - 0.4542 * g - 0.0458 * b
        return (0.5 + cb, 0.5 - cr)
    }

    /// `vectorSize`² image: each pixel's chroma plotted in its own colour (brighter where many pixels land).
    static func vectorscope(rgba: [UInt8], width w: Int, height h: Int) -> CGImage? {
        let n = vectorSize
        var counts = [UInt32](repeating: 0, count: n * n)
        var sum = [SIMD3<Double>](repeating: .zero, count: n * n)
        for i in 0..<(w * h) {
            let r = Double(rgba[i * 4]) / 255, g = Double(rgba[i * 4 + 1]) / 255, b = Double(rgba[i * 4 + 2]) / 255
            let p = vectorPoint(r: r, g: g, b: b)
            let x = min(max(Int(p.x * Double(n)), 0), n - 1), y = min(max(Int(p.y * Double(n)), 0), n - 1)
            counts[y * n + x] += 1; sum[y * n + x] += SIMD3(r, g, b)
        }
        let full = Double(max(w * h, 1)) / 400
        var out = [UInt8](repeating: 0, count: n * n * 4)
        for k in 0..<(n * n) where counts[k] > 0 {
            let a = min(1, (Double(counts[k]) / full).squareRoot() + 0.25)
            // the pixels' own hue, lifted so dark colours stay visible
            var c = sum[k] / Double(counts[k])
            let m = max(c.x, c.y, c.z, 1e-3)
            c = c / m * 0.75 + SIMD3(repeating: 0.25)
            out[k * 4] = UInt8(c.x * a * 255); out[k * 4 + 1] = UInt8(c.y * a * 255); out[k * 4 + 2] = UInt8(c.z * a * 255)
            out[k * 4 + 3] = UInt8(a * 255)
        }
        return cgImage(out, width: n, height: n)
    }

    /// RGB histogram (`256 / 2` bins × `levels`): R, G and B overlaid additively, bar height = log-ish share.
    static func histogram(rgba: [UInt8], width w: Int, height h: Int) -> CGImage? {
        let bins = 128
        var hist = [[UInt32]](repeating: [UInt32](repeating: 0, count: bins), count: 3)
        for i in 0..<(w * h) { for ch in 0..<3 { hist[ch][Int(rgba[i * 4 + ch]) * bins / 256] += 1 } }
        let peak = Double(hist.flatMap { $0 }.max() ?? 1)
        var out = [UInt8](repeating: 0, count: bins * levels * 4)
        let tint: [(Double, Double, Double)] = [(1, 0.3, 0.3), (0.3, 1, 0.35), (0.35, 0.5, 1)]
        for ch in 0..<3 {
            for x in 0..<bins {
                let v = Double(hist[ch][x]) / max(peak, 1)
                let top = Int((v.squareRoot() * Double(levels - 1)).rounded())
                guard hist[ch][x] > 0 else { continue }
                for lv in 0...top {
                    let o = ((levels - 1 - lv) * bins + x) * 4
                    out[o] = UInt8(min(255, Double(out[o]) + tint[ch].0 * 0.75 * 255))
                    out[o + 1] = UInt8(min(255, Double(out[o + 1]) + tint[ch].1 * 0.75 * 255))
                    out[o + 2] = UInt8(min(255, Double(out[o + 2]) + tint[ch].2 * 0.75 * 255))
                    out[o + 3] = max(out[o + 3], 200)
                }
            }
        }
        return cgImage(out, width: bins, height: levels)
    }

    static func cgImage(_ px: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

extension PlayerView {
    private static let ciContext = CIContext(mtlDevice: MetalContext.shared.device, options: [.cacheIntermediates: false])

    /// RGBA8 pixels of the presented frame, downscaled to `width` columns (nil before the first frame).
    func sampleFrame(width: Int = 192) -> (pixels: [UInt8], width: Int, height: Int)? {
        guard let tex = presentedTexture, tex.width > 0, tex.height > 0,
              let img = CIImage(mtlTexture: tex, options: [.colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!]) else { return nil }
        let w = width, h = max(1, Int(Double(width) * Double(tex.height) / Double(tex.width)))
        let scaled = img.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / CGFloat(tex.width), y: CGFloat(h) / CGFloat(tex.height)))
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        Self.ciContext.render(scaled, toBitmap: &buf, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                              format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return (buf, w, h)
    }
}
