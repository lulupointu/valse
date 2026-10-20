import SwiftUI
import MontageCore
import MontageEffects
import Perception

/// Animation ▸ In · Out · Combo (Loop for text/stickers): search, 62 pt tiles that play the animation on hover, None
/// first; clicking applies and previews once in the player; then a Duration slider (UX.md §5.1 Animation, [31]).
/// Content comes from `Registries.animations` (W5).
struct AnimationPickerSection: View {
    let ctx: InspectorContext
    let phase: AnimationPhaseKind

    var target: AnimationTargets {
        switch ctx.kind {
        case .text: return .text
        case .sticker: return .sticker
        default: return .video
        }
    }

    func current(_ c: Clip?) -> AnimationInstance? {
        switch phase {
        case .in: return c?.animations.inAnim
        case .out: return c?.animations.outAnim
        case .combo: return c?.animations.combo
        }
    }

    var body: some View {
        WithPerceptionTracking {
            let ui = InspectorUIState.shared
            let cur = current(ctx.clip)
            let query = ui.animationSearch.trimmingCharacters(in: .whitespaces).lowercased()
            let items = Registries.animations(phase, for: target).filter { query.isEmpty || tr($0.nameKey).lowercased().contains(query) }
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(IStyle.caption)
                    TextField(tr("inspector.animation.search"), text: Binding(get: { ui.animationSearch }, set: { ui.animationSearch = $0 }))
                        .textFieldStyle(.plain).font(.system(size: 12)).testID("anim.search")
                }
                .padding(.horizontal, 10).frame(height: 28)
                .background(IStyle.field, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.08)))
                TileGrid {
                    if query.isEmpty {
                        Tile(title: tr("anim.none"), selected: cur == nil, testID: "anim.none", titleLines: 2) { apply(nil) } content: {
                            Image(systemName: "nosign").font(.system(size: 26, weight: .light)).foregroundStyle(Color(white: 0.75))
                        }
                    }
                    ForEach(items) { d in
                        WithPerceptionTracking {
                            AnimationTile(descriptor: d, selected: cur?.typeID == d.id, subject: target) { apply(d) }
                        }
                    }
                }
                if items.isEmpty && !query.isEmpty { HintText(text: tr("inspector.animation.noResults")) }
                if cur != nil, let clip = ctx.clip {
                    let other: Double = {
                        switch self.phase {
                        case .in: return clip.animations.outAnim?.duration.seconds ?? 0
                        case .out: return clip.animations.inAnim?.duration.seconds ?? 0
                        case .combo: return 0
                        }
                    }()
                    let maxD = max(0.1, clip.duration.seconds - other)
                    let ph = self.phase
                    ClipParamRow(ctx: ctx, label: tr("inspector.duration"), spec: RowSpec(range: 0.1...maxD, step: 0.1, format: Fmt.seconds),
                                 get: { c, _ in current(c)?.duration.seconds ?? 0.5 },
                                 set: { c, v, _ in
                                     switch ph {
                                     case .in: c.animations.inAnim?.duration = Time(v)
                                     case .out: c.animations.outAnim?.duration = Time(v)
                                     case .combo: c.animations.combo?.duration = Time(v)
                                     }
                                 }, gestureName: "cmd.animation")
                }
            }
        }
    }

    func apply(_ d: AnimationDescriptor?) {
        guard let clip = ctx.clip else { return }
        let phase = self.phase
        // Video combos span the whole clip (CapCut default); sticker/text loops repeat with the preset's period.
        let wholeClip = phase == .combo && target == .video
        ctx.store.performInspector(UpdateClip(clip.id, nameKey: "cmd.animation") { c in
            let inst = d.map { AnimationInstance(typeID: $0.id, duration: wholeClip ? c.duration
                                                    : phase == .combo ? min($0.defaultDuration, c.duration)
                                                    : min($0.defaultDuration, c.duration * 0.5)) }
            switch phase {
            case .in: c.animations.inAnim = inst; if inst != nil { c.animations.combo = nil }
            case .out: c.animations.outAnim = inst; if inst != nil { c.animations.combo = nil }
            case .combo: c.animations.combo = inst; if inst != nil { c.animations.inAnim = nil; c.animations.outAnim = nil }
            }
        })
        if let d { preview(clip, d) }
    }

    /// Plays the animated part of the clip once in the player (CapCut previews right after applying).
    func preview(_ clip: Clip, _ d: AnimationDescriptor) {
        let store = ctx.store
        let dur = phase == .combo && target == .video ? clip.duration
            : min(d.defaultDuration, phase == .combo ? clip.duration : clip.duration * 0.5)
        let start = phase == .out ? clip.end - dur : clip.start
        store.seek(to: start)
        if !store.transport.isPlaying { store.togglePlay() }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(dur.seconds, 0.3) + 0.05))
            if store.transport.isPlaying { store.togglePlay() }
        }
    }
}

/// Tile that animates a sample picture with the descriptor's own `apply` while hovered (a cheap, faithful preview).
struct AnimationTile: View {
    let descriptor: AnimationDescriptor
    let selected: Bool
    /// What the tile animates: a sample picture (video), "Abc" (text) or a star (sticker), like CapCut's tiles.
    var subject: AnimationTargets = .video
    let action: () -> Void
    @State private var hover = false
    @State private var start = Date()

