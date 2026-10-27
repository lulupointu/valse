import Foundation
import ValseCore

/// Text In / Out / Loop animations (TX-020): per character / word / line, staggered, descriptor-driven (`GlyphAnimationSpec`).
/// Registered in `Registries.animations` with `targets: .text`; the text engine renders them per glyph.
public enum BuiltinTextAnimations {
    public typealias D = AnimationDescriptor
    public typealias G = GlyphAnimationSpec

    // Easing
    static func out3(_ t: Double) -> Double { 1 - pow(1 - min(max(t, 0), 1), 3) }
    static func in2(_ t: Double) -> Double { let x = min(max(t, 0), 1); return x * x }
    static func backOut(_ t: Double, _ s: Double = 1.70158) -> Double { let x = min(max(t, 0), 1) - 1; return x * x * ((s + 1) * x + s) + 1 }
    static func elasticOut(_ t: Double) -> Double {
        let x = min(max(t, 0), 1)
        if x == 0 || x == 1 { return x }
        return pow(2, -10 * x) * sin((x * 10 - 0.75) * (2 * .pi / 3)) + 1
    }
    static func bounceOut(_ t: Double) -> Double {
        var x = min(max(t, 0), 1)
        let n = 7.5625, d = 2.75
        if x < 1 / d { return n * x * x }
        if x < 2 / d { x -= 1.5 / d; return n * x * x + 0.75 }
        if x < 2.5 / d { x -= 2.25 / d; return n * x * x + 0.9375 }
        x -= 2.625 / d; return n * x * x + 0.984375
    }

    static func a(_ name: String, _ phase: AnimationPhaseKind, _ symbol: String, duration: Double, _ g: G) -> D {
        D(id: "valse.anim.text.\(phase.rawValue).\(name)", phase: phase, targets: .text, nameKey: "anim.text.\(name)",
          symbol: symbol, defaultDuration: Time(duration), glyph: g)
    }

    // MARK: In (t: 0 hidden → 1 rest)

