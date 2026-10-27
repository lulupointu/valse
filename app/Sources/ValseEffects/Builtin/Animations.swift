import Foundation
import ValseCore

/// Easing curves for the animation presets (progress 0…1 → 0…1; `back`/`elastic` overshoot).
public enum AnimEase {
    public static func linear(_ x: Double) -> Double { clamp(x) }
    public static func outCubic(_ x: Double) -> Double { let t = clamp(x); return 1 - pow(1 - t, 3) }
    public static func inCubic(_ x: Double) -> Double { let t = clamp(x); return t * t * t }
    public static func inOutCubic(_ x: Double) -> Double { let t = clamp(x); return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
    public static func outQuad(_ x: Double) -> Double { let t = clamp(x); return 1 - (1 - t) * (1 - t) }
    public static func inQuad(_ x: Double) -> Double { let t = clamp(x); return t * t }
    public static func outBack(_ x: Double) -> Double {
        let t = clamp(x), c1 = 1.70158, c3 = c1 + 1, u = t - 1
        return 1 + c3 * u * u * u + c1 * u * u
    }
    public static func inBack(_ x: Double) -> Double { let t = clamp(x), c1 = 1.70158, c3 = c1 + 1; return c3 * t * t * t - c1 * t * t }
    public static func outBounce(_ x: Double) -> Double {
        let t = clamp(x), n1 = 7.5625, d1 = 2.75
        if t < 1 / d1 { return n1 * t * t }
        if t < 2 / d1 { let u = t - 1.5 / d1; return n1 * u * u + 0.75 }
        if t < 2.5 / d1 { let u = t - 2.25 / d1; return n1 * u * u + 0.9375 }
        let u = t - 2.625 / d1; return n1 * u * u + 0.984375
    }
    public static func outElastic(_ x: Double) -> Double {
        let t = clamp(x)
        if t == 0 || t == 1 { return t }
        return pow(2, -10 * t) * sin((t * 10 - 0.75) * (2 * .pi / 3)) + 1
    }
    static func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
}

/// "Animation" inspector tab: In / Out / Combo (video, image) and In / Out / Loop (sticker, text) presets (W5,
/// FEATURES CV-012, KF-010, ST-004).
///
/// Presets are generated from *motions*: `motion(k, &state)` moves a layer away from its rest state by an amount
/// `k` (0 = at rest, 1 = fully "away": hidden, off-screen, flipped…). An In preset runs `k = 1 − ease(p)`, an Out
/// preset `k = easeIn(p)`, so In ends and Out starts exactly at the clip's keyframed state. Combos (video) play an in
/// motion over the first part of the clip and an out motion over the last; Loops (stickers, text) repeat a periodic
/// motion that starts and ends at rest. Ids are persisted: never rename, only append.
///
/// Text: these generic transform presets also target text until the text team (W7) registers per-glyph presets in the
/// same registry (`Registries.animations.register`, targets `.text`).
public enum BuiltinAnimations {
    public typealias Motion = @Sendable (_ k: Double, _ s: inout AnimatedLayerState) -> Void
    static func ease(_ x: Double) -> Double { AnimEase.outCubic(x) }

    /// In preset from a motion.
    static func inAnim(_ name: String, _ nameKey: String, _ symbol: String, targets: AnimationTargets = .all,
                       duration: Double = 0.5, ease: @escaping @Sendable (Double) -> Double = AnimEase.outCubic,
                       _ m: @escaping Motion) -> AnimationDescriptor {
        AnimationDescriptor(id: "valse.anim.in.\(name)", phase: .in, targets: targets, nameKey: nameKey, symbol: symbol,
                            defaultDuration: Time(duration)) { p, s in m(1 - ease(p), &s) }
    }

