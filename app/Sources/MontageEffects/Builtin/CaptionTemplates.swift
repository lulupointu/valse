import Foundation
import MontageCore

/// Caption templates (TX-021, TX-026 lyrics): caption looks with karaoke word states (spoken / unspoken),
/// applied to all captions in one click. Need word timings (auto captions) — without them words are spread evenly.
public enum BuiltinCaptionTemplates {
    public typealias C = CaptionTemplateDescriptor
    static let yellow = RGBA(hex: 0xFFE14D), green = RGBA(hex: 0x5CFF7A), cyan = RGBA(hex: 0x4DE1FF)
    static let purple = RGBA(hex: 0x8C4BFF), red = RGBA(hex: 0xFF3B30), orange = RGBA(hex: 0xFF9500)

    static func t(_ name: String, _ group: String = "karaoke", inAnim: String? = nil,
                  _ body: @escaping @Sendable (inout TextContent) -> Void) -> C {
        C(id: "montage.captionTemplate.\(name)", nameKey: "captionTemplate.\(name)", groupKey: "captionTemplate.group.\(group)",
          inAnim: inAnim) { c in
            // common caption base: bold, outlined, no box
            c.color = .white; c.bold = true; c.strokeColor = .black; c.strokeWidth = 0.08
            c.backgroundColor = .clear; c.shadowColor = .clear; c.glow = nil; c.fill = nil; c.karaoke = nil
            body(&c)
        }
    }

    public static let all: [C] = [
        // Plain
        t("classic", "basic") { c in c.strokeWidth = 0.06; c.bold = false },
        t("label", "basic") { c in
            c.strokeWidth = 0; c.bold = false; c.backgroundColor = RGBA(0, 0, 0, 0.6)
            c.background = TextBackgroundStyle(mode: .line, cornerRadius: 0.2, paddingX: 0.25, paddingY: 0.08)
        },
        t("bold", "basic") { c in c.strokeWidth = 0.14; c.textCase = .upper },
        // Karaoke: active word
        t("yellowWord") { c in c.karaoke = KaraokeStyle(mode: .highlightWord, highlightColor: yellow, highlightScale: 1.12) },
        t("greenWord") { c in c.textCase = .upper; c.karaoke = KaraokeStyle(mode: .highlightWord, highlightColor: green, highlightScale: 1.15) },
        t("boxPurple") { c in
            c.strokeWidth = 0; c.shadowColor = RGBA(0, 0, 0, 0.5)
            c.karaoke = KaraokeStyle(mode: .highlightWord, highlightColor: .white, highlightScale: 1.05, boxColor: purple)
        },
        t("boxGreen") { c in
            c.strokeWidth = 0; c.textCase = .upper; c.shadowColor = RGBA(0, 0, 0, 0.5)
            c.karaoke = KaraokeStyle(mode: .highlightWord, highlightColor: .black, highlightScale: 1.05, boxColor: green)
        },
        t("boxRed") { c in
            c.strokeWidth = 0; c.shadowColor = RGBA(0, 0, 0, 0.5)
            c.karaoke = KaraokeStyle(mode: .highlightWord, highlightColor: .white, highlightScale: 1.0, boxColor: red)
        },
        // Karaoke: fill as spoken
        t("fillSpoken") { c in c.karaoke = KaraokeStyle(mode: .fillSpoken, highlightColor: .white, highlightScale: 1, unspokenOpacity: 0.45) },
        t("fillYellow") { c in
            c.karaoke = KaraokeStyle(mode: .fillSpoken, highlightColor: yellow, highlightStroke: .black, highlightScale: 1, unspokenOpacity: 1)
        },
        // Pop-in
        t("reveal", "pop") { c in c.karaoke = KaraokeStyle(mode: .reveal, highlightColor: .white, highlightScale: 1, bounce: 0.15) },
        t("revealYellow", "pop") { c in
            c.textCase = .upper; c.strokeWidth = 0.12
            c.karaoke = KaraokeStyle(mode: .reveal, highlightColor: yellow, highlightScale: 1.1, bounce: 0.2)
        },
        t("singleWord", "pop") { c in
            c.fontSize = max(c.fontSize, 0.09); c.textCase = .upper; c.strokeWidth = 0.14
            c.karaoke = KaraokeStyle(mode: .singleWord, highlightColor: .white, highlightScale: 1.0, bounce: 0.12)
        },
        t("singleWordColor", "pop") { c in
            c.fontSize = max(c.fontSize, 0.09); c.textCase = .upper; c.strokeWidth = 0.14
            c.karaoke = KaraokeStyle(mode: .singleWord, highlightColor: orange, highlightScale: 1.0, bounce: 0.12)
        },
        // Glow
        t("neon", "glow") { c in
            c.strokeWidth = 0; c.glow = TextGlowStyle(color: cyan, intensity: 0.9, radius: 0.25)
            c.karaoke = KaraokeStyle(mode: .highlightWord, highlightColor: cyan.mix(.white, 0.6), highlightScale: 1.1)
        },
    ]
}
