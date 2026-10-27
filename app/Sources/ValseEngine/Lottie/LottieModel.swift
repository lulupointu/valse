import CoreGraphics
import Foundation
import ValseCore

/// A parsed Lottie (Bodymovin JSON) animation — the subset Valse plays for animated stickers and titles (W5, KF-012):
/// shape / solid / null / precomp layers with parenting, layer transforms, groups, rectangles, ellipses, stars and
/// polygons, bezier paths, fills, strokes, linear/radial gradients, trim paths, hold / bezier-eased keyframes
/// (incl. spatial position tangents). Not supported (ignored): masks, mattes, expressions, effects, text and image
/// layers, repeaters, merge paths. Parsing is tolerant: unknown items are skipped.
public final class LottieAnimation: @unchecked Sendable {
    public let width: Double, height: Double
    public let frameRate: Double
    public let inPoint: Double, outPoint: Double
    let layers: [LottieLayer]
    let assets: [String: [LottieLayer]]

    public var duration: Double { max(outPoint - inPoint, 1) / max(frameRate, 1) }

    public init(data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LottieError.invalid }
        width = num(root["w"]) ?? 512; height = num(root["h"]) ?? 512
        frameRate = num(root["fr"]) ?? 30
        inPoint = num(root["ip"]) ?? 0; outPoint = num(root["op"]) ?? 60
        layers = (root["layers"] as? [[String: Any]] ?? []).compactMap(LottieLayer.init)
        var a: [String: [LottieLayer]] = [:]
        for asset in root["assets"] as? [[String: Any]] ?? [] {
            if let id = asset["id"] as? String, let ls = asset["layers"] as? [[String: Any]] { a[id] = ls.compactMap(LottieLayer.init) }
        }
        assets = a
    }

    public convenience init(url: URL) throws { try self.init(data: Data(contentsOf: url)) }

    /// Lottie frame shown at `seconds` after the clip start (loops over [ip, op)).
    public func frame(at seconds: Double) -> Double {
        let span = max(outPoint - inPoint, 1)
        let f = seconds * frameRate
        return inPoint + (f.truncatingRemainder(dividingBy: span) + span).truncatingRemainder(dividingBy: span)
    }
}

public enum LottieError: Error { case invalid }

func num(_ v: Any?) -> Double? {
    if let d = v as? Double { return d }
    if let i = v as? Int { return Double(i) }
    if let n = v as? NSNumber { return n.doubleValue }
    if let a = v as? [Any], let f = a.first { return num(f) }
    return nil
}

func nums(_ v: Any?) -> [Double]? {
    if let a = v as? [Any] { let r = a.compactMap { num($0) }; return r.count == a.count ? r : nil }
    if let d = num(v) { return [d] }
    return nil
}

// MARK: Animated values

/// An animatable property: static or keyframed vector of doubles (scalars are 1-element vectors).
struct LottieValue {
    struct Key {
        var t: Double
        var s: [Double]
        var e: [Double]?
        var hold: Bool
        var o: (x: Double, y: Double), i: (x: Double, y: Double)
        var to: [Double]?, ti: [Double]?
    }
    var constant: [Double]
    var keys: [Key] = []

    init(_ constant: [Double]) { self.constant = constant }

    init?(_ any: Any?, default def: [Double]? = nil) {
        guard let obj = any as? [String: Any] else {
            if let d = def { self.init(d); return }
            return nil
        }
        // separated position {s: true, x: {...}, y: {...}} is handled by the transform parser
        let k = obj["k"]
        let animated = (num(obj["a"]) ?? 0) == 1
        if animated, let arr = k as? [[String: Any]], !arr.isEmpty {
            var keys: [Key] = []
            for kf in arr {
                let t = num(kf["t"]) ?? 0
                let s = nums(kf["s"]) ?? keys.last?.e ?? keys.last?.s ?? []
                func tangent(_ v: Any?) -> (Double, Double) {
                    guard let d = v as? [String: Any] else { return (0.5, 0.5) }
                    return (num(d["x"]) ?? 0.5, num(d["y"]) ?? 0.5)
                }
                keys.append(Key(t: t, s: s, e: nums(kf["e"]), hold: (num(kf["h"]) ?? 0) == 1,
                                o: tangent(kf["o"]), i: tangent(kf["i"]), to: nums(kf["to"]), ti: nums(kf["ti"])))
            }
            self.init(keys.first?.s ?? def ?? [0])
            self.keys = keys
        } else if let v = nums(k) {
            self.init(v)
        } else if let d = def {
            self.init(d)
        } else {
            return nil
        }
    }