    /// Out preset from a motion.
    static func outAnim(_ name: String, _ nameKey: String, _ symbol: String, targets: AnimationTargets = .all,
                        duration: Double = 0.5, ease: @escaping @Sendable (Double) -> Double = AnimEase.inCubic,
                        _ m: @escaping Motion) -> AnimationDescriptor {
        AnimationDescriptor(id: "valse.anim.out.\(name)", phase: .out, targets: targets, nameKey: nameKey, symbol: symbol,
                            defaultDuration: Time(duration)) { p, s in m(ease(p), &s) }
    }

    /// Video combo over the whole clip: `inM` over [0, edge], rest, `outM` over [1 − edge, 1]; `hold` runs across.
    static func combo(_ name: String, _ symbol: String, edge: Double = 0.3, _ inM: @escaping Motion, _ outM: @escaping Motion,
                      hold: (@Sendable (Double, inout AnimatedLayerState) -> Void)? = nil) -> AnimationDescriptor {
        AnimationDescriptor(id: "valse.anim.combo.\(name)", phase: .combo, targets: .video, nameKey: "anim.combo.\(name)",
                            symbol: symbol, defaultDuration: Time(3)) { p, s in
            hold?(p, &s)
            if p < edge { inM(1 - AnimEase.outCubic(p / edge), &s) }
            else if p > 1 - edge { outM(AnimEase.inCubic((p - (1 - edge)) / edge), &s) }
        }
    }

    /// Sticker / text loop: a periodic function of the loop phase (sin/cos of 2πp start and end at rest).
    static func loop(_ name: String, _ symbol: String, duration: Double = 1,
                     _ body: @escaping @Sendable (Double, inout AnimatedLayerState) -> Void) -> AnimationDescriptor {
        AnimationDescriptor(id: "valse.anim.loop.\(name)", phase: .combo, targets: [.sticker, .text],
                            nameKey: "anim.loop.\(name)", symbol: symbol, defaultDuration: Time(duration), apply: body)
    }

    // MARK: Motions (k = 0 rest … 1 away)

    static let fade: Motion = { k, s in s.opacity *= 1 - k }
    static func slide(_ dx: Double, _ dy: Double, fade f: Bool = true) -> Motion {
        { k, s in s.transform.position.x += dx * k; s.transform.position.y += dy * k; if f { s.opacity *= 1 - k } }
    }
    static func scale(_ to: Double, fade f: Bool = true) -> Motion {
        { k, s in s.transform.scale = s.transform.scale * (1 + (to - 1) * k); if f { s.opacity *= 1 - k } }
    }
    static func rotate(_ degrees: Double, scaleTo: Double = 1, fade f: Bool = true) -> Motion {
        { k, s in
            s.transform.rotation += degrees * k
            if scaleTo != 1 { s.transform.scale = s.transform.scale * (1 + (scaleTo - 1) * k) }
            if f { s.opacity *= 1 - k }
        }
    }
    /// 3D flip around the vertical (horizontal = false: horizontal) axis, faked by squashing.
    static func flip(vertical: Bool) -> Motion {
        { k, s in
            let c = cos(k * .pi / 2)
            if vertical { s.transform.scale.y *= c } else { s.transform.scale.x *= c }
            s.opacity *= 1 - 0.3 * k
        }
    }
    static let blur: Motion = { k, s in s.blur += 0.03 * k; s.opacity *= 1 - 0.6 * k }
    /// Reveal (wipe): `side` hidden fraction grows with k (0 left, 1 top, 2 right, 3 bottom; 4 = both sides to centre).
    static func wipe(_ side: Int) -> Motion {
        { k, s in
            switch side {
            case 0: s.reveal.left = max(s.reveal.left, k)
            case 1: s.reveal.top = max(s.reveal.top, k)
            case 2: s.reveal.right = max(s.reveal.right, k)
            case 3: s.reveal.bottom = max(s.reveal.bottom, k)
            default: s.reveal.left = max(s.reveal.left, k / 2); s.reveal.right = max(s.reveal.right, k / 2)
            }
        }
    }
    static let swing: Motion = { k, s in s.transform.rotation += -35 * k; s.transform.position.x -= 0.08 * k; s.opacity *= 1 - k }
    static let swirl: Motion = { k, s in s.transform.rotation += 270 * k; s.transform.scale = s.transform.scale * (1 - 0.85 * k); s.opacity *= 1 - 0.5 * k }
    static let stretch: Motion = { k, s in s.transform.scale.x *= 1 + 1.6 * k; s.transform.scale.y *= 1 - 0.6 * k; s.opacity *= 1 - k }
    static let tilt: Motion = { k, s in s.transform.rotation += 20 * k; s.transform.position.y += 0.15 * k; s.opacity *= 1 - k }
    static let zoomBlur: Motion = { k, s in s.transform.scale = s.transform.scale * (1 + 0.5 * k); s.blur += 0.02 * k; s.opacity *= 1 - k }
    static let roll: Motion = { k, s in s.transform.position.x -= 0.6 * k; s.transform.rotation -= 240 * k }
    static let fold: Motion = { k, s in s.transform.scale.y *= 1 - k }
    static let flicker: Motion = { k, s in
        let on = (k * 7).truncatingRemainder(dividingBy: 1) < 0.5
        s.opacity *= k < 0.05 ? 1 : (on ? 1 - k * 0.6 : 1 - k)
    }
    static let shake: Motion = { k, s in
        // decaying jitter: k sweeps 1 → 0 on In, so phase = k
        s.transform.position.x += sin(k * .pi * 14) * 0.05 * k
        s.transform.rotation += sin(k * .pi * 11) * 6 * k
        s.opacity *= 1 - 0.5 * k
    }

