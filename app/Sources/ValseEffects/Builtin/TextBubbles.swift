import Foundation
import ValseCore

/// "Text ▸ Bubble" frames (TX-014, TX-BUBBLE2): speech bubbles, labels, banners, bursts, neon outlines, comic balloons,
/// social chips — auto-sized to the text box.
public enum BuiltinTextBubbles {
    public typealias B = TextBubbleDescriptor
    public typealias S = TextBubbleStyle
    static let w = RGBA.white, k = RGBA(hex: 0x141414), y = RGBA(hex: 0xFFD400), r = RGBA(hex: 0xE53935)
    static let bl = RGBA(hex: 0x2F80FF), g = RGBA(hex: 0x34C759), p = RGBA(hex: 0xFF4FA3), pu = RGBA(hex: 0x7B2FF7)
    // TX-BUBBLE2 palette
    static let pink = RGBA(hex: 0xFF2E88), cyan = RGBA(hex: 0x19E6FF), lime = RGBA(hex: 0xA6FF3D), violet = RGBA(hex: 0xB44BFF)
    static let orange = RGBA(hex: 0xFF8A1F), red = RGBA(hex: 0xFF3B3B), ice = RGBA(hex: 0xE8F6FF), amber = RGBA(hex: 0xFFE53D)
    static let none = RGBA.clear

    static func b(_ name: String, _ group: String, _ shape: BubbleShape, fill: RGBA, stroke: RGBA? = nil, sw: Double = 0.06,
                  text: RGBA = RGBA(hex: 0x141414), pad: Vec2 = Vec2(0.45, 0.3)) -> B {
        B(id: "valse.bubble.\(name)", nameKey: "bubble.\(name)", groupKey: "bubble.group.\(group)", shape: shape, padding: pad,
          fill: fill, stroke: stroke, strokeWidth: sw, textColor: text)
    }

    /// TX-BUBBLE2 preset.
    static func n(_ name: String, _ group: String, _ style: S, text: RGBA = .white, backdrop: B.PreviewBackdrop = .dark) -> B {
        B(id: "valse.bubble.\(name)", nameKey: "bubble.\(name)", groupKey: "bubble.group.\(group)", style: style, textColor: text,
          previewBackdrop: backdrop)
    }

    /// Shape helper: oval / cloud / burst contain the text (TX-BUBBLE2 sizing), with a tighter padding.
    static func shape(_ f: S.Family, r: Double = 0.3, edge: S.Edge? = nil, tail: TextBubbleTail? = nil, fill: RGBA,
                      outline: TextBubbleOutline? = nil, shadow: TextBubbleShadow? = nil, bar: Double = 0.18) -> S {
        var s = S(family: f, cornerRadius: r, barHeight: bar, tail: tail, padding: f.canContain ? Vec2(0.4, 0.2) : Vec2(0.45, 0.3),
                  fill: fill, outline: outline, shadow: shadow, containsText: true)
        if let edge { s.setEdge(edge) }
        if f == .underline { s.padding = Vec2(0.15, 0.08) }
        if f == .circle { s.padding = Vec2(0.12, 0.12) }   // added to the text box's half diagonal
        return s
    }

    static func neon(_ c: RGBA, width: Double = 0.06, glow: Double = 0.35, dash: TextBubbleOutline.Dash = .solid,
                     flicker: TextNeonFlicker = .off) -> TextBubbleOutline {
        TextBubbleOutline(color: c, width: width, dash: dash, neon: TextBubbleOutline.neonStyle(glow: glow, flicker: flicker))
    }

    static func line(_ c: RGBA, _ width: Double, _ dash: TextBubbleOutline.Dash = .solid) -> TextBubbleOutline {
        TextBubbleOutline(color: c, width: width, dash: dash)
    }

    static func tail(_ side: TextBubbleTail.Side, _ kind: TextBubbleTail.Kind = .point) -> TextBubbleTail { TextBubbleTail(side: side, kind: kind) }

    /// Group order of the Bubble tab (filter pills and section headers).
    public static let groups = ["bubble.group.neon", "bubble.group.outline", "bubble.group.speech", "bubble.group.comic",
                                "bubble.group.social", "bubble.group.label", "bubble.group.minimal", "bubble.group.banner"]

