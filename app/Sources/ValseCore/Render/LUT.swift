import Foundation
import simd

public enum LUTError: Error, Sendable, Equatable {
    case empty
    case malformed(line: Int)
    case badSize
    case wrongEntryCount(expected: Int, got: Int)
    public var messageKey: String { "lut.error.invalid" }
}

/// A colour look-up table (CapCut "LUT"): 1D (per channel) or 3D (RGB lattice). Values are RGB triples.
///
/// 3D storage order is the .cube order: red changes fastest, then green, then blue
/// (`index = r + g·N + b·N²`). Parsers for `.cube` (Adobe/Resolve, 1D + 3D) and `.3dl` (Autodesk/Lustre) live here;
/// the engine uploads `baked3D()` as an rgba16Float 3D texture (trilinear, hardware filtering).
public struct LUT: Sendable, Equatable {
    public enum Kind: String, Sendable { case oneD, threeD }
    public var kind: Kind
    public var size: Int
    public var title: String
    public var domainMin: SIMD3<Float>
    public var domainMax: SIMD3<Float>
    /// RGB triples: `size` entries (1D) or `size³` entries (3D).
    public var values: [SIMD3<Float>]

    public init(kind: Kind, size: Int, title: String = "", domainMin: SIMD3<Float> = .zero,
                domainMax: SIMD3<Float> = .one, values: [SIMD3<Float>]) {
        self.kind = kind; self.size = size; self.title = title
        self.domainMin = domainMin; self.domainMax = domainMax; self.values = values
    }

    /// Identity 3D LUT (tests, "None" previews).
    public static func identity(size: Int = 17) -> LUT {
        var v: [SIMD3<Float>] = []
        v.reserveCapacity(size * size * size)
        let k = Float(size - 1)
        for b in 0..<size { for g in 0..<size { for r in 0..<size { v.append(SIMD3(Float(r) / k, Float(g) / k, Float(b) / k)) } } }
        return LUT(kind: .threeD, size: size, values: v)
    }

    /// Builds a 3D LUT from a function (tests, generated looks).
    public static func make(size: Int = 17, _ f: (SIMD3<Float>) -> SIMD3<Float>) -> LUT {
        var l = identity(size: size)
        l.values = l.values.map(f)
        return l
    }

    // MARK: Evaluation (CPU reference, matches the GPU path)

    /// Applies the LUT to an RGB value in [0,1] (trilinear for 3D, linear for 1D).
    public func apply(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let span = simd_max(domainMax - domainMin, SIMD3(repeating: 1e-6))
        let x = simd_clamp((c - domainMin) / span, .zero, .one)
        switch kind {
        case .oneD:
            func ch(_ v: Float, _ i: Int) -> Float {
                let p = v * Float(size - 1)
                let i0 = min(Int(p), size - 1), i1 = min(i0 + 1, size - 1)
                let t = p - Float(i0)
                return values[i0][i] * (1 - t) + values[i1][i] * t
            }
            return SIMD3(ch(x.x, 0), ch(x.y, 1), ch(x.z, 2))
        case .threeD:
            let n = size
            let p = x * Float(n - 1)
            let i0 = SIMD3<Int>(min(Int(p.x), n - 1), min(Int(p.y), n - 1), min(Int(p.z), n - 1))
            let i1 = SIMD3<Int>(min(i0.x + 1, n - 1), min(i0.y + 1, n - 1), min(i0.z + 1, n - 1))
            let t = p - SIMD3<Float>(Float(i0.x), Float(i0.y), Float(i0.z))
            func at(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Float> { values[r + g * n + b * n * n] }
            let c00 = at(i0.x, i0.y, i0.z) * (1 - t.x) + at(i1.x, i0.y, i0.z) * t.x
            let c10 = at(i0.x, i1.y, i0.z) * (1 - t.x) + at(i1.x, i1.y, i0.z) * t.x
            let c01 = at(i0.x, i0.y, i1.z) * (1 - t.x) + at(i1.x, i0.y, i1.z) * t.x
            let c11 = at(i0.x, i1.y, i1.z) * (1 - t.x) + at(i1.x, i1.y, i1.z) * t.x
            let c0 = c00 * (1 - t.y) + c10 * t.y
            let c1 = c01 * (1 - t.y) + c11 * t.y
            return c0 * (1 - t.z) + c1 * t.z
        }
    }

    /// 3D lattice over the [0,1] domain (1D LUTs and non-default domains are resampled). Ready for GPU upload.
    public func baked3D(size bakeSize: Int = 33) -> LUT {
        if kind == .threeD, domainMin == .zero, domainMax == .one { return self }
        let n = kind == .threeD ? size : bakeSize
        return LUT.make(size: n) { apply($0) }.with(title: title)
    }

    func with(title: String) -> LUT { var l = self; l.title = title; return l }

    // MARK: Parsing

    /// Parses by file extension (`cube` or `3dl`).
    public static func load(_ url: URL) throws -> LUT {
        let text = try String(contentsOf: url, encoding: .utf8)
        var lut = url.pathExtension.lowercased() == "3dl" ? try parse3DL(text) : try parseCube(text)
        if lut.title.isEmpty { lut.title = url.deletingPathExtension().lastPathComponent }
        return lut
    }

    /// Adobe / Resolve `.cube` (LUT_1D_SIZE or LUT_3D_SIZE, optional TITLE, DOMAIN_MIN/MAX, comments with #).
    public static func parseCube(_ text: String) throws -> LUT {
        var title = "", size3 = 0, size1 = 0
        var dmin = SIMD3<Float>(0, 0, 0), dmax = SIMD3<Float>(1, 1, 1)
        var values: [SIMD3<Float>] = []
        for (n, raw) in text.split(whereSeparator: \.isNewline).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let head = parts.first else { continue }
            func triple() throws -> SIMD3<Float> {
                let f = parts.dropFirst().compactMap { Float($0) }
                guard f.count == 3 else { throw LUTError.malformed(line: n + 1) }
                return SIMD3(f[0], f[1], f[2])
            }
            switch head.uppercased() {
            case "TITLE":
                title = line.dropFirst(5).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            case "LUT_3D_SIZE": size3 = Int(parts.dropFirst().first ?? "") ?? 0
            case "LUT_1D_SIZE": size1 = Int(parts.dropFirst().first ?? "") ?? 0
            case "DOMAIN_MIN": dmin = try triple()
            case "DOMAIN_MAX": dmax = try triple()
            case "LUT_3D_INPUT_RANGE", "LUT_1D_INPUT_RANGE":
                let f = parts.dropFirst().compactMap { Float($0) }
                guard f.count == 2 else { throw LUTError.malformed(line: n + 1) }
                dmin = SIMD3(repeating: f[0]); dmax = SIMD3(repeating: f[1])
            default:
                let f = parts.compactMap { Float($0) }
                guard f.count == 3, parts.count == 3 else {
                    // Unknown keywords are ignored (spec allows vendor extensions); stray numbers are errors.
                    if Float(head) != nil { throw LUTError.malformed(line: n + 1) }
                    continue
                }
                values.append(SIMD3(f[0], f[1], f[2]))
            }
        }
        guard !values.isEmpty else { throw LUTError.empty }
        if size3 > 0 {
            guard size3 >= 2, size3 <= 256 else { throw LUTError.badSize }
            guard values.count == size3 * size3 * size3 else { throw LUTError.wrongEntryCount(expected: size3 * size3 * size3, got: values.count) }
            return LUT(kind: .threeD, size: size3, title: title, domainMin: dmin, domainMax: dmax, values: values)
        }
        guard size1 >= 2, size1 <= 65536 else { throw LUTError.badSize }
        guard values.count == size1 else { throw LUTError.wrongEntryCount(expected: size1, got: values.count) }
        return LUT(kind: .oneD, size: size1, title: title, domainMin: dmin, domainMax: dmax, values: values)
    }

