import Foundation

/// Crop window → source mapping with rotation inside the crop (CV-006 crop dialog). Coordinates are normalized display
/// uv (0…1, y down); `aspect` = source width / height in display pixels (rotation happens in square pixels).
public enum CropGeometry {
    /// Zoom factor (≤ 1) applied to the sampled window so the rotated window stays inside the source (no empty corners).
    public static func fitZoom(_ c: CropRect, aspect: Double) -> Double {
        let deg = c.rotation ?? 0
        guard deg != 0 else { return 1 }
        let A = max(aspect, 1e-6)
        let cx = (c.left + 1 - c.right) / 2 * A, cy = (c.top + 1 - c.bottom) / 2
        let hw = (1 - c.left - c.right) / 2 * A, hh = (1 - c.top - c.bottom) / 2
        guard hw > 0, hh > 0 else { return 1 }
        let t = -deg * .pi / 180, co = cos(t), si = sin(t)
        var s = 1.0
        for (ox, oy) in [(hw, hh), (-hw, hh), (hw, -hh), (-hw, -hh)] {
            let rx = co * ox - si * oy, ry = si * ox + co * oy
            if rx > 1e-12 { s = min(s, (A - cx) / rx) } else if rx < -1e-12 { s = min(s, cx / -rx) }
            if ry > 1e-12 { s = min(s, (1 - cy) / ry) } else if ry < -1e-12 { s = min(s, cy / -ry) }
        }
        return max(min(s, 1), 0.01)
    }

    /// Affine (a, b, c, d, tx, ty) mapping crop-window uv → source uv: p' = (a·x + c·y + tx, b·x + d·y + ty).
    public static func affine(_ c: CropRect, aspect: Double) -> (a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        let w = 1 - c.left - c.right, h = 1 - c.top - c.bottom
        let deg = c.rotation ?? 0
        guard deg != 0 else { return (w, 0, 0, h, c.left, c.top) }
        let A = max(aspect, 1e-6)
        let s = fitZoom(c, aspect: aspect)
        let t = -deg * .pi / 180, co = cos(t), si = sin(t)
        let cx = c.left + w / 2, cy = c.top + h / 2
        // offset in square px: o = ((x − ½)·w·A, (y − ½)·h); o' = s·R·o; source = (cx + o'x / A, cy + o'y)
        let a = s * co * w, cc = -s * si * h / A
        let b = s * si * w * A, d = s * co * h
        let tx = cx - 0.5 * (a + cc), ty = cy - 0.5 * (b + d)
        return (a, b, cc, d, tx, ty)
    }

    /// Source-uv corners of the sampled window (TL, TR, BR, BL), for drawing / tests.
    public static func sampledCorners(_ c: CropRect, aspect: Double) -> [(Double, Double)] {
        let m = affine(c, aspect: aspect)
        return [(0, 0), (1, 0), (1, 1), (0, 1)].map { (x, y) in (m.a * x + m.c * y + m.tx, m.b * x + m.d * y + m.ty) }
    }
}