    var isAnimated: Bool { keys.count > 1 }

    func value(_ f: Double) -> [Double] {
        guard let first = keys.first else { return constant }
        if keys.count == 1 || f <= first.t { return first.s }
        for j in 0..<(keys.count - 1) {
            let a = keys[j], b = keys[j + 1]
            guard f < b.t else { continue }
            let end = a.e ?? b.s
            if a.hold || b.t <= a.t { return a.s }
            let x = (f - a.t) / (b.t - a.t)
            let p = CubicBezier.solve(x, a.o.x, a.o.y, a.i.x, a.i.y)
            if let to = a.to, let ti = a.ti, to.count == a.s.count, ti.count == a.s.count, a.s.count >= 2,
               to.contains(where: { $0 != 0 }) || ti.contains(where: { $0 != 0 }) {
                // spatial bezier (motion path): s → s+to → e+ti → e
                return (0..<a.s.count).map { d in
                    let p0 = a.s[d], p1 = a.s[d] + to[d], p3 = d < end.count ? end[d] : a.s[d], p2 = p3 + ti[d]
                    let u = 1 - p
                    return u * u * u * p0 + 3 * u * u * p * p1 + 3 * u * p * p * p2 + p * p * p * p3
                }
            }
            return zip(a.s, end).map { $0 + ($1 - $0) * p }
        }
        let last = keys[keys.count - 1]
        return last.s.isEmpty ? (keys[keys.count - 2].e ?? constant) : last.s
    }

    func scalar(_ f: Double) -> Double { value(f).first ?? 0 }
    func point(_ f: Double) -> CGPoint { let v = value(f); return CGPoint(x: v.first ?? 0, y: v.count > 1 ? v[1] : 0) }
}

/// Animatable bezier path (`sh` shapes).
struct LottiePathValue {
    struct Shape { var closed: Bool; var v: [CGPoint]; var i: [CGPoint]; var o: [CGPoint] }
    struct Key { var t: Double; var s: Shape; var hold: Bool; var o: (x: Double, y: Double); var i: (x: Double, y: Double) }
    var keys: [Key]

    init?(_ any: Any?) {
        guard let obj = any as? [String: Any] else { return nil }
        func shape(_ v: Any?) -> Shape? {
            let d = (v as? [String: Any]) ?? ((v as? [Any])?.first as? [String: Any])
            guard let d else { return nil }
            func pts(_ x: Any?) -> [CGPoint] { (x as? [[Any]] ?? []).map { CGPoint(x: num($0.first) ?? 0, y: $0.count > 1 ? num($0[1]) ?? 0 : 0) } }
            return Shape(closed: (d["c"] as? Bool) ?? ((num(d["c"]) ?? 0) == 1), v: pts(d["v"]), i: pts(d["i"]), o: pts(d["o"]))
        }
        if (num(obj["a"]) ?? 0) == 1, let arr = obj["k"] as? [[String: Any]] {
            var ks: [Key] = []
            for kf in arr {
                guard let s = shape(kf["s"]) ?? ks.last?.s else { continue }
                func tangent(_ v: Any?) -> (Double, Double) {
                    guard let d = v as? [String: Any] else { return (0.5, 0.5) }
                    return (num(d["x"]) ?? 0.5, num(d["y"]) ?? 0.5)
                }
                ks.append(Key(t: num(kf["t"]) ?? 0, s: s, hold: (num(kf["h"]) ?? 0) == 1, o: tangent(kf["o"]), i: tangent(kf["i"])))
            }
            guard !ks.isEmpty else { return nil }
            keys = ks
        } else if let s = shape(obj["k"]) {
            keys = [Key(t: 0, s: s, hold: false, o: (0.5, 0.5), i: (0.5, 0.5))]
        } else { return nil }
    }

