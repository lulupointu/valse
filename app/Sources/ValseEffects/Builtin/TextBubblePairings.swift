import Foundation
import ValseCore

/// TX-BUBBLE2 bubble ↔ text pairing (owner: "bubbles should use the best text effect as preset"): the text look each of
/// the 60 bubble presets brings (designer spec, 2026-11-04), and how a pick / switch / None / Reset merges it into the
/// clip's text without stacking looks or overriding what the user chose.
public enum TextBubblePairing {
    typealias Bub = BuiltinTextBubbles
    static let ink = RGBA(hex: 0x141414)

    // MARK: Recipes

    /// Look built on a scratch text.
    static func L(_ edit: (inout TextContent) -> Void) -> TextLook {
        var t = TextContent(string: "")
        edit(&t)
        return t.look
    }

    static func font(_ t: inout TextContent, _ name: String, caps: Bool, spacing: Double) {
        t.fontName = name
        t.textCase = caps ? .upper : .none
        t.letterSpacing = spacing
        if !name.isEmpty { t.bold = false }   // explicit faces carry their own weight (a bold trait would swap the face)
    }

    /// Word art (`valse.textfx.*`) as the base of a look.
    static func art(_ d: TextStyleDescriptor, _ t: inout TextContent) {
        d.apply(&t)
        t.styleID = d.id
    }

    /// SIGN WHITE: what the owner's reference neon sign does inside its tube, plain white letters (no neon of their
    /// own), with a faint black "dusk guard" glow behind them so they stay readable on light video.
    static func signWhite(_ fontName: String, caps: Bool = false, spacing: Double = 0.02) -> TextLook {
        L { t in
            t.color = .white
            t.glow = TextGlowStyle(color: .black, intensity: 0.5, radius: 0.22, mode: .outer)
            t.bold = true
            font(&t, fontName, caps: caps, spacing: spacing)
        }
    }

    /// NEON(c): neon tube letters (same tube profile as the frame, a slightly shorter halo so the word stays crisp) + a
    /// faint black "dusk guard" glow behind it (readable on light video), letters spaced so the tubes don't fuse.
    static func neon(_ c: RGBA, _ fontName: String = "ArialRoundedMTBold", caps: Bool = false, spacing: Double = 0.03,
                     tube: Int? = nil, glowSize: Double = 0.3, duskGuard: Bool = true, flicker: TextNeonFlicker = .off,
                     fx extra: (inout TextContent) -> Void = { _ in }) -> TextLook {
        L { t in
            t.color = .white
            t.neon = TextNeonStyle(color: c, intensity: 0.8, glowSize: glowSize, thickness: 0.05, flicker: flicker)
            if duskGuard { t.glow = TextGlowStyle(color: .black, intensity: 0.35, radius: 0.3, mode: .outer) }
            t.bold = true
            font(&t, fontName, caps: caps, spacing: spacing)
            t.styleID = tube.map { "valse.textfx.neon.\($0)" }
            extra(&t)
        }
    }

    /// ON-VIDEO(c): soft drop shadow word art (`valse.textfx.shadow.1`), recoloured.
    static func onVideo(_ c: RGBA = .white, _ fontName: String = "", caps: Bool = false, spacing: Double = 0) -> TextLook {
        L { t in
            art(BuiltinTextStyles.shadows[0], &t)
            if c != .white { t.color = c; t.shadowColor = RGBA(0, 0, 0, 0.7) }
            font(&t, fontName, caps: caps, spacing: spacing)
        }
    }