    static let ins: [D] = [
        a("typewriter", .in, "character.cursor.ibeam", duration: 1.2, G(unit: .character, span: 0.04, extent: 0.2) { t, _, s in
            s.opacity = t >= 0.5 ? 1 : 0
        }),
        a("fadeChars", .in, "textformat.abc", duration: 1.0, G(unit: .character, span: 0.3, extent: 0.2) { t, _, s in s.opacity = t }),
        a("popChars", .in, "sparkle", duration: 0.9, G(unit: .character, span: 0.3) { t, _, s in
            let k = backOut(t, 2.2); s.scale = Vec2(k, k); s.opacity = min(t * 3, 1)
        }),
        a("drop", .in, "arrow.down.to.line", duration: 1.0, G(unit: .character, span: 0.35, extent: 1.4) { t, _, s in
            s.offset.y = -(1 - bounceOut(t)) * 1.2; s.opacity = min(t * 4, 1)
        }),
        a("rise", .in, "arrow.up", duration: 0.9, G(unit: .character, span: 0.3) { t, _, s in
            s.offset.y = (1 - out3(t)) * 0.8; s.opacity = t
        }),
        a("slideChars", .in, "arrow.left", duration: 0.9, G(unit: .character, span: 0.35, extent: 1.2) { t, _, s in
            s.offset.x = (1 - out3(t)) * 1.0; s.opacity = t
        }),
        a("spinChars", .in, "arrow.triangle.2.circlepath", duration: 1.0, G(unit: .character, span: 0.4) { t, _, s in
            let e = out3(t); s.rotation = (1 - e) * -180; s.scale = Vec2(e, e); s.opacity = t
        }),
        a("bounceIn", .in, "figure.jumprope", duration: 1.2, G(unit: .character, span: 0.4, extent: 1.6) { t, _, s in
            s.offset.y = -(1 - bounceOut(t)) * 1.5; s.opacity = min(t * 5, 1)
        }),
        a("flip", .in, "rectangle.2.swap", duration: 0.9, G(unit: .character, span: 0.35) { t, _, s in
            s.scale = Vec2(out3(t), 1); s.opacity = t
        }),
        a("stretch", .in, "arrow.up.and.down", duration: 1.0, G(unit: .character, span: 0.4) { t, _, s in
            s.scale = Vec2(1, max(elasticOut(t), 0.01)); s.opacity = min(t * 3, 1)
        }),
        a("elastic", .in, "waveform.path", duration: 1.1, G(unit: .character, span: 0.4) { t, _, s in
            let k = elasticOut(t); s.scale = Vec2(k, k); s.opacity = min(t * 4, 1)
        }),
        a("scatter", .in, "circle.grid.cross", duration: 1.2, G(unit: .character, span: 0.6, extent: 3) { t, u, s in
            let e = out3(t), ang = u.random * 2 * .pi, r = 2.5 * (1 - e)
            s.offset = Vec2(cos(ang) * r, sin(ang) * r); s.rotation = (1 - e) * (u.random - 0.5) * 360; s.opacity = t
        }),
        a("randomFade", .in, "sparkles", duration: 1.0, G(unit: .character, order: .random, span: 0.3, extent: 0.2) { t, _, s in s.opacity = t }),
        a("centerOut", .in, "arrow.left.and.right", duration: 0.9, G(unit: .character, order: .center, span: 0.35) { t, _, s in
            let k = out3(t); s.scale = Vec2(k, k); s.opacity = t
        }),
        a("swingIn", .in, "metronome", duration: 1.0, G(unit: .character, span: 0.4) { t, _, s in
            s.rotation = (1 - elasticOut(t)) * 60; s.opacity = min(t * 3, 1)
        }),
        a("rollIn", .in, "arrow.turn.right.down", duration: 1.0, G(unit: .character, span: 0.4) { t, _, s in
            let e = out3(t); s.offset.y = (1 - e) * 0.6; s.rotation = (1 - e) * 90; s.opacity = t
        }),
        a("zoomWords", .in, "plus.magnifyingglass", duration: 0.9, G(unit: .word, span: 0.45) { t, _, s in
            let k = 2 - out3(t); s.scale = Vec2(k, k); s.opacity = t
        }),
        a("popWords", .in, "bubble.left", duration: 0.8, G(unit: .word, span: 0.45) { t, _, s in
            let k = backOut(t, 2.5); s.scale = Vec2(k, k); s.opacity = min(t * 3, 1)
        }),
        a("riseWords", .in, "text.line.first.and.arrowtriangle.forward", duration: 0.9, G(unit: .word, span: 0.5) { t, _, s in
            s.offset.y = (1 - out3(t)) * 0.9; s.opacity = t
        }),
        a("slideLines", .in, "text.alignleft", duration: 0.9, G(unit: .line, span: 0.6, extent: 2) { t, _, s in
            s.offset.x = -(1 - out3(t)) * 1.5; s.opacity = t
        }),
        a("riseLines", .in, "text.justify", duration: 0.9, G(unit: .line, span: 0.6) { t, _, s in
            s.offset.y = (1 - out3(t)) * 0.7; s.opacity = t
        }),
        a("blowUp", .in, "arrow.up.left.and.arrow.down.right", duration: 0.7, G(unit: .all) { t, _, s in
            let k = 0.3 + 0.7 * backOut(t); s.scale = Vec2(k, k); s.opacity = t
        }),
    ]

    // MARK: Out (t: 0 rest → 1 gone)

    static let outs: [D] = [
        a("backspace", .out, "delete.left", duration: 1.0, G(unit: .character, order: .backward, span: 0.04, extent: 0.2) { t, _, s in
            s.opacity = t >= 0.5 ? 0 : 1
        }),
        a("fadeCharsOut", .out, "textformat.abc", duration: 0.9, G(unit: .character, span: 0.3, extent: 0.2) { t, _, s in s.opacity = 1 - t }),
        a("popCharsOut", .out, "sparkle", duration: 0.8, G(unit: .character, span: 0.3) { t, _, s in
            let k = 1 - in2(t); s.scale = Vec2(k, k); s.opacity = 1 - t
        }),
        a("fall", .out, "arrow.down", duration: 1.0, G(unit: .character, order: .random, span: 0.5, extent: 2) { t, u, s in
            let e = in2(t); s.offset.y = e * 1.8; s.rotation = e * (u.random - 0.5) * 120; s.opacity = 1 - t
        }),
        a("riseOut", .out, "arrow.up", duration: 0.8, G(unit: .character, span: 0.3) { t, _, s in
            s.offset.y = -in2(t) * 0.8; s.opacity = 1 - t
        }),
        a("slideCharsOut", .out, "arrow.right", duration: 0.8, G(unit: .character, span: 0.35, extent: 1.2) { t, _, s in
            s.offset.x = in2(t) * 1.0; s.opacity = 1 - t
        }),
        a("spinOut", .out, "arrow.triangle.2.circlepath", duration: 0.9, G(unit: .character, span: 0.4) { t, _, s in
            s.rotation = in2(t) * 180; let k = 1 - in2(t); s.scale = Vec2(k, k); s.opacity = 1 - t
        }),
        a("scatterOut", .out, "circle.grid.cross", duration: 1.0, G(unit: .character, span: 0.6, extent: 3) { t, u, s in
            let e = in2(t), ang = u.random * 2 * .pi
            s.offset = Vec2(cos(ang) * 2.5 * e, sin(ang) * 2.5 * e); s.opacity = 1 - t
        }),
        a("randomFadeOut", .out, "sparkles", duration: 0.9, G(unit: .character, order: .random, span: 0.3, extent: 0.2) { t, _, s in s.opacity = 1 - t }),
        a("flipOut", .out, "rectangle.2.swap", duration: 0.8, G(unit: .character, span: 0.35) { t, _, s in
            s.scale = Vec2(max(1 - in2(t), 0), 1); s.opacity = 1 - t
        }),
        a("shrinkWords", .out, "minus.magnifyingglass", duration: 0.8, G(unit: .word, span: 0.45) { t, _, s in
            let k = 1 - in2(t); s.scale = Vec2(k, k); s.opacity = 1 - t
        }),
        a("slideLinesOut", .out, "text.alignright", duration: 0.8, G(unit: .line, span: 0.6, extent: 2) { t, _, s in
            s.offset.x = in2(t) * 1.5; s.opacity = 1 - t
        }),
    ]

