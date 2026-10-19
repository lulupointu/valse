import CoreGraphics
import Foundation
import Vision
import MontageCore
import MontageEngine

/// Adjust ▸ Basic ▸ Color card (CL-028): calibrate a clip from a ColorChecker 24 chart filmed in the shot.
/// The chart is found in the frame under the playhead (Vision rectangle candidates + the whole frame; every candidate is
/// sampled as a 6 × 4 patch grid in its four orientations), the 24 patch means are fitted to the X-Rite reference
/// values with a 3 × 3 matrix in linear light (least squares, white-preserving fallback), and the matrix is baked into
/// a 33³ look LUT (`ColorLooks`, kind `.card`) — HDR projects get the same delta re-bake as the other looks.
public enum ColorCard {
    /// ColorChecker 24 reference (X-Rite, post-2014 formulation), sRGB 8-bit, row-major from dark skin to black.
    public static let reference: [SIMD3<Double>] = [
        [115, 82, 68], [194, 150, 130], [98, 122, 157], [87, 108, 67], [133, 128, 177], [103, 189, 170],
        [214, 126, 44], [80, 91, 166], [193, 90, 99], [94, 60, 108], [157, 188, 64], [224, 163, 46],
        [56, 61, 150], [70, 148, 73], [175, 54, 60], [231, 199, 31], [187, 86, 149], [8, 133, 161],
        [243, 243, 242], [200, 200, 200], [160, 160, 160], [122, 122, 121], [85, 85, 85], [52, 52, 52],
    ].map { SIMD3<Double>($0[0], $0[1], $0[2]) / 255 }

    /// A detected chart: corners in normalized image coordinates (top-left origin) in patch order —
    /// top-left (dark skin), top-right (bluish green), bottom-right (black), bottom-left (white).
    public struct Detection: Sendable {
        public var corners: [CGPoint]
        /// Measured patch colours (display-encoded 0…1), reference order.
        public var patches: [SIMD3<Double>]
        /// Correction matrix (linear light), row-major.
        public var matrix: [Double]
        /// RMS error of the corrected patches vs the reference (display 0…1).
        public var residual: Double
        /// RMS error before correction.
        public var before: Double
    }

    // MARK: Colour math

