@preconcurrency import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import ValseCore
import ValseEngine

/// Per-patch colour comparisons for the colour-space look tests (C1): CIE Lab / CIEDE2000 of frames in a project
/// colour space against Apple's own rendering of the same source.
public enum ColorScience {
    /// Encoded RGB of one frame (display orientation), row-major, top row first.
    public struct Frame: Sendable {
        public let width: Int, height: Int
        public var rgb: [Float]
        public init(width: Int, height: Int, rgb: [Float]) { self.width = width; self.height = height; self.rgb = rgb }

        /// Mean code values of a `gx × gy` grid of patches (inner 60 % of each cell: robust to edges / chroma blur).
        public func patches(_ gx: Int, _ gy: Int) -> [[Double]] {
            var out: [[Double]] = []
            for py in 0..<gy {
                for px in 0..<gx {
                    let x0 = Int((Double(px) + 0.2) / Double(gx) * Double(width)), x1 = max(x0 + 1, Int((Double(px) + 0.8) / Double(gx) * Double(width)))
                    let y0 = Int((Double(py) + 0.2) / Double(gy) * Double(height)), y1 = max(y0 + 1, Int((Double(py) + 0.8) / Double(gy) * Double(height)))
                    var s = [0.0, 0.0, 0.0], n = 0.0
                    for y in y0..<min(y1, height) {
                        for x in x0..<min(x1, width) {
                            let i = (y * width + x) * 3
                            s[0] += Double(rgb[i]); s[1] += Double(rgb[i + 1]); s[2] += Double(rgb[i + 2]); n += 1
                        }
                    }
                    out.append(s.map { $0 / max(n, 1) })
                }
            }
            return out
        }
    }

    /// Code values → linear light (1 = SDR / 203-nit reference white) in BT.2020 primaries, with Apple's conventions:
    /// SDR = BT.709 primaries, BT.1886 (γ 2.4) display; HLG = BT.2100 1000-nit OOTF; PQ = absolute nits / 203.
    public static func linear2020(_ c: [Double], _ space: ProjectColorSpace) -> [Double] {
        switch space {
        case .sdr709:
            let l = c.map { pow(min(max($0, 0), 1), 2.4) }
            return (0..<3).map { r in ColorMath.m709to2020[r][0] * l[0] + ColorMath.m709to2020[r][1] * l[1] + ColorMath.m709to2020[r][2] * l[2] }
        case .hdrHLG, .hdrPQ: return ColorMath.toLinear(c, space.transfer, wide: true)
        }
    }