    var body: some View {
        WithPerceptionTracking {
            Tile(title: tr(descriptor.nameKey), selected: selected, testID: "anim.\(descriptor.id.replacingOccurrences(of: "montage.anim.", with: ""))", titleLines: 2, action: action) {
              if descriptor.glyph != nil {
                // per-glyph text animation (text engine, W7)
                GlyphAnimationPreview(descriptor: descriptor, playing: hover, start: start)
              } else {
                // CapCut tiles show a sample picture caught mid-animation on black; hover plays the animation.
                SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !hover || TestAnchors.isEnabled)) { tl in
                    WithPerceptionTracking {
                        let state = state(at: tl.date)
                        // one Canvas: transforms, reveal mask, blur and clipping are rasterised together (never overflow the tile)
                        Canvas { ctx, size in
                            let w = size.width, h = size.height
                            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(subject == .video ? .black : Color(hex: 0x262626)))
                            let r = state.reveal
                            ctx.clip(to: Path(CGRect(x: w * r.left, y: h * r.top, width: w * max(0, 1 - r.left - r.right),
                                                     height: h * max(0, 1 - r.top - r.bottom))))
                            ctx.opacity = state.opacity
                            if state.blur > 0 { ctx.addFilter(.blur(radius: state.blur * w)) }
                            ctx.translateBy(x: w / 2 + state.transform.position.x * w, y: h / 2 + state.transform.position.y * h)
                            ctx.rotate(by: .degrees(state.transform.rotation))
                            ctx.scaleBy(x: state.transform.scale.x, y: state.transform.scale.y)
                            ctx.translateBy(x: -w / 2, y: -h / 2)
                            switch subject {
                            case .text:
                                ctx.draw(Text(verbatim: "Abc").font(.system(size: h * 0.32, weight: .bold)).foregroundColor(.white), at: CGPoint(x: w / 2, y: h / 2))
                            case .sticker:
                                ctx.draw(Text(verbatim: "⭐️").font(.system(size: h * 0.46)), at: CGPoint(x: w / 2, y: h / 2))
                            default:
                                AnimationSampleScene.draw(in: &ctx, size: size)
                            }
                        }
                    }
                }
              }
            }
            .onHover { h in hover = h; if h { start = Date() } }
        }
    }

    /// Hover loops the animation (with a short hold at the end); idle shows the clip's resting state.
    func state(at date: Date) -> AnimatedLayerState {
        var s = AnimatedLayerState(transform: Transform(), opacity: 1)
        guard hover else {
            // still: the animation caught part-way, so tiles read differently at rest (like CapCut's stills)
            descriptor.apply(descriptor.phase == .out ? 0.65 : (descriptor.phase == .combo ? (subject == .video ? 0.08 : 0.3) : 0.35), &s)
            return s
        }
        let d = max(descriptor.defaultDuration.seconds, 0.3)
        let cycle = d + 0.4
        // UI tests: the hovered tile (the one just clicked) holds the end pose instead of playing, so snapshots don't
        // depend on how long the step took (w5_animation_apply was 1 % off under load)
        let t = TestAnchors.isEnabled ? d : date.timeIntervalSince(start).truncatingRemainder(dividingBy: cycle)
        let p = min(t / d, 1)
        descriptor.apply(descriptor.phase == .combo ? (t / d).truncatingRemainder(dividingBy: 1) : p, &s)
        return s
    }
}

/// Small vector landscape (sky, sun, hills, lake) used as the animated subject of animation tiles: no assets, crisp at
/// any size, and its asymmetric layout makes slides / flips / rotations readable.
enum AnimationSampleScene {
    static func draw(in ctx: inout GraphicsContext, size: CGSize) {
        let w = size.width, h = size.height
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .linearGradient(Gradient(colors: [Color(hex: 0x3E7CB1), Color(hex: 0xF2A65A)]),
                                       startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
        ctx.fill(Path(ellipseIn: CGRect(x: w * 0.62, y: h * 0.16, width: w * 0.24, height: w * 0.24)), with: .color(Color(hex: 0xFFE08A)))
        var hills = Path()
        hills.move(to: CGPoint(x: 0, y: h * 0.72)); hills.addLine(to: CGPoint(x: w * 0.3, y: h * 0.42))
        hills.addLine(to: CGPoint(x: w * 0.55, y: h * 0.66)); hills.addLine(to: CGPoint(x: w * 0.78, y: h * 0.48))
        hills.addLine(to: CGPoint(x: w, y: h * 0.7)); hills.addLine(to: CGPoint(x: w, y: h)); hills.addLine(to: CGPoint(x: 0, y: h))
        hills.closeSubpath()
        ctx.fill(hills, with: .color(Color(hex: 0x4B3F72)))
        ctx.fill(Path(CGRect(x: 0, y: h * 0.8, width: w, height: h * 0.2)), with: .color(Color(hex: 0x2A9D8F)))
    }
}
