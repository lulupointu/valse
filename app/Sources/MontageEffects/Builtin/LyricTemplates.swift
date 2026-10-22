import Foundation
import MontageCore

/// Lyric templates (TX-026, F3): caption looks made for song lyrics — fill-as-sung karaoke, gradient / serif / neon /
/// typewriter looks — listed first ("Lyrics") on lyric caption tracks and applied to all lyrics in one click.
public enum BuiltinLyricTemplates {
    public typealias C = CaptionTemplateDescriptor
    static let rose = RGBA(hex: 0xFF5C8A), sunset = RGBA(hex: 0xFFB347), violet = RGBA(hex: 0xA46BFF), sky = RGBA(hex: 0x5AC8FA)
    static let gold = RGBA(hex: 0xFFD45C), mint = RGBA(hex: 0x6DF2C4)

    static func t(_ name: String, inAnim: String? = nil, _ body: @escaping @Sendable (inout TextContent) -> Void) -> C {
        C(id: "montage.lyricTemplate.\(name)", nameKey: "lyricTemplate.\(name)", groupKey: "captionTemplate.group.lyrics",
          inAnim: inAnim) { c in
            c.color = .white; c.bold = false; c.italic = false; c.strokeColor = .black; c.strokeWidth = 0
            c.backgroundColor = .clear; c.shadowColor = RGBA(0, 0, 0, 0.55); c.shadow = TextShadowStyle(distance: 0.04, angle: 90, blur: 0.12)
            c.glow = nil; c.fill = nil; c.karaoke = nil; c.inactiveKaraoke = nil; c.textCase = .none; c.letterSpacing = 0
            body(&c)
        }
    }

    public static let all: [C] = [
        // the sung part fills in, the rest waits dimmed (CapCut's default lyric look)
        t("sing") { c in c.bold = true; c.karaoke = KaraokeStyle(mode: .fillSpoken, highlightColor: .white, highlightScale: 1, unspokenOpacity: 0.4) },
        t("goldSing") { c in
            c.bold = true; c.strokeWidth = 0.05
            c.karaoke = KaraokeStyle(mode: .fillSpoken, highlightColor: gold, highlightStroke: .black, highlightScale: 1, unspokenOpacity: 1)
        },
        t("sunset") { c in
            c.bold = true; c.fill = .gradient(TextGradient([rose, sunset], angle: 0))
            c.karaoke = KaraokeStyle(mode: .reveal, highlightColor: .white, highlightScale: 1, bounce: 0.08)
        },
        t("serif") { c in
            c.fontName = "Georgia-Italic"; c.italic = true; c.shadowColor = RGBA(0, 0, 0, 0.7)
            c.karaoke = KaraokeStyle(mode: .fillSpoken, highlightColor: .white, highlightScale: 1, unspokenOpacity: 0.5)
        },
        t("neon") { c in
            c.bold = true; c.shadowColor = .clear; c.glow = TextGlowStyle(color: violet, intensity: 0.9, radius: 0.3)
            c.karaoke = KaraokeStyle(mode: .highlightWord, highlightColor: violet.mix(.white, 0.65), highlightScale: 1.08)
        },
        t("typewriter", inAnim: "montage.anim.text.in.typewriter") { c in
            c.fontName = "CourierNewPS-BoldMT"; c.shadowColor = .clear; c.strokeColor = .black; c.strokeWidth = 0.06
            c.karaoke = KaraokeStyle(mode: .reveal, highlightColor: .white, highlightScale: 1, bounce: 0)
        },
        t("airy") { c in
            c.textCase = .lower; c.letterSpacing = 0.12; c.shadow = TextShadowStyle(distance: 0, angle: 90, blur: 0.3)
            c.karaoke = KaraokeStyle(mode: .fillSpoken, highlightColor: sky.mix(.white, 0.5), highlightScale: 1, unspokenOpacity: 0.55)
        },
        t("bar") { c in
            c.bold = true; c.textCase = .upper; c.shadowColor = .clear
            c.karaoke = KaraokeStyle(mode: .highlightWord, highlightColor: .black, highlightScale: 1.0, boxColor: mint)
        },
    ]
}