    // MARK: In

    static let ins: [AnimationDescriptor] = [
        // persisted foundation ids
        inAnim("fade", "anim.fadeIn", "circle.lefthalf.filled", fade),
        inAnim("slideUp", "anim.slideUp", "arrow.up", slide(0, 0.25)),
        inAnim("slideRight", "anim.slideRight", "arrow.right", slide(-0.3, 0)),
        inAnim("zoom", "anim.zoomIn", "plus.magnifyingglass", scale(0.6)),
        inAnim("spin", "anim.spinIn", "arrow.clockwise", rotate(-180, scaleTo: 0, fade: false)),
        // W5
        inAnim("slideDown", "anim.in.slideDown", "arrow.down", slide(0, -0.25)),
        inAnim("slideLeft", "anim.in.slideLeft", "arrow.left", slide(0.3, 0)),
        inAnim("flyUp", "anim.in.flyUp", "arrow.up.to.line", ease: AnimEase.outQuad, slide(0, 1, fade: false)),
        inAnim("flyLeft", "anim.in.flyLeft", "arrow.left.to.line", ease: AnimEase.outQuad, slide(1, 0, fade: false)),
        inAnim("zoomOut", "anim.in.zoomOut", "minus.magnifyingglass", scale(1.8)),
        inAnim("rotate", "anim.in.rotate", "rotate.right", rotate(-90)),
        inAnim("flipH", "anim.in.flipH", "arrow.left.and.right.righttriangle.left.righttriangle.right", flip(vertical: false)),
        inAnim("flipV", "anim.in.flipV", "arrow.up.and.down.righttriangle.up.righttriangle.down", flip(vertical: true)),
        inAnim("blur", "anim.in.blur", "drop.fill", blur),
        inAnim("wipeRight", "anim.in.wipeRight", "rectangle.righthalf.inset.filled", ease: AnimEase.inOutCubic, wipe(2)),
        inAnim("wipeLeft", "anim.in.wipeLeft", "rectangle.lefthalf.inset.filled", ease: AnimEase.inOutCubic, wipe(0)),
        inAnim("wipeDown", "anim.in.wipeDown", "rectangle.bottomhalf.inset.filled", ease: AnimEase.inOutCubic, wipe(3)),
        inAnim("wipeUp", "anim.in.wipeUp", "rectangle.tophalf.inset.filled", ease: AnimEase.inOutCubic, wipe(1)),
        inAnim("openCenter", "anim.in.openCenter", "arrow.left.and.right", ease: AnimEase.inOutCubic, wipe(4)),
        inAnim("swing", "anim.in.swing", "metronome", ease: AnimEase.outBack, swing),
        inAnim("bounce", "anim.in.bounce", "arrow.down.to.line", duration: 0.8, ease: AnimEase.outBounce, slide(0, -0.6, fade: false)),
        inAnim("pop", "anim.in.pop", "bubble.left.fill", ease: AnimEase.outBack, scale(0, fade: false)),
        inAnim("elastic", "anim.in.elastic", "waveform.path", duration: 0.8, ease: AnimEase.outElastic, scale(0, fade: false)),
        inAnim("shake", "anim.in.shake", "iphone.radiowaves.left.and.right", duration: 0.6, ease: AnimEase.linear, shake),
        inAnim("swirl", "anim.in.swirl", "hurricane", swirl),
        inAnim("stretch", "anim.in.stretch", "arrow.left.and.right.square", stretch),
        inAnim("tilt", "anim.in.tilt", SFSymbolCompat.compat("rectangle.portrait.rotate"), tilt),
        inAnim("zoomBlur", "anim.in.zoomBlur", "circle.circle", zoomBlur),
        inAnim("rollIn", "anim.in.rollIn", "arrow.uturn.right.circle", roll),
        inAnim("flicker", "anim.in.flicker", SFSymbolCompat.compat("lightbulb.max"), ease: AnimEase.linear, flicker),
        inAnim("unfold", "anim.in.unfold", "rectangle.expand.vertical", ease: AnimEase.outBack, fold),
    ]

