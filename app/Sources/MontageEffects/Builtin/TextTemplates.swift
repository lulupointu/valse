import Foundation
import MontageCore

/// Text templates (TX-013): designed, animated multi-layer titles with editable text slots. Our own authored set
/// (CapCut's thousands are downloadable); each is text slots + shapes + per-layer timing and glyph animations.
/// Offsets / sizes are in em of the clip font size, so a template scales with Font size / Scale.
public enum BuiltinTextTemplates {
    public typealias T = TextTemplateDescriptor
    public typealias L = TextTemplateLayer

    static func anim(_ phase: String, _ name: String) -> String { "montage.anim.text.\(phase).\(name)" }
    static func inA(_ name: String, _ d: Double = 0.8) -> (id: String, duration: Double) { (anim("in", name), d) }
    static func outA(_ name: String, _ d: Double = 0.6) -> (id: String, duration: Double) { (anim("out", name), d) }
    static func loopA(_ name: String, _ p: Double = 1.2) -> (id: String, period: Double) { (anim("combo", name), p) }

    static func text(_ slot: Int, _ style: @escaping @Sendable (inout TextContent) -> Void = { _ in }) -> L.Kind { .text(slot: slot, style: style) }

    static func tpl(_ name: String, _ group: String, slots: Int, duration: Double = 4,
                    base: @escaping @Sendable (inout TextContent) -> Void = { _ in }, _ layers: [L]) -> T {
        T(id: "montage.template.\(name)", nameKey: "template.\(name)", groupKey: "template.group.\(group)",
          slotKeys: (0..<slots).map { "template.\(name).slot\($0)" }, defaultDuration: Time(duration), base: base, layers: layers)
    }

    static let white = RGBA.white, black = RGBA(hex: 0x141414), yellow = RGBA(hex: 0xFFD400), red = RGBA(hex: 0xE53935)
    static let accent = RGBA(hex: 0x57BECB), pink = RGBA(hex: 0xFF4FA3), blue = RGBA(hex: 0x2F80FF)

