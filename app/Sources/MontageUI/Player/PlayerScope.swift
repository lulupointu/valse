import AppKit
import CoreImage
@preconcurrency import Metal
import MontageEngine

/// Player ☰ ▸ Color oscilloscope (UX.md §4.1, screenshot 107; W2-6): a luma waveform or an RGB parade of the frame in
/// the player, drawn in the bottom-right corner of the canvas. Updated a few times per second from a 256-px-wide
/// sample of the presented frame, so it costs next to nothing on a MacBook Air.
public enum ScopeMode: String, CaseIterable, Sendable {
    case off, waveform, parade
    var titleKey: String { "player.scope.\(rawValue)" }
}

nonisolated enum ScopeAnalyzer {
    static let levels = 128

    /// Scope image (RGBA, premultiplied, `columns` × `levels`, top row = white) from RGBA8 pixels.
    /// Waveform: one column per image column, luma (Rec. 709). Parade: R, G and B side by side, a third of the width each.
    static func image(rgba: [UInt8], width w: Int, height h: Int, mode: ScopeMode) -> CGImage? {
        guard w > 0, h > 0, mode != .off, rgba.count >= w * h * 4 else { return nil }
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