    /// INK / PAPER: dark or white text, bold, no effects (+ optional extras).
    static func plain(_ c: RGBA, _ fontName: String = "", caps: Bool = false, spacing: Double = 0, bold: Bool = true,
                      italic: Bool = false, fx extra: (inout TextContent) -> Void = { _ in }) -> TextLook {
        L { t in
            t.color = c; t.bold = bold
            font(&t, fontName, caps: caps, spacing: spacing)
            if fontName.isEmpty { t.bold = bold }
            t.italic = italic
            extra(&t)
        }
    }
    static func inkL(_ f: String = "", caps: Bool = false, spacing: Double = 0, bold: Bool = true, italic: Bool = false,
                     fx extra: (inout TextContent) -> Void = { _ in }) -> TextLook {
        plain(ink, f, caps: caps, spacing: spacing, bold: bold, italic: italic, fx: extra)
    }
    static func paperL(_ f: String = "", caps: Bool = false, spacing: Double = 0, bold: Bool = true,
                       fx extra: (inout TextContent) -> Void = { _ in }) -> TextLook {
        plain(.white, f, caps: caps, spacing: spacing, bold: bold, fx: extra)
    }
    static func softShadow(_ c: RGBA, distance: Double, blur: Double) -> (inout TextContent) -> Void {
        { t in t.shadowColor = c; t.shadow = TextShadowStyle(distance: distance, angle: 60, blur: blur) }
    }
    static func hardShadow(_ c: RGBA, distance: Double) -> (inout TextContent) -> Void {
        { t in t.shadowColor = c; t.shadow = TextShadowStyle(distance: distance, angle: 45, blur: 0) }
    }

    static let AR = "ArialRoundedMTBold", chalk = "ChalkboardSE-Bold", chalkR = "ChalkboardSE-Regular"
    static let condHeavy = "AvenirNextCondensed-Heavy", din = "DINCondensed-Bold", futuraXB = "Futura-CondensedExtraBold"

    // MARK: The table (designer spec §4)