    public static func toLinear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    public static func toDisplay(_ v: Double) -> Double {
        let x = min(max(v, 0), 1)
        return x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1 / 2.4) - 0.055
    }
    static func lin(_ c: SIMD3<Double>) -> SIMD3<Double> { SIMD3(toLinear(c.x), toLinear(c.y), toLinear(c.z)) }
    static func disp(_ c: SIMD3<Double>) -> SIMD3<Double> { SIMD3(toDisplay(c.x), toDisplay(c.y), toDisplay(c.z)) }

    public static func apply(_ m: [Double], _ c: SIMD3<Double>) -> SIMD3<Double> {
        let l = lin(c)
        return disp(SIMD3(m[0] * l.x + m[1] * l.y + m[2] * l.z, m[3] * l.x + m[4] * l.y + m[5] * l.z, m[6] * l.x + m[7] * l.y + m[8] * l.z))
    }

    /// Least-squares 3 × 3 matrix taking measured linear colours to the reference (patch-weighted; clipped patches skipped).
    public static func solve(measured: [SIMD3<Double>]) -> [Double] {
        precondition(measured.count == reference.count)
        var ata = [Double](repeating: 0, count: 9), atb = [[Double]](repeating: [0, 0, 0], count: 3)
        for (m0, r0) in zip(measured, reference) {
            // a clipped channel (sensor saturation) says nothing about the transform
            if max(m0.x, m0.y, m0.z) > 0.985 || min(m0.x, m0.y, m0.z) < 0.004 { continue }
            let m = lin(m0), r = lin(r0)
            let a = [m.x, m.y, m.z], b = [r.x, r.y, r.z]
            for i in 0..<3 { for j in 0..<3 { ata[i * 3 + j] += a[i] * a[j] } }
            for k in 0..<3 { for i in 0..<3 { atb[k][i] += a[i] * b[k] } }
        }
        // light ridge toward identity keeps a near-singular fit sane
        let lambda = 1e-4
        for i in 0..<3 { ata[i * 4] += lambda }
        guard let inv = invert3(ata) else { return [1, 0, 0, 0, 1, 0, 0, 0, 1] }
        var m = [Double](repeating: 0, count: 9)
        for k in 0..<3 {
            let rhs = [atb[k][0] + (k == 0 ? lambda : 0), atb[k][1] + (k == 1 ? lambda : 0), atb[k][2] + (k == 2 ? lambda : 0)]
            for j in 0..<3 { m[k * 3 + j] = inv[j * 3 + 0] * rhs[0] + inv[j * 3 + 1] * rhs[1] + inv[j * 3 + 2] * rhs[2] }
        }
        return m.map { min(max($0, -4), 4) }
    }

    static func invert3(_ a: [Double]) -> [Double]? {
        let det = a[0] * (a[4] * a[8] - a[5] * a[7]) - a[1] * (a[3] * a[8] - a[5] * a[6]) + a[2] * (a[3] * a[7] - a[4] * a[6])
        guard abs(det) > 1e-12 else { return nil }
        let d = 1 / det
        return [(a[4] * a[8] - a[5] * a[7]) * d, (a[2] * a[7] - a[1] * a[8]) * d, (a[1] * a[5] - a[2] * a[4]) * d,
                (a[5] * a[6] - a[3] * a[8]) * d, (a[0] * a[8] - a[2] * a[6]) * d, (a[2] * a[3] - a[0] * a[5]) * d,
                (a[3] * a[7] - a[4] * a[6]) * d, (a[1] * a[6] - a[0] * a[7]) * d, (a[0] * a[4] - a[1] * a[3]) * d]
    }

    static func rms(_ a: [SIMD3<Double>], _ b: [SIMD3<Double>]) -> Double {
        let s = zip(a, b).reduce(0.0) { acc, p in let d = p.0 - p.1; return acc + (d * d).sum() / 3 }
        return (s / Double(max(a.count, 1))).squareRoot()
    }

    // MARK: Sampling

    /// 8-bit RGBA pixels of an image, top row first.
    public struct Pixels: Sendable {
        public let data: [UInt8], width: Int, height: Int
        public init(_ image: CGImage, maxSide: Int = 720) {
            let s = min(1, Double(maxSide) / Double(max(image.width, image.height)))
            let w = max(1, Int(Double(image.width) * s)), h = max(1, Int(Double(image.height) * s))
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            buf.withUnsafeMutableBytes { raw in
                guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
                ctx.interpolationQuality = .medium
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            data = buf; width = w; height = h
        }
        /// Mean colour of a small square around a normalized (top-left origin) point.
        func mean(at p: CGPoint, radius: Int) -> SIMD3<Double> {
            let cx = Int(p.x * Double(width)), cy = Int(p.y * Double(height))
            var s = SIMD3<Double>(0, 0, 0), n = 0.0
            for y in max(0, cy - radius)...min(height - 1, cy + radius) {
                for x in max(0, cx - radius)...min(width - 1, cx + radius) {
                    let i = (y * width + x) * 4
                    s += SIMD3(Double(data[i]), Double(data[i + 1]), Double(data[i + 2])); n += 1
                }
            }
            return n > 0 ? s / (n * 255) : .zero
        }
    }

    /// Bilinear point inside a quad (corners TL, TR, BR, BL) at (u, v) ∈ [0, 1]².
    static func point(_ q: [CGPoint], _ u: Double, _ v: Double) -> CGPoint {
        let top = CGPoint(x: q[0].x + (q[1].x - q[0].x) * u, y: q[0].y + (q[1].y - q[0].y) * u)
        let bot = CGPoint(x: q[3].x + (q[2].x - q[3].x) * u, y: q[3].y + (q[2].y - q[3].y) * u)
        return CGPoint(x: top.x + (bot.x - top.x) * v, y: top.y + (bot.y - top.y) * v)
    }

    /// 24 patch means of a quad whose first corner is the dark-skin corner and whose first edge runs along a 6-patch row.
    /// `margin` is the chart border (fraction of the quad) around the patch grid.
    static func samplePatches(_ px: Pixels, quad q: [CGPoint], margin: Double) -> [SIMD3<Double>] {
        let edge = hypot(Double(q[1].x - q[0].x) * Double(px.width), Double(q[1].y - q[0].y) * Double(px.height))
        let r = max(1, Int(edge / 6 * 0.12))
        var out: [SIMD3<Double>] = []
        for row in 0..<4 {
            for col in 0..<6 {
                let u = margin + (1 - 2 * margin) * (Double(col) + 0.5) / 6
                let v = margin + (1 - 2 * margin) * (Double(row) + 0.5) / 4
                out.append(px.mean(at: point(q, u, v), radius: r))
            }
        }
        return out
    }

    /// Best chart reading of a candidate quad (any corner order): every rotation / mirror, two border margins.
    static func evaluate(_ px: Pixels, quad: [CGPoint]) -> Detection? {
        var best: Detection?
        let orders: [[Int]] = [[0, 1, 2, 3], [1, 2, 3, 0], [2, 3, 0, 1], [3, 0, 1, 2], [1, 0, 3, 2], [0, 3, 2, 1], [3, 2, 1, 0], [2, 1, 0, 3]]
        for o in orders {
            let q = o.map { quad[$0] }
            // the patch rows must run along the longer edge (6 patches) in image pixels
            let e1 = hypot(Double(q[1].x - q[0].x) * Double(px.width), Double(q[1].y - q[0].y) * Double(px.height))
            let e2 = hypot(Double(q[3].x - q[0].x) * Double(px.width), Double(q[3].y - q[0].y) * Double(px.height))
            guard e1 >= e2 * 0.9 else { continue }
            for margin in [0.0, 0.04] {
                let patches = samplePatches(px, quad: q, margin: margin)
                // a chart has a neutral bottom row getting darker left to right
                let neutral = patches[18...23].map { ($0.x + $0.y + $0.z) / 3 }
                guard zip(neutral, neutral.dropFirst()).allSatisfy({ $0.0 > $0.1 - 0.01 }), neutral[0] - neutral[5] > 0.25 else { continue }
                let m = solve(measured: patches)
                let corrected = patches.map { apply(m, $0) }
                let res = rms(corrected, reference)
                if res < (best?.residual ?? .infinity) {
                    best = Detection(corners: q, patches: patches, matrix: m, residual: res, before: rms(patches, reference))
                }
            }
        }
        return best
    }

    /// Finds a ColorChecker 24 in the image (nil when nothing fits well enough).
    public static func detect(in image: CGImage) -> Detection? {
        let px = Pixels(image)
        var quads: [[CGPoint]] = []
        let req = VNDetectRectanglesRequest()
        req.minimumAspectRatio = 0.45; req.maximumAspectRatio = 1
        req.minimumSize = 0.15; req.maximumObservations = 12; req.quadratureTolerance = 25; req.minimumConfidence = 0.4
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        if (try? handler.perform([req])) != nil {
            for r in req.results ?? [] {
                // Vision: bottom-left origin → top-left
                func f(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: 1 - p.y) }
                quads.append([f(r.topLeft), f(r.topRight), f(r.bottomRight), f(r.bottomLeft)])
            }
        }
        // the chart filling the frame
        quads.append([CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)])
        var best: Detection?
        for q in quads { if let d = evaluate(px, quad: q), d.residual < (best?.residual ?? .infinity) { best = d } }
        // a real chart corrects to within a few levels; anything else is not a chart
        guard let b = best, b.residual < 0.06 else { return nil }
        return b
    }

    /// The look LUT for a correction matrix (display-encoded in and out).
    public static func lut(_ m: [Double]) -> LUT {
        var l = LUT.make(size: 33) { c in
            let o = apply(m, SIMD3(Double(c.x), Double(c.y), Double(c.z)))
            return SIMD3<Float>(Float(o.x), Float(o.y), Float(o.z))
        }
        l.title = "Color card"
        return l
    }

    // MARK: Job → one undoable edit

    /// Calibrates `clipID` from the chart in its frame at timeline time `t`.
    public static func calibrate(project p: Project, clipID: ClipID, at t: Time) async throws -> any EditCommand {
        guard let c = p.timeline.clip(clipID), let a = c.mediaID.flatMap(p.asset) else { throw AIToolError.noInput }
        let s = c.sourceTime(at: min(max(t, c.start), c.end - Time(ticks: 1)))
        let frames = try await ColorLooks.frames(a, range: TimeRange(start: s, duration: Time(0.04)), count: 1, maxSize: 1280)
        guard let img = frames.first else { throw AIToolError.noInput }
        guard let d = detect(in: img) else { throw ColorCardError.notFound }
        let id = try ColorLooks.register(ColorLooks.inProjectSpace(lut(d.matrix), p.settings.colorSpace), kind: .card)
        return Edit("cmd.colorCard") { p in try ColorLooks.set(id, kind: .card, strength: 1, on: clipID, in: &p) }
    }
}

public enum ColorCardError: Error, Sendable { case notFound }