    /// The 24 v1 presets (TX-014): ids and look unchanged.
    public static let legacy: [B] = [
        // Speech
        b("speechWhite", "speech", .speech(radius: 0.5, tail: .bottomLeft), fill: w, stroke: k, sw: 0.07),
        b("speechBlack", "speech", .speech(radius: 0.5, tail: .bottomRight), fill: k, text: w),
        b("speechYellow", "speech", .speech(radius: 0.3, tail: .bottom), fill: y, stroke: k, sw: 0.07),
        b("speechBlue", "speech", .speech(radius: 0.6, tail: .left), fill: bl, text: w),
        b("thought", "speech", .thought, fill: w, stroke: k, sw: 0.06, pad: Vec2(0.7, 0.5)),
        b("cloud", "speech", .cloud(bumps: 9), fill: w, stroke: k, sw: 0.06, pad: Vec2(0.7, 0.55)),
        b("chat", "speech", .speech(radius: 0.9, tail: .bottomRight), fill: g, text: w),
        // Labels
        b("labelWhite", "label", .roundedRect(radius: 0.25), fill: w),
        b("labelBlack", "label", .roundedRect(radius: 0.25), fill: k, text: w),
        b("pillPink", "label", .capsule, fill: p, text: w),
        b("pillYellow", "label", .capsule, fill: y),
        b("outlineBox", "label", .roundedRect(radius: 0.15), fill: .clear, stroke: w, sw: 0.08, text: w),
        b("ellipse", "label", .ellipse, fill: w, stroke: k, sw: 0.05, pad: Vec2(0.7, 0.45)),
        b("hexagon", "label", .hexagon, fill: pu, text: w, pad: Vec2(0.7, 0.35)),
        b("tag", "label", .tag, fill: r, text: w, pad: Vec2(0.55, 0.3)),
        b("brackets", "label", .brackets, fill: .clear, stroke: w, sw: 0.08, text: w, pad: Vec2(0.5, 0.25)),
        b("underline", "label", .underlineBar(height: 0.18), fill: y, text: w, pad: Vec2(0.15, 0.12)),
        // Banners & bursts
        b("bannerRed", "banner", .banner(fold: 0.5), fill: r, text: w, pad: Vec2(0.8, 0.3)),
        b("bannerBlue", "banner", .banner(fold: 0.5), fill: bl, text: w, pad: Vec2(0.8, 0.3)),
        b("ribbon", "banner", .ribbon, fill: g, text: w, pad: Vec2(0.9, 0.3)),
        b("arrow", "banner", .arrow, fill: y, pad: Vec2(0.5, 0.3)),
        b("burstYellow", "banner", .burst(spikes: 14, depth: 0.25), fill: y, stroke: r, sw: 0.07, pad: Vec2(0.9, 0.8)),
        b("burstRed", "banner", .burst(spikes: 10, depth: 0.3), fill: r, text: w, pad: Vec2(0.9, 0.8)),
        b("burstPink", "banner", .burst(spikes: 18, depth: 0.18), fill: p, stroke: w, sw: 0.06, text: w, pad: Vec2(0.9, 0.8)),
    ]

