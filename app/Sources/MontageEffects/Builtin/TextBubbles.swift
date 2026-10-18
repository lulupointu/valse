import Foundation
import MontageCore

/// "Text ▸ Bubble" frames (TX-014): speech bubbles, labels, banners, bursts — auto-sized to the text box.
public enum BuiltinTextBubbles {
    public typealias B = TextBubbleDescriptor
    static let w = RGBA.white, k = RGBA(hex: 0x141414), y = RGBA(hex: 0xFFD400), r = RGBA(hex: 0xE53935)
    static let bl = RGBA(hex: 0x2F80FF), g = RGBA(hex: 0x34C759), p = RGBA(hex: 0xFF4FA3), pu = RGBA(hex: 0x7B2FF7)

    static func b(_ name: String, _ group: String, _ shape: BubbleShape, fill: RGBA, stroke: RGBA? = nil, sw: Double = 0.06,
                  text: RGBA = RGBA(hex: 0x141414), pad: Vec2 = Vec2(0.45, 0.3)) -> B {
        B(id: "montage.bubble.\(name)", nameKey: "bubble.\(name)", groupKey: "bubble.group.\(group)", shape: shape, padding: pad,
          fill: fill, stroke: stroke, strokeWidth: sw, textColor: text)
    }

    public static let all: [B] = [
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
}