    /// Autodesk `.3dl`: a first line of N input mesh points (e.g. `0 64 … 1023`), then N³ integer triples with
    /// BLUE changing fastest. Output bit depth is inferred from the largest value (10/12/14/16-bit).
    public static func parse3DL(_ text: String) throws -> LUT {
        var mesh: [Float]?
        var rows: [SIMD3<Float>] = []
        for (n, raw) in text.split(whereSeparator: \.isNewline).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.first.map({ Float($0) == nil }) ?? true { continue }  // keywords such as "3DMESH", "Mesh 4 12"
            let f = parts.compactMap { Float($0) }
            guard f.count == parts.count else { throw LUTError.malformed(line: n + 1) }
            if mesh == nil, rows.isEmpty, f.count != 3 { mesh = f; continue }
            guard f.count == 3 else { throw LUTError.malformed(line: n + 1) }
            rows.append(SIMD3(f[0], f[1], f[2]))
        }
        guard !rows.isEmpty else { throw LUTError.empty }
        let n = mesh?.count ?? Int(round(cbrt(Double(rows.count))))
        guard n >= 2 else { throw LUTError.badSize }
        guard rows.count == n * n * n else { throw LUTError.wrongEntryCount(expected: n * n * n, got: rows.count) }
        let peak = rows.reduce(Float(0)) { max($0, $1.max()) }
        let scale: Float = peak <= 1.0 ? 1 : (peak < 1024 ? 1023 : (peak < 4096 ? 4095 : (peak < 16384 ? 16383 : 65535)))
        var values = [SIMD3<Float>](repeating: .zero, count: n * n * n)
        // 3dl index: b + g·N + r·N² → cube index: r + g·N + b·N²
        for r in 0..<n { for g in 0..<n { for b in 0..<n {
            values[r + g * n + b * n * n] = rows[b + g * n + r * n * n] / scale
        } } }
        return LUT(kind: .threeD, size: n, values: values)
    }

    /// Serializes as a `.cube` file (library storage of imported .3dl / generated LUTs).
    public func cubeText() -> String {
        var s = "TITLE \"\(title)\"\n"
        s += kind == .threeD ? "LUT_3D_SIZE \(size)\n" : "LUT_1D_SIZE \(size)\n"
        if domainMin != .zero { s += "DOMAIN_MIN \(domainMin.x) \(domainMin.y) \(domainMin.z)\n" }
        if domainMax != .one { s += "DOMAIN_MAX \(domainMax.x) \(domainMax.y) \(domainMax.z)\n" }
        for v in values { s += String(format: "%.6f %.6f %.6f\n", v.x, v.y, v.z) }
        return s
    }
}