    // MARK: Out

    static let outs: [AnimationDescriptor] = [
        // persisted foundation ids
        outAnim("fade", "anim.fadeOut", "circle.righthalf.filled", fade),
        outAnim("slideDown", "anim.slideDown", "arrow.down", slide(0, 0.25)),
        outAnim("zoom", "anim.zoomOut", "minus.magnifyingglass", scale(0.6)),
        // W5
        outAnim("slideUp", "anim.out.slideUp", "arrow.up", slide(0, -0.25)),
        outAnim("slideLeft", "anim.out.slideLeft", "arrow.left", slide(-0.3, 0)),
        outAnim("slideRight", "anim.out.slideRight", "arrow.right", slide(0.3, 0)),
        outAnim("flyDown", "anim.out.flyDown", "arrow.down.to.line", ease: AnimEase.inQuad, slide(0, 1, fade: false)),
        outAnim("flyRight", "anim.out.flyRight", "arrow.right.to.line", ease: AnimEase.inQuad, slide(1, 0, fade: false)),
        outAnim("zoomIn", "anim.out.zoomIn", "plus.magnifyingglass", scale(1.8)),
        outAnim("spin", "anim.out.spin", "arrow.counterclockwise", rotate(180, scaleTo: 0, fade: false)),
        outAnim("rotate", "anim.out.rotate", "rotate.left", rotate(90)),
        outAnim("flipH", "anim.out.flipH", "arrow.left.and.right.righttriangle.left.righttriangle.right", flip(vertical: false)),
        outAnim("flipV", "anim.out.flipV", "arrow.up.and.down.righttriangle.up.righttriangle.down", flip(vertical: true)),
        outAnim("blur", "anim.out.blur", "drop", blur),
        outAnim("wipeRight", "anim.out.wipeRight", "rectangle.righthalf.inset.filled", ease: AnimEase.inOutCubic, wipe(0)),
        outAnim("wipeLeft", "anim.out.wipeLeft", "rectangle.lefthalf.inset.filled", ease: AnimEase.inOutCubic, wipe(2)),
        outAnim("wipeDown", "anim.out.wipeDown", "rectangle.bottomhalf.inset.filled", ease: AnimEase.inOutCubic, wipe(1)),
        outAnim("wipeUp", "anim.out.wipeUp", "rectangle.tophalf.inset.filled", ease: AnimEase.inOutCubic, wipe(3)),
        outAnim("closeCenter", "anim.out.closeCenter", "arrow.right.and.line.vertical.and.arrow.left", ease: AnimEase.inOutCubic, wipe(4)),
        outAnim("swing", "anim.out.swing", "metronome", ease: AnimEase.inBack, swing),
        outAnim("drop", "anim.out.drop", "arrow.down.circle", ease: AnimEase.inBack, slide(0, 0.8, fade: false)),
        outAnim("pop", "anim.out.pop", "bubble.left", ease: AnimEase.inBack, scale(0, fade: false)),
        outAnim("shake", "anim.out.shake", "iphone.radiowaves.left.and.right", duration: 0.6, ease: AnimEase.linear, shake),
        outAnim("swirl", "anim.out.swirl", "hurricane", swirl),
        outAnim("stretch", "anim.out.stretch", "arrow.left.and.right.square", stretch),
        outAnim("tilt", "anim.out.tilt", SFSymbolCompat.compat("rectangle.portrait.rotate"), tilt),
        outAnim("zoomBlur", "anim.out.zoomBlur", "circle.circle", zoomBlur),
        outAnim("rollOut", "anim.out.rollOut", "arrow.uturn.left.circle", { k, s in roll(k, &s); s.transform.position.x += 1.2 * k }),
        outAnim("flicker", "anim.out.flicker", "lightbulb.slash", ease: AnimEase.linear, flicker),
        outAnim("fold", "anim.out.fold", "rectangle.compress.vertical", ease: AnimEase.inBack, fold),
    ]