    /// CIE L*a*b* (D65) of linear BT.2020 light; L* 100 = reference white (HDR highlights go above 100).
    public static func lab(linear2020 c: [Double]) -> [Double] {
        let x = 0.636958 * c[0] + 0.144617 * c[1] + 0.168881 * c[2]
        let y = 0.262700 * c[0] + 0.677998 * c[1] + 0.059302 * c[2]
        let z = 0.000000 * c[0] + 0.028073 * c[1] + 1.060985 * c[2]
        func f(_ t: Double) -> Double { t > 216.0 / 24389 ? cbrt(t) : (24389.0 / 27 * t + 16) / 116 }
        let fx = f(x / 0.95047), fy = f(y), fz = f(z / 1.08883)
        return [116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)]
    }

    /// CIEDE2000 colour difference.
    public static func deltaE2000(_ l1: [Double], _ l2: [Double]) -> Double {
        let (L1, a1, b1) = (l1[0], l1[1], l1[2]), (L2, a2, b2) = (l2[0], l2[1], l2[2])
        let c1 = hypot(a1, b1), c2 = hypot(a2, b2), cb = (c1 + c2) / 2
        let g = 0.5 * (1 - sqrt(pow(cb, 7) / (pow(cb, 7) + pow(25, 7))))
        let a1p = (1 + g) * a1, a2p = (1 + g) * a2
        let c1p = hypot(a1p, b1), c2p = hypot(a2p, b2)
        func hue(_ b: Double, _ a: Double) -> Double {
            if a == 0 && b == 0 { return 0 }
            let h = atan2(b, a) * 180 / .pi
            return h < 0 ? h + 360 : h
        }
        let h1p = hue(b1, a1p), h2p = hue(b2, a2p)
        let dLp = L2 - L1, dCp = c2p - c1p
        var dhp = 0.0
        if c1p * c2p != 0 { dhp = h2p - h1p; if dhp > 180 { dhp -= 360 } else if dhp < -180 { dhp += 360 } }
        let dHp = 2 * sqrt(c1p * c2p) * sin(dhp / 2 * .pi / 180)
        let lbp = (L1 + L2) / 2, cbp = (c1p + c2p) / 2
        var hbp = h1p + h2p
        if c1p * c2p != 0 {
            hbp = abs(h1p - h2p) > 180 ? (h1p + h2p < 360 ? (h1p + h2p + 360) / 2 : (h1p + h2p - 360) / 2) : (h1p + h2p) / 2
        }
        let t = 1 - 0.17 * cos((hbp - 30) * .pi / 180) + 0.24 * cos(2 * hbp * .pi / 180)
            + 0.32 * cos((3 * hbp + 6) * .pi / 180) - 0.20 * cos((4 * hbp - 63) * .pi / 180)
        let dTheta = 30 * exp(-pow((hbp - 275) / 25, 2))
        let rc = 2 * sqrt(pow(cbp, 7) / (pow(cbp, 7) + pow(25, 7)))
        let sl = 1 + 0.015 * pow(lbp - 50, 2) / sqrt(20 + pow(lbp - 50, 2)), sc = 1 + 0.045 * cbp, sh = 1 + 0.015 * cbp * t
        let rt = -sin(2 * dTheta * .pi / 180) * rc
        return sqrt(pow(dLp / sl, 2) + pow(dCp / sc, 2) + pow(dHp / sh, 2) + rt * (dCp / sc) * (dHp / sh))
    }

    public struct Stats: Sendable, CustomStringConvertible {
        public let mean: Double, p95: Double, max: Double
        public var description: String { String(format: "ΔE00 mean %.2f p95 %.2f max %.2f", mean, p95, max) }
    }

    /// Per-patch ΔE2000 between two frames in the same colour space (`gx × gy` patches).
    public static func compare(_ a: Frame, _ b: Frame, space: ProjectColorSpace, bSpace: ProjectColorSpace? = nil,
                               gx: Int = 9, gy: Int = 16) -> Stats {
        let pa = a.patches(gx, gy), pb = b.patches(gx, gy)
        let d = zip(pa, pb).map { deltaE2000(lab(linear2020: linear2020($0, space)), lab(linear2020: linear2020($1, bSpace ?? space))) }.sorted()
        return Stats(mean: d.reduce(0, +) / Double(d.count), p95: d[min(d.count - 1, Int(Double(d.count) * 0.95))], max: d.last ?? 0)
    }

    // MARK: Frames

    /// RGB code values of a BGRA8 / RGBA half / x420 (10-bit, BT.2020 or 709 matrix) pixel buffer, rotated clockwise
    /// by `rotation` and box-resampled to `size` (nil = native).
    public static func frame(_ pb: CVPixelBuffer, rotation: Int = 0, size: (Int, Int)? = nil, matrix2020: Bool = true) -> Frame {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        var raw = [Float](repeating: 0, count: w * h * 3)
        if fmt == kCVPixelFormatType_32BGRA {
            let base = CVPixelBufferGetBaseAddress(pb)!, bpr = CVPixelBufferGetBytesPerRow(pb)
            for y in 0..<h {
                let row = (base + y * bpr).assumingMemoryBound(to: UInt8.self)
                for x in 0..<w { for c in 0..<3 { raw[(y * w + x) * 3 + c] = Float(row[x * 4 + 2 - c]) / 255 } }
            }
        } else if fmt == kCVPixelFormatType_64RGBAHalf {
            let base = CVPixelBufferGetBaseAddress(pb)!, bpr = CVPixelBufferGetBytesPerRow(pb)
            for y in 0..<h {
                #if arch(arm64)
                let row = (base + y * bpr).assumingMemoryBound(to: Float16.self)
                for x in 0..<w { for c in 0..<3 { raw[(y * w + x) * 3 + c] = Float(row[x * 4 + c]) } }
                #else
                let row = (base + y * bpr).assumingMemoryBound(to: UInt16.self)
                for x in 0..<w { for c in 0..<3 { raw[(y * w + x) * 3 + c] = Half.float(row[x * 4 + c]) } }
                #endif
            }
        } else if fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange {
            let yb = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!, ybpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            let cb = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!, cbpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            let (kr, kb): (Float, Float) = matrix2020 ? (0.2627, 0.0593) : (0.2126, 0.0722)
            let kg = 1 - kr - kb
            for y in 0..<h {
                let yr = (yb + y * ybpr).assumingMemoryBound(to: UInt16.self)
                let cr = (cb + (y / 2) * cbpr).assumingMemoryBound(to: UInt16.self)
                for x in 0..<w {
                    let Y = (Float(yr[x] >> 6) - 64) / 876
                    let u = (Float(cr[(x / 2) * 2] >> 6) - 512) / 896, v = (Float(cr[(x / 2) * 2 + 1] >> 6) - 512) / 896
                    let r = Y + 2 * (1 - kr) * v, b = Y + 2 * (1 - kb) * u
                    let g = (Y - kr * r - kb * b) / kg
                    raw[(y * w + x) * 3] = r; raw[(y * w + x) * 3 + 1] = g; raw[(y * w + x) * 3 + 2] = b
                }
            }
        }
        // rotate (display = raw rotated clockwise)
        let (dw, dh) = rotation % 180 == 0 ? (w, h) : (h, w)
        var disp = [Float](repeating: 0, count: dw * dh * 3)
        for y in 0..<dh {
            for x in 0..<dw {
                let (rx, ry): (Int, Int)
                switch (rotation % 360 + 360) % 360 {
                case 90: (rx, ry) = (y, h - 1 - x)
                case 180: (rx, ry) = (w - 1 - x, h - 1 - y)
                case 270: (rx, ry) = (w - 1 - y, x)
                default: (rx, ry) = (x, y)
                }
                for c in 0..<3 { disp[(y * dw + x) * 3 + c] = raw[(ry * w + rx) * 3 + c] }
            }
        }
        guard let (ow, oh) = size, ow != dw || oh != dh else { return Frame(width: dw, height: dh, rgb: disp) }
        var out = [Float](repeating: 0, count: ow * oh * 3)
        for y in 0..<oh {
            let sy0 = y * dh / oh, sy1 = max(sy0 + 1, (y + 1) * dh / oh)
            for x in 0..<ow {
                let sx0 = x * dw / ow, sx1 = max(sx0 + 1, (x + 1) * dw / ow)
                var s: [Float] = [0, 0, 0], n: Float = 0
                for yy in sy0..<min(sy1, dh) { for xx in sx0..<min(sx1, dw) { for c in 0..<3 { s[c] += disp[(yy * dw + xx) * 3 + c] }; n += 1 } }
                for c in 0..<3 { out[(y * ow + x) * 3 + c] = s[c] / max(n, 1) }
            }
        }
        return Frame(width: ow, height: oh, rgb: out)
    }

    // MARK: Apple's DISPLAY of a frame (BUG-SDR-IN-HDR: "looks like the original file in QuickTime")

    /// What Apple shows. `.sdr`: AVAssetImageGenerator / Core Image into sRGB 8-bit (QuickTime, Finder, Photos on an SDR
    /// screen; HDR is tone-mapped). `.edr`: Core Image into extended-linear Display P3 (1 = SDR / UI white, > 1 = EDR
    /// headroom), the values an EDR screen shows (HLG 75 % and PQ 203 nits → 1.0; Rec.709 video → code^1.961).
    public enum AppleTarget: String, Sendable, CaseIterable { case sdr, edr }

    /// Frame values of an Apple rendering: sRGB code values (`.sdr`) or linear Display P3 (`.edr`).
    public static func appleDisplay(_ url: URL, at seconds: Double, target: AppleTarget, size: (Int, Int)) async throws -> Frame {
        try await OffPool.run { _ in
            let asset = AVURLAsset(url: url)
            guard let track = asset.tracks(withMediaType: .video).first else { throw NSError(domain: "ColorScience", code: 1) }
            if target == .sdr {
                // exactly what QuickTime-family thumbnails do (the HLG / PQ tone map of AVFoundation)
                let gen = AVAssetImageGenerator(asset: asset)
                gen.appliesPreferredTrackTransform = true
                gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
                let img = try gen.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 6000), actualTime: nil)
                return resample(srgb8(img), to: size)
            }
            let fd = track.formatDescriptions.first.map { $0 as! CMFormatDescription }
            let ext = fd.flatMap { CMFormatDescriptionGetExtensions($0) as? [String: Any] } ?? [:]
            let tf = ext[kCVImageBufferTransferFunctionKey as String] as? String ?? ""
            let ten = tf.contains("HLG") || tf.contains("2084") || ((ext["BitsPerComponent"] as? Int) ?? 8) > 8
            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = CMTimeRange(start: CMTime(seconds: seconds, preferredTimescale: 6000), duration: CMTime(seconds: 1, preferredTimescale: 600))
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: ten ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()])
            reader.add(out)
            reader.startReading()
            guard let sb = out.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) else { throw reader.error ?? NSError(domain: "ColorScience", code: 2) }
            let xf = track.preferredTransform
            let rot = abs(xf.b) > 0.5 ? (xf.b > 0 ? 90 : 270) : (xf.a < 0 ? 180 : 0)
            let f = appleDisplay(pb, target: .edr, rotation: rot, size: size)
            reader.cancelReading()
            return f
        }
    }

    /// Apple's rendering of a tagged pixel buffer (e.g. the preview's composed HLG / PQ frame, or a Rec.709 frame):
    /// Core Image honours the buffer's colour attachments, like Core Animation does for the preview layer.
    public static func appleDisplay(_ pb: CVPixelBuffer, target: AppleTarget, rotation: Int = 0, size: (Int, Int)) -> Frame {
        var im = CIImage(cvPixelBuffer: pb)
        let o: CGImagePropertyOrientation = rotation == 90 ? .right : rotation == 270 ? .left : rotation == 180 ? .down : .up
        im = im.oriented(o)
        im = im.transformed(by: CGAffineTransform(translationX: -im.extent.minX, y: -im.extent.minY))
        let w = Int(im.extent.width), h = Int(im.extent.height)
        let ctx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .workingFormat: CIFormat.RGBAh,
                                      .cacheIntermediates: false])
        var px = [Float](repeating: 0, count: w * h * 3)
        if target == .edr {
            var buf = [Float](repeating: 0, count: w * h * 4)
            buf.withUnsafeMutableBytes { p in
                ctx.render(im, toBitmap: p.baseAddress!, rowBytes: w * 16, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                           format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!)
            }
            for i in 0..<(w * h) { for c in 0..<3 { px[i * 3 + c] = buf[i * 4 + c] } }
        } else {
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            buf.withUnsafeMutableBytes { p in
                ctx.render(im, toBitmap: p.baseAddress!, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            }
            for i in 0..<(w * h) { for c in 0..<3 { px[i * 3 + c] = Float(buf[i * 4 + c]) / 255 } }
        }
        return resample(Frame(width: w, height: h, rgb: px), to: size)
    }

    /// sRGB 8-bit code values of a CGImage (drawn into sRGB like an SDR screen shows it).
    static func srgb8(_ img: CGImage) -> Frame {
        let w = img.width, h = img.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let c = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var px = [Float](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) { for k in 0..<3 { px[i * 3 + k] = Float(buf[i * 4 + k]) / 255 } }
        return Frame(width: w, height: h, rgb: px)
    }

    /// Box resample (area average) to `size`.
    public static func resample(_ f: Frame, to size: (Int, Int)) -> Frame {
        let (ow, oh) = size
        guard ow != f.width || oh != f.height else { return f }
        var out = [Float](repeating: 0, count: ow * oh * 3)
        for y in 0..<oh {
            let sy0 = y * f.height / oh, sy1 = max(sy0 + 1, (y + 1) * f.height / oh)
            for x in 0..<ow {
                let sx0 = x * f.width / ow, sx1 = max(sx0 + 1, (x + 1) * f.width / ow)
                var s: [Float] = [0, 0, 0], n: Float = 0
                for yy in sy0..<min(sy1, f.height) { for xx in sx0..<min(sx1, f.width) { for c in 0..<3 { s[c] += f.rgb[(yy * f.width + xx) * 3 + c] }; n += 1 } }
                for c in 0..<3 { out[(y * ow + x) * 3 + c] = s[c] / max(n, 1) }
            }
        }
        return Frame(width: ow, height: oh, rgb: out)
    }

    /// CIE Lab of an Apple rendering value (sRGB code values or linear Display P3; L* 100 = SDR white).
    public static func lab(apple c: [Double], _ target: AppleTarget) -> [Double] {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let (x, y, z): (Double, Double, Double)
        if target == .sdr {
            let l = c.map(lin)
            (x, y, z) = (0.4124 * l[0] + 0.3576 * l[1] + 0.1805 * l[2], 0.2126 * l[0] + 0.7152 * l[1] + 0.0722 * l[2],
                         0.0193 * l[0] + 0.1192 * l[1] + 0.9505 * l[2])
        } else {
            let l = c
            (x, y, z) = (0.4866 * l[0] + 0.2657 * l[1] + 0.1982 * l[2], 0.2290 * l[0] + 0.6917 * l[1] + 0.0793 * l[2],
                         0.0451 * l[1] + 1.0439 * l[2])
        }
        func f(_ t: Double) -> Double { t > 216.0 / 24389 ? cbrt(t) : (24389.0 / 27 * t + 16) / 116 }
        let fx = f(x / 0.95047), fy = f(y), fz = f(z / 1.08883)
        return [116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)]
    }

    /// Per-patch ΔE2000 between two Apple renderings (same target).
    public static func compareApple(_ a: Frame, _ b: Frame, target: AppleTarget, gx: Int, gy: Int) -> Stats {
        let d = zip(a.patches(gx, gy), b.patches(gx, gy)).map { deltaE2000(lab(apple: $0, target), lab(apple: $1, target)) }.sorted()
        return Stats(mean: d.reduce(0, +) / Double(d.count), p95: d[min(d.count - 1, Int(Double(d.count) * 0.95))], max: d.last ?? 0)
    }

    /// One decoded frame of `url` at `seconds` as Apple renders it into `space` (AVAssetReader colour conversion by
    /// VideoToolbox: HDR → SDR tone mapping for `.sdr709`, HLG → PQ for `.hdrPQ`), or untouched (`space` nil).
    /// Runs on a GCD queue (blocking reads must stay off Swift's cooperative pool, see STATUS gotchas).
    public static func appleFrame(_ url: URL, at seconds: Double, space: ProjectColorSpace?, size: (Int, Int)? = nil) async throws -> Frame {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Frame, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let asset = AVURLAsset(url: url)
                    guard let track = asset.tracks(withMediaType: .video).first else { throw NSError(domain: "C1", code: 1) }
                    let xf = track.preferredTransform
                    let rot = abs(xf.b) > 0.5 ? (xf.b > 0 ? 90 : 270) : (xf.a < 0 ? 180 : 0)
                    var settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String:
                                                    space == .sdr709 ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_64RGBAHalf]
                    if let space { settings[AVVideoColorPropertiesKey] = ColorTags(space).properties }
                    let reader = try AVAssetReader(asset: asset)
                    reader.timeRange = CMTimeRange(start: CMTime(seconds: seconds, preferredTimescale: 600), duration: CMTime(seconds: 1, preferredTimescale: 600))
                    let out = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
                    reader.add(out)
                    reader.startReading()
                    guard let sb = out.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) else { throw reader.error ?? NSError(domain: "C1", code: 2) }
                    let f = frame(pb, rotation: rot, size: size)
                    reader.cancelReading()
                    c.resume(returning: f)
                } catch { c.resume(throwing: error) }
            }
        }
    }
}