    func shape(_ f: Double) -> Shape {
        if keys.count == 1 || f <= keys[0].t { return keys[0].s }
        for j in 0..<(keys.count - 1) {
            let a = keys[j], b = keys[j + 1]
            guard f < b.t else { continue }
            if a.hold || a.s.v.count != b.s.v.count { return a.s }
            let p = CubicBezier.solve((f - a.t) / max(b.t - a.t, 1e-9), a.o.x, a.o.y, a.i.x, a.i.y)
            func mix(_ x: [CGPoint], _ y: [CGPoint]) -> [CGPoint] {
                zip(x, y).map { CGPoint(x: $0.x + ($1.x - $0.x) * p, y: $0.y + ($1.y - $0.y) * p) }
            }
            return Shape(closed: a.s.closed, v: mix(a.s.v, b.s.v), i: mix(a.s.i, b.s.i), o: mix(a.s.o, b.s.o))
        }
        return keys[keys.count - 1].s
    }
}

// MARK: Layers and shapes

struct LottieTransform {
    var anchor: LottieValue, position: LottieValue?, posX: LottieValue?, posY: LottieValue?
    var scale: LottieValue, rotation: LottieValue, opacity: LottieValue

    init(_ d: [String: Any]?) {
        let d = d ?? [:]
        anchor = LottieValue(d["a"], default: [0, 0]) ?? LottieValue([0, 0])
        if let p = d["p"] as? [String: Any], (p["s"] as? Bool) == true || (num(p["s"]) ?? 0) == 1 {
            posX = LottieValue(p["x"], default: [0]); posY = LottieValue(p["y"], default: [0]); position = nil
        } else {
            position = LottieValue(d["p"], default: [0, 0]); posX = nil; posY = nil
        }
        scale = LottieValue(d["s"], default: [100, 100]) ?? LottieValue([100, 100])
        rotation = LottieValue(d["r"] ?? d["rz"], default: [0]) ?? LottieValue([0])
        opacity = LottieValue(d["o"], default: [100]) ?? LottieValue([100])
    }

    /// Affine transform (layer → parent space) at frame f: translate(p) · rotate(r) · scale(s) · translate(−a).
    func matrix(_ f: Double) -> CGAffineTransform {
        let a = anchor.point(f)
        let p: CGPoint = position?.point(f) ?? CGPoint(x: posX?.scalar(f) ?? 0, y: posY?.scalar(f) ?? 0)
        let s = scale.value(f)
        let sx = (s.first ?? 100) / 100, sy = (s.count > 1 ? s[1] : s.first ?? 100) / 100
        let r = rotation.scalar(f) * .pi / 180
        return CGAffineTransform(translationX: -a.x, y: -a.y)
            .concatenating(CGAffineTransform(scaleX: sx, y: sy))
            .concatenating(CGAffineTransform(rotationAngle: r))
            .concatenating(CGAffineTransform(translationX: p.x, y: p.y))
    }

    func opacityValue(_ f: Double) -> Double { min(max(opacity.scalar(f) / 100, 0), 1) }
}