    /// Paired look per preset id.
    public static let looks: [String: TextLook] = {
        let shadow13 = BuiltinTextStyles.shadows[12], shadow16 = BuiltinTextStyles.shadows[15]
        // one closure per entry: each look is built in its own small frame (a single literal of 60 built
        // looks overflowed the 512 KB test-thread stack in debug builds)
        let m: [(String, () -> TextLook)] = [
            // Neon (TX-NEON rework: like the owner's reference sign, a neon frame holds plain white letters; the sign-like
            // presets - burst, duo, night sign, flicker - keep neon letters)
            ("neonPinkPill", { signWhite(AR) }),
            ("neonCyanBox", { signWhite("Futura-Medium", caps: true, spacing: 0.08) }),
            ("neonLimeSpeech", { signWhite("AvenirNext-Medium") }),
            ("neonVioletThought", { signWhite("Noteworthy-Bold") }),
            ("neonOrangeBurst", { neon(Bub.amber, condHeavy, caps: true) }),
            ("neonRedOval", { signWhite(din, caps: true, spacing: 0.1) }),
            ("neonIceBrackets", { signWhite("Menlo-Bold", caps: true, spacing: 0.06) }),
            ("neonAmberArrow", { signWhite(din, caps: true, spacing: 0.06) }),
            ("neonDuo", { neon(Bub.pink, tube: 25, fx: hardShadow(Bub.cyan, distance: 0.06)) }),
            ("neonNightSign", { neon(Bub.cyan, "SnellRoundhand-Bold", spacing: 0, tube: 26, glowSize: 0.28, duskGuard: false) }),
            // the faulty tube and the faulty letter share one envelope: frame and letter fail together
            ("neonFlicker", { neon(Bub.cyan, tube: 26, flicker: .oneLetter) }),
            ("neonMarquee", { L { t in art(BuiltinTextStyles.neons[2], &t); font(&t, futuraXB, caps: true, spacing: 0.05) } }),
            // Outline
            ("outlineSpeech", { onVideo() }),
            ("outlinePillDark", { inkL(fx: softShadow(RGBA(1, 1, 1, 0.4), distance: 0, blur: 0.15)) }),
            ("dashedFrame", { onVideo(.white, "AvenirNext-DemiBold", caps: true, spacing: 0.06) }),
            ("dottedCloud", { onVideo(.white, chalk) }),
            ("thinOval", { onVideo(.white, "AvenirNext-Medium", caps: true, spacing: 0.12) }),
            ("frostedPill", { paperL(fx: softShadow(RGBA(0, 0, 0, 0.35), distance: 0.03, blur: 0.1)) }),
            ("smokeBox", { paperL(fx: softShadow(RGBA(0, 0, 0, 0.5), distance: 0.04, blur: 0.08)) }),
            // Speech
            ("speechWhite", { inkL() }), ("speechBlack", { paperL() }), ("speechYellow", { inkL() }), ("speechBlue", { paperL() }),
            ("thought", { inkL("Noteworthy-Bold") }), ("cloud", { inkL(chalk) }),
            ("chat", { paperL(fx: softShadow(RGBA(hex: 0x0B4D1F, alpha: 0.55), distance: 0.03, blur: 0.05)) }),
            // Comic
            ("comicClassic", { inkL(chalk, caps: true, spacing: 0.02) }),
            ("comicShout", { inkL(chalk, caps: true, spacing: 0.02, italic: true) }),
            ("comicPow", { L { t in art(shadow16, &t); font(&t, "Impact", caps: true, spacing: 0.02); t.italic = true } }),
            ("comicWhisper", { plain(RGBA(hex: 0x4A4A4A), chalkR, bold: false) }),
            ("comicDaydream", { inkL(chalkR, caps: true, bold: false) }),
            ("comicCaption", { inkL("AmericanTypewriter-Semibold") }),
            ("comicRetro", { L { t in art(shadow13, &t); font(&t, futuraXB, caps: true, spacing: 0.03) } }),
            // Social
            ("chatSent", { paperL(bold: false) }), ("chatReceived", { inkL(bold: false) }), ("commentCard", { inkL(bold: false) }),
            ("ctaPill", { paperL(caps: true, spacing: 0.04) }),
            ("newBadge", { paperL(condHeavy, caps: true, spacing: 0.02) }),
            ("promoTag", { inkL(condHeavy, caps: true) }),
            ("hashtagChip", { paperL() }),
            // Labels
            ("labelWhite", { inkL() }), ("labelBlack", { paperL() }), ("pillPink", { paperL() }), ("pillYellow", { inkL() }),
            ("outlineBox", { onVideo() }),
            ("ellipse", { inkL("AvenirNext-DemiBold") }),
            ("hexagon", { paperL("AvenirNextCondensed-Bold", caps: true, spacing: 0.06) }),
            ("tag", { paperL(din, caps: true, spacing: 0.04) }),
            ("brackets", { onVideo(.white, "Menlo-Bold") }),
            ("underline", { onVideo() }),
            // Minimal
            ("squareBlock", { paperL("HelveticaNeue-Bold", spacing: -0.01) }),
            ("softCard", { plain(RGBA(hex: 0x2B2B2B), "Georgia", bold: false) }),
            ("highlighter", { inkL() }),
            // Banners
            ("bannerRed", { paperL(futuraXB, caps: true, spacing: 0.04) }),
            ("bannerBlue", { paperL(futuraXB, caps: true, spacing: 0.04) }),
            ("ribbon", { paperL(futuraXB, caps: true, spacing: 0.04, fx: hardShadow(RGBA(hex: 0x1E7B34), distance: 0.05)) }),
            ("arrow", { inkL(din, caps: true, spacing: 0.06) }),
            ("burstYellow", { inkL("Impact", caps: true) }),
            ("burstRed", { paperL("Impact", caps: true) }),
            ("burstPink", { paperL("Impact", caps: true, fx: { t in t.strokeColor = RGBA(hex: 0xB0236A); t.strokeWidth = 0.06; t.strokePosition = .outside }) }),
            // Round (circle family)
            ("roundSpeech", { inkL(chalk, caps: true, spacing: 0.02) }),
            ("roundBadge", { onVideo(.white, "AvenirNext-DemiBold", caps: true, spacing: 0.08) }),
            ("roundNeon", { neon(Bub.cyan, AR, tube: 26) }),
        ]
        return Dictionary(uniqueKeysWithValues: m.map { ("valse.bubble.\($0.0)", $0.1()) })
    }()

    /// Presets whose text colour is a deliberate duo, not the outline colour (Customize colour linking skips them).
    static let duos: Set<String> = ["valse.bubble.neonDuo", "valse.bubble.neonNightSign", "valse.bubble.neonOrangeBurst"]