    // MARK: Combo (video / image, whole clip)

    static let combos: [AnimationDescriptor] = [
        combo("zoomInOut", "arrow.up.left.and.down.right.magnifyingglass", scale(0.6), scale(0.6)),
        combo("zoomOutIn", "arrow.down.right.and.arrow.up.left", scale(1.6), scale(1.6)),
        combo("rotateInOut", "arrow.triangle.2.circlepath", rotate(-90), rotate(90)),
        combo("slideLeftRight", "arrow.left.arrow.right", slide(-0.4, 0), slide(0.4, 0)),
        combo("slideUpDown", "arrow.up.arrow.down", slide(0, 0.3), slide(0, -0.3)),
        combo("spinInOut", "arrow.clockwise.circle", rotate(-180, scaleTo: 0, fade: false), rotate(180, scaleTo: 0, fade: false)),
        combo("flipInOut", "arrow.left.and.right.righttriangle.left.righttriangle.right", flip(vertical: false), flip(vertical: false)),
        combo("blurInOut", "drop.fill", blur, blur),
        combo("swingInOut", "metronome", swing, swing),
        combo("wipeInOut", "rectangle.split.2x1", wipe(2), wipe(0)),
        combo("popInOut", "bubble.left.and.bubble.right", edge: 0.2, scale(0, fade: false), scale(0, fade: false)),
        combo("kenBurns", "photo.artframe", edge: 0.0001, { _, _ in }, { _, _ in }, hold: { p, s in
            s.transform.scale = s.transform.scale * (1 + 0.18 * AnimEase.inOutCubic(p))
            s.transform.position.x += 0.04 * AnimEase.inOutCubic(p)
        }),
        combo("pushIn", SFSymbolCompat.compat("arrow.down.right.and.arrow.up.left.rectangle"), edge: 0.0001, { _, _ in }, { _, _ in }, hold: { p, s in
            s.transform.scale = s.transform.scale * (1 + 0.15 * p)
        }),
        combo("pullBack", SFSymbolCompat.compat("arrow.up.left.and.arrow.down.right.rectangle"), edge: 0.0001, { _, _ in }, { _, _ in }, hold: { p, s in
            s.transform.scale = s.transform.scale * (1.15 - 0.15 * p)
        }),
        combo("rock", "arrow.left.and.right.circle", edge: 0.0001, { _, _ in }, { _, _ in }, hold: { p, s in
            s.transform.rotation += 4 * sin(p * 2 * .pi * 3)
        }),
    ]

