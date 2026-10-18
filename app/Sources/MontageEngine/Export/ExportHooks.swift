@preconcurrency import AVFoundation
import Accelerate
import Foundation
import MontageCore

/// Export-time extensions installed by higher modules (the engine can't depend on MontageAI).
public enum ExportHooks {
    /// EX-018 "AI ultra HD": returns `project` with the clips listed by `clipsNeedingUpscale` pointed at super-resolved
    /// copies of their media (progress 0…1). Installed by MontageAI (`AIEngineHooks.install`); nil = switch is a no-op.
    public typealias SuperResolve = @Sendable (Project, ExportSettings, TimeRange?, @escaping @Sendable (Double) -> Void) async throws -> Project
    public static var superResolve: SuperResolve? {
        get { lock.withLock { _superResolve } }
        set { lock.withLock { _superResolve = newValue } }
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _superResolve: SuperResolve?

    /// Minimum enlargement (displayed export pixels ÷ source pixels) before a clip is worth super-resolving.
    public static let upscaleThreshold = 1.25

    /// Video clips (visible tracks, enabled, inside `range`) shown larger than their source at the export resolution,
    /// with the needed enlargement factor. Clips already enhanced with an upscale are skipped.
    public static func clipsNeedingUpscale(_ p: Project, settings: ExportSettings, range: TimeRange? = nil) -> [(clip: ClipID, factor: Double)] {
        let canvas = p.settings.canvasSize
        let (w, _) = settings.outputSize(canvas: canvas)
        let outScale = Double(w) / max(canvas.width, 1)
        var out: [(ClipID, Double)] = []
        for t in p.timeline.tracks where t.kind == .video && !t.isHidden {
            for c in t.clips where c.isEnabled && c.enhance?.upscale == nil {
                if let r = range, c.end <= r.start || c.start >= r.end { continue }
                guard case .media(let id) = c.content, let a = p.asset(id), a.kind == .video else { continue }
                var src = a.pixelSize
                if a.sourceRotation % 180 != 0 { src = Size2(src.height, src.width) }
                guard src.width > 0, src.height > 0 else { continue }
                var scale = Vec2(abs(c.transform.scale.x), abs(c.transform.scale.y))
                for k in c.keyframes[ParamKey.scale.raw]?.keyframes ?? [] {
                    if let v = k.value.vec2 { scale = Vec2(max(scale.x, abs(v.x)), max(scale.y, abs(v.y))) }
                }
                var tr = c.transform; tr.scale = scale
                let g = LayerGeometry(sourceSize: src, canvasSize: canvas, transform: tr, crop: c.crop)
                let crop = c.crop
                let shownW = 2 * abs(g.halfSize.x) * outScale, shownH = 2 * abs(g.halfSize.y) * outScale
                let k = min(shownW / max(src.width * (1 - crop.left - crop.right), 1), shownH / max(src.height * (1 - crop.top - crop.bottom), 1))
                if k >= upscaleThreshold { out.append((c.id, k)) }
            }
        }
        return out
    }
}

/// EX-025: averages groups of sub-frames into one output frame, in place in the first pixel buffer of the group.
/// Works on the export's read formats (8-bit BGRA, 10-bit 4:2:0 bi-planar, 16-bit half RGBA): each plane is a grid of
/// UInt8 / UInt16 / Float16 elements averaged element-wise (linear in the encoded values, like a camera shutter on
/// the graded image).
final class FrameAccumulator {
    private var acc: [[Float]] = []
    private(set) var count = 0
    private var tmp: [Float] = []

    enum Element { case u8, u16, f16 }

    static func element(_ pb: CVPixelBuffer) -> Element? {
        switch CVPixelBufferGetPixelFormatType(pb) {
        case kCVPixelFormatType_32BGRA, kCVPixelFormatType_32RGBA, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: return .u8
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_64ARGB, kCVPixelFormatType_64RGBALE: return .u16
        case kCVPixelFormatType_64RGBAHalf: return .f16
        default: return nil
        }
    }

