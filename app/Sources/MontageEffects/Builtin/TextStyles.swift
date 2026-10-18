import Foundation
import MontageCore

/// Text style presets (Text ▸ Basic preset row, TX-003) and the word-art "Text effects" library (TX-012).
/// CapCut ships hundreds of downloadable presets; ours are parameter sets of the procedural text style engine, generated
/// from colour palettes × outline / glow / shadow / gradient / label / 3D / texture recipes (FEATURES.md §21).
public enum BuiltinTextStyles {
    public typealias D = TextStyleDescriptor

    // MARK: Palette

    public static let palette: [(name: String, color: RGBA)] = [
        ("white", .white), ("black", RGBA(hex: 0x111111)), ("yellow", RGBA(hex: 0xFFD400)), ("red", RGBA(hex: 0xFF3B30)),
        ("orange", RGBA(hex: 0xFF8A00)), ("pink", RGBA(hex: 0xFF4FA3)), ("purple", RGBA(hex: 0x9B5CFF)),
        ("blue", RGBA(hex: 0x2F80FF)), ("cyan", RGBA(hex: 0x1ED3E6)), ("green", RGBA(hex: 0x34C759)),
        ("lime", RGBA(hex: 0xB6F23A)), ("gold", RGBA(hex: 0xE8B33A)),
    ]
    static func c(_ i: Int) -> RGBA { palette[i % palette.count].color }
    static let white = RGBA.white, black = RGBA(hex: 0x111111)

    public static let gradients: [[RGBA]] = [
        [RGBA(hex: 0xFF5F6D), RGBA(hex: 0xFFC371)], [RGBA(hex: 0x2193B0), RGBA(hex: 0x6DD5ED)],
        [RGBA(hex: 0x8E2DE2), RGBA(hex: 0x4A00E0)], [RGBA(hex: 0xF12711), RGBA(hex: 0xF5AF19)],
        [RGBA(hex: 0x00B09B), RGBA(hex: 0x96C93D)], [RGBA(hex: 0xFF6FD8), RGBA(hex: 0x3813C2)],
        [RGBA(hex: 0xF7E09A), RGBA(hex: 0xC68B2C)], [RGBA(hex: 0xE0F7FF), RGBA(hex: 0x7FB2FF)],
        [RGBA(hex: 0xFF0000), RGBA(hex: 0xFFA500), RGBA(hex: 0xFFFF00), RGBA(hex: 0x00C853), RGBA(hex: 0x2979FF), RGBA(hex: 0xAA00FF)],
        [RGBA(hex: 0xFFB88C), RGBA(hex: 0xDE6262)], [RGBA(hex: 0xD4FC79), RGBA(hex: 0x96E6A1)],
        [RGBA(hex: 0x00F5A0), RGBA(hex: 0x00D9F5)], [RGBA(hex: 0xFFFFFF), RGBA(hex: 0x9E9E9E), RGBA(hex: 0xFFFFFF), RGBA(hex: 0x6E6E6E)],
        [RGBA(hex: 0xF4C4F3), RGBA(hex: 0xFC67FA)], [RGBA(hex: 0x134E5E), RGBA(hex: 0x71B280)], [RGBA(hex: 0xFDFC47), RGBA(hex: 0x24FE41)],
    ]

    /// Procedural fill textures the engine knows how to draw (`TextTexture.id`).
    public static let textures = ["gold", "silver", "holo", "stripes", "dots", "checker", "marble", "sparkle"]

    // MARK: Basic preset row (CapCut's ~20 "Aa" tiles)

    static func preset(_ name: String, _ body: @escaping @Sendable (inout TextContent) -> Void) -> D {
        D(id: "montage.text.\(name)", nameKey: "textStyle.\(name)", groupKey: "textStyle.group.basic", kind: .preset, apply: body)
    }