    public static let all: [T] = [
        // Basic
        tpl("titleSubtitle", "basic", slots: 2, base: { $0.fontSize = 0.09; $0.bold = true }, [
            L(text(0) { $0.strokeColor = black; $0.strokeWidth = 0.06 }, offset: Vec2(0, -0.35), inAnim: inA("popChars", 0.9), outAnim: outA("fadeCharsOut")),
            L(text(1) { $0.bold = false; $0.fontSize *= 0.45; $0.letterSpacing = 0.15; $0.textCase = .upper },
              offset: Vec2(0, 0.55), start: 0.12, inAnim: inA("riseWords", 0.7), outAnim: outA("fadeCharsOut")),
        ]),
        tpl("bigWord", "basic", slots: 1, base: { $0.fontSize = 0.16; $0.bold = true }, [
            L(text(0) { $0.textCase = .upper; $0.strokeColor = black; $0.strokeWidth = 0.08; $0.shadowColor = RGBA(0, 0, 0, 0.6) },
              inAnim: inA("zoomWords", 0.6), outAnim: outA("shrinkWords"), loopAnim: loopA("breathe", 1.6)),
        ]),
        tpl("typewriter", "basic", slots: 1, base: { $0.fontSize = 0.06; $0.fontName = "American Typewriter" }, [
            L(text(0), inAnim: inA("typewriter", 1.6), outAnim: outA("backspace", 1.0)),
        ]),
        tpl("chapter", "basic", slots: 2, base: { $0.fontSize = 0.08; $0.bold = true }, [
            L(text(0) { $0.fontSize *= 0.35; $0.letterSpacing = 0.4; $0.bold = false; $0.textCase = .upper },
              offset: Vec2(0, -0.75), inAnim: inA("fadeChars", 0.8)),
            L(text(1), offset: Vec2(0, 0.1), start: 0.08, inAnim: inA("riseLines", 0.8), outAnim: outA("fadeCharsOut")),
            L(.shape(.roundedRect(radius: 0.02), size: Vec2(3.2, 0.06), color: white), offset: Vec2(0, 0.8), start: 0.15,
              inAnim: (anim("in", "blowUp"), 0.6), fitSlot: 1, fitPadding: 0.2),
        ]),
        // Titles
        tpl("neonSign", "titles", slots: 1, base: { $0.fontSize = 0.1 }, [
            L(text(0) { $0.color = RGBA(hex: 0xFFE0F2); $0.glow = TextGlowStyle(color: pink, intensity: 1, radius: 0.35); $0.bold = true },
              inAnim: inA("randomFade", 1.0), loopAnim: loopA("flicker", 2.0)),
        ]),
        tpl("goldTitle", "titles", slots: 2, base: { $0.fontSize = 0.1; $0.fontName = "Didot"; $0.bold = true }, [
            L(text(0) { $0.fill = .texture(TextTexture(id: "gold")); $0.shadowColor = RGBA(0, 0, 0, 0.6) },
              inAnim: inA("centerOut", 1.0), outAnim: outA("fadeCharsOut")),
            L(text(1) { $0.fontSize *= 0.32; $0.letterSpacing = 0.5; $0.color = RGBA(hex: 0xF7E09A); $0.bold = false; $0.textCase = .upper },
              offset: Vec2(0, 0.8), start: 0.15, inAnim: inA("fadeChars", 0.8)),
        ]),
        tpl("retroWave", "titles", slots: 1, base: { $0.fontSize = 0.12; $0.bold = true; $0.fontName = "Futura" }, [
            L(text(0) {
                $0.fill = .gradient(TextGradient([RGBA(hex: 0xFF6FD8), RGBA(hex: 0x3813C2)], angle: 90)); $0.textCase = .upper
                $0.shadowColor = RGBA(hex: 0x00E5FF); $0.shadow = TextShadowStyle(distance: 0.1, angle: 45, blur: 0, extrude: true)
            }, rotation: -6, inAnim: inA("slideChars", 0.9), loopAnim: loopA("wave", 1.6)),
        ]),
        tpl("comicBurst", "titles", slots: 1, base: { $0.fontSize = 0.11; $0.bold = true; $0.fontName = "Chalkboard SE" }, [
            L(.shape(.burst(spikes: 14, depth: 0.22), size: Vec2(4.6, 3.0), color: yellow), rotation: -8, inAnim: (anim("in", "blowUp"), 0.5),
              loopAnim: loopA("heartbeat", 1.0)),
            L(text(0) { $0.color = red; $0.strokeColor = white; $0.strokeWidth = 0.1; $0.textCase = .upper }, rotation: -8,
              inAnim: inA("popChars", 0.6), loopAnim: loopA("jiggle", 0.6)),
        ]),
        // Social
        tpl("subscribe", "social", slots: 1, duration: 3, base: { $0.fontSize = 0.07; $0.bold = true }, [
            L(.shape(.capsule, size: Vec2(4, 1.7), color: red), inAnim: (anim("in", "blowUp"), 0.5), outAnim: outA("shrinkWords", 0.4),
              fitSlot: 0, fitPadding: 0.8),
            L(text(0) { $0.textCase = .upper; $0.color = white }, start: 0.05, inAnim: inA("popChars", 0.6), outAnim: outA("popCharsOut", 0.4)),
        ]),
        tpl("follow", "social", slots: 2, duration: 3, base: { $0.fontSize = 0.065; $0.bold = true }, [
            L(.shape(.roundedRect(radius: 0.4), size: Vec2(5, 2.6), color: white), inAnim: (anim("in", "blowUp"), 0.5), fitSlot: 0, fitPadding: 0.7),
            L(text(0) { $0.color = black }, offset: Vec2(0, -0.35), start: 0.05, inAnim: inA("riseWords", 0.6)),
            L(text(1) { $0.color = pink; $0.fontSize *= 0.6 }, offset: Vec2(0, 0.55), start: 0.12, inAnim: inA("fadeChars", 0.6)),
        ]),
        tpl("speech", "social", slots: 1, base: { $0.fontSize = 0.06; $0.bold = true; $0.bubbleID = "montage.bubble.speechWhite"; $0.color = black }, [
            L(text(0), inAnim: (anim("in", "blowUp"), 0.5), outAnim: outA("shrinkWords", 0.4), loopAnim: loopA("float", 2.0)),
        ]),
        tpl("likeShare", "social", slots: 1, duration: 3, base: { $0.fontSize = 0.07; $0.bold = true }, [
            L(text(0) { $0.color = white; $0.strokeColor = blue; $0.strokeWidth = 0.12 }, inAnim: inA("bounceIn", 1.0),
              loopAnim: loopA("hop", 1.0)),
        ]),
        // Vlog
        tpl("dayCount", "vlog", slots: 2, base: { $0.fontSize = 0.12; $0.bold = true; $0.fontName = "Futura" }, [
            L(text(0) { $0.textCase = .upper; $0.color = yellow; $0.strokeColor = black; $0.strokeWidth = 0.06 }, offset: Vec2(0, -0.3),
              inAnim: inA("drop", 1.0)),
            L(text(1) { $0.fontSize *= 0.38; $0.bold = false; $0.fontName = "Snell Roundhand"; $0.color = white }, offset: Vec2(0.6, 0.55),
              start: 0.15, inAnim: inA("fadeChars", 1.0)),
        ]),
        tpl("location", "vlog", slots: 2, base: { $0.fontSize = 0.07; $0.bold = true }, [
            L(text(0) { $0.textCase = .upper; $0.letterSpacing = 0.12 }, offset: Vec2(0, -0.2), inAnim: inA("slideChars", 0.9),
              outAnim: outA("slideCharsOut")),
            L(.shape(.roundedRect(radius: 0.02), size: Vec2(3, 0.05), color: white), offset: Vec2(0, 0.45), start: 0.1,
              inAnim: (anim("in", "blowUp"), 0.5), fitSlot: 0, fitPadding: 0.2),
            L(text(1) { $0.fontSize *= 0.45; $0.bold = false; $0.letterSpacing = 0.3; $0.textCase = .upper }, offset: Vec2(0, 0.85),
              start: 0.15, inAnim: inA("fadeChars", 0.8)),
        ]),
        tpl("dateStamp", "vlog", slots: 1, base: { $0.fontSize = 0.05; $0.fontName = "Menlo"; $0.bold = true }, [
            L(text(0) { $0.color = RGBA(hex: 0xFF9A3C); $0.glow = TextGlowStyle(color: RGBA(hex: 0xFF5A00), intensity: 0.7, radius: 0.15) },
              inAnim: inA("typewriter", 1.0), loopAnim: loopA("flicker", 3.0)),
        ]),
        tpl("travel", "vlog", slots: 2, base: { $0.fontSize = 0.1; $0.fontName = "Snell Roundhand"; $0.bold = true }, [
            L(text(0) { $0.color = white; $0.shadowColor = RGBA(0, 0, 0, 0.5) }, inAnim: inA("fadeChars", 1.2), loopAnim: loopA("float", 2.4)),
            L(text(1) { $0.fontName = "Avenir Next"; $0.fontSize *= 0.3; $0.letterSpacing = 0.6; $0.textCase = .upper; $0.bold = false },
              offset: Vec2(0, 0.85), start: 0.2, inAnim: inA("fadeChars", 0.8)),
        ]),
        // Business
        tpl("lowerThird", "business", slots: 2, base: { $0.fontSize = 0.055; $0.bold = true; $0.alignment = .left }, [
            L(.shape(.roundedRect(radius: 0.05), size: Vec2(5, 1.5), color: accent), offset: Vec2(0, -0.25),
              inAnim: (anim("in", "slideLines"), 0.6), outAnim: (anim("out", "slideLinesOut"), 0.5), fitSlot: 0, fitPadding: 0.5),
            L(text(0) { $0.color = white }, offset: Vec2(0, -0.25), start: 0.05, inAnim: inA("slideLines", 0.6), outAnim: outA("slideLinesOut", 0.5)),
            L(.shape(.roundedRect(radius: 0.05), size: Vec2(3, 1.0), color: white), offset: Vec2(0, 1.05), start: 0.08,
              inAnim: (anim("in", "slideLines"), 0.6), outAnim: (anim("out", "slideLinesOut"), 0.5), fitSlot: 1, fitPadding: 0.4),
            L(text(1) { $0.color = black; $0.fontSize *= 0.6; $0.bold = false }, offset: Vec2(0, 1.05), start: 0.12,
              inAnim: inA("fadeChars", 0.6), outAnim: outA("fadeCharsOut", 0.4)),
        ]),
        tpl("breakingNews", "business", slots: 2, base: { $0.fontSize = 0.06; $0.bold = true }, [
            L(.shape(.roundedRect(radius: 0.02), size: Vec2(5.5, 1.5), color: red), offset: Vec2(-3.8, 0), inAnim: (anim("in", "slideLines"), 0.5)),
            L(text(0) { $0.color = white; $0.textCase = .upper }, offset: Vec2(-3.8, 0), start: 0.05, inAnim: inA("popChars", 0.5)),
            L(.shape(.roundedRect(radius: 0.02), size: Vec2(9.5, 1.5), color: white), offset: Vec2(3.7, 0), start: 0.05,
              inAnim: (anim("in", "slideLines"), 0.6)),
            L(text(1) { $0.color = black; $0.bold = false }, offset: Vec2(3.7, 0), start: 0.1, inAnim: inA("typewriter", 1.0)),
        ]),
        tpl("quote", "business", slots: 2, base: { $0.fontSize = 0.06; $0.fontName = "Georgia"; $0.italic = true }, [
            L(text(0), offset: Vec2(0, -0.2), inAnim: inA("fadeChars", 1.4), outAnim: outA("fadeCharsOut")),
            L(text(1) { $0.italic = false; $0.fontSize *= 0.55; $0.color = RGBA(hex: 0xCCCCCC) }, offset: Vec2(0, 0.9), start: 0.3,
              inAnim: inA("riseWords", 0.8)),
        ]),
        tpl("sale", "business", slots: 2, base: { $0.fontSize = 0.1; $0.bold = true }, [
            L(.shape(.tag, size: Vec2(4, 2.4), color: red), rotation: -10, inAnim: (anim("in", "blowUp"), 0.5), loopAnim: loopA("heartbeat", 1.2),
              fitSlot: 0, fitPadding: 0.6),
            L(text(0) { $0.color = white }, offset: Vec2(0.25, -0.15), rotation: -10, start: 0.05, inAnim: inA("popChars", 0.5)),
            L(text(1) { $0.color = yellow; $0.fontSize *= 0.4; $0.textCase = .upper }, offset: Vec2(0.25, 0.75), rotation: -10, start: 0.1,
              inAnim: inA("fadeChars", 0.5)),
        ]),
        // Holidays
        tpl("holiday", "holidays", slots: 2, base: { $0.fontSize = 0.1; $0.fontName = "Snell Roundhand"; $0.bold = true }, [
            L(text(0) { $0.fill = .gradient(TextGradient([RGBA(hex: 0xFF5F6D), RGBA(hex: 0xFFC371)], angle: 0)); $0.strokeColor = white; $0.strokeWidth = 0.04 },
              inAnim: inA("fadeChars", 1.4), loopAnim: loopA("float", 2.0)),
            L(text(1) { $0.fontName = ""; $0.fontSize *= 0.5 }, offset: Vec2(0, 0.95), start: 0.25, inAnim: inA("popWords", 0.6),
              loopAnim: loopA("pulseChars", 1.2)),
        ]),
        tpl("birthday", "holidays", slots: 1, base: { $0.fontSize = 0.1; $0.bold = true; $0.fontName = "Chalkboard SE" }, [
            L(text(0) {
                $0.fill = .gradient(TextGradient(BuiltinTextStyles.gradients[8], angle: 0)); $0.strokeColor = white; $0.strokeWidth = 0.08
            }, inAnim: inA("bounceIn", 1.2), loopAnim: loopA("hop", 1.0)),
        ]),
        tpl("thankYou", "holidays", slots: 1, base: { $0.fontSize = 0.11; $0.fontName = "Snell Roundhand"; $0.bold = true }, [
            L(text(0) { $0.color = white; $0.glow = TextGlowStyle(color: pink, intensity: 0.7, radius: 0.2) },
              inAnim: inA("fadeChars", 1.4), outAnim: outA("fadeCharsOut", 0.8)),
        ]),
        tpl("comingSoon", "holidays", slots: 1, base: { $0.fontSize = 0.08; $0.bold = true }, [
            L(text(0) { $0.textCase = .upper; $0.letterSpacing = 0.3; $0.color = white }, inAnim: inA("centerOut", 1.0),
              loopAnim: loopA("breathe", 1.8)),
            L(.shape(.roundedRect(radius: 0.02), size: Vec2(3, 0.06), color: accent), offset: Vec2(0, 0.75), start: 0.15,
              inAnim: (anim("in", "blowUp"), 0.6), fitSlot: 0, fitPadding: 0.1),
        ]),
    ]
}