    /// TX-BUBBLE2: 36 presets (neon, outline, comic, social, minimal).
    public static let added: [B] = {
        var nightSign = shape(.box, r: 0.3, fill: RGBA(hex: 0x0B0B1A, alpha: 0.6), outline: neon(pink, glow: 0.45))
        nightSign.padding = Vec2(0.5, 0.32)
        return [
            // Neon: transparent fill + neon outline
            n("neonPinkPill", "neon", shape(.pill, fill: none, outline: neon(pink))),
            n("neonCyanBox", "neon", shape(.box, r: 0.2, fill: none, outline: neon(cyan))),
            n("neonLimeSpeech", "neon", shape(.box, r: 0.5, tail: tail(.bottomLeft), fill: none, outline: neon(lime))),
            n("neonVioletThought", "neon", shape(.cloud, edge: .calm, tail: tail(.bottomLeft, .dots), fill: none, outline: neon(violet))),
            n("neonOrangeBurst", "neon", shape(.burst, edge: .spiky, fill: none, outline: neon(orange))),
            n("neonRedOval", "neon", shape(.oval, fill: none, outline: neon(red))),
            n("neonIceBrackets", "neon", shape(.brackets, fill: none, outline: neon(ice, width: 0.07))),
            n("neonAmberArrow", "neon", shape(.arrow, fill: none, outline: neon(amber))),
            n("neonDuo", "neon", shape(.box, r: 0.3, fill: none, outline: neon(pink), shadow: TextBubbleShadow(color: cyan, kind: .hard))),
            n("neonNightSign", "neon", nightSign),
            n("neonFlicker", "neon", shape(.pill, fill: none, outline: neon(cyan, flicker: .oneLetter))),   // the tube is a faulty segment
            n("neonMarquee", "neon", shape(.box, r: 0.15, fill: none, outline: neon(amber, width: 0.08, dash: .dotted))),
            // Outline
            n("outlineSpeech", "outline", shape(.box, r: 0.5, tail: tail(.bottom), fill: none, outline: line(w, 0.07))),
            n("outlinePillDark", "outline", shape(.pill, fill: none, outline: line(k, 0.07)), text: k, backdrop: .light),
            n("dashedFrame", "outline", shape(.box, r: 0.2, fill: none, outline: line(w, 0.05, .dashed))),
            n("dottedCloud", "outline", shape(.cloud, edge: .calm, fill: none, outline: line(w, 0.07, .dotted))),
            n("thinOval", "outline", shape(.oval, fill: none, outline: line(w, 0.03))),
            n("frostedPill", "outline", shape(.pill, fill: RGBA(1, 1, 1, 0.25), outline: line(RGBA(1, 1, 1, 0.6), 0.03))),
            n("smokeBox", "outline", shape(.box, r: 0.25, fill: RGBA(hex: 0x141414, alpha: 0.45)), backdrop: .light),
            // Comic
            n("comicClassic", "comic", shape(.oval, tail: tail(.bottomLeft, .curve), fill: w, outline: line(k, 0.07)), text: k),
            n("comicShout", "comic", shape(.burst, edge: .wild, tail: tail(.bottomRight), fill: w, outline: line(k, 0.08)), text: k),
            n("comicPow", "comic", shape(.burst, edge: .spiky, fill: amber, outline: line(red, 0.08),
                                         shadow: TextBubbleShadow(color: k, kind: .hard)), text: red),
            n("comicWhisper", "comic", shape(.oval, tail: tail(.bottomLeft, .curve), fill: w, outline: line(k, 0.05, .dashed)), text: k),
            n("comicDaydream", "comic", shape(.cloud, edge: .calm, tail: tail(.bottomRight, .dots), fill: w, outline: line(k, 0.06)), text: k),
            n("comicCaption", "comic", shape(.box, r: 0, fill: RGBA(hex: 0xFFF3B0), outline: line(k, 0.06),
                                             shadow: TextBubbleShadow(color: k, kind: .hard)), text: k),
            n("comicRetro", "comic", shape(.box, r: 0.4, tail: tail(.bottom), fill: RGBA(hex: 0xFF4FA3), outline: line(k, 0.08),
                                           shadow: TextBubbleShadow(color: k, kind: .hard))),
            // Social
            n("chatSent", "social", shape(.box, r: 0.9, tail: tail(.bottomRight, .curve), fill: RGBA(hex: 0x2F80FF))),
            n("chatReceived", "social", shape(.box, r: 0.9, tail: tail(.bottomLeft, .curve), fill: RGBA(hex: 0xE9E9EB)), text: k),
            n("commentCard", "social", shape(.box, r: 0.3, fill: w, shadow: TextBubbleShadow(color: RGBA(hex: 0x141414, alpha: 0.35))), text: k),
            n("ctaPill", "social", shape(.pill, fill: RGBA(hex: 0xE53935), shadow: TextBubbleShadow(color: RGBA(hex: 0x141414, alpha: 0.4)))),
            n("newBadge", "social", shape(.burst, edge: .calm, fill: red)),
            n("promoTag", "social", shape(.tag, fill: amber, outline: line(k, 0.05)), text: k),
            n("hashtagChip", "social", shape(.pill, fill: RGBA(hex: 0x7B2FF7, alpha: 0.7))),
            // Minimal
            n("squareBlock", "minimal", shape(.box, r: 0, fill: k), backdrop: .light),
            n("softCard", "minimal", shape(.box, r: 0.35, fill: RGBA(hex: 0xF5F1E8), shadow: TextBubbleShadow(color: RGBA(hex: 0x141414, alpha: 0.3))), text: k),
            n("highlighter", "minimal", shape(.underline, fill: RGBA(hex: 0xFFE53D, alpha: 0.8), bar: 0.45), text: k, backdrop: .light),
            // Round: a true circle around the text
            n("roundSpeech", "speech", shape(.circle, tail: tail(.bottomLeft, .curve), fill: w, outline: line(k, 0.06)), text: k),
            n("roundBadge", "outline", shape(.circle, fill: none, outline: line(w, 0.06))),
            n("roundNeon", "neon", shape(.circle, fill: none, outline: neon(cyan))),
        ]
    }()

    /// Every preset in grid order (None, then the groups in `groups` order).
    public static let all: [B] = {
        let every = legacy + added
        return groups.flatMap { g in every.filter { $0.groupKey == g } }
    }()
}