    static let basics: [D] = [
        preset("default") { _ in },
        preset("outline") { t in t.color = .white; t.strokeColor = .black; t.strokeWidth = 0.12; t.bold = true },
        preset("thickOutline") { t in t.color = .white; t.strokeColor = .black; t.strokeWidth = 0.2; t.bold = true },
        preset("shadow") { t in t.color = .white; t.shadowColor = RGBA(0, 0, 0, 0.8) },
        preset("softGlow") { t in t.color = .white; t.bold = true; t.glow = TextGlowStyle(color: .black, intensity: 0.9, radius: 0.25) },
        preset("yellow") { t in t.color = RGBA(hex: 0xFFD400); t.strokeColor = .black; t.strokeWidth = 0.1; t.bold = true },
        preset("redWhite") { t in t.color = RGBA(hex: 0xE53935); t.strokeColor = .white; t.strokeWidth = 0.1; t.bold = true },
        preset("orangeWhite") { t in t.color = RGBA(hex: 0xFF8A00); t.strokeColor = .white; t.strokeWidth = 0.1; t.bold = true },
        preset("blueWhite") { t in t.color = RGBA(hex: 0x2F80FF); t.strokeColor = .white; t.strokeWidth = 0.1; t.bold = true },
        preset("greenBlack") { t in t.color = RGBA(hex: 0x6CF04A); t.strokeColor = .black; t.strokeWidth = 0.1; t.bold = true },
        preset("box") { t in t.color = .black; t.backgroundColor = .white; t.bold = true },
        preset("darkLabel") { t in t.color = .white; t.backgroundColor = RGBA(0, 0, 0, 0.6); t.background.mode = .line },
        preset("yellowBox") { t in t.color = .black; t.backgroundColor = RGBA(hex: 0xFFD400); t.bold = true },
        preset("purpleBox") { t in t.color = .white; t.backgroundColor = RGBA(hex: 0x7B2FF7); t.bold = true },
        preset("silver") { t in t.fill = .gradient(TextGradient([.white, RGBA(hex: 0x8A8A8A)], angle: 90)); t.bold = true; t.shadowColor = RGBA(0, 0, 0, 0.5) },
        preset("chrome") { t in t.fill = .gradient(TextGradient(gradients[12], angle: 90)); t.strokeColor = RGBA(hex: 0x333333); t.strokeWidth = 0.05; t.bold = true },
        preset("neonGreen") { t in t.color = RGBA(hex: 0xD8FFD0); t.glow = TextGlowStyle(color: RGBA(hex: 0x2CFF4A), intensity: 1, radius: 0.3); t.bold = true },
        preset("neonPink") { t in t.color = RGBA(hex: 0xFFE0F2); t.glow = TextGlowStyle(color: RGBA(hex: 0xFF2E9A), intensity: 1, radius: 0.3); t.bold = true },
        preset("retro") { t in
            t.color = RGBA(hex: 0xFFE14D); t.shadowColor = RGBA(hex: 0xE5406A); t.shadow = TextShadowStyle(distance: 0.12, angle: 45, blur: 0, extrude: true)
            t.bold = true
        },
        preset("gold") { t in t.fill = .texture(TextTexture(id: "gold")); t.strokeColor = RGBA(hex: 0x5A3A00); t.strokeWidth = 0.05; t.bold = true },
    ]

    // MARK: Word-art families

    static func fx(_ family: String, _ n: Int, _ body: @escaping @Sendable (inout TextContent) -> Void) -> D {
        D(id: "montage.textfx.\(family).\(n)", nameKey: "textStyle.fx.\(family)", groupKey: "textStyle.group.\(family)",
          kind: .effect, number: n, apply: { t in t.bold = true; body(&t) })
    }

    /// Fill colour × outline (thin dark, thick white, thick matching dark).
    static let outlines: [D] = (0..<36).map { i in
        let fill = c(i % 12), variant = i / 12
        return fx("outline", i + 1) { t in
            t.color = fill
            switch variant {
            case 0: t.strokeColor = fill == white ? black : black; t.strokeWidth = 0.08
            case 1: t.strokeColor = fill == white ? black : .white; t.strokeWidth = 0.16
            default: t.strokeColor = fill.mix(.black, 0.6); t.strokeWidth = 0.14; t.shadowColor = RGBA(0, 0, 0, 0.6)
            }
        }
    }

    /// Neon: white-hot core + coloured glow, or coloured text + white glow.
    static let neons: [D] = (0..<24).map { i in
        let col = c(i % 12 == 1 ? 8 : i % 12), variant = i / 12
        return fx("neon", i + 1) { t in
            if variant == 0 {
                t.color = col.mix(.white, 0.75); t.glow = TextGlowStyle(color: col, intensity: 1, radius: 0.35, mode: .outer)
            } else {
                t.color = col; t.glow = TextGlowStyle(color: col.mix(.white, 0.4), intensity: 0.8, radius: 0.22, mode: .both)
                t.strokeColor = col.mix(.white, 0.8); t.strokeWidth = 0.03
            }
        }
    }