    // MARK: Loop (t: one cycle)

    static let loops: [D] = [
        a("wave", .combo, "water.waves", duration: 1.2, G(unit: .character, waveSpread: 0.8, extent: 0.5) { t, _, s in
            s.offset.y = -sin(t * 2 * .pi) * 0.22
        }),
        a("jiggle", .combo, "tornado", duration: 0.6, G(unit: .character, order: .random, waveSpread: 1) { t, _, s in
            s.rotation = sin(t * 2 * .pi) * 10
        }),
        a("pulseChars", .combo, "heart", duration: 1.0, G(unit: .character, waveSpread: 0.7) { t, _, s in
            let k = 1 + 0.18 * max(0, sin(t * 2 * .pi)); s.scale = Vec2(k, k)
        }),
        a("float", .combo, "cloud", duration: 2.0, G(unit: .word, waveSpread: 0.5, extent: 0.5) { t, _, s in
            s.offset.y = sin(t * 2 * .pi) * 0.12
        }),
        a("flicker", .combo, "lightbulb", duration: 1.5, G(unit: .character, order: .random, waveSpread: 1, extent: 0.1) { t, u, s in
            let k = Int(t * 12) + Int(u.random * 97)
            s.opacity = glyphRandom(k, seed: u.index) > 0.82 ? 0.25 : 1
        }),
        a("shake", .combo, "waveform", duration: 0.4, G(unit: .character, order: .random, waveSpread: 1, extent: 0.3) { t, u, s in
            let k = Int(t * 6)
            s.offset = Vec2((glyphRandom(k, seed: u.index) - 0.5) * 0.12, (glyphRandom(k + 31, seed: u.index) - 0.5) * 0.12)
        }),
        a("hop", .combo, "figure.jumprope", duration: 1.0, G(unit: .character, waveSpread: 1, extent: 0.6) { t, _, s in
            s.offset.y = -abs(sin(t * .pi)) * 0.35
        }),
        a("swingWords", .combo, "metronome", duration: 1.4, G(unit: .word, waveSpread: 0.4) { t, _, s in
            s.rotation = sin(t * 2 * .pi) * 10
        }),
        a("breathe", .combo, "lungs", duration: 1.6, G(unit: .all) { t, _, s in
            let k = 1 + 0.06 * sin(t * 2 * .pi); s.scale = Vec2(k, k)
        }),
        a("heartbeat", .combo, "heart.fill", duration: 1.0, G(unit: .all) { t, _, s in
            let beat = t < 0.15 ? sin(t / 0.15 * .pi) : (t > 0.25 && t < 0.4 ? sin((t - 0.25) / 0.15 * .pi) * 0.6 : 0)
            let k = 1 + 0.12 * beat; s.scale = Vec2(k, k)
        }),
        a("sway", .combo, "wind", duration: 2.0, G(unit: .line, waveSpread: 0.3, extent: 0.4) { t, _, s in
            s.offset.x = sin(t * 2 * .pi) * 0.15
        }),
    ]

    public static let all: [D] = ins + outs + loops
}