    /// Planes as (base, rows, bytesPerRow, elements per row).
    private static func planes(_ pb: CVPixelBuffer, _ e: Element) -> [(UnsafeMutableRawPointer, Int, Int, Int)] {
        let size = e == .u8 ? 1 : 2
        if CVPixelBufferIsPlanar(pb) {
            return (0..<CVPixelBufferGetPlaneCount(pb)).compactMap { i in
                guard let b = CVPixelBufferGetBaseAddressOfPlane(pb, i) else { return nil }
                let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, i)
                let w = CVPixelBufferGetWidthOfPlane(pb, i)
                let comps = i == 0 ? 1 : 2   // Y, then interleaved CbCr
                guard w * comps * size <= bpr else { return nil }
                return (b, CVPixelBufferGetHeightOfPlane(pb, i), bpr, w * comps)
            }
        }
        guard let b = CVPixelBufferGetBaseAddress(pb) else { return [] }
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let n = CVPixelBufferGetWidth(pb) * 4   // 4 components per pixel
        guard n * size <= bpr else { return [] }
        return [(b, CVPixelBufferGetHeight(pb), bpr, n)]
    }

    /// Adds a sub-frame. Returns false for an unsupported format (the caller then passes frames through).
    func add(_ pb: CVPixelBuffer) -> Bool {
        guard let e = Self.element(pb) else { return false }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let ps = Self.planes(pb, e)
        if acc.count != ps.count { acc = ps.map { [Float](repeating: 0, count: $0.1 * $0.3) } }
        for (pi, (base, rows, bpr, n)) in ps.enumerated() {
            if tmp.count < n { tmp = [Float](repeating: 0, count: n) }
            acc[pi].withUnsafeMutableBufferPointer { a in
                tmp.withUnsafeMutableBufferPointer { t in
                    for r in 0..<rows {
                        let row = base + r * bpr
                        switch e {
                        case .u8: vDSP_vfltu8(row.assumingMemoryBound(to: UInt8.self), 1, t.baseAddress!, 1, vDSP_Length(n))
                        case .u16: vDSP_vfltu16(row.assumingMemoryBound(to: UInt16.self), 1, t.baseAddress!, 1, vDSP_Length(n))
                        case .f16:
                            let h = row.assumingMemoryBound(to: Float16.self)
                            for i in 0..<n { t[i] = Float(h[i]) }
                        }
                        let dst = a.baseAddress! + r * n
                        vDSP_vadd(dst, 1, t.baseAddress!, 1, dst, 1, vDSP_Length(n))
                    }
                }
            }
        }
        count += 1
        return true
    }

    /// Writes the average into `pb` (same format/size as the added frames) and resets.
    func write(into pb: CVPixelBuffer) {
        guard count > 0, let e = Self.element(pb) else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []); reset() }
        var k = 1 / Float(count)
        for (pi, (base, rows, bpr, n)) in Self.planes(pb, e).enumerated() where pi < acc.count {
            acc[pi].withUnsafeMutableBufferPointer { a in
                vDSP_vsmul(a.baseAddress!, 1, &k, a.baseAddress!, 1, vDSP_Length(rows * n))
                for r in 0..<rows {
                    let row = base + r * bpr, src = a.baseAddress! + r * n
                    switch e {
                    case .u8: vDSP_vfixru8(src, 1, row.assumingMemoryBound(to: UInt8.self), 1, vDSP_Length(n))
                    case .u16: vDSP_vfixru16(src, 1, row.assumingMemoryBound(to: UInt16.self), 1, vDSP_Length(n))
                    case .f16:
                        let h = row.assumingMemoryBound(to: Float16.self)
                        for i in 0..<n { h[i] = Float16(src[i]) }
                    }
                }
            }
        }
    }

    func reset() {
        count = 0
        for i in acc.indices { acc[i].withUnsafeMutableBufferPointer { vDSP_vclr($0.baseAddress!, 1, vDSP_Length($0.count)) } }
    }
}