    /// Paired look of preset `id`. On karaoke captions a neon tube (which ignores the text colour, so the highlight
    /// would vanish) degrades to the glow neon word art in the same colour.
    public static func look(_ id: String, karaoke: Bool = false) -> TextLook? {
        guard var l = looks[id] else { return nil }
        if karaoke, let n = l.neon {
            l.neon = nil
            l.color = n.color.mix(.white, 0.75)
            l.glow = TextGlowStyle(color: n.color, intensity: 1, radius: 0.35, mode: .outer)
            l.styleID = nil
        }
        return l
    }

    // MARK: Applying

    /// A bubble tile pick (`d` nil = None) on one text: bubble fields + a three-way merge of the look.
    /// - first pick (no snapshot): snapshots the look, applies the pairing; font, case and spacing only when the text
    ///   still has the defaults (a font the user chose is kept).
    /// - switch: every field still equal to the previous pairing takes the new one; fields the user edited stay.
    /// - None: fields still equal to the pairing go back to the snapshot (plain white, font kept, without one).
    public static func pick(_ d: TextBubbleDescriptor?, on t: inout TextContent, pairText: Bool = true) {
        let karaoke = t.karaoke != nil
        let prev = t.bubbleID.flatMap { look($0, karaoke: karaoke) }
        let original = t.look   // before the bubble turns the flat Background off (None brings it back)
        t.bubbleID = d?.id
        t.bubbleColor = nil
        t.bubbleStyle = nil
        if d != nil {
            t.runs = t.runs.map { var r = $0; r.style.color = nil; return r }
            t.backgroundColor.a = 0
        }
        guard pairText else { return }
        let cur = t.look
        let new = d.flatMap { look($0.id, karaoke: karaoke) }
        var out = cur
        if let prior = t.bubblePriorLook, let prev {
            let target = new ?? prior
            for f in TextLook.fields where f.same(cur, prev) { f.take(&out, from: target) }
            t.look = out
            t.bubblePriorLook = d == nil ? nil : prior
            return
        }
        if let new {
            // first pick (or a bubble set before pairing existed: its text look counts as the user's, minus effects)
            let defaults = TextLook.plain()
            for f in TextLook.fields where !f.typography || f.same(cur, defaults) { f.take(&out, from: new) }
            t.bubblePriorLook = prev == nil ? original : TextLook.plain(fontName: cur.fontName, textCase: cur.textCase, letterSpacing: cur.letterSpacing)
            t.look = out
        } else {
            if let prev {
                let plain = TextLook.plain()
                for f in TextLook.fields where !f.typography && f.same(cur, prev) { f.take(&out, from: plain) }
                t.look = out
            }
            t.bubblePriorLook = nil
        }
    }

    /// Customize ▸ Reset: the preset bubble and its paired text again (a font the user chose is kept).
    public static func reset(_ t: inout TextContent) {
        t.bubbleStyle = nil; t.bubbleColor = nil
        guard let id = t.bubbleID, let new = look(id, karaoke: t.karaoke != nil) else { return }
        let cur = t.look
        if t.bubblePriorLook == nil { t.bubblePriorLook = TextLook.plain(fontName: cur.fontName, textCase: cur.textCase, letterSpacing: cur.letterSpacing) }
        var out = new
        if !cur.fontName.isEmpty, cur.fontName != new.fontName { out.fontName = cur.fontName; out.bold = cur.bold }
        t.look = out
    }

    /// Linked colours: after a Customize edit of the bubble, the text follows an outline recolour when it still had the
    /// old outline colour (its neon tube, or its colour on a transparent bubble). Duo presets are not linked.
    public static func followOutline(_ t: inout TextContent, before: TextBubbleStyle?) {
        guard let id = t.bubbleID, !duos.contains(id), let old = before?.outline?.color,
              let new = t.resolvedBubble()?.outline?.color, old != new else { return }
        if var n = t.neon, n.color == old { n.color = new; t.neon = n }
        else if t.neon == nil, (before?.fill.a ?? 1) == 0, t.color == old { t.color = new }
    }
}