    /// Shadows: soft drop, hard offset, long 3D extrusion.
    static let shadows: [D] = (0..<24).map { i in
        let col = c(i % 12), variant = i / 8
        return fx("shadow", i + 1) { t in
            t.color = col == black ? .white : col
            switch variant {
            case 0: t.shadowColor = RGBA(0, 0, 0, 0.85); t.shadow = TextShadowStyle(distance: 0.08, angle: 60, blur: 0.18)
            case 1: t.shadowColor = (col == black ? white : black).mix(col, 0.15); t.shadow = TextShadowStyle(distance: 0.1, angle: 45, blur: 0)
                t.strokeColor = black; t.strokeWidth = 0.05
            default: t.shadowColor = col.mix(.black, 0.55); t.shadow = TextShadowStyle(distance: 0.16, angle: 45, blur: 0, extrude: true)
                t.strokeColor = .white; t.strokeWidth = 0.04
            }
        }
    }

    /// Gradient fills (with and without a white outline).
    static let gradientStyles: [D] = (0..<32).map { i in
        let g = gradients[i % gradients.count], outlined = i >= gradients.count
        return fx("gradient", i + 1) { t in
            t.fill = .gradient(TextGradient(g, angle: i % 3 == 0 ? 0 : 90))
            t.color = g[0]
            if outlined { t.strokeColor = .white; t.strokeWidth = 0.1; t.shadowColor = RGBA(0, 0, 0, 0.5) }
        }
    }

    /// Labels: rounded / square / per-line / per-letter boxes.
    static let labels: [D] = (0..<36).map { i in
        let bg = c(i % 12), variant = i / 12
        return fx("label", i + 1) { t in
            t.backgroundColor = bg
            t.color = [0, 2, 10, 11].contains(i % 12) ? black : .white
            switch variant {
            case 0: t.background = TextBackgroundStyle(mode: .block, cornerRadius: 0.5)
            case 1: t.background = TextBackgroundStyle(mode: .line, cornerRadius: 0.15, paddingX: 0.25, paddingY: 0.08)
            default: t.background = TextBackgroundStyle(mode: .letter, cornerRadius: 0.3, paddingX: 0.06, paddingY: 0.06)
            }
        }
    }

    /// Retro 3D: two-tone extrusion with an outline.
    static let retros: [D] = (0..<16).map { i in
        let a = c(i % 12), b = c((i * 5 + 3) % 12)
        return fx("retro", i + 1) { t in
            t.color = a == black ? .white : a; t.strokeColor = black; t.strokeWidth = 0.06
            t.shadowColor = (b == a ? b.mix(.black, 0.5) : b); t.shadow = TextShadowStyle(distance: 0.14 + Double(i % 3) * 0.04, angle: i % 2 == 0 ? 45 : 135, blur: 0, extrude: true)
        }
    }

    /// Triple layer: fill + two contrasting outlines.
    static let multiLayer: [D] = (0..<16).map { i in
        let a = c(i % 12), b = c((i + 4) % 12), cc = c((i + 7) % 12)
        return fx("multi", i + 1) { t in
            t.color = a; t.strokeColor = b; t.strokeWidth = 0.07
            t.extraStrokes = [TextStrokeLayer(color: cc, width: 0.16), TextStrokeLayer(color: black, width: 0.22)]
        }
    }

    /// Textured fills (metal, holographic, patterns).
    static let textured: [D] = (0..<16).map { i in
        let tex = textures[i % textures.count], variant = i / textures.count
        return fx("texture", i + 1) { t in
            t.fill = .texture(TextTexture(id: tex, scale: 1))
            t.color = .white
            if variant == 0 { t.strokeColor = black; t.strokeWidth = 0.05 }
            else { t.strokeColor = .white; t.strokeWidth = 0.08; t.shadowColor = RGBA(0, 0, 0, 0.6) }
        }
    }

    /// Curved / path word art.
    static let shaped: [D] = (0..<8).map { i in
        fx("shape", i + 1) { t in
            t.color = c(i + 2); t.strokeColor = .white; t.strokeWidth = 0.08
            switch i % 4 {
            case 0: t.curve = 0.35
            case 1: t.curve = -0.35
            case 2: t.path = TextPathShape(.wave, amount: 0.5)
            default: t.path = TextPathShape(.arch, amount: 0.6)
            }
        }
    }

    public static let effects: [D] = outlines + neons + shadows + gradientStyles + labels + retros + multiLayer + textured + shaped
    public static let all: [D] = basics + effects

    /// Group keys of the word-art library, in display order.
    public static let effectGroups = ["outline", "neon", "shadow", "gradient", "label", "retro", "multi", "texture", "shape"]
        .map { "textStyle.group.\($0)" }
}
