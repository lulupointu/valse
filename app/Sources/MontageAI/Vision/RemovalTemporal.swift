import CoreGraphics
import Foundation

/// AI remove on video (AI-041): temporal consistency of the per-frame LaMa fill. Each frame is inpainted on its own,
/// so a static hole (logo, watermark, parked object) gets a slightly different texture every frame and shimmers.
/// When the scene around the hole is still (the ring of pixels just outside the mask barely changes from the previous
/// source frame), the new fill is blended with the previous output inside the mask (exponential smoothing,
/// `alpha` = weight of the new fill); when the ring changes (camera move, cut, something passing) the fresh fill is
/// used as is, so nothing ghosts. Pixels outside the mask are never touched.
final class RemovalTemporalSmoother {
    nonisolated(unsafe) static var enabled = true
    static let alpha: Float = 0.35
    /// Mean absolute ring change (0…255, on the 1/4-scale gray image) below which the scene counts as still.
    static let stillThreshold: Float = 4

    let w: Int, h: Int
    let sw: Int, sh: Int
    private var prevOut: [UInt8]?
    private var prevSmall: [UInt8]?
    private(set) var blendedFrames = 0

    init(width: Int, height: Int) {
        w = width; h = height
        sw = max(1, width / 4); sh = max(1, height / 4)
    }

    static func gray(_ img: CGImage, _ w: Int, _ h: Int) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: w * h)
        px.withUnsafeMutableBytes { b in
            let ctx = CGContext(data: b.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.interpolationQuality = .medium
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return px
    }

    /// Ring cells (small scale): outside the mask, within 3 cells of it.
    static func ring(_ small: [UInt8], _ sw: Int, _ sh: Int) -> [Int] {
        var out: [Int] = []
        for y in 0..<sh {
            for x in 0..<sw where small[y * sw + x] < 8 {
                var near = false
                outer: for dy in -3...3 {
                    for dx in -3...3 {
                        let xx = x + dx, yy = y + dy
                        if xx >= 0, yy >= 0, xx < sw, yy < sh, small[yy * sw + xx] >= 8 { near = true; break outer }
                    }
                }
                if near { out.append(y * sw + x) }
            }
        }
        return out
    }

    /// Mean absolute change of the ring between two small gray frames (nil without a previous frame or ring).
    static func ringChange(_ a: [UInt8], _ b: [UInt8], ring: [Int]) -> Float? {
        guard !ring.isEmpty, a.count == b.count else { return nil }
        var s = 0
        for i in ring { s += abs(Int(a[i]) - Int(b[i])) }
        return Float(s) / Float(ring.count)
    }

    /// Blends the BGRA output frame (in place) with the previous output inside `mask` when the surroundings are still.
    func apply(out: UnsafeMutablePointer<UInt8>, bytesPerRow: Int, source: CGImage, mask: CGImage) {
        let small = Self.gray(source, sw, sh)
        defer {
            prevSmall = small
            var copy = [UInt8](repeating: 0, count: w * h * 4)
            for y in 0..<h { memcpy(&copy[y * w * 4], out + y * bytesPerRow, w * 4) }
            prevOut = copy
        }
        guard Self.enabled, let prevSmall, let prevOut else { return }
        let smallMask = Self.gray(mask, sw, sh)
        guard let change = Self.ringChange(small, prevSmall, ring: Self.ring(smallMask, sw, sh)), change < Self.stillThreshold else { return }
        let m = Self.gray(mask, w, h)
        let keep = 1 - Self.alpha
        for y in 0..<h {
            // CGContext rows of the mask are top-down like the pixel buffer's
            let row = out + y * bytesPerRow
            for x in 0..<w {
                let mv = m[y * w + x]
                guard mv > 0 else { continue }
                let k = keep * Float(mv) / 255
                let p = (y * w + x) * 4
                for c in 0..<3 {
                    let v = Float(row[x * 4 + c]) * (1 - k) + Float(prevOut[p + c]) * k
                    row[x * 4 + c] = UInt8(min(255, max(0, v.rounded())))
                }
            }
        }
        blendedFrames += 1
    }
}
