import Testing
import Foundation
import ValseCore
import ValseEngine
import ValseTestSupport

/// Every blend mode against a CPU reference, and the heart/star mask shapes (W6).
@Suite(.serialized) struct BlendMaskTests {
    static func ch(_ m: BlendMode, _ b: Double, _ s: Double) -> Double {
        switch m {
        case .normal: return s
        case .darken: return min(b, s)
        case .multiply: return b * s
        case .colorBurn: return b >= 1 ? 1 : (s <= 0 ? 0 : 1 - min(1, (1 - b) / s))
        case .lighten: return max(b, s)
        case .screen: return b + s - b * s
        case .colorDodge: return b <= 0 ? 0 : (s >= 1 ? 1 : min(1, b / (1 - s)))
        case .add, .linearDodge: return min(1, b + s)
        case .overlay: return b <= 0.5 ? 2 * b * s : 1 - 2 * (1 - b) * (1 - s)
        case .softLight:
            let d = b <= 0.25 ? ((16 * b - 12) * b + 4) * b : b.squareRoot()
            return s <= 0.5 ? b - (1 - 2 * s) * b * (1 - b) : b + (2 * s - 1) * (d - b)
        case .hardLight: return s <= 0.5 ? 2 * b * s : 1 - 2 * (1 - b) * (1 - s)
        case .difference: return abs(b - s)
        case .exclusion: return b + s - 2 * b * s
        case .linearBurn: return max(0, b + s - 1)
        case .vividLight: return s <= 0.5 ? (s <= 0 ? 0 : max(0, 1 - (1 - b) / (2 * s))) : (s >= 1 ? 1 : min(1, b / (2 * (1 - s))))
        case .linearLight: return min(max(b + 2 * s - 1, 0), 1)
        case .pinLight: return s <= 0.5 ? min(b, 2 * s) : max(b, 2 * s - 1)
        case .hardMix: return b + s >= 1 ? 1 : 0
        case .subtract: return max(0, b - s)
        case .divide: return s <= 0 ? 1 : min(1, b / s)
        default: return .nan
        }
    }

    static func lum(_ c: RGBA) -> Double { 0.3 * c.r + 0.59 * c.g + 0.11 * c.b }
    static func clip(_ c: RGBA) -> RGBA {
        let l = lum(c), n = min(c.r, c.g, c.b), x = max(c.r, c.g, c.b)
        var o = c
        if n < 0 { o = RGBA(l + (o.r - l) * l / (l - n), l + (o.g - l) * l / (l - n), l + (o.b - l) * l / (l - n)) }
        if x > 1 { o = RGBA(l + (o.r - l) * (1 - l) / (x - l), l + (o.g - l) * (1 - l) / (x - l), l + (o.b - l) * (1 - l) / (x - l)) }
        return o
    }
    static func setLum(_ c: RGBA, _ l: Double) -> RGBA { let d = l - lum(c); return clip(RGBA(c.r + d, c.g + d, c.b + d)) }
    static func sat(_ c: RGBA) -> Double { max(c.r, c.g, c.b) - min(c.r, c.g, c.b) }
    static func setSat(_ c: RGBA, _ s: Double) -> RGBA {
        let mn = min(c.r, c.g, c.b), mx = max(c.r, c.g, c.b)
        guard mx > mn else { return RGBA(0, 0, 0) }
        return RGBA((c.r - mn) * s / (mx - mn), (c.g - mn) * s / (mx - mn), (c.b - mn) * s / (mx - mn))
    }

    static func reference(_ m: BlendMode, _ b: RGBA, _ s: RGBA) -> RGBA {
        switch m {
        case .hue: return setLum(setSat(s, sat(b)), lum(b))
        case .saturation: return setLum(setSat(b, sat(s)), lum(b))
        case .color: return setLum(s, lum(b))
        case .luminosity: return setLum(b, lum(s))
        case .darkerColor: return lum(s) < lum(b) ? s : b
        case .lighterColor: return lum(s) > lum(b) ? s : b
        default: return RGBA(ch(m, b.r, s.r), ch(m, b.g, s.g), ch(m, b.b, s.b))
        }
    }

    @Test(arguments: BlendMode.allCases)
    func blendModeMatchesReference(_ mode: BlendMode) async throws {
        for (b, s) in [(RGBA(0.2, 0.5, 0.8), RGBA(0.7, 0.3, 0.4)), (RGBA(0.8, 0.6, 0.1), RGBA(0.4, 0.9, 0.5))] {
            var p = TestProject()
            try p.addSolid(b)
            let o = try p.addSolid(s)
            p[o].blendMode = mode
            let got = try await p.render(at: 0.5)[0.5, 0.5]
            let want = Self.reference(mode, b, s)
            #expect(got.isClose(to: want, tolerance: 0.03), "\(mode): got \(got) want \(want)")
        }
    }

    @Test func heartAndStarMasks() async throws {
        for shape in [MaskShape.heart, .star] {
            var p = TestProject(canvas: Size2(320, 320), background: .black)
            let id = try p.addSolid(.white)
            p[id].mask = Mask(shape: shape, size: Vec2(0.8, 0.8))
            let img = try await p.render(at: 0.5)
            #expect(img[0.5, 0.5].isClose(to: .white), "\(shape) centre")
            #expect(img[0.12, 0.88].isClose(to: .black), "\(shape) bottom-left corner")
            #expect(img[0.88, 0.88].isClose(to: .black), "\(shape) bottom-right corner")
            if shape == .heart {
                #expect(img[0.5, 0.17].isClose(to: .black), "heart notch between the lobes")
                #expect(img[0.3, 0.3].isClose(to: .white), "heart left lobe")
            } else {
                #expect(img[0.5, 0.15].isClose(to: .white), "star top tip")
                #expect(img[0.5, 0.82].isClose(to: .black), "star gap between the bottom arms")
            }
        }
    }

    @Test func maskFeatherIsSmoothAndMonotonic() async throws {
        var p = TestProject(background: .black)
        let id = try p.addSolid(.white)
        p[id].mask = Mask(shape: .linear, feather: 0.6)
        let img = try await p.render(at: 0.5)
        var prev = 2.0
        for y in stride(from: 0.3, through: 0.7, by: 0.05) {
            let v = img[0.5, y].luma
            #expect(v <= prev + 0.01)
            prev = v
        }
        #expect(img[0.5, 0.5].luma > 0.3 && img[0.5, 0.5].luma < 0.7)
    }
}