    // MARK: Loop (stickers, text)

    static let loops: [AnimationDescriptor] = [
        // persisted foundation ids (were combos for every target; now sticker/text loops)
        AnimationDescriptor(id: "valse.anim.combo.pulse", phase: .combo, targets: [.sticker, .text], nameKey: "anim.pulse",
                            symbol: "heart", defaultDuration: Time(1)) { p, s in
            s.transform.scale = s.transform.scale * (1 + 0.06 * sin(p * 2 * .pi))
        },
        AnimationDescriptor(id: "valse.anim.combo.swing", phase: .combo, targets: [.sticker, .text], nameKey: "anim.swing",
                            symbol: "metronome", defaultDuration: Time(1.2)) { p, s in
            s.transform.rotation += 8 * sin(p * 2 * .pi)
        },
        // W5
        loop("spin", "arrow.clockwise", duration: 2) { p, s in s.transform.rotation += 360 * p },
        loop("hop", "figure.jumprope", duration: 0.8) { p, s in s.transform.position.y -= 0.06 * abs(sin(p * .pi)) },
        loop("float", "cloud", duration: 2) { p, s in s.transform.position.y += 0.025 * sin(p * 2 * .pi) },
        loop("heartbeat", "heart.fill", duration: 1) { p, s in
            let b = max(0, sin(p * 4 * .pi)) * (p < 0.5 ? 1 : 0.6)
            s.transform.scale = s.transform.scale * (1 + 0.12 * b)
        },
        loop("shake", "iphone.radiowaves.left.and.right", duration: 0.5) { p, s in
            s.transform.position.x += 0.012 * sin(p * 2 * .pi * 3); s.transform.rotation += 3 * sin(p * 2 * .pi * 2)
        },
        loop("wobble", "circle.and.line.horizontal", duration: 1) { p, s in
            let w = sin(p * 2 * .pi)
            s.transform.scale.x *= 1 + 0.08 * w; s.transform.scale.y *= 1 - 0.08 * w
        },
        loop("blink", "eye", duration: 1) { p, s in s.opacity *= p > 0.45 && p < 0.55 ? 0 : 1 },
        loop("breathe", "lungs", duration: 2) { p, s in s.opacity *= 1 - 0.45 * (0.5 - 0.5 * cos(p * 2 * .pi)) },
        loop("jelly", SFSymbolCompat.compat("drop.halffull"), duration: 0.8) { p, s in
            let d = exp(-3 * p) * sin(p * 2 * .pi * 3)
            s.transform.scale.x *= 1 + 0.15 * d; s.transform.scale.y *= 1 - 0.15 * d
        },
        loop("rock", "arrow.left.and.right.circle", duration: 1.5) { p, s in s.transform.rotation += 15 * sin(p * 2 * .pi) },
        loop("zoom", "plus.magnifyingglass", duration: 1.5) { p, s in s.transform.scale = s.transform.scale * (1 + 0.15 * (0.5 - 0.5 * cos(p * 2 * .pi))) },
        loop("orbit", SFSymbolCompat.compat("circle.dotted.circle"), duration: 2) { p, s in
            s.transform.position.x += 0.03 * sin(p * 2 * .pi); s.transform.position.y += 0.03 * (1 - cos(p * 2 * .pi))
        },
        loop("flash", "bolt", duration: 0.6) { p, s in s.opacity *= 0.55 + 0.45 * cos(p * 2 * .pi) },
    ]

    public static let all: [AnimationDescriptor] = ins + outs + combos + loops
}