indirect enum LottieShape {
    case group([LottieShape], LottieTransform?, hidden: Bool)
    case rect(position: LottieValue, size: LottieValue, roundness: LottieValue, reversed: Bool)
    case ellipse(position: LottieValue, size: LottieValue)
    case star(polygon: Bool, position: LottieValue, points: LottieValue, rotation: LottieValue, outer: LottieValue, inner: LottieValue)
    case path(LottiePathValue)
    case fill(color: LottieValue, opacity: LottieValue, evenOdd: Bool)
    case stroke(color: LottieValue, opacity: LottieValue, width: LottieValue, cap: Int, join: Int)
    case gradient(stroke: Bool, type: Int, stops: Int, colors: LottieValue, start: LottieValue, end: LottieValue,
                  opacity: LottieValue, width: LottieValue?)
    case trim(start: LottieValue, end: LottieValue, offset: LottieValue)

    static func parse(_ d: [String: Any]) -> LottieShape? {
        let hidden = (d["hd"] as? Bool) ?? false
        switch d["ty"] as? String {
        case "gr":
            let items = (d["it"] as? [[String: Any]] ?? [])
            var shapes: [LottieShape] = []
            var tr: LottieTransform?
            for it in items {
                if it["ty"] as? String == "tr" { tr = LottieTransform(it) } else if let s = parse(it) { shapes.append(s) }
            }
            return .group(shapes, tr, hidden: hidden)
        case "rc":
            return hidden ? nil : .rect(position: LottieValue(d["p"], default: [0, 0])!, size: LottieValue(d["s"], default: [100, 100])!,
                                        roundness: LottieValue(d["r"], default: [0])!, reversed: (num(d["d"]) ?? 1) == 3)
        case "el":
            return hidden ? nil : .ellipse(position: LottieValue(d["p"], default: [0, 0])!, size: LottieValue(d["s"], default: [100, 100])!)
        case "sr":
            return hidden ? nil : .star(polygon: (num(d["sy"]) ?? 1) == 2, position: LottieValue(d["p"], default: [0, 0])!,
                                        points: LottieValue(d["pt"], default: [5])!, rotation: LottieValue(d["r"], default: [0])!,
                                        outer: LottieValue(d["or"], default: [50])!, inner: LottieValue(d["ir"], default: [25])!)
        case "sh":
            guard !hidden, let p = LottiePathValue(d["ks"]) else { return nil }
            return .path(p)
        case "fl":
            return hidden ? nil : .fill(color: LottieValue(d["c"], default: [1, 1, 1, 1])!, opacity: LottieValue(d["o"], default: [100])!,
                                        evenOdd: (num(d["r"]) ?? 1) == 2)
        case "st":
            return hidden ? nil : .stroke(color: LottieValue(d["c"], default: [1, 1, 1, 1])!, opacity: LottieValue(d["o"], default: [100])!,
                                          width: LottieValue(d["w"], default: [2])!, cap: Int(num(d["lc"]) ?? 2), join: Int(num(d["lj"]) ?? 2))
        case "gf", "gs":
            let g = d["g"] as? [String: Any]
            return hidden ? nil : .gradient(stroke: d["ty"] as? String == "gs", type: Int(num(d["t"]) ?? 1), stops: Int(num(g?["p"]) ?? 2),
                                            colors: LottieValue(g?["k"], default: [0, 1, 1, 1, 1, 0, 0, 0])!,
                                            start: LottieValue(d["s"], default: [0, 0])!, end: LottieValue(d["e"], default: [100, 0])!,
                                            opacity: LottieValue(d["o"], default: [100])!, width: LottieValue(d["w"]))
        case "tm":
            return hidden ? nil : .trim(start: LottieValue(d["s"], default: [0])!, end: LottieValue(d["e"], default: [100])!,
                                        offset: LottieValue(d["o"], default: [0])!)
        default:
            return nil
        }
    }
}

struct LottieLayer {
    enum Kind { case shape([LottieShape]), solid(color: CGColor, w: Double, h: Double), null, precomp(ref: String) }
    var index: Int?
    var parent: Int?
    var kind: Kind
    var transform: LottieTransform
    var inPoint: Double, outPoint: Double, startTime: Double, stretch: Double
    var hidden: Bool

    init?(_ d: [String: Any]) {
        index = num(d["ind"]).map { Int($0) }
        parent = num(d["parent"]).map { Int($0) }
        transform = LottieTransform(d["ks"] as? [String: Any])
        inPoint = num(d["ip"]) ?? 0; outPoint = num(d["op"]) ?? .greatestFiniteMagnitude
        startTime = num(d["st"]) ?? 0; stretch = num(d["sr"]) ?? 1
        hidden = (d["hd"] as? Bool) ?? false
        switch Int(num(d["ty"]) ?? -1) {
        case 4: kind = .shape((d["shapes"] as? [[String: Any]] ?? []).compactMap(LottieShape.parse))
        case 1:
            let hex = (d["sc"] as? String ?? "#000000").trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            let v = UInt32(hex, radix: 16) ?? 0
            kind = .solid(color: CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                                         blue: CGFloat(v & 0xFF) / 255, alpha: 1),
                          w: num(d["sw"]) ?? 100, h: num(d["sh"]) ?? 100)
        case 3: kind = .null
        case 0: kind = .precomp(ref: d["refId"] as? String ?? "")
        default: return nil   // image, text, audio, camera… not supported
        }
    }
}
